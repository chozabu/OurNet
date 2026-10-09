import 'dart:io';
import 'dart:math';
import 'dart:async';
import 'dart:collection';
import 'dart:developer';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:ournet_core/ournet_core.dart';
import 'network.dart';

class Files {
  static final _previews = Expando<_BoundedQueue<Uint8List>>();
  static final _transfers = Expando<_BoundedQueue<void>>();
  final Node node;
  final PeerNetwork network;
  Files(this.node, this.network);
  _BoundedQueue<Uint8List> get _previewQueue => _previews[node] ??=
      _BoundedQueue(32, 'Preview queue is full; tap to retry');
  _BoundedQueue<void> get _transferQueue => _transfers[node] ??=
      _BoundedQueue(16, 'Transfer queue is full; retry shortly');
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

    /// The object kind to publish as, where the usual choice from the other
    /// arguments is not wanted (a private group's forum posts).
    String? kind,

    /// Extra payload fields, such as a voice message's duration and transcript.
    Json? extra,
    List<String> via = const [],
    void Function(int completed, int total)? onProgress,
  }) async {
    final stored = await store(
      path,
      encrypt: audience.isNotEmpty,
      onProgress: onProgress,
    );
    return await node.publish(
      kind ??
          (postSpace != null
              ? 'post'
              : everyday != null
              ? (room == null ? 'inbox' : 'room_item')
              : drive != null
              ? 'drive'
              : audience.isEmpty
              ? 'file'
              : 'message'),
      {
        'text': text,
        'name': name ?? stored['name'],
        'size': stored['size'],
        'chunks': stored['chunks'],
        'chunkBytes': chunkSize,
        'key': stored['key'],
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
  }

  /// Encrypts [path] into stored chunks without publishing anything, and
  /// returns the payload fields that describe it (`name`, `size`, `chunks`,
  /// `chunkBytes`, `key`). For objects that carry a file among other things,
  /// such as a calendar event's voice note.
  Future<Json> store(
    String path, {
    bool encrypt = true,
    void Function(int completed, int total)? onProgress,
  }) async {
    final trace = TimelineTask()..start('attachment.import');
    try {
      final file = File(path);
      final size = await file.length();
      if (size > maxSize) throw StateError('Prototype file limit is 64 MiB');
      final key = await Chacha20.poly1305Aead().newSecretKey();
      final keyBytes = encrypt ? await key.extractBytes() : null;
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
      return {
        'name': file.uri.pathSegments.last,
        'size': size,
        'chunks': chunks,
        'chunkBytes': chunkSize,
        'key': keyBytes == null ? null : b64(keyBytes),
      };
    } finally {
      trace.finish();
    }
  }

  static final _complete = Expando<LinkedHashSet<String>>();

  /// Whether every original chunk is local. Chunks are content-addressed and
  /// retained, so positive answers are remembered; others use one query.
  bool cached(Json payload) {
    final chunks = (payload['chunks'] as List).cast<String>();
    if (chunks.isEmpty) return true;
    final known = _complete[node] ??= LinkedHashSet<String>();
    // Chunk hashes have fixed width. Include every chunk, without hashing or
    // reading blobs on the UI isolate, and bound retained cache metadata.
    final key = chunks.join();
    if (known.remove(key)) {
      known.add(key);
      return true;
    }
    if (!node.store.hasBlobs(chunks)) return false;
    known.add(key);
    if (known.length > 128) known.remove(known.first);
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

  /// Missing chunks asked of one source in one request, and how many such
  /// requests run at once, spread over the devices that may hold the file.
  static const batchChunks = PeerNetwork.maxBatchChunks;
  static const batchesInFlight = 4;

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
    final chunks = (payload['chunks'] as List).cast<String>();
    final fetch = _Fetch(this, object, key, chunks);
    for (var i = 0; i < chunks.length; i++) {
      final plain = await fetch.chunk(i);
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
  }) => _previewQueue.run(
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
        limit: limit,
        expectedSize: payload['size'] as int,
      );
      if (local != null) {
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
  }) => _transferQueue.run(
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
  }) => _transferQueue.run(
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

/// Runs at most two jobs at once and shares duplicate in-flight requests by
/// key. Previews (bounding memory and CPU; completed plaintext is owned by
/// the caller, never retained here) and original transfers each have one.
/// A full queue refuses with [full]; callers retry explicitly.
class _BoundedQueue<T> {
  _BoundedQueue(this.limit, this.full);
  final int limit;
  final String full;
  final _pending = <String, Future<T>>{};
  final _waiting = Queue<void Function()>();
  int _active = 0;

  Future<T> run(String key, Future<T> Function() load) {
    final existing = _pending[key];
    if (existing != null) return existing;
    if (_pending.length >= limit) return Future.error(StateError(full));
    final result = Completer<T>();
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

/// Fetches the chunks of one file that are not stored here, in batches of
/// [Files.batchChunks] from the devices that may hold it, a few batches ahead
/// of the reader. A batch goes to one source; chunks it lacks are asked of
/// the next. Each chunk is verified and stored as it arrives.
class _Fetch {
  _Fetch(this.files, this.object, this.key, this.chunks) {
    final held = files.node.store.heldBlobs(chunks);
    final missing = [
      for (var i = 0; i < chunks.length; i++)
        if (!held.contains(chunks[i])) i,
    ];
    for (var i = 0; i < missing.length; i += Files.batchChunks) {
      final batch = missing.sublist(
        i,
        min(i + Files.batchChunks, missing.length),
      );
      for (final index in batch) {
        _batchOf[index] = _batches.length;
      }
      _batches.add(batch);
    }
  }

  final Files files;
  final SignedObject object;
  final List<int>? key;
  final List<String> chunks;
  final _batches = <List<int>>[];
  final _batchOf = <int, int>{};
  final _results = <int, Future<Map<int, Uint8List>>>{};

  /// Devices that failed once are not asked again for this file: each
  /// attempt can wait out a connection timeout.
  final _failed = <String>{};
  late final List<String> _sources = _rank();

  Node get node => files.node;

  /// Admitted devices that may hold the file, its author's first, then those
  /// heard from most recently.
  List<String> _rank() {
    final network = files.network;
    final candidates = [
      for (final peer in node.contacts.values)
        if (node.allowedPeer(peer.device) &&
            node.canOffer(object, peer, {object.space}, relay: true))
          peer,
    ];
    int heard(DeviceCertificate p) => max(
      network.lastInbound[p.device]?.millisecondsSinceEpoch ?? 0,
      network.lastSync[p.device]?.millisecondsSinceEpoch ?? 0,
    );
    candidates.sort((a, b) {
      final author =
          (a.person == object.author ? 0 : 1) -
          (b.person == object.author ? 0 : 1);
      return author != 0 ? author : heard(b).compareTo(heard(a));
    });
    return [for (final p in candidates) p.device];
  }

  Future<Uint8List> chunk(int index) async {
    final batch = _batchOf[index];
    if (batch == null) {
      final plain = await node.blobs.decode(chunks[index], key);
      if (plain != null) return plain;
      // Unreadable, or removed since it was found: fetched on its own.
      final fetched = (await _fetch([index], 0))[index];
      if (fetched != null) return fetched;
      throw StateError('No online source holds this file chunk');
    }
    // Keep the next few batches coming while this one is read.
    final ahead = min(batch + Files.batchesInFlight, _batches.length);
    for (var b = batch; b < ahead; b++) {
      _results[b] ??= _fetch(_batches[b], b);
    }
    final result = await _results[batch]!;
    _batchOf.remove(index);
    // Plaintext is held only until the reader takes it.
    final plain = result.remove(index);
    if (!_batches[batch].any(_batchOf.containsKey)) _results.remove(batch);
    if (plain == null) {
      throw StateError('No online source holds this file chunk');
    }
    return plain;
  }

  /// Fetches [indices], asking sources in turn from the [n]th, so batches in
  /// flight spread over the devices that hold the file.
  Future<Map<int, Uint8List>> _fetch(List<int> indices, int n) async {
    final got = <int, Uint8List>{};
    final sources = _sources;
    for (var s = 0; s < sources.length && got.length < indices.length; s++) {
      final device = sources[(n + s) % sources.length];
      if (_failed.contains(device)) continue;
      final wanted = [
        for (final i in indices)
          if (!got.containsKey(i)) i,
      ];
      try {
        final fetched = await _ask(device, [for (final i in wanted) chunks[i]]);
        for (final (k, bytes) in fetched.indexed) {
          if (bytes == null || bytes.length > Files.chunkSize + 64) continue;
          final i = wanted[k];
          final plain = await node.blobs.decode(chunks[i], key, bytes: bytes);
          if (plain != null) got[i] = plain;
        }
      } catch (_) {
        _failed.add(device);
        /* Another admitted source may be available. */
      }
    }
    return got;
  }

  /// [hashes] from [device], null where it does not hold one.
  Future<List<List<int>?>> _ask(String device, List<String> hashes) async {
    final network = files.network;
    if (network.peerCaps[device]?.contains('blob_batch') != true) {
      return [
        for (final hash in hashes)
          switch ((await network.request(device, {
            'type': 'blob',
            'object': object.id,
            'hash': hash,
          }))['bytes']) {
            final String b => unb64(b),
            _ => null,
          },
      ];
    }
    final (header, body) = await network.requestBytes(device, {
      'type': 'blobs',
      'object': object.id,
      'hashes': hashes,
    });
    final sizes = header['sizes'];
    if (sizes is! List || sizes.length != hashes.length) {
      throw StateError('Invalid chunk reply');
    }
    var offset = 0;
    final out = <List<int>?>[];
    for (final size in sizes) {
      if (size is! int) {
        out.add(null);
        continue;
      }
      if (size < 0 || offset + size > body.length) {
        throw StateError('Invalid chunk reply');
      }
      out.add(Uint8List.sublistView(body, offset, offset + size));
      offset += size;
    }
    return out;
  }
}
