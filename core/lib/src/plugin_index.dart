import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:sqlite3/sqlite3.dart';
import 'package:ournet_native/ournet_native.dart' show NativeDisk;

/// Derived plugin indexes on disk, with a bounded SQLite page cache and one
/// worker-owned connection. Git stores derived locations here; original file
/// bodies remain encrypted attachment chunks.
class PluginIndex {
  final String path;
  PluginIndex(this.path);
  final _responses = ReceivePort();
  final _pending = <int, Completer<Object?>>{};
  Future<SendPort>? _ready;
  Isolate? _isolate;
  int _next = 0;
  bool _closed = false;
  Object? _failure;

  Future<SendPort> _start() async {
    final ready = Completer<SendPort>();
    _responses.listen((message) {
      if (message is SendPort) {
        ready.complete(message);
      } else if (message is Map) {
        final request = _pending.remove(message['id']);
        if (message['error'] != null) {
          request?.completeError(StateError(message['error'] as String));
        } else {
          request?.complete(message['value']);
        }
      } else {
        _failure = StateError('Plugin index worker stopped');
        if (!ready.isCompleted) ready.completeError(_failure!);
        for (final c in _pending.values) {
          c.completeError(_failure!);
        }
        _pending.clear();
      }
    });
    try {
      _isolate = await Isolate.spawn(
        _run,
        (path, _responses.sendPort),
        onError: _responses.sendPort,
        onExit: _responses.sendPort,
        debugName: 'ournet-plugin-index',
      );
    } catch (e, stack) {
      _failure = e;
      if (!ready.isCompleted) ready.completeError(e, stack);
    }
    return ready.future;
  }

  Future<Object?> _send(Map<String, Object?> command) async {
    final port = await (_ready ??= _start());
    if (_failure != null) throw _failure!;
    final id = _next++;
    final reply = Completer<Object?>();
    _pending[id] = reply;
    port.send({...command, 'id': id});
    return reply.future;
  }

  Future<Object?> request(
    String plugin,
    String op,
    String bucket, {
    String? key,
    List<(String, Uint8List)> entries = const [],
  }) {
    if (_closed) throw StateError('Plugin index is closed');
    if (bucket.length > 200 ||
        (key?.length ?? 0) > 200 ||
        entries.length > 512 ||
        entries.any((e) => e.$1.length > 200 || e.$2.length > 256 * 1024)) {
      throw StateError('Index batch exceeds per-call resource budget');
    }
    return _send({
      'plugin': plugin,
      'op': op,
      'bucket': bucket,
      'key': key,
      'entries': entries,
    });
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      if (_ready != null && _failure == null) await _send({'op': 'close'});
    } finally {
      _isolate?.kill(priority: Isolate.immediate);
      _responses.close();
    }
  }

  static void _run((String, SendPort) initial) {
    final (path, reply) = initial;
    Directory(File(path).parent.path).createSync(recursive: true);
    final db = sqlite3.open(path);
    db.execute('PRAGMA journal_mode=WAL');
    db.execute('PRAGMA synchronous=NORMAL');
    db.execute('PRAGMA cache_size=-4096');
    db.execute(
      'CREATE TABLE IF NOT EXISTS entries(plugin TEXT NOT NULL, bucket TEXT NOT NULL, key TEXT NOT NULL, value BLOB NOT NULL, PRIMARY KEY(plugin,bucket,key)) WITHOUT ROWID',
    );
    final input = ReceivePort();
    reply.send(input.sendPort);
    input.listen((raw) {
      final m = raw as Map;
      try {
        Object? value;
        switch (m['op']) {
          case 'get':
            final rows = db.select(
              'SELECT value FROM entries WHERE plugin=? AND bucket=? AND key=?',
              [m['plugin'], m['bucket'], m['key']],
            );
            value = rows.isEmpty ? null : rows.single['value'];
          case 'put':
            final needed = (m['entries'] as List)
                .cast<(String, Uint8List)>()
                .fold<int>(0, (n, e) => n + e.$1.length + e.$2.length + 256);
            final free = NativeDisk.freeBytes(File(path).parent.path);
            if (free != null && needed > free - 64 * 1024 * 1024) {
              throw StateError(
                'Not enough free disk space for the repository index',
              );
            }
            db.execute('BEGIN IMMEDIATE');
            final statement = db.prepare(
              'INSERT INTO entries VALUES(?,?,?,?) ON CONFLICT(plugin,bucket,key) DO UPDATE SET value=excluded.value',
            );
            try {
              for (final e
                  in (m['entries'] as List).cast<(String, Uint8List)>()) {
                statement.execute([m['plugin'], m['bucket'], e.$1, e.$2]);
              }
              db.execute('COMMIT');
            } catch (_) {
              db.execute('ROLLBACK');
              rethrow;
            } finally {
              statement.close();
            }
          case 'clear':
            db.execute('DELETE FROM entries WHERE plugin=? AND bucket=?', [
              m['plugin'],
              m['bucket'],
            ]);
          case 'close':
            db.close();
            input.close();
        }
        reply.send({'id': m['id'], 'value': value});
      } catch (e) {
        reply.send({'id': m['id'], 'error': '$e'});
      }
    });
  }
}
