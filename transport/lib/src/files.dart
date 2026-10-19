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

  /// The largest image shown inline, decoded whole in memory. Larger images
  /// are files like any other.
  static const inlineImageLimit = 32 * 1024 * 1024;

  /// Space left free on a disk when deciding whether a file fits.
  static const diskReserve = 64 * 1024 * 1024;

  /// The chunk size new files use; tests set a small one to build deep chunk
  /// trees from small files.
  static int newChunkBytes = chunkSize;
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
  }) async => _publish(
    await store(path, encrypt: audience.isNotEmpty, onProgress: onProgress),
    audience: audience,
    text: text,
    name: name,
    drive: drive,
    everyday: everyday,
    room: room,
    postSpace: postSpace,
    post: post,
    kind: kind,
    extra: extra,
    via: via,
  );

  /// Publishes a file read from [source] as it is encrypted, with no copy
  /// on disk: a folder sync file, say. [size] must be its exact length.
  Future<SignedObject> publishFrom(
    Stream<List<int>> source, {
    required int size,
    required String name,
    List<String> audience = const [],
    Json? drive,
    void Function(int completed, int total)? onProgress,
    ChunkSeen? onChunk,
  }) async => _publish(
    await storeFrom(
      source,
      size: size,
      name: name,
      encrypt: audience.isNotEmpty,
      onProgress: onProgress,
      onChunk: onChunk,
    ),
    audience: audience,
    name: name,
    drive: drive,
  );

  Future<SignedObject> _publish(
    Json stored, {
    required List<String> audience,
    String text = '',
    String? name,
    Json? drive,
    Json? everyday,
    String? room,
    String? postSpace,
    Json? post,
    String? kind,
    Json? extra,
    List<String> via = const [],
  }) async {
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
        if (stored['chunkTree'] != null) ...{
          'chunkTree': stored['chunkTree'],
          'chunkDepth': stored['chunkDepth'],
        },
        'chunkBytes': stored['chunkBytes'],
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
  /// `chunkBytes`, `key`, and `chunkTree` and `chunkDepth` for a file of
  /// more than [inlineChunks] chunks). For objects that carry a file among
  /// other things, such as a calendar event's voice note.
  Future<Json> store(
    String path, {
    bool encrypt = true,
    void Function(int completed, int total)? onProgress,
  }) async {
    final file = File(path);
    final size = await file.length();
    return storeFrom(
      file.openRead(),
      size: size,
      name: file.uri.pathSegments.last,
      encrypt: encrypt,
      onProgress: onProgress,
    );
  }

  /// [store] for a file read from [source] as it is encrypted, a chunk at a
  /// time. [size] must be its exact length, or the import fails as changed.
  Future<Json> storeFrom(
    Stream<List<int>> source, {
    required int size,
    required String name,
    bool encrypt = true,
    void Function(int completed, int total)? onProgress,
    ChunkSeen? onChunk,
  }) async {
    checkRoom(size, name: name);
    final trace = TimelineTask()..start('attachment.import');
    try {
      final key = await Chacha20.poly1305Aead().newSecretKey();
      final keyBytes = encrypt ? await key.extractBytes() : null;
      final bytes = newChunkBytes;
      // A file that will be listed in a tree keeps its chunks as files.
      final asFile = size > inlineChunks * bytes;
      final listing = ChunkTreeBuilder(
        listFanOut(bytes),
        (plain) => node.blobs.encode(plain, keyBytes, asFile: asFile),
      );
      var completed = 0;
      onProgress?.call(0, size);
      await for (final data in rechunk(source, bytes)) {
        final offset = completed;
        completed += data.length;
        if (completed > size) throw StateError('File changed during import');
        final hash = await node.blobs.encode(data, keyBytes, asFile: asFile);
        await listing.add(hash);
        onChunk?.call(hash, offset, data.length);
        onProgress?.call(completed, size);
      }
      if (completed != size) throw StateError('File changed during import');
      final stored = {
        'name': name,
        'size': size,
        ...await listing.finish(),
        'chunkBytes': bytes,
        'key': keyBytes == null ? null : b64(keyBytes),
      };
      await indexTree(stored);
      return stored;
    } finally {
      trace.finish();
    }
  }

  /// What storing a file of [size] bytes takes here, encrypted: each chunk
  /// gains a version byte, nonce and tag, and a tree's list chunks hold a
  /// hash per chunk.
  static int storedSize(int size) {
    final chunks = size ~/ newChunkBytes + 1;
    return size + chunks * (1 + 12 + 16 + 32);
  }

  /// Refuses, with a message saying why, a file of [size] bytes that would
  /// not fit: in OurNet's storage limit and on the disk holding its store
  /// (when [stored]), or on the disk at [destination] for a plaintext copy.
  /// Free disk space that cannot be told is not checked.
  void checkRoom(
    int size, {
    String name = 'This file',
    bool stored = true,
    String? destination,
  }) {
    if (stored) {
      final needed = storedSize(size);
      final left = node.store.storageLimit - node.store.storedBytes;
      if (needed > left) {
        throw StateError(
          '$name needs ${_sizeText(needed)}, but the storage limit leaves '
          '${_sizeText(max(0, left))}. Raise the limit in Settings → Storage, '
          'or remove files.',
        );
      }
      final path = node.store.path;
      final free = path == null ? null : NativeDisk.freeBytes(File(path).parent.path);
      if (free != null && needed > free - diskReserve) {
        throw StateError(
          '$name needs ${_sizeText(needed)}, but this device has '
          '${_sizeText(max(0, free))} free.',
        );
      }
    }
    if (destination != null) {
      final free = NativeDisk.freeBytes(destination);
      if (free != null && size > free - diskReserve) {
        throw StateError(
          '$name needs ${_sizeText(size)}, but there is only '
          '${_sizeText(max(0, free))} free where it is saved.',
        );
      }
    }
  }

  /// Checks there is room to fetch [payload]'s file and, with [destination],
  /// to write it there.
  void checkRoomFor(Json payload, {String? destination}) => checkRoom(
    payload['size'] as int,
    name: '${payload['name']}',
    stored: !cached(payload),
    destination: destination,
  );

  /// Records what the chunk tree of [payload] holds, from list chunks stored
  /// here, so its chunks can be offered to other devices and counted as
  /// cached. Returns false when a list chunk is not stored here yet.
  Future<bool> indexTree(Json payload) => indexChunkTree(node, payload);


  static final _complete = Expando<LinkedHashSet<String>>();

  /// Whether every original chunk is local. Chunks are content-addressed and
  /// retained, so positive answers are remembered; others use one query.
  bool cached(Json payload) {
    if (hasChunkTree(payload)) {
      return node.store.treeStored(
        (payload['chunkTree'] as List).cast<String>(),
      );
    }
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
    ChunkSeen? onChunk,
  }) async* {
    final payload = await node.content(object);
    if (payload == null || payload['chunks'] is! List)
      throw StateError('File is not readable by this device');
    var size = 0;
    onProgress?.call(0, payload['size'] as int);
    final key = payload['key'] == null ? null : unb64(payload['key']);
    // List chunks of a tree are fetched as they are reached, one at a time;
    // data chunks a list chunk at a time, in batches as before.
    Future<Uint8List> open(String hash) =>
        _Fetch(this, object, key, [hash], asFile: true).chunk(0);
    await for (final chunks in chunkSegments(payload, open)) {
      final fetch = _Fetch(
        this,
        object,
        key,
        chunks,
        asFile: hasChunkTree(payload),
      );
      for (var i = 0; i < chunks.length; i++) {
        final plain = await fetch.chunk(i);
        onChunk?.call(chunks[i], size, plain.length);
        size += plain.length;
        if (size > payload['size']) throw StateError('File size exceeded');
        onProgress?.call(size, payload['size'] as int);
        yield plain;
      }
    }
    if (size != payload['size']) throw StateError('File size mismatch');
    await indexTree(payload);
  }

  /// The plaintext of [object]'s file, fetched and decrypted a chunk at a
  /// time as it is read: for writing straight to where it is wanted.
  /// [onChunk] sees each data chunk's hash and where it is in the file.
  Stream<List<int>> open(
    SignedObject object, {
    void Function(int, int)? onProgress,
    ChunkSeen? onChunk,
  }) => _plain(object, onProgress: onProgress, onChunk: onChunk);

  /// Whether this device keeps its own encrypted copy of a large file (over
  /// 64 MiB, listed in a chunk tree) it also holds as plaintext in a synced
  /// folder, or that another of the person's devices holds. Off saves the
  /// space: chunks are made again from the folder, or fetched again.
  bool get keepLargeCopies =>
      node.store.setting('files/keepLargeCopies') != false;
  set keepLargeCopies(bool value) =>
      node.store.set('files/keepLargeCopies', value);

  /// Whether released copies stay released: not while the drive keeps every
  /// file offline, which would fetch them straight back.
  bool get releasesCopies =>
      !keepLargeCopies && node.store.setting('drive/offline') != true;

  /// Drops this device's copy of the data chunks of tree-listed [object]
  /// once another device has shown it holds them, by sending a sample of
  /// them, verified, on request. Returns how many chunks were dropped. The
  /// list chunks stay, so the file can be fetched again.
  Future<int> releaseHeldElsewhere(SignedObject object) async {
    final payload = await node.content(object);
    if (payload == null || !hasChunkTree(payload)) return 0;
    final key = payload['key'] == null ? null : unb64(payload['key']);
    final data = <String>[];
    Future<Uint8List> open(String hash) async =>
        (await node.blobs.decode(hash, key)) ?? (throw StateError('No list'));
    await for (final segment in chunkSegments(payload, open)) {
      data.addAll(segment);
    }
    if (data.isEmpty) return 0;
    final sample = {data.first, data[data.length ~/ 2], data.last}.toList();
    final fetch = _Fetch(this, object, key, sample);
    for (final device in fetch._sources) {
      try {
        final answers = await fetch._ask(device, sample);
        var held = true;
        for (final (i, bytes) in answers.indexed) {
          if (bytes == null ||
              await node.blobs.decode(
                    sample[i],
                    key,
                    bytes: bytes,
                    keep: false,
                  ) ==
                  null) {
            held = false;
            break;
          }
        }
        if (!held) continue;
        var dropped = 0;
        for (final hash in data.toSet()) {
          if (node.store.removeBlob(hash)) dropped++;
        }
        return dropped;
      } catch (_) {
        /* Not reachable, or not holding it: ask the next. */
      }
    }
    return 0;
  }

  /// Decode only into memory; the durable cache retains encrypted chunks.
  Future<Uint8List> readBytes(
    SignedObject object, {
    int limit = 8 * 1024 * 1024,
  }) =>
      _previewQueue.run('${object.id}/$limit', () => _readBytes(object, limit));

  Future<Uint8List> _readBytes(SignedObject object, int limit) async {
    final trace = TimelineTask()..start('attachment.preview');
    try {
      final payload = await node.content(object);
      if (payload == null || payload['size'] is! int || payload['size'] > limit)
        throw StateError('Image exceeds preview limit');
      // Stored chunks decrypt in parallel with other attachment work; fetch
      // from a source device only when some are not on this device. A
      // tree-listed file is read through its tree.
      if (!hasChunkTree(payload)) {
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
  }) => _transferQueue.run('cache/${object.id}', () async {
    await for (final _ in _plain(object, onProgress: onProgress)) {}
  });

  /// Verified encrypted chunks remain cached after interruption, including
  /// across process restarts. Retries fetch only missing chunks. The plaintext
  /// export is temporary and is removed on failure.
  Future<void> save(
    SignedObject object,
    String path, {
    void Function(int, int)? onProgress,
  }) => _transferQueue.run('save/${object.id}/$path', () async {
    final payload = await node.content(object);
    if (payload != null && payload['size'] is int) {
      checkRoomFor(payload, destination: File(path).parent.path);
    }
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
  });
}

