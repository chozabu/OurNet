import 'dart:math' as math;
import 'dart:typed_data';
import 'package:sqlite3/sqlite3.dart';

/// A rectangle of the world to keep for offline use.
class MapBounds {
  final double south, west, north, east;
  const MapBounds(this.south, this.west, this.north, this.east);

  /// The web-mercator tile range covering these bounds at [zoom], inclusive.
  ({int x0, int x1, int y0, int y1}) tiles(int zoom) {
    final n = 1 << zoom;
    int x(double lng) => ((lng + 180) / 360 * n).floor().clamp(0, n - 1);
    int y(double lat) {
      final l = lat.clamp(-85.0511, 85.0511) * math.pi / 180;
      return ((1 - math.log(math.tan(l) + 1 / math.cos(l)) / math.pi) / 2 * n)
          .floor()
          .clamp(0, n - 1);
    }

    return (x0: x(west), x1: x(east), y0: y(north), y1: y(south));
  }

  /// Tiles needed for zoom levels [minZoom] to [maxZoom].
  int count(int minZoom, int maxZoom) {
    var total = 0;
    for (var z = minZoom; z <= maxZoom; z++) {
      final t = tiles(z);
      total += (t.x1 - t.x0 + 1) * (t.y1 - t.y0 + 1);
    }
    return total;
  }

  /// Every tile `(z, x, y)` of the area, level by level.
  Iterable<(int, int, int)> cover(int minZoom, int maxZoom) sync* {
    for (var z = minZoom; z <= maxZoom; z++) {
      final t = tiles(z);
      for (var x = t.x0; x <= t.x1; x++) {
        for (var y = t.y0; y <= t.y1; y++) {
          yield (z, x, y);
        }
      }
    }
  }

  Map<String, Object> toJson() => {
    's': south,
    'w': west,
    'n': north,
    'e': east,
  };
}

/// An area kept for offline use.
class OfflineRegion {
  final int id;
  final String name;
  final MapBounds bounds;
  final int minZoom, maxZoom, tiles, bytes, created;

  /// Whether every tile of the region has been fetched.
  final bool complete;
  const OfflineRegion({
    required this.id,
    required this.name,
    required this.bounds,
    required this.minZoom,
    required this.maxZoom,
    required this.tiles,
    required this.bytes,
    required this.created,
    required this.complete,
  });
}

/// Vector map tiles on disk: a bounded cache of what has been looked at, and
/// named regions that are kept until deleted. Both are read the same way, so
/// the map works offline anywhere it has been or was downloaded.
///
/// This is its own database file, apart from the profile's: tiles are public
/// map data, large, and can be thrown away without losing anything of the
/// person's.
class TileStore {
  final Database db;

  /// What passing views may take before the least recently used go.
  final int cacheLimit;
  int _cacheBytes = 0;
  TileStore({String? path, this.cacheLimit = 256 * 1024 * 1024})
    : db = path == null ? sqlite3.openInMemory() : sqlite3.open(path) {
    db.execute('PRAGMA busy_timeout=5000');
    db.execute('PRAGMA journal_mode=WAL');
    db.execute('''
      CREATE TABLE IF NOT EXISTS tiles(
        z INTEGER NOT NULL, x INTEGER NOT NULL, y INTEGER NOT NULL,
        data BLOB NOT NULL, used INTEGER NOT NULL,
        PRIMARY KEY(z,x,y)) WITHOUT ROWID;
      CREATE INDEX IF NOT EXISTS tiles_used ON tiles(used);
      CREATE TABLE IF NOT EXISTS regions(
        id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,
        bounds TEXT NOT NULL, min_zoom INTEGER NOT NULL,
        max_zoom INTEGER NOT NULL, tiles INTEGER NOT NULL,
        created INTEGER NOT NULL, complete INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS region_tiles(
        region INTEGER NOT NULL, z INTEGER NOT NULL, x INTEGER NOT NULL,
        y INTEGER NOT NULL, PRIMARY KEY(region,z,x,y)) WITHOUT ROWID;
      CREATE INDEX IF NOT EXISTS region_tiles_tile ON region_tiles(z,x,y);
      CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
    ''');
    _cacheBytes = _unpinnedBytes();
  }

  int _unpinnedBytes() =>
      db
          .select(
            'SELECT COALESCE(SUM(LENGTH(data)),0) b FROM tiles t WHERE NOT EXISTS '
            '(SELECT 1 FROM region_tiles r WHERE r.z=t.z AND r.x=t.x AND r.y=t.y)',
          )
          .first['b']
      as int;

  Uint8List? get(int z, int x, int y) {
    final rows = db.select('SELECT data,used FROM tiles WHERE z=? AND x=? AND y=?', [
      z,
      x,
      y,
    ]);
    if (rows.isEmpty) return null;
    final now = DateTime.now().millisecondsSinceEpoch;
    // Recency is only worth a write now and then.
    if (now - (rows.first['used'] as int) > 3600000) {
      db.execute('UPDATE tiles SET used=? WHERE z=? AND x=? AND y=?', [
        now,
        z,
        x,
        y,
      ]);
    }
    return rows.first['data'] as Uint8List;
  }

  bool has(int z, int x, int y) => db
      .select('SELECT 1 FROM tiles WHERE z=? AND x=? AND y=?', [z, x, y])
      .isNotEmpty;

