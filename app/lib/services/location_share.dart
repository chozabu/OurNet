import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' show min;
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

/// Live location sharing: this device's position goes to this person's other
/// devices as it changes, and to friends' devices when this is the person's
/// primary device; theirs come in the same way. Nothing is kept but each
/// person's last known position, and each of this person's own devices' (see
/// [Locations]): no trail, no history, and a position does not expire.
///
/// A person has one primary device, which syncs between their devices
/// (`NoteState.locationPrimary`) and is the only one that tells friends where
/// they are, so a laptop left at home never overrides the phone in a pocket.
/// While none has been chosen every device does, as before; a phone that
/// finds none after syncing with its sibling devices claims it once.
///
/// A device that does not answer is tried again after a back-off that grows
/// to [maxBackoff], with the latest place, until one reaches it; so a walk
/// across town does not keep dialling a friend whose phone is off, and a
/// friend out of signal still hears within minutes of coming back. A device
/// that syncs with this one is sent the current place at once.
class LocationShare extends ChangeNotifier {
  final PeerNetwork network;
  final PositionSource source;

  /// Where the primary device is kept; null in tests of a single device.
  final NoteState? state;

  /// Whether this device is a phone, which may claim to be primary once.
  final bool phone;

  /// Movement that is worth telling people about, and how often a still
  /// device confirms it is still there.
  static const minMove = 20.0;
  static const heartbeat = Duration(minutes: 15);

