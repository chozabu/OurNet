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

  test('a moving friend shows up on the other device, and is kept', () async {
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
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('pausing stops sending, and resuming sends the current place', () async {
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
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a friend who reconnects is told where you are', () async {
    await pair();
    await sa.start();
    // Nobody has been heard from yet, so this goes nowhere.
    source.controller.add(at(48.85, 2.35));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(b.locations.of(a.person), isNull);
    // The first sync between them hands it over.
    await na.sync(b.identity.device);
    await until(() => b.locations.of(a.person) != null);
    expect(b.locations.of(a.person)!.lng, 2.35);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('implausible and stale positions are refused', () async {
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
  }, timeout: const Timeout(Duration(seconds: 60)));

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