  /// Stores a tile. Belonging to [region] keeps it; without one it is cache.
  void put(int z, int x, int y, Uint8List data, {int? region}) {
    final had = has(z, x, y);
    db.execute(
      'INSERT INTO tiles VALUES (?,?,?,?,?) ON CONFLICT(z,x,y) DO UPDATE '
      'SET data=excluded.data, used=excluded.used',
      [z, x, y, data, DateTime.now().millisecondsSinceEpoch],
    );
    if (region != null) {
      db.execute('INSERT OR IGNORE INTO region_tiles VALUES (?,?,?,?)', [
        region,
        z,
        x,
        y,
      ]);
    } else if (!had) {
      _cacheBytes += data.length;
      if (_cacheBytes > cacheLimit) _trim();
    }
  }

  /// Drops the least recently used cached tiles down to 90% of the limit.
  void _trim() {
    final target = (cacheLimit * 0.9).floor();
    final rows = db.select(
      'SELECT z,x,y,LENGTH(data) n FROM tiles t WHERE NOT EXISTS '
      '(SELECT 1 FROM region_tiles r WHERE r.z=t.z AND r.x=t.x AND r.y=t.y) '
      'ORDER BY used LIMIT 5000',
    );
    final drop = db.prepare('DELETE FROM tiles WHERE z=? AND x=? AND y=?');
    try {
      for (final row in rows) {
        if (_cacheBytes <= target) break;
        drop.execute([row['z'], row['x'], row['y']]);
        _cacheBytes -= row['n'] as int;
      }
    } finally {
      drop.close();
    }
    if (_cacheBytes > target) _cacheBytes = _unpinnedBytes();
  }

  int get cacheBytes => _cacheBytes;

  /// Bytes held for regions (tiles in two regions count once).
  int get regionBytes =>
      db
              .select(
                'SELECT COALESCE(SUM(LENGTH(data)),0) b FROM tiles t WHERE EXISTS '
                '(SELECT 1 FROM region_tiles r WHERE r.z=t.z AND r.x=t.x AND r.y=t.y)',
              )
              .first['b']
          as int;

  /// Forgets the cache, keeping every region.
  void clearCache() {
    db.execute(
      'DELETE FROM tiles WHERE NOT EXISTS (SELECT 1 FROM region_tiles r '
      'WHERE r.z=tiles.z AND r.x=tiles.x AND r.y=tiles.y)',
    );
    _cacheBytes = 0;
  }

  // Regions.

  int addRegion(String name, MapBounds bounds, int minZoom, int maxZoom) {
    final count = bounds.count(minZoom, maxZoom);
    db.execute(
      'INSERT INTO regions(name,bounds,min_zoom,max_zoom,tiles,created) '
      'VALUES (?,?,?,?,?,?)',
      [
        name,
        '${bounds.south},${bounds.west},${bounds.north},${bounds.east}',
        minZoom,
        maxZoom,
        count,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
    return db.lastInsertRowId;
  }

  void completeRegion(int id) =>
      db.execute('UPDATE regions SET complete=1 WHERE id=?', [id]);

  /// Tiles of region [id] not yet held, so an interrupted download resumes.
  Iterable<(int, int, int)> missing(int id) sync* {
    final r = region(id);
    if (r == null) return;
    for (final (z, x, y) in r.bounds.cover(r.minZoom, r.maxZoom)) {
      if (!has(z, x, y)) {
        yield (z, x, y);
      } else {
        db.execute('INSERT OR IGNORE INTO region_tiles VALUES (?,?,?,?)', [
          id,
          z,
          x,
          y,
        ]);
      }
    }
  }

  OfflineRegion? region(int id) =>
      regions().where((r) => r.id == id).firstOrNull;

  List<OfflineRegion> regions() => [
    for (final row in db.select('SELECT * FROM regions ORDER BY created DESC'))
      () {
        final b = (row['bounds'] as String).split(',').map(double.parse).toList();
        final id = row['id'] as int;
        return OfflineRegion(
          id: id,
          name: row['name'] as String,
          bounds: MapBounds(b[0], b[1], b[2], b[3]),
          minZoom: row['min_zoom'] as int,
          maxZoom: row['max_zoom'] as int,
          tiles: row['tiles'] as int,
          bytes:
              db
                      .select(
                        'SELECT COALESCE(SUM(LENGTH(t.data)),0) b FROM region_tiles r '
                        'JOIN tiles t USING(z,x,y) WHERE r.region=?',
                        [id],
                      )
                      .first['b']
                  as int,
          created: row['created'] as int,
          complete: row['complete'] == 1,
        );
      }(),
  ];

  /// Removes a region. Its tiles go back to being cache, which the limit then
  /// trims, unless another region keeps them.
  void deleteRegion(int id) {
    db.execute('DELETE FROM regions WHERE id=?', [id]);
    db.execute('DELETE FROM region_tiles WHERE region=?', [id]);
    _cacheBytes = _unpinnedBytes();
    if (_cacheBytes > cacheLimit) _trim();
  }

  String? meta(String key) {
    final rows = db.select('SELECT value FROM meta WHERE key=?', [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  void setMeta(String key, String value) => db.execute(
    'INSERT INTO meta VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
    [key, value],
  );

  void close() => db.close();
}
