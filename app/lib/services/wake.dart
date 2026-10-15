import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart' show validWake;
import 'undelivered.dart';

/// Push wake-up (see `docs/CONNECTIVITY.md`): a friend's device that has a
/// message for this phone asks a push server to wake it through Firebase
/// Cloud Messaging, and the phone then syncs as a background run does. Wakes
/// carry nothing; messages still travel directly between friends.
///
/// Each friend device gets its own wake token, derived from a key kept in
/// this profile. The server holds only hashes of the tokens this device
/// granted, so only current friends can wake it, and one can be cut off
/// without the others. The server is OurNetPushServer.

/// OurNet's own push server.
const defaultWakeServer = 'https://push.chozabu.net';

/// How often a registration is renewed, so the server keeps it.
const _renewAfter = Duration(days: 7);

/// The FCM side on Android (`PushWake.kt`).
class FcmChannel {
  static const _channel = MethodChannel('ournet/push');

  /// This device's FCM registration token. Null off Android and in builds
  /// without a Firebase configuration (`res/values/firebase.xml`).
  static Future<String?> token() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('token');
    } on MissingPluginException {
      return null;
    }
  }

  /// Turns FCM on or off; off also deletes this device's token.
  static Future<void> setEnabled(bool on) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('enable', on);
    } on MissingPluginException {
      // Not in this build.
    }
  }

  /// Calls [onToken] when FCM replaces this device's token.
  static void listen(void Function(String token) onToken) {
    if (!Platform.isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'token' && call.arguments is String) {
        onToken(call.arguments as String);
      }
    });
  }
}

String _b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

String _random(int bytes) {
  final random = Random.secure();
  return _b64(List.generate(bytes, (_) => random.nextInt(256)));
}

String _wakeToken(Json registration, String device) => _b64(
  Hmac(
    sha256,
    base64Url.decode(base64Url.normalize(registration['key'] as String)),
  ).convert(utf8.encode('ournet-wake/1|$device')).bytes,
);

Json? _registration(Node node) =>
    switch (node.store.setting('wakeRegistration')) {
      final Json r
          when r['url'] is String &&
              r['device'] is String &&
              r['secret'] is String &&
              r['key'] is String =>
        r,
      _ => null,
    };

/// This device's wake address for [device], told to it in each exchange:
/// the push server, this device's ID there, and [device]'s own token. Null
/// when push wake-up is off or not registered, or [device] may not wake
/// this one. Every network on this profile tells it (see `Network`), since
/// an exchange without one makes the peer forget it.
Json? wakeAddressFor(Node node, String device) {
  final r = _registration(node);
  if (r == null ||
      node.store.setting('pushWake') == false ||
      device == node.identity.device ||
      !node.allowedPeer(device)) {
    return null;
  }
  return {
    'url': r['url'],
    'device': r['device'],
    'token': _wakeToken(r, device),
  };
}

/// This device's registration with a push server, and the wake tokens it
/// grants its friends' devices.
class WakeRegistration {
  final Node node;

  /// The FCM token, read once and then kept up to date by [tokenChanged].
  final Future<String?> Function() fcmToken;
  final http.Client client;
  final void Function(String)? onError;

  WakeRegistration(
    this.node, {
    this.fcmToken = FcmChannel.token,
    http.Client? client,
    this.onError,
  }) : client = client ?? http.Client();

  StreamSubscription<void>? _changes;
  Timer? _timer;
  Future<void>? _refreshing;
  bool _again = false;
  String? _fcm;

  /// Whether this device wakes through a push server (on by default).
  bool get enabled => node.store.setting('pushWake') != false;

  String get server => switch (node.store.setting('wakeServer')) {
    final String url when url.isNotEmpty => url,
    _ => defaultWakeServer,
  };

  /// `{url, device, secret, key, fcm, renewed}`: the server's URL, this
  /// device's ID and admin secret there, the key wake tokens are derived
  /// from, the FCM token it holds, and when it was last registered.
  Json? get registration => _registration(node);

