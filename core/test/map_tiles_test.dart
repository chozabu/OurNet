import 'dart:io';
import 'dart:typed_data';
import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';

Uint8List bytes(int n) => Uint8List(n)..fillRange(0, n, 7);

void main() {
  group('MapBounds', () {
    test('covers a small area with a handful of tiles per level', () {
      // Central London.
      const b = MapBounds(51.49, -0.15, 51.53, -0.07);
      final t = b.tiles(12);
      expect(t.x0, 2046);
      expect(t.y0, 1361);
      expect(t.x1 >= t.x0 && t.y1 >= t.y0, isTrue);
      expect(b.count(0, 0), 1);
      expect(b.cover(10, 11).length, b.count(10, 11));
      // Never more than the world holds.
      expect(const MapBounds(-90, -180, 90, 180).count(0, 3), 1 + 4 + 16 + 64);
    });

    test('is stable at the edges', () {
      const b = MapBounds(-85.06, -180, 85.06, 180);
      final t = b.tiles(4);
      expect((t.x0, t.x1, t.y0, t.y1), (0, 15, 0, 15));
    });
  });

  group('TileStore', () {
    test('returns what was stored and nothing else', () {
      final s = TileStore();
      expect(s.get(1, 0, 0), isNull);
      s.put(1, 0, 0, bytes(10));
      expect(s.get(1, 0, 0), bytes(10));
      expect(s.get(1, 1, 0), isNull);
      s.close();
    });

    test('trims the least recently used cache but never a region', () {
      final s = TileStore(cacheLimit: 1000);
      final id = s.addRegion('Home', const MapBounds(0, 0, 1, 1), 5, 5);
      s.put(5, 1, 1, bytes(400), region: id);
      for (var i = 0; i < 20; i++) {
        s.put(6, i, 0, bytes(100));
      }
      expect(s.cacheBytes, lessThanOrEqualTo(1000));
      expect(s.get(5, 1, 1), isNotNull);
      // The oldest were dropped, the newest kept.
      expect(s.has(6, 19, 0), isTrue);
      expect(s.has(6, 0, 0), isFalse);
      s.close();
    });

    test('regions resume, report size and return tiles to the cache', () {
      final s = TileStore();
      const b = MapBounds(51.49, -0.15, 51.53, -0.07);
      final id = s.addRegion('London', b, 10, 12);
      final all = b.cover(10, 12).toList();
      expect(s.region(id)!.tiles, all.length);
      expect(s.missing(id).length, all.length);
      for (final (z, x, y) in all.take(3)) {
        s.put(z, x, y, bytes(50), region: id);
      }
      expect(s.missing(id).length, all.length - 3);
      expect(s.region(id)!.bytes, 150);
      expect(s.region(id)!.complete, isFalse);
      s.completeRegion(id);
      expect(s.regions().single.complete, isTrue);
      // A tile already cached counts toward a new overlapping region.
      final other = s.addRegion('Again', b, 10, 12);
      expect(s.missing(other).length, all.length - 3);
      expect(s.regionBytes, 150);
      s.deleteRegion(id);
      // Still held by the second region.
      expect(s.regionBytes, 150);
      s.deleteRegion(other);
      expect(s.regionBytes, 0);
      expect(s.cacheBytes, 150);
      s.clearCache();
      expect(s.cacheBytes, 0);
      expect(s.has(all.first.$1, all.first.$2, all.first.$3), isFalse);
      s.close();
    });

    test('persists across opens', () {
      final dir = Directory.systemTemp.createTempSync('ournet_tiles');
      addTearDown(() => dir.deleteSync(recursive: true));
      var s = TileStore(path: '${dir.path}/t.db');
      s.put(3, 1, 2, bytes(20));
      s.setMeta('k', 'v');
      s.close();
      s = TileStore(path: '${dir.path}/t.db');
      expect(s.get(3, 1, 2), bytes(20));
      expect(s.meta('k'), 'v');
      expect(s.cacheBytes, 20);
      s.close();
    });
  });
}
