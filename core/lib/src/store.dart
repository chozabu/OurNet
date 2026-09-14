import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';
import 'package:sqlite3/sqlite3.dart';
import 'model.dart';

class Store {
  final Database db;
  final String? path;
  Store({this.path})
    : db = path == null ? sqlite3.openInMemory() : sqlite3.open(path) {
    if ((db.select('PRAGMA user_version').first['user_version'] as int) > 1) {
      db.close();
      throw StateError('This database needs a newer OurNet version');
    }
    db.execute('PRAGMA busy_timeout=5000');
    db.execute('PRAGMA journal_mode=WAL');
    db.execute('''CREATE TABLE IF NOT EXISTS objects (
      id TEXT PRIMARY KEY, kind TEXT NOT NULL, space TEXT NOT NULL,
      author TEXT NOT NULL, created INTEGER NOT NULL, wire TEXT NOT NULL);
      CREATE INDEX IF NOT EXISTS objects_view ON objects(kind,space,created);
      CREATE TABLE IF NOT EXISTS evidence(id TEXT PRIMARY KEY, object_id TEXT NOT NULL, wire TEXT NOT NULL);
      CREATE INDEX IF NOT EXISTS evidence_object ON evidence(object_id);
      CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS blobs(id TEXT PRIMARY KEY, bytes BLOB NOT NULL);
    ''');
    db.execute('PRAGMA user_version=1');
    db.execute('''CREATE TABLE IF NOT EXISTS previews(
      id TEXT PRIMARY KEY, bytes BLOB NOT NULL, size INTEGER NOT NULL, used INTEGER NOT NULL);
      CREATE INDEX IF NOT EXISTS previews_used ON previews(used);
    ''');
    // Maintain the quota across connections without scanning every blob for
    // every chunk. Triggers also cover direct deletes and transaction rollback.
    db.execute('''
      CREATE TABLE IF NOT EXISTS blob_usage(id INTEGER PRIMARY KEY CHECK(id=1), bytes INTEGER NOT NULL);
      INSERT OR IGNORE INTO blob_usage SELECT 1, COALESCE(SUM(length(bytes)),0) FROM blobs;
      CREATE TRIGGER IF NOT EXISTS blob_quota BEFORE INSERT ON blobs
      WHEN NOT EXISTS(SELECT 1 FROM blobs WHERE id=NEW.id)
        AND (SELECT bytes FROM blob_usage WHERE id=1)+length(NEW.bytes)>536870912
      BEGIN SELECT RAISE(ABORT, 'Blob storage limit is 512 MiB'); END;
      CREATE TRIGGER IF NOT EXISTS blob_added AFTER INSERT ON blobs
      BEGIN UPDATE blob_usage SET bytes=bytes+length(NEW.bytes) WHERE id=1; END;
      CREATE TRIGGER IF NOT EXISTS blob_removed AFTER DELETE ON blobs
      BEGIN UPDATE blob_usage SET bytes=bytes-length(OLD.bytes) WHERE id=1; END;
      CREATE TRIGGER IF NOT EXISTS blob_updated AFTER UPDATE OF bytes ON blobs
      BEGIN UPDATE blob_usage SET bytes=bytes+length(NEW.bytes)-length(OLD.bytes) WHERE id=1; END;
    ''');
  }

  /// Encrypted local previews (e.g. list thumbnails) are derived data. They are
  /// bounded separately from original chunks and evicted least-recently-used.
  static const maxPreviewBytes = 128 * 1024 * 1024;
  static const maxPreviewSize = 2 * 1024 * 1024;

  // Stored objects are immutable, so parsed copies can be shared. Bounded.
  static const _parsedLimit = 8000;
  final _parsed = LinkedHashMap<String, SignedObject>();

  SignedObject _parse(String id, String wire) {
    final cached = _parsed.remove(id);
    final object = cached ?? SignedObject.fromJson(jsonDecode(wire));
    _parsed[id] = object;
    if (_parsed.length > _parsedLimit) _parsed.remove(_parsed.keys.first);
    return object;
  }

