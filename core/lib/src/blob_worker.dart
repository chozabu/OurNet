import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:image/image.dart' as img;
import 'package:sqlite3/sqlite3.dart';

import 'model.dart';
import 'store.dart';

/// One lazy, long-lived attachment worker per node. Only chunk bytes and keys
/// cross this boundary; identities, networking and UI objects never do.
/// Disk profiles use a worker-owned SQLite connection. In-memory test stores
/// keep their blobs in the caller but still offload cryptography.
class BlobWorker {
  final Store store;
  BlobWorker(this.store);

  Future<SendPort>? _ready;
  final _responses = ReceivePort();
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  Isolate? _isolate;
  int _next = 0;
  bool _closing = false;
  Object? _failure;
  Future<void>? _closeFuture;

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
          request?.complete(Map<String, dynamic>.from(message));
        }
      } else {
        final error = StateError('Attachment worker stopped');
        _failure = error;
        if (!ready.isCompleted) ready.completeError(error);
        for (final request in _pending.values) {
          request.completeError(error);
        }
        _pending.clear();
      }
    });
    try {
      _isolate = await Isolate.spawn(
        _run,
        (port: _responses.sendPort, path: store.path),
        onError: _responses.sendPort,
        onExit: _responses.sendPort,
        debugName: 'ournet-attachments',
      );
    } catch (error, stack) {
      _failure = error;
      if (!ready.isCompleted) ready.completeError(error, stack);
    }
    return ready.future;
  }

  Future<Map<String, dynamic>> _request(Map<String, dynamic> command) async {
    if (_closing) throw StateError('Attachment worker is closed');
    return _send(command);
  }

  Future<Map<String, dynamic>> _send(Map<String, dynamic> command) async {
    final port = await (_ready ??= _start());
    if (_failure != null) throw _failure!;
    final id = _next++;
    final result = Completer<Map<String, dynamic>>();
    _pending[id] = result;
    port.send({...command, 'id': id});
    return result.future;
  }

  Future<String> encode(Uint8List bytes, List<int>? key) async {
    final result = await _request({'op': 'encode', 'bytes': bytes, 'key': key});
    final hash = result['hash'] as String;
    if (store.path == null) store.putBlob(hash, result['bytes'] as Uint8List);
    return hash;
  }

  /// Returns null only when a chunk is absent. Supplied network bytes are
  /// verified and authenticated before they are cached.
  Future<Uint8List?> decode(
    String hash,
    List<int>? key, {
    List<int>? bytes,
  }) async {
    final result = await _request({
      'op': 'decode',
      'hash': hash,
      'key': key,
      'bytes': bytes ?? (store.path == null ? store.blob(hash) : null),
    });
    if (store.path == null && bytes != null && result['bytes'] != null) {
      store.putBlob(hash, bytes);
    }
    return result['bytes'] as Uint8List?;
  }

  /// Verifies and decrypts a whole locally stored attachment on a short-lived
  /// isolate with its own read-only connection, so preview reads run beside
  /// the serial worker instead of interleaving chunk by chunk. Callers bound
  /// how many run at once. Returns null when any chunk is not stored locally.
  /// Stops before retaining bytes beyond [limit] or [expectedSize], and checks
  /// the final length when an expected size is supplied.
  Future<Uint8List?> readLocal(
    List<String> hashes,
    List<int>? key, {
    int limit = 8 * 1024 * 1024,
    int? expectedSize,
  }) async {
    if (_closing) throw StateError('Attachment worker is closed');
    if (limit < 0 ||
        (expectedSize != null && (expectedSize < 0 || expectedSize > limit))) {
      throw StateError('Invalid attachment size limit');
    }
    final budget = expectedSize ?? limit;
    final path = store.path;
    if (path == null) {
      final result = BytesBuilder(copy: false);
      for (final hash in hashes) {
        final plain = await decode(hash, key);
        if (plain == null) return null;
        if (result.length + plain.length > budget) {
          throw StateError('File size exceeded');
        }
        result.add(plain);
      }
      if (expectedSize != null && result.length != expectedSize) {
        throw StateError('File size mismatch');
      }
      return result.takeBytes();
    }
    final read = await Isolate.run(
      () => _readLocal(path, hashes, key, budget, expectedSize),
      debugName: 'ournet-attachment-read',
    );
    return read?.materialize().asUint8List();
  }

  /// Returns a decrypted local preview, or null when none is stored.
  Future<Uint8List?> readPreview(String id, List<int>? key) async {
    if (store.path == null) {
      final stored = store.preview(id);
      if (stored == null) return null;
      final result = await _request({
        'op': 'preview_open',
        'preview': id,
        'key': key,
        'bytes': stored,
      });
      return result['bytes'] as Uint8List?;
    }
    final result = await _request({
      'op': 'preview_get',
      'preview': id,
      'key': key,
    });
    return result['bytes'] as Uint8List?;
  }

  /// Compresses straight (non-premultiplied) RGBA pixels, encrypts them with
  /// [key] when given, stores the result and returns the plaintext encoding.
  Future<Uint8List> storePreview(
    String id,
    List<int>? key,
    Uint8List rgba,
    int width,
    int height,
  ) async {
    if (width <= 0 ||
        height <= 0 ||
        width * height > 4096 * 4096 ||
        rgba.length != width * height * 4) {
      throw StateError('Invalid preview pixels');
    }
    // Compression runs in a short-lived isolate so it never delays chunk jobs
    // queued on this serial worker.
    final encoded = await _encodeElsewhere(
      TransferableTypedData.fromList([rgba]),
      width,
      height,
    );
    final result = await _request({
      'op': 'preview_put',
      'preview': id,
      'key': key,
      'bytes': encoded,
    });
    if (store.path == null) store.putPreview(id, result['stored'] as Uint8List);
    return encoded;
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closing = true;
    try {
      if (_ready != null && _failure == null) await _send({'op': 'close'});
    } finally {
      _isolate?.kill(priority: Isolate.immediate);
      _responses.close();
    }
  }
}