  /// Whether friends can wake this device now.
  bool get registered =>
      registration != null && node.store.setting('wakeGranted') != null;

  void start() {
    _changes = node.changes.stream.listen((_) => _schedule());
    unawaited(refresh());
  }

  /// FCM replaced this device's token.
  void tokenChanged(String token) {
    _fcm = token;
    unawaited(refresh());
  }

  // Contacts change rarely; coalesce the store's frequent changes.
  void _schedule() => _timer ??= Timer(const Duration(seconds: 5), () {
    _timer = null;
    unawaited(refresh());
  });

  /// The devices that may wake this one: admitted, not revoked or blocked.
  List<String> get _allowed => [
    for (final device in node.contacts.keys)
      if (device != node.identity.device && node.allowedPeer(device)) device,
  ]..sort();

  /// The wake address told to [device] in each exchange, or null.
  Json? addressFor(String device) => wakeAddressFor(node, device);

  /// Brings the registration and grants up to date; runs one at a time.
  Future<void> refresh() async {
    if (_refreshing != null) {
      _again = true;
      return _refreshing;
    }
    _refreshing = () async {
      try {
        do {
          _again = false;
          await _refresh();
        } while (_again);
      } catch (e) {
        onError?.call('Push wake-up: $e');
      } finally {
        _refreshing = null;
      }
    }();
    return _refreshing;
  }

  Future<Json> _post(String url, String path, Json body) async {
    final response = await client
        .post(
          Uri.parse('$url$path'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 20));
    final Object? reply;
    try {
      reply = jsonDecode(response.body);
    } on FormatException {
      throw HttpException('Push server answered ${response.statusCode}');
    }
    if (response.statusCode >= 300) {
      throw WakeRefused(
        response.statusCode,
        reply is Map ? '${reply['error']}' : '',
      );
    }
    return reply is Json ? reply : {};
  }

  Future<void> _refresh() async {
    var r = registration;
    if (!enabled) {
      if (r != null) {
        node.store.set('wakeRegistration', null);
        node.store.set('wakeGranted', null);
        try {
          await _post(r['url'] as String, '/v1/unregister', {
            'device': r['device'],
            'secret': r['secret'],
          });
        } catch (_) {
          // Forgotten by the server after a while anyway.
        }
        await FcmChannel.setEnabled(false);
        _fcm = null;
      }
      return;
    }
    final fcm = _fcm ??= await fcmToken();
    if (fcm == null) return;
    final url = server;
    if (r != null && r['url'] != url) {
      node.store.set('wakeRegistration', null);
      node.store.set('wakeGranted', null);
      r = null;
    }
    final renewed = r?['renewed'] is int
        ? DateTime.fromMillisecondsSinceEpoch(r!['renewed'] as int)
        : DateTime(2000);
    if (r != null &&
        (r['fcm'] != fcm || DateTime.now().difference(renewed) > _renewAfter)) {
      try {
        await _post(url, '/v1/register', {
          'fcm': fcm,
          'device': r['device'],
          'secret': r['secret'],
        });
        r = {
          ...r,
          'fcm': fcm,
          'renewed': DateTime.now().millisecondsSinceEpoch,
        };
        node.store.set('wakeRegistration', r);
      } on WakeRefused catch (e) {
        // Forgotten by the server: start again.
        if (e.status != 404 && e.status != 403) rethrow;
        r = null;
      }
    }
    if (r == null) {
      final reply = await _post(url, '/v1/register', {'fcm': fcm});
      if (reply['device'] is! String || reply['secret'] is! String) {
        throw const HttpException('Push server gave no registration');
      }
      r = {
        'url': url,
        'device': reply['device'],
        'secret': reply['secret'],
        'key': _random(32),
        'fcm': fcm,
        'renewed': DateTime.now().millisecondsSinceEpoch,
      };
      node.store.set('wakeRegistration', r);
      node.store.set('wakeGranted', null);
    }
    final hashes = [
      for (final device in _allowed)
        sha256.convert(utf8.encode(_wakeToken(r, device))).toString(),
    ]..sort();
    final digest = sha256
        .convert(utf8.encode('${r['device']}|${hashes.join(',')}'))
        .toString();
    if (node.store.setting('wakeGranted') == digest) return;
    await _post(url, '/v1/grants', {
      'device': r['device'],
      'secret': r['secret'],
      'replace': hashes,
    });
    node.store.set('wakeGranted', digest);
  }

