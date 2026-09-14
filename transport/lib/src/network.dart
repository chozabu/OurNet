import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:iroh_quic/iroh_quic.dart' as iroh;
import 'package:ournet_core/ournet_core.dart';

part 'pairing.dart';
part 'friend_invitation.dart';

/// The only application module that knows the iroh API. Protocol and policy
/// remain in the Dart core. Connections authenticate independent device keys.
class PeerNetwork {
  PairingSession? pairing;
  FriendSession? friendInvitation;
  final Node node;
  final updates = StreamController<void>.broadcast();
  void notifyListeners() {
    if (!updates.isClosed) updates.add(null);
  }

  PeerNetwork(this.node);
  iroh.Endpoint? _endpoint;
  StreamSubscription<void>? _changes;
  Timer? _debounce;
  final Map<String, Timer> _retry = {};
  final Map<String, int> _failures = {};
  final Set<String> _busy = {};
  final Set<iroh.Connection> _connections = {};
  final Set<Future<void>> _jobs = {};
  final Map<String, DateTime> lastSync = {};
  final Map<String, int> _progress = {};

  /// Fires as syncs start, exchange pages and finish. Kept separate from
  /// [updates] so progress only rebuilds widgets that show it.
  final syncActivity = StreamController<void>.broadcast();

  /// Devices with a sync in progress, mapped to items exchanged so far.
  Map<String, int> get syncing => Map.unmodifiable(_progress);
  void _activity() {
    if (!syncActivity.isClosed) syncActivity.add(null);
  }

  final List<String> events = [];
  bool get running => _endpoint != null;
  String? error;
  int _activeInbound = 0;
  Future<Json> Function(String, Json)? signal;
  static final _alpn = utf8.encode('ournet/2');

  void log(String message) {
    events.insert(0, '${DateTime.now().toIso8601String()} $message');
    if (events.length > 100) events.removeLast();
    notifyListeners();
  }

  Future<void> start({bool local = false, bool automatic = true}) async {
    if (running) return;
    try {
      await iroh.Iroh.init();
      _endpoint = await iroh.Endpoint.bind(
        secretKey: iroh.SecretKey.fromBytes(
          await node.identity.deviceKey.extractPrivateKeyBytes(),
        ),
        alpns: [_alpn],
        relayMode: local ? iroh.RelayMode.disabled : iroh.RelayMode.n0Default,
      );
      error = null;
      if (automatic)
        _changes = node.changes.stream.listen((_) {
          _debounce?.cancel();
          _debounce = Timer(const Duration(milliseconds: 400), syncAll);
        });
      unawaited(_accept());
      log(local ? 'Local network started' : 'Network started');
      if (automatic) unawaited(syncAll());
    } catch (e) {
      error = '$e';
      log('Network unavailable: $e');
      rethrow;
    }
  }

  String contactCard() => canonical({
    'version': 2,
    'certificate': node.identity.certificate.toJson(),
    'address': _endpoint == null ? null : b64(_endpoint!.addr.encode()),
  });
  Future<void> addCard(String card) async {
    if (card.length > 16384) throw StateError('Contact card too large');
    final j = jsonDecode(card) as Json;
    if (j['version'] != 2) throw StateError('Unsupported contact card');
    final certificate = DeviceCertificate.fromJson(j['certificate']);
    if (j['address'] != null) {
      await iroh.Iroh.init();
      final address = iroh.EndpointAddr.decode(unb64(j['address']));
      if (b64(address.id.asBytes()) != certificate.device) {
        throw StateError('Address does not match device');
      }
    }
    await node.addContact(certificate);
    if (j['address'] != null) {
      node.store.set('address/${certificate.device}', j['address']);
    }
    log('Contact device added: ${certificate.label}');
  }

  Future<iroh.Connection> _connect(String device) async {
    if (!node.allowedPeer(device)) throw StateError('Device not admitted');
    final ep = _endpoint;
    if (ep == null) throw StateError('Network is stopped');
    final encoded = node.store.setting('address/$device') as String?;
    final address = encoded == null
        ? iroh.EndpointAddr(iroh.PublicKey.fromBytes(unb64(device)))
        : iroh.EndpointAddr.decode(unb64(encoded));
    var abandoned = false;
    final pending = ep.connect(address, _alpn).then((connection) {
      if (abandoned || !identical(ep, _endpoint)) {
        connection.close();
        throw StateError('Connection cancelled');
      }
      return connection;
    });
    try {
      return await pending.timeout(const Duration(seconds: 15));
    } catch (_) {
      abandoned = true;
      rethrow;
    }
  }

  Future<Json> request(String device, Json request) async {
    final connection = await _connect(device);
    _connections.add(connection);
    try {
      final (send, recv) = await connection.openBi();
      await send.writeAll(bytes(request));
      await send.finish();
      final data = await recv
          .readToEnd(3 * 1024 * 1024)
          .timeout(const Duration(seconds: 20));
      final reply = jsonDecode(utf8.decode(data)) as Json;
      if (reply['error'] != null) throw StateError(reply['error']);
      return reply;
    } finally {
      connection.close();
      _connections.remove(connection);
    }
  }

  Future<void> sync(String device) {
    final job = _sync(device);
    _jobs.add(job);
    return job.whenComplete(() => _jobs.remove(job));
  }

