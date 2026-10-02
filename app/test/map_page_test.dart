import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/services/location_share.dart';
import 'package:ournet/services/map_tiles.dart';
import 'package:ournet/services/network.dart';
import 'package:ournet/ui/map_page.dart';
import 'package:ournet_core/ournet_core.dart';

class _Asks implements PositionSource {
  bool asked = false;
  @override
  Future<LocationAccess> access({bool request = false}) async {
    if (request) asked = true;
    return asked ? LocationAccess.granted : LocationAccess.denied;
  }

  @override
  Stream<Fix> fixes() => const Stream.empty();
  @override
  Future<Fix?> now() async => null;
}

class _NoGps implements PositionSource {
  @override
  Future<LocationAccess> access({bool request = false}) async =>
      LocationAccess.unsupported;
  @override
  Stream<Fix> fixes() => const Stream.empty();
  @override
  Future<Fix?> now() async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('helpers', () {
    test('ages read naturally', () {
      final now = DateTime(2026, 10, 2, 12);
      int ms(Duration d) => now.subtract(d).millisecondsSinceEpoch;
      expect(ago(ms(const Duration(seconds: 20)), now: now), 'just now');
      expect(ago(ms(const Duration(minutes: 5)), now: now), '5 min ago');
      expect(ago(ms(const Duration(hours: 3)), now: now), '3 h ago');
      expect(ago(ms(const Duration(days: 2)), now: now), '2 d ago');
      expect(ago(ms(const Duration(days: 30)), now: now), '2026-09-02');
    });

    test('coordinates are understood in common spellings', () {
      expect(parseCoordinates('51.5, -0.12')!.latitude, 51.5);
      expect(parseCoordinates('51.5 -0.12')!.longitude, -0.12);
      expect(parseCoordinates('-33.86;151.2')!.latitude, -33.86);
      expect(parseCoordinates('91, 0'), isNull);
      expect(parseCoordinates('Anna'), isNull);
      expect(parseCoordinates('1'), isNull);
    });

    test('distances are short', () {
      expect(distanceText(42), '40 m');
      expect(distanceText(1234), '1.2 km');
      expect(distanceText(48000), '48 km');
    });
  });

  testWidgets('friends appear where they last were and can be found', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final me = Node(await LocalIdentity.create(label: 'Desk'), Store());
    final anna = Node(await LocalIdentity.create(label: 'Annas phone'), Store());
    await me.addContact(anna.identity.certificate);
    final network = Network(me);
    final share = LocationShare(network, source: _NoGps());
    final tiles = MapTiles(TileStore(), allowed: () => false);
    addTearDown(() async {
      share.dispose();
      tiles.dispose();
      tiles.store.close();
      await me.close();
      await anna.close();
    });
    me.locations.update(
      anna.person,
      Fix(
        lat: 51.5,
        lng: -0.12,
        at: DateTime.now().millisecondsSinceEpoch - 5 * 60000,
        device: 'Annas phone',
      ),
    );
    String nameOf(String p) => p == anna.person ? 'Anna' : 'You';
    String? messaged;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapPage(
            node: me,
            tiles: tiles,
            share: share,
            nameOf: nameOf,
            onMessage: (p) => messaged = p,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(FlutterMap), findsOneWidget);
    // Annas chip, and her marker.
    expect(find.text('Anna'), findsWidgets);

    await tester.tap(find.widgetWithText(InkWell, 'Anna').first);
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.textContaining('Updated 5 min ago'), findsOneWidget);
    expect(find.textContaining('Annas phone'), findsOneWidget);

    await tester.tap(find.text('Message'));
    expect(messaged, anna.person);

    // Searching by name and by coordinates.
    await tester.tap(find.byTooltip('Close'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'ann');
    await tester.pump();
    expect(find.text('5 min ago'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '48.85, 2.35');
    await tester.pump();
    expect(find.text('Go to these coordinates'), findsOneWidget);
    await tester.tap(find.text('Go to these coordinates'));
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.text('Dropped pin'), findsOneWidget);
    // The tile layer keeps a short timer of its own; let it run out.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('the sharing page says who sees you and can pause', (
    tester,
  ) async {
    final me = Node(await LocalIdentity.create(), Store());
    final bob = Node(await LocalIdentity.create(label: 'Bobs phone'), Store());
    await me.addContact(bob.identity.certificate);
    final share = LocationShare(Network(me), source: _NoGps());
    addTearDown(() async {
      share.dispose();
      await me.close();
      await bob.close();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: LocationSharingPage(
          node: me,
          share: share,
          nameOf: (p) => p == bob.person ? 'Bob' : 'You',
        ),
      ),
    );
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('Not sharing with you yet'), findsOneWidget);
    expect(me.locations.sharing, isTrue);
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(me.locations.sharing, isFalse);
    expect(find.textContaining('Paused'), findsOneWidget);
  });

  testWidgets('the first visit explains sharing and asks once', (tester) async {
    final me = Node(await LocalIdentity.create(), Store());
    final source = _Asks();
    final share = LocationShare(Network(me), source: source);
    final tiles = MapTiles(TileStore(), allowed: () => false);
    addTearDown(() async {
      tiles.dispose();
      tiles.store.close();
      await me.close();
    });
    Future<void> open() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MapPage(node: me, tiles: tiles, share: share, nameOf: (_) => 'x'),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
    }

    await open();
    expect(find.text('Share your location with friends?'), findsOneWidget);
    expect(source.asked, isFalse);
    await tester.tap(find.text('Turn on'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(source.asked, isTrue);
    expect(share.active, isTrue);
    // Not asked again.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 4));
    await open();
    expect(find.text('Share your location with friends?'), findsNothing);
    share.dispose();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 4));
  });
}
