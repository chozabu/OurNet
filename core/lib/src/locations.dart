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

/// How much of this person's position one friend is sent. Chosen per friend
/// and kept in this person's synced personal state (`NoteState`), never
/// published and never sent to the friend: the sender enforces it.
enum LocationLevel {
  /// The position as the device reads it.
  precise,

  /// Snapped to the centre of an [ApproxGrid] cell, a few kilometres across.
  approximate,

  /// Nothing is sent, as when sharing is paused.
  off,
}

/// A friend's level as chosen. A temporary choice ("precise for an hour")
/// holds [level] until [until] and is [then] afterwards, the level it
/// replaced.
class LocationChoice {
  final LocationLevel level;
  final int? until;
  final LocationLevel then;
  const LocationChoice(this.level, {this.until, LocationLevel? then})
    : then = then ?? level;

  /// The level in force at [now] (milliseconds since the epoch).
  LocationLevel at(int now) => until != null && now >= until! ? then : level;

  /// Whether this is a temporary choice that has not run out at [now].
  bool temporaryAt(int now) => until != null && now < until!;

  static LocationLevel? _level(Object? v) => switch (v) {
    'precise' => LocationLevel.precise,
    'approximate' => LocationLevel.approximate,
    'off' => LocationLevel.off,
    _ => null,
  };

  /// Reads the stored form, `{level, until?, then?}`; null when malformed.
  static LocationChoice? parse(Object? v) {
    if (v is! Map) return null;
    final level = _level(v['level']);
    final until = v['until'];
    final then = v['then'] == null ? level : _level(v['then']);
    if (level == null || then == null) return null;
    if (until != null && (until is! int || until < 0)) return null;
    return LocationChoice(level, until: until as int?, then: then);
  }

  Map<String, Object> toJson() => {
    'level': level.name,
    if (until != null) 'until': until!,
    if (until != null) 'then': then.name,
  };
}

/// A cell of [ApproxGrid]: a row of latitude and a column within it.
typedef GridCell = ({int row, int col});

/// The fixed grid approximate positions are snapped to. Rows are
/// [latStep] degrees of latitude (about 5.6 km); each row is cut into a whole
/// number of columns about as wide as the row is tall, so cells are near
/// square everywhere. A position becomes its cell's centre: it is the same
/// for every fix inside the cell, so averaging many reveals nothing more.
class ApproxGrid {
  static const latStep = 0.05;
  static const rows = 3600;
  static const _metresPerDegree = 111195.0;

  /// How far past its edge a position must go before it leaves the cell it
  /// was last shown in, so walking along a boundary does not flip between
  /// two cells and show where the boundary is.
  static const margin = 500.0;

  static double _rad(double d) => d * math.pi / 180;

  static double centreLat(int row) => -90 + (row + 0.5) * latStep;

  static int columns(int row) => math.max(
    1,
    (360 * math.cos(_rad(centreLat(row))) / latStep).floor(),
  );

  static double lngStep(int row) => 360 / columns(row);

  static double centreLng(GridCell cell) =>
      -180 + (cell.col + 0.5) * lngStep(cell.row);

  static GridCell cellOf(double lat, double lng) {
    final row = ((lat + 90) / latStep).floor().clamp(0, rows - 1);
    final cols = columns(row);
    final col = ((lng + 180) / lngStep(row)).floor() % cols;
    return (row: row, col: col);
  }

  /// Whether ([lat], [lng]) lies inside [cell] or within [margin] of it.
  static bool near(GridCell cell, double lat, double lng) {
    final lo = -90 + cell.row * latStep, hi = lo + latStep;
    final mLat = margin / _metresPerDegree;
    if (lat < lo - mLat || lat > hi + mLat) return false;
    final cos = math.max(0.01, math.cos(_rad(lat)));
    final mLng = margin / (_metresPerDegree * cos);
    var d = (lng - centreLng(cell)) % 360;
    if (d > 180) d -= 360;
    return d.abs() <= lngStep(cell.row) / 2 + mLng;
  }

  /// The cell [fix] is shown in: [previous] while the fix is still near it,
  /// otherwise the one it is in.
  static GridCell place(Fix fix, {GridCell? previous}) =>
      previous != null && near(previous, fix.lat, fix.lng)
      ? previous
      : cellOf(fix.lat, fix.lng);

  /// [fix] as an approximate position: [cell]'s centre, with an accuracy
  /// that covers the cell, and no heading or speed.
  static Fix snap(Fix fix, GridCell cell) {
    final lat = centreLat(cell.row);
    final halfHeight = latStep / 2 * _metresPerDegree;
    final halfWidth =
        lngStep(cell.row) / 2 * _metresPerDegree * math.cos(_rad(lat));
    final cover = math.sqrt(halfHeight * halfHeight + halfWidth * halfWidth);
    return Fix(
      lat: lat,
      lng: centreLng(cell),
      at: fix.at,
      accuracy: math.max(cover, fix.accuracy ?? 0).ceilToDouble(),
      device: fix.device,
    );
  }
}