Future<TransferableTypedData?> _readLocal(
  String path,
  List<String> hashes,
  List<int>? keyBytes,
  int budget,
  int? expectedSize,
) async {
  final db = sqlite3.open(path, mode: OpenMode.readOnly);
  try {
    db.execute('PRAGMA busy_timeout=5000');
    final statement = db.prepare('SELECT bytes FROM blobs WHERE id=?');
    final key = keyBytes == null ? null : SecretKey(keyBytes);
    final chunks = <Uint8List>[];
    var size = 0;
    try {
      for (final hash in hashes) {
        final rows = statement.select([hash]);
        if (rows.isEmpty) return null;
        final bytes = rows.first['bytes'] as Uint8List;
        // Same checks as the worker's decode: bounded, content-addressed,
        // authenticated before any plaintext is returned.
        if (bytes.length > 128 * 1024 + 64 || blobHash(bytes) != hash) {
          throw StateError('Invalid file chunk');
        }
        final plain = key == null
            ? bytes
            : Uint8List.fromList(
                await Chacha20.poly1305Aead().decrypt(
                  SecretBox.fromConcatenation(
                    bytes,
                    nonceLength: 12,
                    macLength: 16,
                  ),
                  secretKey: key,
                ),
              );
        size += plain.length;
        if (size > budget) throw StateError('File size exceeded');
        chunks.add(plain);
      }
    } finally {
      statement.close();
    }
    if (expectedSize != null && size != expectedSize) {
      throw StateError('File size mismatch');
    }
    return TransferableTypedData.fromList(chunks);
  } finally {
    db.close();
  }
}