  Future<void> _sync(String device) async {
    if (!running || !node.allowedPeer(device) || !_busy.add(device)) return;
    _progress[device] = 0;
    _activity();
    try {
      // Bounded work per session; subsequent changes or manual sync resume it.
      var exhausted = true;
      for (var page = 0; page < 16; page++) {
        final reply = await request(device, {
          'type': 'pull',
          'inventory': node.inventory(peerDevice: device),
        });
        final incoming = await node.receive(device, reply['items']);
        final outgoing = await node.offer(device, reply['inventory']);
        final pushed = await request(device, {
          'type': 'push',
          'items': outgoing,
        });
        _progress[device] = _progress[device]! + incoming + outgoing.length;
        _activity();
        if (incoming == 0 && outgoing.isEmpty && pushed['changed'] == 0) {
          exhausted = false;
          break;
        }
      }
      lastSync[device] = DateTime.now();
      _failures.remove(device);
      _retry.remove(device)?.cancel();
      if (exhausted && running) {
        _retry[device] = Timer(const Duration(seconds: 1), () => sync(device));
      }
      log('Synced ${node.contacts[device]?.label ?? device}');
    } catch (e) {
      final failures = (_failures[device] ?? 0) + 1;
      _failures[device] = failures;
      _retry.remove(device)?.cancel();
      final seconds = (15 * (1 << failures.clamp(0, 6))).clamp(30, 900);
      if (running) {
        _retry[device] = Timer(Duration(seconds: seconds), () => sync(device));
      }
      log('Sync delayed: $e');
    } finally {
      _busy.remove(device);
      _progress.remove(device);
      _activity();
    }
  }

  Future<void> syncAll() async {
    final devices = node.contacts.keys.toList();
    var next = 0;
    Future<void> worker() async {
      while (running && next < devices.length) {
        await sync(devices[next++]);
      }
    }

    await Future.wait([worker(), worker()]);
  }

  Future<void> _accept() async {
    final endpoint = _endpoint!;
    while (identical(_endpoint, endpoint)) {
      try {
        final connection = await endpoint.accept();
        if (connection == null) break;
        final peer = b64(connection.remoteId.asBytes());
        if ((!node.allowedPeer(peer) &&
                pairing?.available != true &&
                friendInvitation?.available != true) ||
            _activeInbound >= 4) {
          connection.close();
          continue;
        }
        _activeInbound++;
        _connections.add(connection);
        final job = _serve(connection, peer);
        _jobs.add(job);
        unawaited(
          job.whenComplete(() {
            _activeInbound--;
            _connections.remove(connection);
            _jobs.remove(job);
          }),
        );
      } catch (e) {
        if (running) log('Accept failed: $e');
        break;
      }
    }
  }

  Future<void> _serve(iroh.Connection connection, String peer) async {
    try {
      final (send, recv) = await connection.acceptBi().timeout(
        const Duration(seconds: 10),
      );
      final raw = await recv
          .readToEnd(2 * 1024 * 1024)
          .timeout(const Duration(seconds: 20));
      final j = jsonDecode(utf8.decode(raw)) as Json;
      Json reply;
      if (j['type'] == 'friend') {
        if (friendInvitation == null)
          throw StateError('Invitation unavailable');
        reply = await friendInvitation!.approve(peer, j);
      } else if (j['type'] == 'pair') {
        reply = await pairing!.approve(peer, j);
      } else {
        if (!node.allowedPeer(peer)) throw StateError('Device not admitted');
        switch (j['type']) {
          case 'pull':
            reply = {
              'items': await node.offer(peer, j['inventory']),
              'inventory': node.inventory(peerDevice: peer),
            };
          case 'push':
            reply = {'changed': await node.receive(peer, j['items'])};
          case 'blob':
            // Require a referenced object that this peer is allowed to receive.
            final o = node.store.get(j['object']);
            if (o == null ||
                !node.canOffer(o, node.contacts[peer]!, {o.space})) {
              throw StateError('File not shared with peer');
            }
            final payload = await node.content(o);
            if (payload == null ||
                !(payload['chunks'] as List? ?? []).contains(j['hash'])) {
              throw StateError('Unknown file chunk');
            }
            final blob = node.store.blob(j['hash']);
            reply = {'bytes': blob == null ? null : b64(blob)};
          case 'signal':
            if (signal == null) throw StateError('Calling unavailable');
            reply = await signal!(peer, j['payload']);
          default:
            throw StateError('Unknown request');
        }
      }
      await send.writeAll(bytes(reply));
      await send.finish();
      // Give QUIC the opportunity to deliver the reply before closing.
      await connection.closed().timeout(
        const Duration(seconds: 3),
        onTimeout: () => 'done',
      );
    } catch (e) {
      log('Rejected request: $e');
    } finally {
      connection.close();
    }
  }

  Future<void> stop() async {
    pairing?.close();
    friendInvitation?.close();
    final endpoint = _endpoint;
    _endpoint = null;
    await _changes?.cancel();
    _changes = null;
    _debounce?.cancel();
    for (final timer in _retry.values) {
      timer.cancel();
    }
    _retry.clear();
    for (final connection in _connections.toList()) {
      connection.close();
    }
    await endpoint?.close();
    await Future.wait(_jobs.toList());
    notifyListeners();
  }
}