/// The last known place of each person, kept as one row per person and
/// replaced in place. A position is not a record: nothing here grows with
/// time, nothing is signed or forwarded, and a person's row is never expired,
/// so a friend who has gone offline stays where they were last seen.
///
/// Positions travel only over live connections between admitted devices (see
/// the transport's `position` request), which are already encrypted. A person's
/// own devices share them too, so a desktop can show where the phone is; those
/// are kept per device as well as per person.
class Locations {
  final Store store;
  final int Function() now;
  final _byPerson = <String, Fix>{};
  final _byDevice = <String, Fix>{};
  final _changes = StreamController<void>.broadcast();
  Locations(this.store, {int Function()? clock})
    : now = clock ?? (() => DateTime.now().millisecondsSinceEpoch) {
    store.db.execute(
      'CREATE TABLE IF NOT EXISTS positions('
      'person TEXT PRIMARY KEY, fix TEXT NOT NULL, device TEXT NOT NULL)',
    );
    // One row per device, kept only for this person's own devices.
    store.db.execute(
      'CREATE TABLE IF NOT EXISTS device_positions('
      'device TEXT PRIMARY KEY, fix TEXT NOT NULL, label TEXT NOT NULL)',
    );
    _load('SELECT person,fix,device FROM positions', 'person', 'device', _byPerson);
    _load('SELECT device,fix,label FROM device_positions', 'device', 'label', _byDevice);
  }

  void _load(String sql, String key, String label, Map<String, Fix> into) {
    for (final row in store.db.select(sql)) {
      try {
        final fix = Fix.parse(
          jsonDecode(row['fix'] as String),
          now: 1 << 52,
          device: row[label] as String,
        );
        if (fix != null) into[row[key] as String] = fix;
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

  /// Whether this device tells this person's other devices where it is. On
  /// unless switched off (a spare phone, to save its battery). Friends are
  /// separate: see [sharing] and the primary device.
  bool get showToOwnDevices => store.setting('shareOwnDevices') != false;
  set showToOwnDevices(bool value) => store.set('shareOwnDevices', value);

  Fix? of(String person) => _byPerson[person];
  Map<String, Fix> get all => Map.unmodifiable(_byPerson);

  /// Where one of this person's own devices last was, by device ID.
  Fix? ofDevice(String device) => _byDevice[device];
  Map<String, Fix> get devices => Map.unmodifiable(_byDevice);

  /// Takes in a fix from [person]'s [device]. Older fixes than the one held
  /// are ignored, so a late delivery cannot move someone back. Returns whether
  /// the stored position changed.
  bool update(String person, Fix fix) {
    if (!_setPerson(person, fix)) return false;
    if (!_changes.isClosed) _changes.add(null);
    return true;
  }

  bool _setPerson(String person, Fix fix) {
    final held = _byPerson[person];
    if (held != null && fix.at <= held.at) return false;
    _byPerson[person] = fix;
    store.db.execute(
      'INSERT INTO positions VALUES (?,?,?) ON CONFLICT(person) DO UPDATE '
      'SET fix=excluded.fix, device=excluded.device',
      [person, jsonEncode(fix.toJson()), fix.device],
    );
    return true;
  }

  /// Takes in a fix from one of this person's own devices. The device keeps
  /// its own row (a person's devices are shown separately to themselves), and
  /// the newest of them stands for the person like any friend's last place.
  bool updateDevice(String device, Fix fix, {required String person}) {
    final held = _byDevice[device];
    var changed = false;
    if (held == null || fix.at > held.at) {
      _byDevice[device] = fix;
      store.db.execute(
        'INSERT INTO device_positions VALUES (?,?,?) ON CONFLICT(device) '
        'DO UPDATE SET fix=excluded.fix, label=excluded.label',
        [device, jsonEncode(fix.toJson()), fix.device],
      );
      changed = true;
    }
    if (_setPerson(person, fix)) changed = true;
    if (changed && !_changes.isClosed) _changes.add(null);
    return changed;
  }

  /// Drops what is held for one of this person's devices (one that was
  /// removed).
  void forgetDevice(String device) {
    if (_byDevice.remove(device) == null) return;
    store.db.execute('DELETE FROM device_positions WHERE device=?', [device]);
    if (!_changes.isClosed) _changes.add(null);
  }

  /// Drops what is held for [person] (a friend removed or blocked).
  void forget(String person) {
    if (_byPerson.remove(person) == null) return;
    store.db.execute('DELETE FROM positions WHERE person=?', [person]);
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> close() => _changes.close();
}