  void close() {
    _changes?.cancel();
    _timer?.cancel();
  }
}

/// The push server refused a request.
class WakeRefused implements Exception {
  final int status;
  final String message;
  const WakeRefused(this.status, this.message);
  @override
  String toString() => 'Push server refused ($status): $message';
}

/// Wakes friends' devices that have not acknowledged this person's recent
/// private messages a few seconds after they were written, through the
/// wake address each device told this one.
class WakeSender {
  final Node node;
  final Undelivered undelivered;
  final http.Client client;
  final void Function(String)? onError;

  /// How long a direct sync gets before a wake is sent instead.
  final Duration grace;

  WakeSender(
    this.node,
    this.undelivered, {
    http.Client? client,
    this.onError,
    this.grace = const Duration(seconds: 4),
  }) : client = client ?? http.Client();

  /// Of the waiting messages, those a wake was already sent for.
  final _woken = <String, Set<String>>{};
  Timer? _timer;
  Future<void>? _sending;

  void start() => undelivered.onWaiting = () => _schedule(grace);

  void _schedule(Duration delay) => _timer ??= Timer(delay, () {
    _timer = null;
    unawaited(_send());
  });

  Future<void> _send() async {
    if (_sending case final sending?) return sending;
    final sending = _sending = _wake();
    try {
      await sending;
    } finally {
      _sending = null;
    }
  }

  Future<void> _wake() async {
    final waiting = undelivered.waiting;
    _woken.removeWhere((device, ids) {
      ids.removeWhere((id) => waiting[device]?.containsKey(id) != true);
      return ids.isEmpty;
    });
    final due = DateTime.now().subtract(grace);
    for (final MapEntry(key: device, value: ids) in waiting.entries.toList()) {
      final address = node.store.setting('wake/$device');
      if (address is! Json || !validWake(address)) continue;
      final woken = _woken[device] ??= {};
      final fresh = [
        for (final MapEntry(key: id, value: seen) in ids.entries)
          if (!woken.contains(id)) (id, seen),
      ];
      final ready = [
        for (final (id, seen) in fresh)
          if (!seen.isAfter(due)) id,
      ];
      if (ready.length < fresh.length) _schedule(grace);
      if (ready.isEmpty) continue;
      final label = node.contacts[device]?.label ?? 'a device';
      try {
        final response = await client
            .post(
              Uri.parse('${address['url']}/v1/wake'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'device': address['device'],
                'token': address['token'],
              }),
            )
            .timeout(const Duration(seconds: 20));
        switch (response.statusCode) {
          case 202 || 200:
            woken.addAll(ready);
          case 410:
            // That device no longer wakes through this address.
            node.store.set('wake/$device', null);
          case 429:
            final retry = switch (jsonDecode(response.body)) {
              {'retry': final int seconds} => seconds,
              _ => 60,
            };
            _schedule(Duration(seconds: retry.clamp(1, 600)));
          default:
            // Not allowed (not granted yet), or malformed: no retrying.
            woken.addAll(ready);
            onError?.call('Wake for $label refused (${response.statusCode})');
        }
      } catch (e) {
        onError?.call('Wake for $label: $e');
        _schedule(const Duration(minutes: 1));
      }
    }
  }

  Future<void> close() async {
    undelivered.onWaiting = null;
    _timer?.cancel();
    await _sending;
  }
}