Future<void> _run(({SendPort port, String? path}) initial) async {
  final store = initial.path == null ? null : Store(path: initial.path);
  final commands = ReceivePort();
  int? closingRequest;
  initial.port.send(commands.sendPort);
  try {
    // Serial consumption bounds crypto/database concurrency across all Files
    // instances belonging to this node. Each producer waits for its chunk.
    await for (final message in commands) {
      final command = Map<String, dynamic>.from(message as Map);
      final id = command['id'];
      try {
        if (command['op'] == 'close') {
          closingRequest = id as int;
          break;
        }
        final keyBytes = command['key'] as List<int>?;
        final key = keyBytes == null ? null : SecretKey(keyBytes);
        if (command['op'] == 'encode') {
          final plain = command['bytes'] as Uint8List;
          if (plain.length > 128 * 1024) throw StateError('Invalid chunk size');
          final bytes = key == null
              ? plain
              : Uint8List.fromList(
                  (await Chacha20.poly1305Aead().encrypt(
                    plain,
                    secretKey: key,
                  )).concatenation(),
                );
          final hash = blobHash(bytes);
          store?.putBlob(hash, bytes);
          initial.port.send({
            'id': id,
            'hash': hash,
            if (store == null) 'bytes': bytes,
          });
        } else if (command['op'] == 'decode') {
          final hash = command['hash'] as String;
          final supplied = command['bytes'] as List<int>?;
          final bytes = supplied ?? store?.blob(hash);
          if (bytes == null) {
            initial.port.send({'id': id, 'bytes': null});
            continue;
          }
          if (bytes.length > 128 * 1024 + 64 || blobHash(bytes) != hash) {
            throw StateError('Invalid file chunk');
          }
          final plain = key == null
              ? bytes
              : await Chacha20.poly1305Aead().decrypt(
                  SecretBox.fromConcatenation(
                    bytes,
                    nonceLength: 12,
                    macLength: 16,
                  ),
                  secretKey: key,
                );
          if (supplied != null) store?.putBlob(hash, bytes);
          initial.port.send({'id': id, 'bytes': Uint8List.fromList(plain)});
        } else if (command['op'] == 'preview_get' ||
            command['op'] == 'preview_open') {
          final preview = command['preview'] as String;
          final stored = command['op'] == 'preview_open'
              ? command['bytes'] as Uint8List
              : store?.preview(preview);
          initial.port.send({
            'id': id,
            'bytes': stored == null
                ? null
                : await _openPreview(preview, stored, key),
          });
        } else if (command['op'] == 'preview_put') {
          final encoded = command['bytes'] as Uint8List;
          final stored = key == null
              ? encoded
              : Uint8List.fromList(
                  (await Chacha20.poly1305Aead().encrypt(
                    encoded,
                    secretKey: key,
                    aad: utf8.encode('ournet/preview/${command['preview']}'),
                  )).concatenation(),
                );
          store?.putPreview(command['preview'] as String, stored);
          initial.port.send({'id': id, if (store == null) 'stored': stored});
        } else {
          throw StateError('Unknown attachment operation');
        }
      } catch (error) {
        initial.port.send({'id': id, 'error': error.toString()});
      }
    }
  } finally {
    commands.close();
    store?.close();
    if (closingRequest != null) initial.port.send({'id': closingRequest});
  }
}

Future<Uint8List> _openPreview(
  String id,
  Uint8List stored,
  SecretKey? key,
) async {
  if (key == null) return stored;
  return Uint8List.fromList(
    await Chacha20.poly1305Aead().decrypt(
      SecretBox.fromConcatenation(stored, nonceLength: 12, macLength: 16),
      secretKey: key,
      aad: utf8.encode('ournet/preview/$id'),
    ),
  );
}

// A small top-level scope keeps the isolate closure from capturing more state.
Future<Uint8List> _encodeElsewhere(
  TransferableTypedData pixels,
  int width,
  int height,
) => Isolate.run(
  () => _encodePreview(pixels.materialize().asUint8List(), width, height),
  debugName: 'ournet-preview-encode',
);

/// JPEG for opaque previews; PNG keeps transparency when present.
Uint8List _encodePreview(Uint8List rgba, int width, int height) {
  var opaque = true;
  for (var i = 3; i < rgba.length; i += 4) {
    if (rgba[i] != 255) {
      opaque = false;
      break;
    }
  }
  final image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgba.buffer,
    bytesOffset: rgba.offsetInBytes,
    numChannels: 4,
  );
  return opaque
      ? img.encodeJpg(image, quality: 82)
      : img.encodePng(image, level: 3);
}
