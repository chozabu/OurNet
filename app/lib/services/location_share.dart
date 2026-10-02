import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';

/// Whether this device may read its own position.
enum LocationAccess {
  granted,
  denied,
  deniedForever,
  serviceOff,
  unsupported,
}

/// Where this device's own position comes from; replaced in tests.
abstract class PositionSource {
  Future<LocationAccess> access({bool request = false});

  /// Fixes as the device moves.
  Stream<Fix> fixes();

  /// One fix now, for when the device has been still for a while.
  Future<Fix?> now();
}

class DevicePositionSource implements PositionSource {
  const DevicePositionSource();

  /// Phones and PCs with a location service; the app is only built for these.
  static bool get supported => Platform.isAndroid || Platform.isWindows;

  @override
  Future<LocationAccess> access({bool request = false}) async {
    if (!supported) return LocationAccess.unsupported;
    try {
      if (!await geo.Geolocator.isLocationServiceEnabled()) {
        return LocationAccess.serviceOff;
      }
      var permission = await geo.Geolocator.checkPermission();
      if (permission == geo.LocationPermission.denied && request) {
        permission = await geo.Geolocator.requestPermission();
      }
      return switch (permission) {
        geo.LocationPermission.always ||
        geo.LocationPermission.whileInUse => LocationAccess.granted,
        geo.LocationPermission.deniedForever => LocationAccess.deniedForever,
        _ => LocationAccess.denied,
      };
    } catch (_) {
      return LocationAccess.unsupported;
    }
  }

  static Fix _fix(geo.Position p) => Fix(
    lat: p.latitude,
    lng: p.longitude,
    at: p.timestamp.millisecondsSinceEpoch,
    accuracy: p.accuracy.isFinite && p.accuracy >= 0 ? p.accuracy : null,
    heading: p.heading.isFinite && p.heading >= 0 && p.heading <= 360
        ? p.heading
        : null,
    speed: p.speed.isFinite && p.speed >= 0 ? p.speed : null,
  );

  @override
  Stream<Fix> fixes() => geo.Geolocator.getPositionStream(
    locationSettings: Platform.isAndroid
        ? geo.AndroidSettings(
            accuracy: geo.LocationAccuracy.high,
            distanceFilter: 15,
            intervalDuration: const Duration(seconds: 20),
          )
        : const geo.LocationSettings(
            accuracy: geo.LocationAccuracy.high,
            distanceFilter: 15,
          ),
  ).map(_fix);

