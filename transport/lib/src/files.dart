import 'dart:io';
import 'dart:async';
import 'dart:collection';
import 'dart:developer';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:ournet_core/ournet_core.dart';
import 'network.dart';

class Files {
  static final _previews = Expando<_PreviewQueue>();
  static final _transfers = Expando<_TransferQueue>();
  final Node node;
  final PeerNetwork network;
  Files(this.node, this.network);
  static const chunkSize = 128 * 1024;
  static const maxSize = 64 * 1024 * 1024;
  Future<SignedObject> publish(
    String path, {
    List<String> audience = const [],
    String text = '',
    String? name,
    Json? drive,
    Json? everyday,
    String? room,
    String? postSpace,
    Json? post,

    /// Extra payload fields, such as a voice message's duration and transcript.
    Json? extra,
    List<String> via = const [],
    void Function(int completed, int total)? onProgress,
  }) async {
    final trace = TimelineTask()..start('attachment.import');
    try {
      final file = File(path);
      final size = await file.length();
      if (size > maxSize) throw StateError('Prototype file limit is 64 MiB');
      final key = await Chacha20.poly1305Aead().newSecretKey();
      final keyBytes = audience.isEmpty ? null : await key.extractBytes();
      final chunks = <String>[];
      var completed = 0;
      onProgress?.call(0, size);
      final handle = await file.open();
      try {
        while (true) {
          final data = await handle.read(chunkSize);
          if (data.isEmpty) break;
          completed += data.length;
          if (completed > maxSize || completed > size) {
            throw StateError('File changed during import');
          }
          final id = await node.blobs.encode(data, keyBytes);
          chunks.add(id);
          onProgress?.call(completed, size);
        }
      } finally {
        await handle.close();
      }
      if (completed != size) throw StateError('File changed during import');
      return await node.publish(
        postSpace != null
            ? 'post'
            : everyday != null
            ? (room == null ? 'inbox' : 'room_item')
            : drive != null
            ? 'drive'
            : audience.isEmpty
            ? 'file'
            : 'message',
        {
          'text': text,
          'name': name ?? file.uri.pathSegments.last,
          'size': size,
          'chunks': chunks,
          'key': keyBytes == null ? null : b64(keyBytes),
          if (drive != null) ...drive,
          if (everyday != null) ...everyday,
          if (post != null) ...post,
          ...?extra,
        },
        space:
            postSpace ??
            (everyday != null
                ? (room ?? '_inbox')
                : drive != null
                ? '_drive'
                : audience.isEmpty
                ? 'files'
                : '_messages'),
        audience: audience,
        via: via,
      );
    } finally {
      trace.finish();
    }
  }

  static final _complete = Expando<Set<String>>();

  /// Whether every original chunk is local. Chunks are content-addressed and
  /// retained, so positive answers are remembered; others use one query.
  bool cached(Json payload) {
    final chunks = (payload['chunks'] as List).cast<String>();
    if (chunks.isEmpty) return true;
    final known = _complete[node] ??= <String>{};
    final key = '${chunks.first}/${chunks.last}/${chunks.length}';
    if (known.contains(key)) return true;
    if (!node.store.hasBlobs(chunks)) return false;
    known.add(key);
    return true;
  }

  /// A decrypted local preview [variant] for [object], or null if none exists.
  /// Previews are encrypted with the file's key, like its original chunks.
  Future<Uint8List?> readPreview(SignedObject object, String variant) async {
    final payload = await node.content(object);
    if (payload == null || payload['chunks'] is! List) return null;
    try {
      return await node.blobs.readPreview(
        '${object.id}/$variant',
        payload['key'] == null ? null : unb64(payload['key']),
      );
    } on StateError {
      return null; // Unreadable or tampered previews are regenerated.
    }
  }

  /// Compress, encrypt and retain a preview from straight RGBA pixels.
  /// Returns the plaintext encoded image for immediate display.
  Future<Uint8List> storePreview(
    SignedObject object,
    String variant,
    Uint8List rgba,
    int width,
    int height,
  ) async {
    final payload = await node.content(object);
    if (payload == null || payload['chunks'] is! List) {
      throw StateError('File is not readable by this device');
    }
    return node.blobs.storePreview(
      '${object.id}/$variant',
      payload['key'] == null ? null : unb64(payload['key']),
      rgba,
      width,
      height,
    );
  }

  Stream<List<int>> _plain(
    SignedObject object, {
    void Function(int, int)? onProgress,
  }) async* {
    final payload = await node.content(object);
    if (payload == null || payload['chunks'] is! List)
      throw StateError('File is not readable by this device');
    var size = 0;
    onProgress?.call(0, payload['size'] as int);
    final key = payload['key'] == null ? null : unb64(payload['key']);
    for (final id in (payload['chunks'] as List).cast<String>()) {
      var plain = await node.blobs.decode(id, key);
      if (plain == null) {
        final sources =
            node.contacts.values
                .where((p) => node.allowedPeer(p.device))
                .toList()
              ..sort(
                (a, b) => (a.person == object.author ? 0 : 1).compareTo(
                  b.person == object.author ? 0 : 1,
                ),
              );
        for (final peer in sources) {
          try {
            final response = await network.request(peer.device, {
              'type': 'blob',
              'object': object.id,
              'hash': id,
            });
            if (response['bytes'] != null) {
              final candidate = unb64(response['bytes']);
              if (candidate.length <= chunkSize + 64) {
                plain = await node.blobs.decode(id, key, bytes: candidate);
                break;
              }
            }
          } catch (_) {
            /* Another admitted source may be available. */
          }
        }
      }
      if (plain == null)
        throw StateError('No online source holds this file chunk');
      size += plain.length;
      if (size > maxSize || size > payload['size'])
        throw StateError('File size exceeded');
      onProgress?.call(size, payload['size'] as int);
      yield plain;
    }
    if (size != payload['size']) throw StateError('File size mismatch');
  }

