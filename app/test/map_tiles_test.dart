import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ournet/services/map_tiles.dart';
import 'package:ournet_core/ournet_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<Uri> requests;
  late String version;
  late bool online;
  late Set<String> missing;

  MapTiles tiles({bool allowed = true}) {
    requests = [];
    version = 'v1';
    online = allowed;
    missing = {};
    final t = MapTiles(
      TileStore(),
      allowed: () => online,
      client: () => MockClient((request) async {
        requests.add(request.url);
        if (request.url.toString() == MapTiles.tileJson) {
          return http.Response(
            jsonEncode({
              'tiles': ['https://t.example/planet/$version/{z}/{x}/{y}.pbf'],
            }),
            200,
          );
        }
        if (!request.url.path.contains('/$version/')) {
          return http.Response('gone', 404);
        }
        if (missing.contains(request.url.pathSegments.last)) {
          return http.Response('', 404);
        }
        return http.Response.bytes(
          Uint8List.fromList(utf8.encode(request.url.path)),
          200,
        );
      }),
    );
    addTearDown(() {
      t.dispose();
      t.store.close();
    });
    return t;
  }

  test('a tile is fetched once and then kept', () async {
    final t = tiles();
    final first = await t.tile(3, 1, 2);
    expect(utf8.decode(first), '/planet/v1/3/1/2.pbf');
    final before = requests.length;
    final again = await t.tile(3, 1, 2);
    expect(again, first);
    expect(requests.length, before);
    expect(t.store.has(3, 1, 2), isTrue);
  });

  test('with the internet off nothing is requested, and kept tiles still show',
      () async {
    final t = tiles();
    await t.tile(4, 0, 0);
    online = false;
    requests.clear();
    expect(await t.tile(4, 0, 0), isNotEmpty);
    await expectLater(t.tile(4, 1, 1), throwsA(anything));
    expect(requests, isEmpty);
  });

  test('a rotated tile version is found again', () async {
    final t = tiles();
    await t.tile(2, 0, 0);
    version = 'v2';
    final bytes = await t.tile(2, 1, 1);
    expect(utf8.decode(bytes), '/planet/v2/2/1/1.pbf');
  });

  test('an empty area is kept as an empty tile and not asked for again',
      () async {
    final t = tiles();
    await t.template();
    missing = {'1.pbf'};
    final empty = await t.tile(2, 1, 1);
    expect(empty, isEmpty);
    requests.clear();
    expect(await t.tile(2, 1, 1), isEmpty);
    expect(requests, isEmpty);
  });

  test('a region downloads, resumes and deletes', () async {
    final t = tiles();
    const bounds = MapBounds(51.49, -0.15, 51.53, -0.07);
    final job = t.addRegion('London', bounds, 8, 11);
    final total = bounds.count(8, 11);
    expect(total, greaterThan(3));
    for (var i = 0; i < 200 && !job.finished; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(job.error, isNull);
    expect(job.finished, isTrue);
    final region = t.store.regions().single;
    expect(region.complete, isTrue);
    expect(t.store.missing(region.id), isEmpty);
    expect(region.bytes, greaterThan(0));

    // Tiles are served with the internet off.
    online = false;
    for (final (z, x, y) in bounds.cover(8, 11)) {
      expect(await t.tile(z, x, y), isNotEmpty);
    }
    t.deleteRegion(region.id);
    expect(t.store.regions(), isEmpty);
  });

  test('a failing network stops a region and leaves it resumable', () async {
    final t = tiles();
    var fail = true;
    final flaky = MapTiles(
      t.store,
      allowed: () => true,
      client: () => MockClient((request) async {
        if (request.url.toString() == MapTiles.tileJson) {
          return http.Response(
            jsonEncode({'tiles': ['https://t.example/p/v1/{z}/{x}/{y}.pbf']}),
            200,
          );
        }
        return fail
            ? http.Response('busy', 503)
            : http.Response.bytes(Uint8List(8), 200);
      }),
    );
    addTearDown(flaky.dispose);
    final job = flaky.addRegion(
      'Small',
      const MapBounds(51.49, -0.15, 51.50, -0.14),
      9,
      10,
    );
    for (var i = 0; i < 400 && !job.finished; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(job.error, isNotNull);
    final region = t.store.regions().single;
    expect(region.complete, isFalse);
    fail = false;
    final again = flaky.download(region.id);
    for (var i = 0; i < 400 && !again.finished; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(again.error, isNull);
    expect(t.store.regions().single.complete, isTrue);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('both bundled styles load with their icons, with no network', () async {
    final t = tiles();
    requests.clear();
    for (final dark in [false, true]) {
      final style = await t.style(dark: dark);
      expect(style.theme.tileSources, contains('openmaptiles'));
      expect(style.sprites, isNotNull);
      expect(style.providers.get('openmaptiles'), same(t.provider));
    }
    expect(requests, isEmpty);
  });

  test('an area that is too large is refused', () {
    final t = tiles();
    expect(
      () => t.addRegion('World', const MapBounds(-80, -180, 80, 180), 0, 14),
      throwsStateError,
    );
  });
}
