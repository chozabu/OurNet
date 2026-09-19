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
      CREATE INDEX IF NOT EXISTS objects_kind ON objects(kind);
      CREATE INDEX IF NOT EXISTS objects_recent ON objects(created DESC,id);
      CREATE TABLE IF NOT EXISTS evidence(id TEXT PRIMARY KEY, object_id TEXT NOT NULL, wire TEXT NOT NULL);
      CREATE INDEX IF NOT EXISTS evidence_object ON evidence(object_id);
      CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS blobs(id TEXT PRIMARY KEY, bytes BLOB NOT NULL);
    ''');
    db.execute('PRAGMA user_version=1');
    // Derived routing index contains no plaintext message payloads.
    if (db
        .select("SELECT name FROM sqlite_master WHERE name='message_peers'")
        .isEmpty) {
      db.execute('''BEGIN IMMEDIATE;
        CREATE TABLE message_peers(owner TEXT NOT NULL, peer TEXT NOT NULL,
          id TEXT NOT NULL, created INTEGER NOT NULL, PRIMARY KEY(owner,peer,id));
        CREATE INDEX message_history ON message_peers(owner,peer,created DESC,id);
        INSERT OR IGNORE INTO message_peers
          SELECT o.author,j.value,o.id,o.created FROM objects o,
          json_each(o.wire,'\$.data.audience') j
          WHERE o.kind='message' AND j.value!=o.author;
        INSERT OR IGNORE INTO message_peers
          SELECT j.value,o.author,o.id,o.created FROM objects o,
          json_each(o.wire,'\$.data.audience') j
          WHERE o.kind='message' AND j.value!=o.author;
        COMMIT;
      ''');
    }
    db.execute(
      'CREATE INDEX IF NOT EXISTS message_object ON message_peers(id)',
    );
    db.execute('''
      CREATE TRIGGER IF NOT EXISTS message_added AFTER INSERT ON objects
      WHEN NEW.kind='message' BEGIN
        INSERT OR IGNORE INTO message_peers
          SELECT NEW.author,value,NEW.id,NEW.created
          FROM json_each(NEW.wire,'\$.data.audience') WHERE value!=NEW.author;
        INSERT OR IGNORE INTO message_peers
          SELECT value,NEW.author,NEW.id,NEW.created
          FROM json_each(NEW.wire,'\$.data.audience') WHERE value!=NEW.author;
      END;
      CREATE TRIGGER IF NOT EXISTS message_removed AFTER DELETE ON objects
      BEGIN DELETE FROM message_peers WHERE id=OLD.id; END;
    ''');

    if (db
        .select("SELECT name FROM sqlite_master WHERE name='message_unread'")
        .isEmpty) {
      db.execute('''BEGIN IMMEDIATE;
        CREATE TABLE message_unread(owner TEXT NOT NULL, peer TEXT NOT NULL,
          id TEXT NOT NULL, expires INTEGER NOT NULL, PRIMARY KEY(owner,peer,id));
        CREATE INDEX message_unread_object ON message_unread(id);
        CREATE INDEX message_unread_expiry ON message_unread(expires);
        CREATE TABLE message_counts(owner TEXT NOT NULL, peer TEXT NOT NULL,
          unread INTEGER NOT NULL, PRIMARY KEY(owner,peer));
        CREATE TRIGGER message_unread_increment AFTER INSERT ON message_unread
        BEGIN
          INSERT INTO message_counts VALUES(NEW.owner,NEW.peer,1)
          ON CONFLICT(owner,peer) DO UPDATE SET unread=unread+1;
        END;
        CREATE TRIGGER message_unread_decrement AFTER DELETE ON message_unread
        BEGIN
          UPDATE message_counts SET unread=unread-1 WHERE owner=OLD.owner AND peer=OLD.peer;
        END;
        INSERT INTO message_unread
          SELECT p.owner,p.peer,p.id,json_extract(o.wire,'\$.data.expires')
          FROM message_peers p JOIN objects o ON o.id=p.id
          LEFT JOIN settings s ON s.key='read/' || p.id
          WHERE p.owner!=o.author AND COALESCE(s.value,'false')!='true';
        COMMIT;
      ''');
    }
    db.execute('''
      CREATE TRIGGER IF NOT EXISTS message_unread_arrived AFTER INSERT ON message_peers
      BEGIN
        INSERT OR IGNORE INTO message_unread
          SELECT NEW.owner,NEW.peer,NEW.id,json_extract(o.wire,'\$.data.expires')
          FROM objects o LEFT JOIN settings s ON s.key='read/' || o.id
          WHERE o.id=NEW.id AND NEW.owner!=o.author AND COALESCE(s.value,'false')!='true';
      END;
      CREATE TRIGGER IF NOT EXISTS message_unread_removed AFTER DELETE ON message_peers
      BEGIN DELETE FROM message_unread WHERE owner=OLD.owner AND peer=OLD.peer AND id=OLD.id; END;
    ''');
    for (final event in ['INSERT', 'UPDATE']) {
      db.execute('''
        CREATE TRIGGER IF NOT EXISTS message_read_${event.toLowerCase()} AFTER $event ON settings
        WHEN substr(NEW.key,1,5)='read/' BEGIN
          DELETE FROM message_unread WHERE id=substr(NEW.key,6) AND NEW.value='true';
          INSERT OR IGNORE INTO message_unread
            SELECT p.owner,p.peer,p.id,json_extract(o.wire,'\$.data.expires')
            FROM message_peers p JOIN objects o ON o.id=p.id
            WHERE p.id=substr(NEW.key,6) AND p.owner!=o.author AND NEW.value!='true';
        END;
      ''');
    }

    // Derived sharing index: the fields that decide whether an object may be
    // offered to a peer, extracted once when it is stored rather than out of
    // every object on every sync page. Contains no plaintext payloads.
    if (db
        .select("SELECT name FROM sqlite_master WHERE name='object_routes'")
        .isEmpty) {
      db.execute('''BEGIN IMMEDIATE;
        CREATE TABLE object_routes(id TEXT PRIMARY KEY, kind TEXT NOT NULL,
          space TEXT NOT NULL, author TEXT NOT NULL, created INTEGER NOT NULL,
          device TEXT NOT NULL, expires INTEGER NOT NULL,
          audience TEXT NOT NULL, via TEXT NOT NULL);
        CREATE INDEX object_routes_order ON object_routes(created DESC,id);
        INSERT OR IGNORE INTO object_routes SELECT o.id, o.kind, o.space,
          o.author, o.created, json_extract(o.wire,'\$.certificate.data.device'),
          json_extract(o.wire,'\$.data.expires'),
          json_extract(o.wire,'\$.data.audience'),
          json_extract(o.wire,'\$.data.via') FROM objects o;
        COMMIT;
      ''');
    }
    db.execute('''
      CREATE TRIGGER IF NOT EXISTS object_route_added AFTER INSERT ON objects
      BEGIN
        INSERT OR IGNORE INTO object_routes VALUES(NEW.id, NEW.kind, NEW.space,
          NEW.author, NEW.created,
          json_extract(NEW.wire,'\$.certificate.data.device'),
          json_extract(NEW.wire,'\$.data.expires'),
          json_extract(NEW.wire,'\$.data.audience'),
          json_extract(NEW.wire,'\$.data.via'));
      END;
      CREATE TRIGGER IF NOT EXISTS object_route_removed AFTER DELETE ON objects
      BEGIN DELETE FROM object_routes WHERE id=OLD.id; END;
    ''');

    // Objects are bounded by the bytes they occupy, not by a count: one
    // object ranges up to 256 KiB, so a row total says nothing about disk.
    // Existing databases gain the accounting without rewriting content.
    // Stored objects are immutable (the ID is their content hash), so there
    // is no update trigger: only inserts and deletes can move the total.
    db.execute('''
      CREATE TABLE IF NOT EXISTS object_usage(id INTEGER PRIMARY KEY CHECK(id=1), bytes INTEGER NOT NULL);
      INSERT OR IGNORE INTO object_usage SELECT 1, COALESCE(SUM(length(wire)),0) FROM objects;
      CREATE TRIGGER IF NOT EXISTS object_added AFTER INSERT ON objects
      BEGIN UPDATE object_usage SET bytes=bytes+length(NEW.wire) WHERE id=1; END;
      CREATE TRIGGER IF NOT EXISTS object_removed AFTER DELETE ON objects
      BEGIN UPDATE object_usage SET bytes=bytes-length(OLD.wire) WHERE id=1; END;
    ''');

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

  // Statements are compiled once: sync and list refreshes run the same few
  // queries for every object, and compiling them each time was measurable.
  final _statements = <String, PreparedStatement>{};
  PreparedStatement _statement(String sql) =>
      _statements[sql] ??= db.prepare(sql, persistent: true);
  ResultSet _select(String sql, [List<Object?> parameters = const []]) =>
      _statement(sql).select(parameters);
  void _execute(String sql, [List<Object?> parameters = const []]) =>
      _statement(sql).execute(parameters);

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

  /// Runs synchronous [writes] as one transaction: one disk sync for the
  /// batch instead of one per row, which stalls the UI isolate on phones.
  T batch<T>(T Function() writes) {
    db.execute('BEGIN IMMEDIATE');
    try {
      final result = writes();
      db.execute('COMMIT');
      return result;
    } catch (_) {
      db.execute('ROLLBACK');
      // Reload rather than trust rows that were rolled back.
      _evidenceSets.clear();
      _evidenceRecords.clear();
      rethrow;
    }
  }

  bool put(SignedObject object) {
    _execute('INSERT OR IGNORE INTO objects VALUES (?,?,?,?,?,?)', [
      object.id,
      object.kind,
      object.space,
      object.author,
      object.created,
      object.wire,
    ]);
    return db.updatedRows > 0;
  }

  SignedObject? get(String id) {
    final cached = _parsed[id];
    if (cached != null) return cached;
    final rows = _select('SELECT wire FROM objects WHERE id=?', [id]);
    return rows.isEmpty ? null : _parse(id, rows.first['wire']);
  }

  /// Incremental unread totals, excluding blocked authors and expired records.
  int conversationUnread(
    String owner, {
    String? peer,
    Set<String> blocked = const {},
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _execute('DELETE FROM message_unread WHERE expires>0 AND expires<=?', [
      now,
    ]);
    return _select(
          'SELECT COALESCE(SUM(unread),0) AS n FROM message_counts WHERE owner=? '
          '${peer == null ? '' : 'AND peer=? '}'
          'AND peer NOT IN (SELECT value FROM json_each(?))',
          [owner, if (peer != null) peer, jsonEncode(blocked.toList())],
        ).first['n']
        as int;
  }

  /// Unread messages from [peer] to [owner], newest first.
  List<SignedObject> unreadMessages(
    String owner,
    String peer, {
    int limit = 50,
  }) => [
    for (final row in _select(
      'SELECT u.id FROM message_unread u JOIN message_peers p '
      'ON p.owner=u.owner AND p.peer=u.peer AND p.id=u.id '
      'WHERE u.owner=? AND u.peer=? AND (u.expires IS NULL OR u.expires<=0 '
      'OR u.expires>?) ORDER BY p.created DESC,p.id LIMIT ?',
      [owner, peer, DateTime.now().millisecondsSinceEpoch, limit.clamp(1, 200)],
    ))
      if (get(row['id'] as String) case final object?) object,
  ];

  /// Stable newest-first keyset pagination, including timestamp ties.
  List<SignedObject> conversation(
    String owner,
    String peer, {
    SignedObject? before,
    int limit = 50,
  }) => [
    for (final row in _select(
      'SELECT id FROM message_peers WHERE owner=? AND peer=? '
      '${before == null ? '' : 'AND (created<? OR (created=? AND id>?)) '}'
      'ORDER BY created DESC,id LIMIT ?',
      [
        owner,
        peer,
        if (before != null) ...[before.created, before.created, before.id],
        limit.clamp(1, 200),
      ],
    ))
      if (get(row['id'] as String) case final object?) object,
  ];

  /// Arrival order, independent of signed wall clocks. Used by derived views
  /// to consume new immutable records without revisiting retained history.
  List<(int, SignedObject)> objectsAfter(String kind, int cursor) => [
    for (final row in _select(
      'SELECT rowid,id FROM objects WHERE kind=? AND rowid>? ORDER BY rowid LIMIT 256',
      [kind, cursor],
    ))
      (row['rowid'] as int, get(row['id'] as String)!),
  ];

  /// Objects newest first. [after] resumes just past one already returned, so
  /// a view that must look at every object of a kind reads it in pages
  /// instead of choosing a limit and quietly stopping there.
  List<SignedObject> objects({
    String? kind,
    List<String>? kinds,
    String? space,
    String? author,
    (int, String)? after,
    int limit = 1000,
  }) {
    var where = kind != null
        ? 'WHERE kind=?'
        : kinds != null
        ? 'WHERE kind IN (${List.filled(kinds.length, '?').join(',')})'
        : '';
    final args = <Object?>[
      if (kind != null) kind else if (kinds != null) ...kinds,
    ];
    if (space != null) {
      where += '${where.isEmpty ? 'WHERE' : ' AND'} space=?';
      args.add(space);
    }
    if (author != null) {
      where += '${where.isEmpty ? 'WHERE' : ' AND'} author=?';
      args.add(author);
    }
    if (after != null) {
      where +=
          '${where.isEmpty ? 'WHERE' : ' AND'} (created<? OR (created=? AND id>?))';
      args.addAll([after.$1, after.$1, after.$2]);
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
      for (final row in _select(
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

  /// Creation times and IDs newest first, without reading or parsing the
  /// objects. [from] and [until] bound the window of creation times a sync
  /// page reconciles; [after] resumes just past an entry already examined, so
  /// a window is walked in bounded pages however much history it spans.
  List<(int, String)> recentEntries({
    int limit = 512,
    int from = 0,
    int? until,
    (int, String)? after,
  }) => [
    for (final row in _select(
      'SELECT created, id FROM objects WHERE created>=? AND created<=? '
      '${after == null ? '' : 'AND (created<? OR (created=? AND id>?)) '}'
      'ORDER BY created DESC,id LIMIT ?',
      [
        from,
        until ?? 253402300799999,
        if (after != null) ...[after.$1, after.$1, after.$2],
        limit,
      ],
    ))
      (row['created'] as int, row['id'] as String),
  ];

  List<String> ids({int limit = 10000}) => [
    for (final row in _select('SELECT id FROM objects ORDER BY id LIMIT ?', [
      limit,
    ]))
      row['id'] as String,
  ];

  /// Sharing fields of stored objects, for inventories, newest first in the
  /// order a sync page walks them. They come from the derived index, so a
  /// page costs an index scan rather than reparsing objects. [after] resumes
  /// just past an entry already examined, so a caller reads the pages it
  /// needs instead of holding every object's route in memory for the life of
  /// the process.
  List<ObjectRoute> routesAfter({(int, String)? after, int limit = 512}) => [
    for (final row in _select(
      'SELECT id,kind,space,author,created,device,expires,audience,via '
      'FROM object_routes '
      '${after == null ? '' : 'WHERE created<? OR (created=? AND id>?) '}'
      'ORDER BY created DESC,id LIMIT ?',
      [
        if (after != null) ...[after.$1, after.$1, after.$2],
        limit,
      ],
    ))
      ObjectRoute(
        id: row['id'] as String,
        kind: row['kind'] as String,
        space: row['space'] as String,
        author: row['author'] as String,
        created: row['created'] as int,
        device: row['device'] as String,
        expires: row['expires'] as int,
        audience: (jsonDecode(row['audience'] as String) as List)
            .cast<String>(),
        via: (jsonDecode(row['via'] as String) as List).cast<String>(),
      ),
  ];

  /// Every stored object matching the filter, newest first, read in pages.
  ///
  /// For the reads whose correctness depends on seeing all of something —
  /// one note's operations, one group's items — where a limit would not cut
  /// off a view but silently drop records that are still live. Bounded by
  /// what is asked for, so callers scope it to a kind and a space.
  List<SignedObject> allOf({String? kind, List<String>? kinds, String? space}) {
    final result = <SignedObject>[];
    (int, String)? after;
    while (true) {
      final page = objects(
        kind: kind,
        kinds: kinds,
        space: space,
        after: after,
        limit: 512,
      );
      if (page.isEmpty) return result;
      result.addAll(page);
      after = (page.last.created, page.last.id);
    }
  }

  /// Distinct spaces holding objects of [kinds].
  List<String> spaces(List<String> kinds) => [
    for (final row in _select(
      'SELECT DISTINCT space FROM objects WHERE kind IN '
      '(SELECT value FROM json_each(?))',
      [jsonEncode(kinds)],
    ))
      row['space'] as String,
  ];

  int get insertionCursor =>
      (_select('SELECT MAX(rowid) AS n FROM objects').first['n'] as int?) ?? 0;

  /// Insertion cursor, independent of untrusted sender timestamps. Readers
  /// process bounded pages and never rescan unrelated history on refresh.
  List<(int, SignedObject)> insertedAfter(
    int cursor,
    List<String> kinds, {
    int limit = 128,
  }) => [
    for (final row in _select(
      'SELECT rowid, id, wire FROM objects WHERE rowid>? AND kind IN '
      '(SELECT value FROM json_each(?)) ORDER BY rowid LIMIT ?',
      [cursor, jsonEncode(kinds), limit.clamp(1, 128)],
    ))
      (row['rowid'] as int, _parse(row['id'] as String, row['wire'] as String)),
  ];
  List<SignedObject> unread(String kind, String person) => [
    for (final row in _select(
      "SELECT o.id, o.wire FROM objects o LEFT JOIN settings s ON s.key=? || o.id WHERE o.kind=? AND o.author!=? AND (s.value IS NULL OR s.value!='true')",
      [kind == 'message' ? 'read/' : 'seen/', kind, person],
    ))
      _parse(row['id'] as String, row['wire'] as String),
  ];
  int get count =>
      _select('SELECT COUNT(*) AS n FROM objects').first['n'] as int;

  /// Bytes the stored objects occupy, maintained by trigger across
  /// connections and transactions. What a storage budget is measured in.
  int get objectBytes =>
      _select('SELECT bytes FROM object_usage WHERE id=1').first['bytes']
          as int;
  bool putEvidence(Evidence evidence) {
    _execute('INSERT OR IGNORE INTO evidence VALUES (?,?,?)', [
      evidence.id,
      evidence.objectId,
      evidence.wire,
    ]);
    final added = db.updatedRows > 0;
    if (added) {
      _evidenceRecords.remove(evidence.objectId);
      _evidenceSets.remove(evidence.objectId);
    }
    return added;
  }

  /// Sorted evidence IDs for one object. Reading every object's evidence into
  /// memory would grow with stored history without bound, so this is a
  /// bounded cache over an indexed lookup: [putEvidence] and [removeEvidence]
  /// are the only writers of evidence rows and drop what they change.
  _EvidenceSet _evidenceSet(String objectId) {
    final cached = _evidenceSets.remove(objectId);
    final set = cached ?? _EvidenceSet();
    if (cached == null) {
      for (final row in _select(
        'SELECT id FROM evidence WHERE object_id=? ORDER BY id',
        [objectId],
      )) {
        set.add(row['id'] as String);
      }
    }
    _evidenceSets[objectId] = set;
    if (_evidenceSets.length > _evidenceLimit) {
      _evidenceSets.remove(_evidenceSets.keys.first);
    }
    return set;
  }

  // Comfortably more than the objects one inventory page reconciles, so a
  // sync page never evicts a digest it is still comparing.
  static const _evidenceLimit = 4096;
  final _evidenceSets = LinkedHashMap<String, _EvidenceSet>();

  /// Loads evidence for a page of objects in one query.
  ///
  /// Sync compares a digest for every object it walks past, and most of them
  /// are already reconciled. Asking per object would make skipping one cost a
  /// query; this keeps the skip a map lookup without holding every object's
  /// evidence at once.
  void primeEvidence(List<String> objectIds) {
    final missing = [
      for (final id in objectIds)
        if (!_evidenceSets.containsKey(id)) id,
    ];
    if (missing.isEmpty) return;
    final found = <String, _EvidenceSet>{};
    for (final row in _select(
      'SELECT object_id, id FROM evidence WHERE object_id IN '
      '(SELECT value FROM json_each(?)) ORDER BY object_id, id',
      [jsonEncode(missing)],
    )) {
      (found[row['object_id'] as String] ??= _EvidenceSet()).add(
        row['id'] as String,
      );
    }
    for (final id in missing) {
      _evidenceSets[id] = found[id] ?? _EvidenceSet();
      if (_evidenceSets.length > _evidenceLimit) {
        _evidenceSets.remove(_evidenceSets.keys.first);
      }
    }
  }

  /// Inventory digest of an object's evidence IDs. Sync compares these for
  /// every object on every page, so each digest is computed once per change.
  String evidenceDigest(String objectId) => _evidenceSet(objectId).digestOf();

  /// Whether evidence [id] for [objectId] is stored (and so was verified).
  bool hasEvidence(String objectId, String id) =>
      _evidenceSet(objectId).ids.contains(id);

  /// Parsed evidence for an object, sorted by ID. Sync reads it for every
  /// offered or received item, so recent results are kept until it changes.
  List<Evidence> evidence(String objectId) {
    final cached = _evidenceRecords.remove(objectId);
    final records =
        cached ??
        List<Evidence>.unmodifiable(
          _select('SELECT wire FROM evidence WHERE object_id=? ORDER BY id', [
            objectId,
          ]).map((r) => Evidence.fromJson(jsonDecode(r['wire']))),
        );
    _evidenceRecords[objectId] = records;
    if (_evidenceRecords.length > 1024) {
      _evidenceRecords.remove(_evidenceRecords.keys.first);
    }
    return records;
  }

  final _evidenceRecords = LinkedHashMap<String, List<Evidence>>();

  /// Objects holding evidence signed by any of [devices].
  Set<String> objectsWithEvidenceFrom(Set<String> devices) => {
    for (final row in _select(
      'SELECT DISTINCT object_id FROM evidence WHERE '
      "json_extract(wire, '\$.certificate.data.device') IN "
      '(SELECT value FROM json_each(?))',
      [jsonEncode(devices.toList())],
    ))
      row['object_id'] as String,
  };

  /// Deletes evidence records, e.g. those withdrawn by a revocation.
  void removeEvidence(Iterable<String> ids) {
    for (final id in ids) {
      _execute('DELETE FROM evidence WHERE id=?', [id]);
    }
    _evidenceSets.clear();
    _evidenceRecords.clear();
  }

  void set(String key, Object? value) => _execute(
    'INSERT INTO settings VALUES (?,?) '
    'ON CONFLICT(key) DO UPDATE SET value=excluded.value '
    'WHERE settings.value != excluded.value',
    [key, canonical(value)],
  );

  /// Keys of settings with [prefix] whose value is `true`, in one query.
  Set<String> trueSettings(String prefix) => {
    for (final row in _select(
      "SELECT key FROM settings WHERE key >= ? AND key < ? AND value='true'",
      [prefix, '$prefix\u{10FFFF}'],
    ))
      (row['key'] as String).substring(prefix.length),
  };

  Map<String, dynamic> settingsUnder(String prefix) => {
    for (final row in _select(
      'SELECT key,value FROM settings WHERE key>=? AND key<?',
      [prefix, '$prefix\u{10FFFF}'],
    ))
      (row['key'] as String).substring(prefix.length): jsonDecode(
        row['value'] as String,
      ),
  };

  void removeSettingsUnder(String prefix) => _execute(
    'DELETE FROM settings WHERE key>=? AND key<?',
    [prefix, '$prefix\u{10FFFF}'],
  );

  dynamic setting(String key) {
    final rows = _select('SELECT value FROM settings WHERE key=?', [key]);
    return rows.isEmpty ? null : jsonDecode(rows.first['value']);
  }

  void putBlob(String id, List<int> bytes) {
    if (bytes.length > 128 * 1024 + 64 || blobHash(bytes) != id)
      throw StateError('Invalid blob');
    if (hasBlob(id)) return;
    final total =
        _select('SELECT bytes FROM blob_usage WHERE id=1').first['bytes']
            as int;
    if (total + bytes.length > 512 * 1024 * 1024)
      throw StateError('Blob storage limit is 512 MiB');
    _execute('INSERT INTO blobs VALUES (?,?)', [id, Uint8List.fromList(bytes)]);
  }

  List<int>? blob(String id) {
    final rows = _select('SELECT bytes FROM blobs WHERE id=?', [id]);
    return rows.isEmpty ? null : rows.first['bytes'] as Uint8List;
  }

  bool hasBlob(String id) =>
      _select('SELECT 1 FROM blobs WHERE id=?', [id]).isNotEmpty;

  /// One query for a file's chunk list instead of one query per chunk.
  bool hasBlobs(List<String> ids) =>
      ids.isEmpty ||
      _select(
            'SELECT COUNT(*) AS n FROM blobs WHERE id IN (SELECT DISTINCT value FROM json_each(?))',
            [jsonEncode(ids)],
          ).first['n'] ==
          ids.toSet().length;

  Uint8List? preview(String id) {
    final rows = _select('SELECT bytes, used FROM previews WHERE id=?', [id]);
    if (rows.isEmpty) return null;
    final now = DateTime.now().millisecondsSinceEpoch;
    // Refresh recency coarsely to avoid a write for every read.
    if ((rows.first['used'] as int) < now - 60 * 60 * 1000) {
      _execute('UPDATE previews SET used=? WHERE id=?', [now, id]);
    }
    return rows.first['bytes'] as Uint8List;
  }

  void putPreview(String id, List<int> bytes) {
    if (bytes.length > maxPreviewSize) throw StateError('Preview too large');
    _execute('INSERT OR REPLACE INTO previews VALUES (?,?,?,?)', [
      id,
      Uint8List.fromList(bytes),
      bytes.length,
      DateTime.now().millisecondsSinceEpoch,
    ]);
    var total =
        _select('SELECT COALESCE(SUM(size),0) AS n FROM previews').first['n']
            as int;
    if (total <= maxPreviewBytes) return;
    for (final row in _select(
      'SELECT id, size FROM previews WHERE id!=? ORDER BY used LIMIT 256',
      [id],
    )) {
      _execute('DELETE FROM previews WHERE id=?', [row['id']]);
      total -= row['size'] as int;
      if (total <= maxPreviewBytes * 0.9) break;
    }
  }

  void close() {
    for (final statement in _statements.values) {
      statement.close();
    }
    db.close();
  }
}

/// The fields that decide whether an object may be offered to a peer.
class ObjectRoute {
  final String id, kind, space, author, device;
  final int created, expires;
  final List<String> audience, via;
  const ObjectRoute({
    required this.id,
    required this.kind,
    required this.space,
    required this.author,
    required this.created,
    required this.device,
    required this.expires,
    required this.audience,
    required this.via,
  });
  ObjectRoute.of(SignedObject o)
    : this(
        id: o.id,
        kind: o.kind,
        space: o.space,
        author: o.author,
        created: o.created,
        device: o.certificate.device,
        expires: o.expires,
        audience: o.audience,
        via: (o.data['via'] as List).cast<String>(),
      );
  bool get isPublic => audience.isEmpty;
}

class _EvidenceSet {
  final ids = SplayTreeSet<String>();
  String? _digest;
  void add(String id) {
    if (ids.add(id)) _digest = null;
  }

  String digestOf() => _digest ??= hash(ids.toList());
}