  @override
  Future<Fix?> now() async {
    try {
      return _fix(
        await geo.Geolocator.getCurrentPosition(
          locationSettings: const geo.LocationSettings(
            accuracy: geo.LocationAccuracy.medium,
            timeLimit: Duration(seconds: 30),
          ),
        ),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Live location sharing: this device's position goes to every friend's
/// devices and to this person's other devices as it changes, and theirs come
/// in the same way. Nothing is kept but each person's last known position
/// (see [Locations]): no trail, no history, and a position does not expire.
///
/// Positions are sent only to devices heard from recently, which keeps a
/// walk across town from dialling every sleeping phone. A device that comes
/// back is sent the last position when it next syncs.
class LocationShare extends ChangeNotifier {
  final PeerNetwork network;
  final PositionSource source;

  /// Movement that is worth telling people about, and how often a still
  /// device confirms it is still there.
  static const minMove = 20.0;
  static const heartbeat = Duration(minutes: 15);

  /// Devices are sent to only if heard from within this long.
  static const recent = Duration(minutes: 10);

  /// Called when this device starts reading its position, so the Android
  /// service that keeps the app running can take on the location type.
  final void Function()? onReading;

  /// The least time between two positions sent to one device. A move inside
  /// it is sent when it is over, so the last place always arrives.
  final Duration minGap;

  LocationShare(
    this.network, {
    this.source = const DevicePositionSource(),
    this.onReading,
    this.minGap = const Duration(seconds: 5),
  }) {
    network.position = _received;
    network.peerSeen = _seen;
  }

  Node get node => network.node;
  Locations get locations => node.locations;

  LocationAccess access = LocationAccess.denied;

  /// This device's latest fix, which feeds the blue dot even when sharing is off.
  Fix? own;
  Fix? _sent;
  StreamSubscription<Fix>? _stream;
  Timer? _heartbeat;
  final _lastTo = <String, DateTime>{};
  final _refused = <String>{};
  final _later = <String, Timer>{};
  bool _disposed = false;

  /// Opens the system page where location permission is granted.
  Future<void> openSystemSettings() async {
    try {
      await geo.Geolocator.openAppSettings();
    } catch (_) {}
  }

  bool get sharing => locations.sharing;
  bool get active => _stream != null;

  /// Starts reading this device's position when allowed. [request] shows the
  /// system permission prompt; without it a missing permission is only noted.
  Future<void> start({bool request = false}) async {
    if (_disposed || _stream != null) return;
    access = await source.access(request: request);
    notifyListeners();
    if (access != LocationAccess.granted || _disposed) return;
    _stream = source.fixes().listen(_moved, onError: (Object _) => _stopped());
    _resetHeartbeat();
    onReading?.call();
    notifyListeners();
  }

  void _stopped() {
    _stream?.cancel();
    _stream = null;
    _heartbeat?.cancel();
    notifyListeners();
  }

  Future<void> stop() async {
    await _stream?.cancel();
    _stream = null;
    _heartbeat?.cancel();
    notifyListeners();
  }

  /// Turns sharing on or off. Off stops sending only: this device's own dot
  /// and what friends share stay.
  Future<void> setSharing(bool value, {bool request = true}) async {
    locations.sharing = value;
    notifyListeners();
    if (value) {
      if (_stream == null) await start(request: request);
      final fix = own;
      if (fix != null) _broadcast(fix, force: true);
    }
  }

  void _resetHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(heartbeat, (_) async {
      if (_stream == null) return;
      final last = own;
      if (last != null &&
          DateTime.now().millisecondsSinceEpoch - last.at < heartbeat.inMilliseconds) {
        return;
      }
      final fix = await source.now();
      if (fix != null) _moved(fix, heartbeat: true);
    });
  }

  void _moved(Fix fix, {bool heartbeat = false}) {
    if (_disposed) return;
    own = fix;
    final sent = _sent;
    final far = sent == null || fix.distanceTo(sent.lat, sent.lng) >= minMove;
    if (sharing && (far || heartbeat)) {
      _sent = fix;
      _broadcast(fix);
    }
    // Kept as this person's last known place too, so their other devices'
    // maps and the next start have it. Pausing stops only the sending.
    locations.update(node.person, _labelled(fix, node.identity.certificate.label));
    notifyListeners();
  }

  Fix _labelled(Fix f, String label) => Fix(
    lat: f.lat,
    lng: f.lng,
    at: f.at,
    accuracy: f.accuracy,
    heading: f.heading,
    speed: f.speed,
    device: label,
  );

  void _broadcast(Fix fix, {bool force = false}) {
    if (!network.running) return;
    for (final device in node.contacts.keys.toList()) {
      _send(device, fix, force: force);
    }
  }

  void _send(String device, Fix fix, {bool force = false}) {
    if (device == node.identity.device ||
        _refused.contains(device) ||
        !node.allowedPeer(device) ||
        !sharing) {
      return;
    }
    final now = DateTime.now();
    final heard = [
      network.lastInbound[device],
      network.lastSync[device],
    ].whereType<DateTime>().fold<DateTime?>(
      null,
      (a, b) => a == null || b.isAfter(a) ? b : a,
    );
    if (!force && (heard == null || now.difference(heard) > recent)) return;
    final last = _lastTo[device];
    if (!force && last != null && now.difference(last) < minGap) {
      _later[device] ??= Timer(minGap - now.difference(last), () {
        _later.remove(device);
        final latest = _sent;
        if (latest != null && !_disposed) _send(device, latest);
      });
      return;
    }
    _lastTo[device] = now;
    unawaited(
      network
          .request(device, {
            'type': 'position',
            'fix': fix.toJson(),
          })
          .then<void>(
            (_) {},
            onError: (Object e) {
              if ('$e'.contains('Unknown request')) _refused.add(device);
            },
          ),
    );
  }

  /// A device has just synced with this one: tell it where this person is.
  void _seen(String device) {
    final fix = own ?? locations.of(node.person);
    if (fix == null || !sharing) return;
    _send(device, fix, force: true);
  }

  void _received(String device, Object? raw) {
    final contact = node.contacts[device];
    if (contact == null) return;
    final fix = Fix.parse(
      raw,
      now: DateTime.now().millisecondsSinceEpoch,
      device: contact.label,
    );
    if (fix != null) locations.update(contact.person, fix);
  }

  @override
  void dispose() {
    _disposed = true;
    _stream?.cancel();
    _heartbeat?.cancel();
    for (final timer in _later.values) {
      timer.cancel();
    }
    if (network.position == _received) network.position = null;
    if (network.peerSeen == _seen) network.peerSeen = null;
    super.dispose();
  }
}