  bool put(SignedObject object) {
    db.execute('INSERT OR IGNORE INTO objects VALUES (?,?,?,?,?,?)', [
      object.id,
      object.kind,
      object.space,
      object.author,
      object.created,
      canonical(object.toJson()),
    ]);
    return db.updatedRows > 0;
  }

  SignedObject? get(String id) {
    final cached = _parsed[id];
    if (cached != null) return cached;
    final rows = db.select('SELECT wire FROM objects WHERE id=?', [id]);
    return rows.isEmpty ? null : _parse(id, rows.first['wire']);
  }

  List<SignedObject> objects({
    String? kind,
    List<String>? kinds,
    String? space,
    int limit = 1000,
  }) {
    var where = kind != null
        ? 'WHERE kind=?'
        : kinds != null
        ? 'WHERE kind IN (${List.filled(kinds.length, '?').join(',')})'
        : '';
    final args = [if (kind != null) kind else if (kinds != null) ...kinds];
    if (space != null) {
      where += '${where.isEmpty ? 'WHERE' : ' AND'} space=?';
      args.add(space);
    }
    // Select IDs first; only objects not already parsed transfer their wire.
    final ids = db
        .select(
          'SELECT id FROM objects $where ORDER BY created DESC,id LIMIT ?',
          [...args, limit],
        )
        .map((r) => r['id'] as String)
        .toList();
    final missing = ids.where((id) => !_parsed.containsKey(id)).toList();
    final wires = <String, String>{};
    for (var i = 0; i < missing.length; i += 500) {
      final page = missing.skip(i).take(500).toList();
      for (final row in db.select(
        'SELECT id, wire FROM objects WHERE id IN (SELECT value FROM json_each(?))',
        [jsonEncode(page)],
      )) {
        wires[row['id'] as String] = row['wire'] as String;
      }
    }
    return [
      for (final id in ids)
        if (_parsed[id] case final object?)
          object
        else if (wires[id] case final wire?)
          _parse(id, wire),
    ];
  }

  List<String> ids({int limit = 10000}) => db
      .select('SELECT id FROM objects ORDER BY id LIMIT ?', [limit])
      .map((r) => r['id'] as String)
      .toList();

  /// Insertion cursor, independent of untrusted sender timestamps. Readers
  /// process bounded pages and never rescan unrelated history on refresh.
  List<(int, SignedObject)> insertedAfter(
    int cursor,
    List<String> kinds, {
    int limit = 128,
  }) => [
    for (final row in db.select(
      'SELECT rowid, id, wire FROM objects WHERE rowid>? AND kind IN '
      '(SELECT value FROM json_each(?)) ORDER BY rowid LIMIT ?',
      [cursor, jsonEncode(kinds), limit.clamp(1, 128)],
    ))
      (row['rowid'] as int, _parse(row['id'] as String, row['wire'] as String)),
  ];
  List<SignedObject> unread(String kind, String person) => [
    for (final row in db.select(
      "SELECT o.id, o.wire FROM objects o LEFT JOIN settings s ON s.key=? || o.id WHERE o.kind=? AND o.author!=? AND (s.value IS NULL OR s.value!='true')",
      [kind == 'message' ? 'read/' : 'seen/', kind, person],
    ))
      _parse(row['id'] as String, row['wire'] as String),
  ];
  int get count =>
      db.select('SELECT COUNT(*) AS n FROM objects').first['n'] as int;
  bool putEvidence(Evidence evidence) {
    db.execute('INSERT OR IGNORE INTO evidence VALUES (?,?,?)', [
      evidence.id,
      evidence.objectId,
      canonical(evidence.toJson()),
    ]);
    return db.updatedRows > 0;
  }

  /// Sorted evidence IDs per object, from one query without parsing records.
  Map<String, List<String>> evidenceIds() {
    final result = <String, List<String>>{};
    for (final row in db.select(
      'SELECT object_id, id FROM evidence ORDER BY object_id, id',
    )) {
      (result[row['object_id'] as String] ??= []).add(row['id'] as String);
    }
    return result;
  }

