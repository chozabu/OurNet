import 'dart:io';
import 'dart:math';

import 'store.dart';

/// Objects sharing a kind, an author or a month: how many, and how many
/// stored bytes they take (counted as [Store.objectBytes] counts them).
class StorageSlice {
  final String id;
  final int count;
  final int bytes;
  const StorageSlice(this.id, this.count, this.bytes);
}

/// Where this device's storage goes. Reading it scans the stored objects, so
/// it is built when a screen asks, in steps that let the app draw between
/// them; nothing else calls it.
class StorageReport {
  final DateTime at;
  final int limit, warning;
  final int objectCount, objectBytes;
  final int fileChunks, fileBytes;
  final int previewCount, previewBytes;
  final int evidenceCount, evidenceBytes;
  final int ownCount, ownBytes;

  /// Objects by kind, largest first.
  final List<StorageSlice> kinds;

  /// Objects by author, largest first.
  final List<StorageSlice> authors;

  /// Objects by month created ("2026-10"), oldest first, the last twelve.
  final List<StorageSlice> months;
  final int databaseBytes, walBytes, freeBytes;
  final DateTime? oldest, newest;

  const StorageReport({
    required this.at,
    required this.limit,
    required this.warning,
    required this.objectCount,
    required this.objectBytes,
    required this.fileChunks,
    required this.fileBytes,
    required this.previewCount,
    required this.previewBytes,
    required this.evidenceCount,
    required this.evidenceBytes,
    required this.ownCount,
    required this.ownBytes,
    required this.kinds,
    required this.authors,
    required this.months,
    required this.databaseBytes,
    required this.walBytes,
    required this.freeBytes,
    required this.oldest,
    required this.newest,
  });

  /// What the limit and warning measure.
  int get stored => objectBytes + fileBytes;

  /// The database file beyond the records above: indexes and page slack.
  int get overheadBytes => max(
    0,
    databaseBytes - objectBytes - fileBytes - previewBytes - evidenceBytes - freeBytes,
  );

  static Future<StorageReport> build(Store store, {required String person}) async {
    final db = store.db;
    Future<void> breathe() => Future<void>.delayed(Duration.zero);
    int number(Object? v) => v is int ? v : 0;

    final range = db.select('SELECT MIN(created) AS a, MAX(created) AS b FROM objects').first;
    final lowest = number(range['a']), highest = number(range['b']);
    // Times are milliseconds; guard against seconds all the same.
    final unit = highest > 100000000000 ? 1000 : 1;
    DateTime? when(int v) =>
        v == 0 ? null : DateTime.fromMillisecondsSinceEpoch(v * (unit == 1000 ? 1 : 1000));
    await breathe();

    final kinds = <StorageSlice>[];
    var objectCount = 0;
    for (final row in db.select('SELECT DISTINCT kind FROM objects')) {
      final kind = row['kind'] as String;
      final r = db.select(
        'SELECT COUNT(*) AS n, COALESCE(SUM(length(wire)),0) AS b FROM objects WHERE kind=?',
        [kind],
      ).first;
      kinds.add(StorageSlice(kind, number(r['n']), number(r['b'])));
      objectCount += number(r['n']);
      await breathe();
    }
    kinds.sort((a, b) => b.bytes.compareTo(a.bytes));

    final authors = <StorageSlice>[];
    var ownCount = 0, ownBytes = 0;
    for (final row in db.select(
      'SELECT author, COUNT(*) AS n, COALESCE(SUM(length(wire)),0) AS b FROM objects GROUP BY author',
    )) {
      final slice = StorageSlice(row['author'] as String, number(row['n']), number(row['b']));
      authors.add(slice);
      if (slice.id == person) {
        ownCount = slice.count;
        ownBytes = slice.bytes;
      }
    }
    authors.sort((a, b) => b.bytes.compareTo(a.bytes));
    await breathe();

    final months = <StorageSlice>[];
    for (final row in db.select(
      "SELECT strftime('%Y-%m', created/?, 'unixepoch') AS m, COUNT(*) AS n, "
      'COALESCE(SUM(length(wire)),0) AS b FROM objects GROUP BY m ORDER BY m DESC LIMIT 12',
      [unit],
    )) {
      months.add(StorageSlice(row['m'] as String, number(row['n']), number(row['b'])));
    }
    months.sort((a, b) => a.id.compareTo(b.id));
    await breathe();

    final evidence = db.select('SELECT COUNT(*) AS n, COALESCE(SUM(length(wire)),0) AS b FROM evidence').first;
    await breathe();
    final files = db.select('SELECT COUNT(*) AS n FROM blobs').first;
    final previews = db.select('SELECT COUNT(*) AS n, COALESCE(SUM(size),0) AS b FROM previews').first;

    int pragma(String name) {
      final rows = db.select('PRAGMA $name');
      return rows.isEmpty ? 0 : number(rows.first.values.first);
    }

    final pageSize = pragma('page_size');
    int fileSize(String path) {
      try {
        final f = File(path);
        return f.existsSync() ? f.lengthSync() : 0;
      } catch (_) {
        return 0;
      }
    }

    final path = store.path;
    return StorageReport(
      at: DateTime.now(),
      limit: store.storageLimit,
      warning: store.storageWarning,
      objectCount: objectCount,
      objectBytes: store.objectBytes,
      fileChunks: number(files['n']),
      fileBytes: store.storedBytes - store.objectBytes,
      previewCount: number(previews['n']),
      previewBytes: number(previews['b']),
      evidenceCount: number(evidence['n']),
      evidenceBytes: number(evidence['b']),
      ownCount: ownCount,
      ownBytes: ownBytes,
      kinds: kinds,
      authors: authors,
      months: months,
      databaseBytes: path == null ? pragma('page_count') * pageSize : fileSize(path),
      walBytes: path == null ? 0 : fileSize('$path-wal'),
      freeBytes: pragma('freelist_count') * pageSize,
      oldest: when(lowest),
      newest: when(highest),
    );
  }
}