  /// Decode only into memory; the durable cache retains encrypted chunks.
  Future<Uint8List> readBytes(
    SignedObject object, {
    int limit = 8 * 1024 * 1024,
  }) => (_previews[node] ??= _PreviewQueue()).run(
    '${object.id}/$limit',
    () => _readBytes(object, limit),
  );

  Future<Uint8List> _readBytes(SignedObject object, int limit) async {
    final trace = TimelineTask()..start('attachment.preview');
    try {
      final payload = await node.content(object);
      if (payload == null || payload['size'] is! int || payload['size'] > limit)
        throw StateError('Image exceeds preview limit');
      // Stored chunks decrypt in parallel with other attachment work; fetch
      // from a source device only when some are not on this device.
      final chunks = (payload['chunks'] as List? ?? const []).cast<String>();
      final local = await node.blobs.readLocal(
        chunks,
        payload['key'] == null ? null : unb64(payload['key']),
      );
      if (local != null) {
        if (local.length > limit) {
          throw StateError('Image exceeds preview limit');
        }
        return local;
      }
      final result = BytesBuilder(copy: false);
      await for (final chunk in _plain(object)) {
        if (result.length + chunk.length > limit)
          throw StateError('Image exceeds preview limit');
        result.add(chunk);
      }
      return result.takeBytes();
    } finally {
      trace.finish();
    }
  }

  /// Retain verified encrypted chunks without writing plaintext to disk.
  Future<void> cache(
    SignedObject object, {
    void Function(int, int)? onProgress,
  }) => (_transfers[node] ??= _TransferQueue()).run(
    'cache/${object.id}',
    () async {
      await for (final _ in _plain(object, onProgress: onProgress)) {}
    },
  );

  /// Verified encrypted chunks remain cached after interruption, including
  /// across process restarts. Retries fetch only missing chunks. The plaintext
  /// export is temporary and is removed on failure.
  Future<void> save(
    SignedObject object,
    String path, {
    void Function(int, int)? onProgress,
  }) => (_transfers[node] ??= _TransferQueue()).run(
    'save/${object.id}/$path',
    () async {
      final target = File('$path.${randomId()}.ournet-part');
      final output = await target.open(mode: FileMode.write);
      var closed = false;
      try {
        await for (final data in _plain(object, onProgress: onProgress)) {
          await output.writeFrom(data);
        }
        await output.close();
        closed = true;
        await target.rename(path);
      } finally {
        if (!closed) await output.close();
        if (await target.exists()) await target.delete();
      }
    },
  );
}

/// Bound preview memory/CPU pressure and share duplicate in-flight requests.
/// Completed plaintext is owned by the caller, never retained in this queue.
class _PreviewQueue {
  final _pending = <String, Future<Uint8List>>{};
  final _waiting = Queue<void Function()>();
  int _active = 0;

  Future<Uint8List> run(String key, Future<Uint8List> Function() load) {
    final existing = _pending[key];
    if (existing != null) return existing;
    if (_pending.length >= 32)
      return Future.error(StateError('Preview queue is full; tap to retry'));
    final result = Completer<Uint8List>();
    _pending[key] = result.future;
    void start() async {
      _active++;
      try {
        result.complete(await load());
      } catch (error, stack) {
        result.completeError(error, stack);
      } finally {
        _pending.remove(key);
        _active--;
        if (_waiting.isNotEmpty) _waiting.removeFirst()();
      }
    }

    if (_active < 2) {
      start();
    } else {
      _waiting.add(start);
    }
    return result.future;
  }
}

/// Bound original transfers independently of preview memory. Callers retry a
/// full queue explicitly; duplicate cache/export requests share existing work.
class _TransferQueue {
  final _pending = <String, Future<void>>{};
  final _waiting = Queue<void Function()>();
  int _active = 0;

  Future<void> run(String key, Future<void> Function() load) {
    final existing = _pending[key];
    if (existing != null) return existing;
    if (_pending.length >= 16)
      return Future.error(StateError('Transfer queue is full; retry shortly'));
    final result = Completer<void>();
    _pending[key] = result.future;
    void start() async {
      _active++;
      try {
        await load();
        result.complete();
      } catch (error, stack) {
        result.completeError(error, stack);
      } finally {
        _pending.remove(key);
        _active--;
        if (_waiting.isNotEmpty) _waiting.removeFirst()();
      }
    }

    if (_active < 2) {
      start();
    } else {
      _waiting.add(start);
    }
    return result.future;
  }
}
