import 'dart:io';
import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';

void main() {
  const t = 1700000000000;
  Fix fix(double lat, double lng, int at) => Fix(lat: lat, lng: lng, at: at);

  group('Fix.parse', () {
    test('reads a plausible fix and rejects the rest', () {
      final ok = Fix.parse({
        'lat': 515000000,
        'lng': -1200000,
        'at': t,
        'acc': 12,
        'hdg': 90,
        'spd': 150,
      }, now: t);
      expect(ok!.lat, 51.5);
      expect(ok.lng, -0.12);
      expect(ok.accuracy, 12);
      expect(ok.speed, 1.5);
      for (final bad in [
        null,
        'x',
        {'lat': 910000000, 'lng': 0, 'at': t},
        {'lat': 0, 'lng': 1810000000, 'at': t},
        // Floating point never travels: it cannot be signed or hashed.
        {'lat': 51.5, 'lng': 0, 'at': t},
        {'lat': '1', 'lng': 0, 'at': t},
        {'lat': 1, 'lng': 0},
        {'lat': 1, 'lng': 0, 'at': -1},
        // A clock a day ahead would pin the marker over every real update.
        {'lat': 1, 'lng': 0, 'at': t + 86400000},
        {'lat': 1, 'lng': 0, 'at': t, 'acc': -3},
        {'lat': 1, 'lng': 0, 'at': t, 'hdg': 400},
      ]) {
        expect(Fix.parse(bad, now: t), isNull, reason: '$bad');
      }
    });

    test('survives its own wire form', () {
      const f = Fix(lat: 51.5074123, lng: -0.1278456, at: t, accuracy: 7.2, heading: 271.6, speed: 3.456);
      final back = Fix.parse(f.toJson(), now: t)!;
      expect(back.lat, closeTo(f.lat, 1e-7));
      expect(back.lng, closeTo(f.lng, 1e-7));
      expect(back.accuracy, 8);
      expect(back.heading, 272);
      expect(back.speed, closeTo(3.46, 1e-9));
      // Everything in it is an integer, which canonical JSON admits.
      expect(f.toJson(), isA<Map<String, int>>());
      expect(canonical(f.toJson()), isNotEmpty);
    });

    test('measures distance on the ground', () {
      // London to Paris is about 344 km.
      final d = fix(51.5074, -0.1278, t).distanceTo(48.8566, 2.3522);
      expect(d, closeTo(343500, 2000));
      expect(fix(1, 1, t).distanceTo(1, 1), 0);
    });
  });

  group('Locations', () {
    test('keeps the newest fix per person and ignores late ones', () {
      final store = Store();
      final l = Locations(store, clock: () => t);
      var events = 0;
      l.changes.listen((_) => events++);
      expect(l.update('a', fix(1, 1, t)), isTrue);
      expect(l.update('a', fix(2, 2, t - 1000)), isFalse);
      expect(l.update('a', fix(2, 2, t)), isFalse);
      expect(l.update('a', fix(3, 3, t + 1)), isTrue);
      expect(l.of('a')!.lat, 3);
      expect(l.of('b'), isNull);
      return Future(() {
        expect(events, 2);
        store.close();
      });
    });

    test('survives a restart, never expires, and does not grow', () {
      final dir = Directory.systemTemp.createTempSync('ournet_loc');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/p.db';
      var store = Store(path: path);
      var l = Locations(store, clock: () => t);
      for (var i = 0; i < 500; i++) {
        l.update('a', Fix(lat: 1, lng: 1 + i / 1000, at: t + i, device: 'phone'));
      }
      l.update('b', fix(5, 5, t));
      expect(
        store.db.select('SELECT COUNT(*) c FROM positions').first['c'],
        2,
      );
      store.close();
      // A year later.
      store = Store(path: path);
      l = Locations(store, clock: () => t + 365 * 86400000);
      expect(l.of('a')!.lng, closeTo(1.499, 1e-9));
      expect(l.of('a')!.device, 'phone');
      expect(l.of('b')!.lat, 5);
      l.forget('b');
      expect(l.of('b'), isNull);
      store.close();
      store = Store(path: path);
      expect(Locations(store).of('b'), isNull);
      store.close();
    });

    test('sharing is on until switched off', () {
      final store = Store();
      final l = Locations(store);
      expect(l.sharing, isTrue);
      l.sharing = false;
      expect(l.sharing, isFalse);
      l.sharing = true;
      expect(l.sharing, isTrue);
      store.close();
    });
  });

  test('a node offers its locations and closes them', () async {
    final n = Node(await LocalIdentity.create(), Store());
    n.locations.update('x', fix(1, 2, DateTime.now().millisecondsSinceEpoch));
    expect(n.locations.of('x')!.lng, 2);
    await n.close();
  });
}