  /// How long to wait before trying again a device that did not answer,
  /// doubling with each failure up to [maxBackoff].
  static const firstBackoff = Duration(seconds: 30);
  static const maxBackoff = Duration(minutes: 15);
  static const maxRetries = 8;

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
    this.state,
    bool? phone,
  }) : phone = phone ?? (!kIsWeb && Platform.isAndroid) {
    network.position = _received;
    network.peerSeen = _seen;
    if (state != null) {
      _updates = network.updates.stream.listen((_) {
        _primaryCheck?.cancel();
        _primaryCheck = Timer(const Duration(seconds: 2), () {
          unawaited(refreshPrimary());
        });
      });
    }
  }

  Node get node => network.node;
  Locations get locations => node.locations;

  StreamSubscription<void>? _updates;
  Timer? _primaryCheck;
  Future<void>? _refreshingPrimary;
  String? _primary;
  bool _primaryKnown = false;

  /// The device that tells friends where this person is, or null when none
  /// has been chosen (or the one chosen has been removed).
  String? get primary => _primary;
  bool get isPrimary => _primary == node.identity.device;

  /// Whether this device sends its position to friends: sharing is not
  /// paused, and this is the primary device (or none is chosen). Until the
  /// primary is known this stays quiet, so a laptop starting up does not
  /// announce itself before it has heard that the phone is the primary.
  bool get sendsToFriends =>
      sharing && (state == null || _primaryKnown) && (_primary == null || isPrimary);

  /// Whether this device tells this person's other devices where it is.
  bool get sendsToOwnDevices => locations.showToOwnDevices;

  /// Whether this device should be reading its position at all.
  bool get wanted => sendsToFriends || sendsToOwnDevices;

  /// This person's other devices that are still admitted.
  List<DeviceCertificate> get otherDevices => [
    for (final c in node.contacts.values)
      if (c.person == node.person &&
          c.device != node.identity.device &&
          node.allowedPeer(c.device))
        c,
  ]..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));

  bool _mine(String device) =>
      device == node.identity.device ||
      node.contacts[device]?.person == node.person &&
          !node.revoked.contains(device);

  /// Reads the primary device from this person's synced state, and acts on a
  /// change: starts or stops reading, and tells friends at once when this
  /// device has just become the primary.
  Future<void> refreshPrimary() =>
      _refreshingPrimary ??= _refreshPrimary().whenComplete(
        () => _refreshingPrimary = null,
      );

  Future<void> _refreshPrimary() async {
    final state = this.state;
    if (state == null || _disposed) return;
    try {
      await state.refresh();
      var id = state.locationPrimary;
      if (id != null && !_mine(id)) id = null;
      if (id == null && await _claim(state)) id = node.identity.device;
      _setPrimary(id);
    } catch (_) {
      // The state could not be read: behave as before it existed.
      _setPrimary(_primary);
    }
  }

  /// A phone with no primary chosen takes the role, once per profile, after it
  /// has heard from this person's other devices (or has none): otherwise a
  /// newly linked phone could take it before the existing choice arrived.
  Future<bool> _claim(NoteState state) async {
    if (!phone || node.store.setting('locationAutoPrimary') == true) return false;
    final others = otherDevices;
    if (others.isNotEmpty &&
        !others.any((c) => network.lastSync[c.device] != null)) {
      return false;
    }
    node.store.set('locationAutoPrimary', true);
    await state.setLocationPrimary(node.identity.device);
    return true;
  }

  void _setPrimary(String? id) {
    if (_disposed) return;
    final friendsBefore = sendsToFriends;
    _primary = id;
    _primaryKnown = true;
    _applyRole(friendsBefore);
  }

  /// Makes [device] (one of this person's devices) the one that tells friends
  /// where they are. Syncs to the others.
  Future<void> makePrimary(String device) async {
    final state = this.state;
    if (state == null || !_mine(device)) return;
    await state.setLocationPrimary(device);
    _setPrimary(device);
  }

  /// Starts or stops reading to match the role, and sends the current place
  /// to friends when this device has just started to.
  void _applyRole(bool friendsBefore) {
    if (wanted && _stream == null && access == LocationAccess.granted) {
      unawaited(start());
    } else if (!wanted && _stream != null) {
      unawaited(stop());
    }
    final fix = own ?? locations.ofDevice(node.identity.device);
    if (!friendsBefore && sendsToFriends && fix != null) {
      _broadcast(fix, force: true);
    }
    notifyListeners();
  }

  /// Turns sending to this person's other devices on or off.
  void setShowToOwnDevices(bool value) {
    final friendsBefore = sendsToFriends;
    locations.showToOwnDevices = value;
    _applyRole(friendsBefore);
    final fix = own;
    if (value && fix != null) _broadcast(fix, force: true);
  }

  LocationAccess access = LocationAccess.denied;

  /// This device's latest fix, which feeds the blue dot even when sharing is off.
  Fix? own;
  Fix? _sent;
  StreamSubscription<Fix>? _stream;
  Timer? _heartbeat;
  final _lastTo = <String, DateTime>{};
  final _refused = <String>{};
  final _later = <String, Timer>{};
  final _retry = <String, Timer>{};
  final _inFlight = <String>{};
  final _backoff = <String, ({DateTime until, int failures})>{};

  /// When the place each device last received was taken.
  final _delivered = <String, int>{};
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
    if (!_primaryKnown) await refreshPrimary();
    access = await source.access(request: request);
    notifyListeners();
    if (access != LocationAccess.granted || _disposed || _stream != null) return;
    if (!wanted && !request) return;
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
      if (fix != null && sendsToFriends) _broadcast(fix, force: true);
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
    if (wanted && (far || heartbeat)) {
      _sent = fix;
      _broadcast(fix);
    }
    // Kept as this device's last known place too, so the next start and this
    // person's other devices' maps have it. Pausing stops only the sending.
    locations.updateDevice(
      node.identity.device,
      _labelled(fix, node.identity.certificate.label),
      person: node.person,
    );
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

  /// Whether this device may tell [device] where it is: this person's own
  /// devices unless switched off here, friends only from the primary device.
  bool _mayTell(String device) {
    final contact = node.contacts[device];
    if (contact == null) return false;
    return contact.person == node.person ? sendsToOwnDevices : sendsToFriends;
  }

  void _send(String device, Fix fix, {bool force = false}) {
    if (device == node.identity.device ||
        _refused.contains(device) ||
        !node.allowedPeer(device) ||
        !_mayTell(device)) {
      return;
    }
    if (_inFlight.contains(device)) {
      // Sent when the request on its way finishes, if this is newer.
      return;
    }
    final now = DateTime.now();
    final waiting = _backoff[device];
    if (!force && waiting != null && now.isBefore(waiting.until)) return;
    final last = _lastTo[device];
    if (!force && last != null && now.difference(last) < minGap) {
      _later[device] ??= Timer(minGap - now.difference(last), () {
        _later.remove(device);
        final latest = _sent;
        if (latest != null && !_disposed) _send(device, latest);
      });
      return;
    }
    _later.remove(device)?.cancel();
    _retry.remove(device)?.cancel();
    _lastTo[device] = now;
    _inFlight.add(device);
    unawaited(
      network
          .request(device, {'type': 'position', 'fix': fix.toJson()})
          .then<void>(
            (_) {
              _inFlight.remove(device);
              _backoff.remove(device);
              _delivered[device] = fix.at;
              _sendNewer(device);
            },
            onError: (Object e) {
              _inFlight.remove(device);
              if ('$e'.contains('Unknown request')) {
                _refused.add(device);
                return;
              }
              _failed(device);
            },
          ),
    );
  }

  /// Whether [device] failed to answer and is waiting to be tried again.
  @visibleForTesting
  bool backingOff(String device) => _backoff.containsKey(device);

  /// Sends the latest place to [device] if it is newer than what reached it.
  void _sendNewer(String device) {
    final latest = _sent ?? own;
    if (_disposed || latest == null) return;
    if (latest.at > (_delivered[device] ?? 0)) _send(device, latest);
  }

  /// [device] did not answer (switched off, or out of signal): wait before
  /// trying it again, twice as long each time it fails, and then send the
  /// latest place. Once a place has reached it nothing more is retried, so a
  /// still phone does not keep dialling friends who are away.
  void _failed(String device) {
    if (_disposed) return;
    final failures = (_backoff[device]?.failures ?? 0) + 1;
    var wait = firstBackoff * (1 << min(failures - 1, 6));
    if (wait > maxBackoff) wait = maxBackoff;
    _backoff[device] = (until: DateTime.now().add(wait), failures: failures);
    _retry.remove(device)?.cancel();
    // About an hour of trying; after that it hears when it next syncs.
    if (failures > maxRetries) return;
    _retry[device] = Timer(wait, () {
      _retry.remove(device);
      _sendNewer(device);
    });
  }

  /// A device has just synced with this one: tell it where this person is.
  void _seen(String device) {
    final fix = own ?? locations.ofDevice(node.identity.device);
    if (fix == null) return;
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
    if (fix == null) return;
    if (contact.person == node.person) {
      locations.updateDevice(device, fix, person: contact.person);
    } else {
      locations.update(contact.person, fix);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _updates?.cancel();
    _primaryCheck?.cancel();
    _stream?.cancel();
    _heartbeat?.cancel();
    for (final timer in [..._later.values, ..._retry.values]) {
      timer.cancel();
    }
    if (network.position == _received) network.position = null;
    if (network.peerSeen == _seen) network.peerSeen = null;
    super.dispose();
  }
}
