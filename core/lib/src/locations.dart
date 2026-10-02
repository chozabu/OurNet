import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'store.dart';

/// Where a person was, as one of their devices last reported it.
class Fix {
  /// Degrees.
  final double lat, lng;

  /// Metres of uncertainty, when the device knows it.
  final double? accuracy;

  /// Degrees clockwise from north, and metres per second, when moving.
  final double? heading, speed;

  /// When the device took the fix (milliseconds since the epoch, by that
  /// device's clock).
  final int at;

  /// The sending device's label, filled in from the contact certificate.
  final String device;
  const Fix({
    required this.lat,
    required this.lng,
    required this.at,
    this.accuracy,
    this.heading,
    this.speed,
    this.device = '',
  });

  /// The most a fix may lead this device's clock: phones drift, but a fix
  /// from next week is a way to pin a marker over everything newer.
  static const maxLead = Duration(minutes: 10);

  /// Reads a fix as it travels and is stored. Numbers on the wire are
  /// integers, as everywhere in OurNet: `lat` and `lng` in ten-millionths of
  /// a degree (about a centimetre), `acc` in metres, `hdg` in degrees, `spd`
  /// in centimetres per second and `at` in milliseconds. Null when the fix is
  /// not a plausible one.
  static Fix? parse(Object? v, {required int now, String device = ''}) {
    if (v is! Map) return null;
    int? whole(String key, int low, int high) {
      final x = v[key];
      if (x == null) return null;
      if (x is! int || x < low || x > high) {
        throw const FormatException('out of range');
      }
      return x;
    }

    try {
      final lat = whole('lat', -900000000, 900000000);
      final lng = whole('lng', -1800000000, 1800000000);
      final at = v['at'];
      if (lat == null ||
          lng == null ||
          at is! int ||
          at < 0 ||
          at > now + maxLead.inMilliseconds) {
        return null;
      }
      return Fix(
        lat: lat / 1e7,
        lng: lng / 1e7,
        at: at,
        accuracy: whole('acc', 0, 1000000)?.toDouble(),
        heading: whole('hdg', 0, 360)?.toDouble(),
        speed: switch (whole('spd', 0, 100000)) {
          final int cm => cm / 100,
          _ => null,
        },
        device: device.length > 64 ? device.substring(0, 64) : device,
      );
    } on FormatException {
      return null;
    }
  }

  /// The wire form read by [parse].
  Map<String, int> toJson() => {
    'lat': (lat * 1e7).round(),
    'lng': (lng * 1e7).round(),
    'at': at,
    if (accuracy != null) 'acc': accuracy!.ceil(),
    if (heading != null) 'hdg': heading!.round() % 361,
    if (speed != null) 'spd': (speed! * 100).round(),
  };

  /// Metres along the ground to [other] (haversine).
  double distanceTo(double otherLat, double otherLng) {
    const radius = 6371008.8;
    double rad(double d) => d * math.pi / 180;
    final dLat = rad(otherLat - lat), dLng = rad(otherLng - lng);
    final a =
        math.pow(math.sin(dLat / 2), 2) +
        math.cos(rad(lat)) *
            math.cos(rad(otherLat)) *
            math.pow(math.sin(dLng / 2), 2);
    return 2 * radius * math.asin(math.min(1, math.sqrt(a)));
  }
}

/// The last known place of each person, kept as one row per person and
/// replaced in place. A position is not a record: nothing here grows with
/// time, nothing is signed or forwarded, and a person's row is never expired,
/// so a friend who has gone offline stays where they were last seen.
///
/// Positions travel only over live connections between admitted devices (see
/// the transport's `position` request), which are already encrypted. A person's
/// own devices share them too, so a desktop can show where the phone is.
class Locations {
  final Store store;
  final int Function() now;
  final _byPerson = <String, Fix>{};
  final _changes = StreamController<void>.broadcast();
  Locations(this.store, {int Function()? clock})
    : now = clock ?? (() => DateTime.now().millisecondsSinceEpoch) {
    store.db.execute(
      'CREATE TABLE IF NOT EXISTS positions('
      'person TEXT PRIMARY KEY, fix TEXT NOT NULL, device TEXT NOT NULL)',
    );
    for (final row in store.db.select('SELECT person,fix,device FROM positions')) {
      try {
        final fix = Fix.parse(
          jsonDecode(row['fix'] as String),
          now: 1 << 52,
          device: row['device'] as String,
        );
        if (fix != null) _byPerson[row['person'] as String] = fix;
      } on FormatException {
        // A damaged row is ignored; the next fix replaces it.
      }
    }
  }

  /// Fires when any person's position changes. Separate from the node's
  /// changes: a moving friend must not refresh every list in the app.
  Stream<void> get changes => _changes.stream;

  /// Whether this person shares their position with their friends. On unless
  /// switched off.
  bool get sharing => store.setting('shareLocation') != false;
  set sharing(bool value) => store.set('shareLocation', value);

  Fix? of(String person) => _byPerson[person];
  Map<String, Fix> get all => Map.unmodifiable(_byPerson);

  /// Takes in a fix from [person]'s [device]. Older fixes than the one held
  /// are ignored, so a late delivery cannot move someone back. Returns whether
  /// the stored position changed.
  bool update(String person, Fix fix) {
    final held = _byPerson[person];
    if (held != null && fix.at <= held.at) return false;
    _byPerson[person] = fix;
    store.db.execute(
      'INSERT INTO positions VALUES (?,?,?) ON CONFLICT(person) DO UPDATE '
      'SET fix=excluded.fix, device=excluded.device',
      [person, jsonEncode(fix.toJson()), fix.device],
    );
    if (!_changes.isClosed) _changes.add(null);
    return true;
  }

  /// Drops what is held for [person] (a friend removed or blocked).
  void forget(String person) {
    if (_byPerson.remove(person) == null) return;
    store.db.execute('DELETE FROM positions WHERE person=?', [person]);
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> close() => _changes.close();
}
