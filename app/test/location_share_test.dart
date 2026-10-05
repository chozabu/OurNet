import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/services/location_share.dart';
import 'package:ournet/services/network.dart';
import 'package:ournet_core/ournet_core.dart';

class FakeSource implements PositionSource {
  final controller = StreamController<Fix>.broadcast();
  LocationAccess grant;
  FakeSource([this.grant = LocationAccess.granted]);
  @override
  Future<LocationAccess> access({bool request = false}) async => grant;
  @override
  Stream<Fix> fixes() => controller.stream;
  @override
  Future<Fix?> now() async => null;
}

int now() => DateTime.now().millisecondsSinceEpoch;
Fix at(double lat, double lng, [int? time]) =>
    Fix(lat: lat, lng: lng, at: time ?? now(), accuracy: 8);

Future<void> until(bool Function() done, {int ms = 8000}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (!done() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Node a, b;
  late Network na, nb;
  late FakeSource source;
  late LocationShare sa, sb;

  Future<void> pair() async {
    a = Node(await LocalIdentity.create(label: 'Pixel'), Store());
    b = Node(await LocalIdentity.create(label: 'Desk'), Store());
    na = Network(a);
    nb = Network(b);
    source = FakeSource();
    sa = LocationShare(
      na,
      source: source,
      minGap: const Duration(milliseconds: 300),
    );
    sb = LocationShare(nb, source: FakeSource(LocationAccess.unsupported));
    addTearDown(() async {
      sa.dispose();
      sb.dispose();
      await na.stop();
      await nb.stop();
      await a.close();
      await b.close();
    });
    await na.start(local: true);
    await nb.start(local: true);
    await na.addCard(nb.contactCard());
    await nb.addCard(na.contactCard());
  }

  test(
    'a moving friend shows up on the other device, and is kept',
    () async {
      await pair();
      await na.sync(b.identity.device);
      await sa.start();
      expect(sa.active, isTrue);
      source.controller.add(at(51.5, -0.12));
      await until(() => b.locations.of(a.person) != null);
      final seen = b.locations.of(a.person)!;
      expect(seen.lat, 51.5);
      expect(seen.device, 'Pixel');
      // The sender's own record is its last place too.
      expect(a.locations.of(a.person)!.lng, -0.12);

      // A few metres is not worth telling anyone.
      source.controller.add(at(51.50001, -0.12, now() + 1000));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(b.locations.of(a.person)!.lat, 51.5);

      // A real move is.
      source.controller.add(at(51.52, -0.12, now() + 2000));
      await until(() => b.locations.of(a.person)!.lat == 51.52);
      expect(b.locations.of(a.person)!.lat, 51.52);
      // One row per person: moving does not add history.
      expect(
        b.store.db.select('SELECT COUNT(*) c FROM positions').first['c'],
        1,
      );
      expect(b.store.objects(kind: 'location'), isEmpty);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'pausing stops sending, and resuming sends the current place',
    () async {
      await pair();
      await na.sync(b.identity.device);
      await sa.start();
      await sa.setSharing(false);
      source.controller.add(at(10, 10));
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(b.locations.of(a.person), isNull);
      expect(sa.own!.lat, 10);

      await sa.setSharing(true);
      await until(() => b.locations.of(a.person) != null);
      expect(b.locations.of(a.person)!.lat, 10);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'a move reaches a friend who has not been heard from lately',
    () async {
      await pair();
      await sa.start();
      // No sync, no message: someone out for the day with nothing to say.
      source.controller.add(at(48.85, 2.35));
      await until(() => b.locations.of(a.person) != null);
      expect(b.locations.of(a.person)!.lng, 2.35);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'a friend out of reach is tried later, and told on reconnecting',
    () async {
      await pair();
      final c = Node(await LocalIdentity.create(label: 'Away'), Store());
      var nc = Network(c);
      addTearDown(() async {
        await nc.stop();
        await c.close();
      });
      await nc.start(local: true);
      await na.addCard(nc.contactCard());
      await nc.addCard(na.contactCard());
      await nc.stop();

      await sa.start();
      source.controller.add(at(48.85, 2.35));
      await until(() => sa.backingOff(c.identity.device), ms: 30000);
      expect(sa.backingOff(c.identity.device), isTrue);
      // The friend who could be reached heard at once.
      expect(b.locations.of(a.person)!.lng, 2.35);

      // Back in signal: its first sync hands the place over.
      nc = Network(c);
      final sc = LocationShare(
        nc,
        source: FakeSource(LocationAccess.unsupported),
      );
      addTearDown(sc.dispose);
      await nc.start(local: true);
      await na.addCard(nc.contactCard());
      await nc.sync(a.identity.device);
      await until(() => c.locations.of(a.person) != null);
      expect(c.locations.of(a.person)!.lng, 2.35);
      await until(() => !sa.backingOff(c.identity.device));
      expect(sa.backingOff(c.identity.device), isFalse);
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'implausible and stale positions are refused',
    () async {
      await pair();
      await na.sync(b.identity.device);
      final device = b.identity.device;
      await na.request(device, {
        'type': 'position',
        'fix': {'lat': 950000000, 'lng': 0, 'at': now()},
      });
      await na.request(device, {
        'type': 'position',
        'fix': {'lat': 10000000, 'lng': 10000000, 'at': now() + 86400000},
      });
      expect(b.locations.of(a.person), isNull);
      await na.request(device, {
        'type': 'position',
        'fix': at(3, 3, now()).toJson(),
      });
      expect(b.locations.of(a.person)!.lat, 3);
      // An older one cannot move them back.
      await na.request(device, {
        'type': 'position',
        'fix': at(4, 4, now() - 60000).toJson(),
      });
      expect(b.locations.of(a.person)!.lat, 3);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  group('one person, several devices', () {
    late Node phone, laptop, friend;
    late Network np, nl, nf;
    late FakeSource phoneGps, laptopGps;
    late LocationShare sp, sl, sf;

    Future<void> setUpDevices() async {
      phone = Node(await LocalIdentity.create(label: 'Pixel'), Store());
      final fresh = await LocalIdentity.create(label: 'Desk');
      laptop = Node(
        await fresh.enrol(await phone.identity.authorise(fresh.certificate)),
        Store(),
      );
      friend = Node(await LocalIdentity.create(label: 'Friend'), Store());
      np = Network(phone);
      nl = Network(laptop);
      nf = Network(friend);
      phoneGps = FakeSource();
      laptopGps = FakeSource();
      const gap = Duration(milliseconds: 100);
      sp = LocationShare(
        np,
        source: phoneGps,
        state: NoteState(phone),
        phone: true,
        minGap: gap,
      );
      sl = LocationShare(
        nl,
        source: laptopGps,
        state: NoteState(laptop),
        phone: false,
        minGap: gap,
      );
      sf = LocationShare(nf, source: FakeSource(LocationAccess.unsupported));
      addTearDown(() async {
        sp.dispose();
        sl.dispose();
        sf.dispose();
        for (final n in [np, nl, nf]) {
          await n.stop();
        }
        for (final n in [phone, laptop, friend]) {
          await n.close();
        }
      });
      for (final n in [np, nl, nf]) {
        await n.start(local: true);
      }
      await np.addCard(nl.contactCard());
      await nl.addCard(np.contactCard());
      for (final n in [np, nl]) {
        await n.addCard(nf.contactCard());
        await nf.addCard(n.contactCard());
      }
      await np.sync(laptop.identity.device);
      await np.sync(friend.identity.device);
      await nl.sync(friend.identity.device);
    }

    test(
      'own devices see each other, each on its own row',
      () async {
        await setUpDevices();
        await sp.start();
        await sl.start();
        phoneGps.controller.add(at(51.5, -0.12));
        laptopGps.controller.add(at(51.6, -0.2));
        await until(
          () =>
              laptop.locations.ofDevice(phone.identity.device) != null &&
              phone.locations.ofDevice(laptop.identity.device) != null,
        );
        expect(laptop.locations.ofDevice(phone.identity.device)!.lat, 51.5);
        expect(
          laptop.locations.ofDevice(phone.identity.device)!.device,
          'Pixel',
        );
        expect(
          phone.locations.ofDevice(laptop.identity.device)!.device,
          'Desk',
        );
        // Nothing is kept as an object, and each device is one row.
        expect(
          laptop.store.db
              .select('SELECT COUNT(*) c FROM device_positions')
              .first['c'],
          2,
        );
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      'only the primary device tells friends where you are',
      () async {
        await setUpDevices();
        await sp.start();
        // The phone has heard from the laptop, found no primary and claimed it.
        await sp.refreshPrimary();
        expect(sp.isPrimary, isTrue);
        await nl.sync(phone.identity.device);
        await sl.refreshPrimary();
        expect(sl.primary, phone.identity.device);
        expect(sl.sendsToFriends, isFalse);
        await sl.start();

        // The laptop, sitting at home, moves and is heard by the phone only.
        laptopGps.controller.add(at(1, 1));
        await until(
          () => phone.locations.ofDevice(laptop.identity.device) != null,
        );
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(friend.locations.of(phone.person), isNull);

        phoneGps.controller.add(at(51.5, -0.12, now() + 1000));
        await until(() => friend.locations.of(phone.person) != null);
        expect(friend.locations.of(phone.person)!.lat, 51.5);
        expect(friend.locations.of(phone.person)!.device, 'Pixel');
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      'choosing another primary hands friends over at once',
      () async {
        await setUpDevices();
        await sp.start();
        await sp.refreshPrimary();
        await nl.sync(phone.identity.device);
        await sl.refreshPrimary();
        await sl.start();
        laptopGps.controller.add(at(1, 1));
        await until(() => sl.own != null);

        await sl.makePrimary(laptop.identity.device);
        expect(sl.isPrimary, isTrue);
        await until(() => friend.locations.of(phone.person) != null);
        expect(friend.locations.of(phone.person)!.device, 'Desk');

        // The phone learns of the change when it next syncs.
        await np.sync(laptop.identity.device);
        await sp.refreshPrimary();
        expect(sp.primary, laptop.identity.device);
        expect(sp.sendsToFriends, isFalse);
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      'a removed device is not chosen as primary',
      () async {
        await setUpDevices();
        await sp.makePrimary('not-one-of-mine');
        expect(sp.primary, isNull);
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });

  test('a device without permission reports it and sends nothing', () async {
    await pair();
    final denied = LocationShare(
      na,
      source: FakeSource(LocationAccess.deniedForever),
    );
    addTearDown(denied.dispose);
    await denied.start();
    expect(denied.active, isFalse);
    expect(denied.access, LocationAccess.deniedForever);
  });
}