  List<Evidence> evidence(String objectId) => db
      .select('SELECT wire FROM evidence WHERE object_id=? ORDER BY id', [
        objectId,
      ])
      .map((r) => Evidence.fromJson(jsonDecode(r['wire'])))
      .toList();
  void set(String key, Object? value) => db.execute(
    'INSERT INTO settings VALUES (?,?) '
    'ON CONFLICT(key) DO UPDATE SET value=excluded.value '
    'WHERE settings.value != excluded.value',
    [key, canonical(value)],
  );

  /// Keys of settings with [prefix] whose value is `true`, in one query.
  Set<String> trueSettings(String prefix) => {
    for (final row in db.select(
      "SELECT key FROM settings WHERE key >= ? AND key < ? AND value='true'",
      [prefix, '$prefix\u{10FFFF}'],
    ))
      (row['key'] as String).substring(prefix.length),
  };

  dynamic setting(String key) {
    final rows = db.select('SELECT value FROM settings WHERE key=?', [key]);
    return rows.isEmpty ? null : jsonDecode(rows.first['value']);
  }

  void putBlob(String id, List<int> bytes) {
    if (bytes.length > 128 * 1024 + 64 || blobHash(bytes) != id)
      throw StateError('Invalid blob');
    if (hasBlob(id)) return;
    final total =
        db.select('SELECT bytes FROM blob_usage WHERE id=1').first['bytes']
            as int;
    if (total + bytes.length > 512 * 1024 * 1024)
      throw StateError('Blob storage limit is 512 MiB');
    db.execute('INSERT INTO blobs VALUES (?,?)', [
      id,
      Uint8List.fromList(bytes),
    ]);
  }

  List<int>? blob(String id) {
    final rows = db.select('SELECT bytes FROM blobs WHERE id=?', [id]);
    return rows.isEmpty ? null : rows.first['bytes'] as Uint8List;
  }

  bool hasBlob(String id) =>
      db.select('SELECT 1 FROM blobs WHERE id=?', [id]).isNotEmpty;

  /// One query for a file's chunk list instead of one query per chunk.
  bool hasBlobs(List<String> ids) =>
      ids.isEmpty ||
      db.select(
            'SELECT COUNT(*) AS n FROM blobs WHERE id IN (SELECT DISTINCT value FROM json_each(?))',
            [jsonEncode(ids)],
          ).first['n'] ==
          ids.toSet().length;

  Uint8List? preview(String id) {
    final rows = db.select('SELECT bytes, used FROM previews WHERE id=?', [id]);
    if (rows.isEmpty) return null;
    final now = DateTime.now().millisecondsSinceEpoch;
    // Refresh recency coarsely to avoid a write for every read.
    if ((rows.first['used'] as int) < now - 60 * 60 * 1000) {
      db.execute('UPDATE previews SET used=? WHERE id=?', [now, id]);
    }
    return rows.first['bytes'] as Uint8List;
  }

  void putPreview(String id, List<int> bytes) {
    if (bytes.length > maxPreviewSize) throw StateError('Preview too large');
    db.execute('INSERT OR REPLACE INTO previews VALUES (?,?,?,?)', [
      id,
      Uint8List.fromList(bytes),
      bytes.length,
      DateTime.now().millisecondsSinceEpoch,
    ]);
    var total =
        db.select('SELECT COALESCE(SUM(size),0) AS n FROM previews').first['n']
            as int;
    if (total <= maxPreviewBytes) return;
    for (final row in db.select(
      'SELECT id, size FROM previews WHERE id!=? ORDER BY used LIMIT 256',
      [id],
    )) {
      db.execute('DELETE FROM previews WHERE id=?', [row['id']]);
      total -= row['size'] as int;
      if (total <= maxPreviewBytes * 0.9) break;
    }
  }

  void close() => db.close();
}