/// Called with each data chunk of a file as it is stored or read: its hash,
/// and the offset and length of its plaintext in the file.
typedef ChunkSeen = void Function(String hash, int offset, int length);

/// [bytes] for people: KB, MB or GB.
String _sizeText(int bytes) => bytes < 1024 * 1024
    ? '${(bytes / 1024).ceil()} KB'
    : bytes < 1024 * 1024 * 1024
    ? '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB'
    : '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';

/// [source] in pieces of exactly [size] bytes, the last one shorter.
Stream<Uint8List> rechunk(Stream<List<int>> source, int size) async* {
  var buffer = Uint8List(size);
  var filled = 0;
  await for (final data in source) {
    var at = 0;
    while (at < data.length) {
      final n = min(size - filled, data.length - at);
      buffer.setRange(filled, filled + n, data, at);
      filled += n;
      at += n;
      if (filled == size) {
        yield buffer;
        buffer = Uint8List(size);
        filled = 0;
      }
    }
  }
  if (filled > 0) yield Uint8List.sublistView(buffer, 0, filled);
}

/// Whether two byte streams hold the same bytes, however they are split.
Future<bool> sameBytes(Stream<List<int>> a, Stream<List<int>> b) async {
  final left = StreamIterator(rechunk(a, Files.chunkSize));
  final right = StreamIterator(rechunk(b, Files.chunkSize));
  try {
    while (true) {
      final more = await left.moveNext();
      if (more != await right.moveNext()) return false;
      if (!more) return true;
      final x = left.current, y = right.current;
      if (x.length != y.length) return false;
      for (var i = 0; i < x.length; i++) {
        if (x[i] != y[i]) return false;
      }
    }
  } finally {
    await left.cancel();
    await right.cancel();
  }
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
  _Fetch(
    this.files,
    this.object,
    this.key,
    this.chunks, {
    this.asFile = false,
  }) {
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

  /// Whether fetched chunks are kept as files: those of tree-listed files.
  final bool asFile;
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
    final local = files.network.chunkSource;
    if (local != null) {
      for (final i in indices) {
        final bytes = await local(object, chunks[i]);
        if (bytes == null) continue;
        final plain = await node.blobs.decode(
          chunks[i],
          key,
          bytes: bytes,
          keep: false,
        );
        if (plain != null) got[i] = plain;
      }
    }
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
          final plain = await node.blobs.decode(
            chunks[i],
            key,
            bytes: bytes,
            asFile: asFile,
          );
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
