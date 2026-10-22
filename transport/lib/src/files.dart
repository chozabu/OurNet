import 'dart:io';
import 'dart:math';
import 'dart:async';
import 'dart:collection';
import 'dart:developer';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:ournet_core/ournet_core.dart';
import 'network.dart';
import 'transfers.dart';

class Files {
  static final _previews = Expando<_BoundedQueue<Uint8List>>();
  static final _transfers = Expando<_BoundedQueue<void>>();
  final Node node;
  final PeerNetwork network;
  Files(this.node, this.network);
  _BoundedQueue<Uint8List> get _previewQueue => _previews[node] ??=
      _BoundedQueue(32, 'Preview queue is full; tap to retry');
  _BoundedQueue<void> get _transferQueue => _transfers[node] ??= _BoundedQueue(
    16,
    'Transfer queue is full; retry shortly',
  );
  static final _rangeQueues = Expando<_BoundedQueue<Uint8List>>();
  static final _rangePages = Expando<LinkedHashMap<String, Uint8List>>();
  _BoundedQueue<Uint8List> get _rangeQueue => _rangeQueues[node] ??=
      _BoundedQueue(16, 'File range queue is full; retry shortly');

  static const chunkSize = 128 * 1024;

  /// The largest image shown inline, decoded whole in memory. Larger images
  /// are files like any other.
  static const inlineImageLimit = 32 * 1024 * 1024;

  /// Space left free on a disk when deciding whether a file fits.
  static const diskReserve = 64 * 1024 * 1024;

  /// The chunk size new files use; tests set a small one to build deep chunk
  /// trees from small files.
  static int newChunkBytes = chunkSize;

  static final _transfersOf = Expando<Transfers>();

  /// Large files being stored or fetched, shared by every [Files] of a node.
  Transfers get transfers => _transfersOf[node] ??= Transfers();

  /// Whether a large file may be synced now, without someone asking for it:
  /// the app says no on a phone in the background or on battery, unless
  /// the person allows it. Null allows it always.
  static Future<bool> Function()? largeTransfersAllowed;

  /// Whether [size] bytes is a large file: one listed in a chunk tree.
  static bool isLarge(int size) => size > inlineChunks * newChunkBytes;

  /// Whether automatic sync may move a file of [size] bytes now.
  static Future<bool> mayTransfer(int size) async =>
      !isLarge(size) || await (largeTransfersAllowed?.call() ?? true);
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
  ///
  /// With [journal] and [fingerprint], [open] reads it from an offset and an
  /// interrupted import carries on (see [storeResumable]).
  Future<SignedObject> publishFrom(
    Stream<List<int>> Function(int offset) open, {
    required int size,
    required String name,
    List<String> audience = const [],
    Json? drive,
    void Function(int completed, int total)? onProgress,
    ChunkSeen? onChunk,
    String? journal,
    String? fingerprint,
    bool keepData = true,
  }) async => _publish(
    journal != null && fingerprint != null
        ? await storeResumable(
            journal: journal,
            fingerprint: fingerprint,
            open: open,
            size: size,
            name: name,
            encrypt: audience.isNotEmpty,
            onProgress: onProgress,
            onChunk: onChunk,
            keepData: keepData,
          )
        : await storeFrom(
            open(0),
            size: size,
            name: name,
            encrypt: audience.isNotEmpty,
            onProgress: onProgress,
            onChunk: onChunk,
            keepData: keepData,
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
        if (stored['nonces'] != null) 'nonces': stored['nonces'],
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
    final stat = await file.stat();
    return storeResumable(
      journal: 'path:${file.absolute.path}',
      fingerprint: '${stat.size}/${stat.modified.microsecondsSinceEpoch}',
      open: (offset) => file.openRead(offset),
      size: stat.size,
      name: file.uri.pathSegments.last,
      encrypt: encrypt,
      onProgress: onProgress,
    );
  }

  /// Chunks sealed at once during an import.
  static const sealAhead = 8;

  /// How far apart, in chunks, an import records where it has got to.
  static const checkpointChunks = 256;

  /// Imports older than this that were never finished are forgotten.
  static const journalAge = Duration(days: 7);

  /// [storeFrom] for a file that can be read again from any [open]ed offset,
  /// such as a file on disk: an import interrupted (or cancelled) part of the
  /// way through a large file carries on from its last checkpoint when it
  /// is started again, keeping its key and the chunks it stored. It does so
  /// only while [fingerprint] (the file's size and modification time, or
  /// its token) is unchanged; otherwise it starts again from the beginning,
  /// so an edited file never mixes old and new chunks. [journal] names the
  /// import, by where the file is.
  Future<Json> storeResumable({
    required String journal,
    required String fingerprint,
    required Stream<List<int>> Function(int offset) open,
    required int size,
    required String name,
    bool encrypt = true,
    void Function(int completed, int total)? onProgress,
    ChunkSeen? onChunk,
    bool keepData = true,
  }) async {
    final key = 'imports/$journal';
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final e in node.store.settingsUnder('imports/').entries) {
      if (e.value is! Map ||
          (e.value['at'] as int? ?? 0) < now - journalAge.inMilliseconds) {
        node.store.removeSetting('imports/${e.key}');
      }
    }
    final saved = node.store.setting(key);
    final resume =
        saved is Map &&
        saved['fingerprint'] == fingerprint &&
        saved['size'] == size &&
        saved['encrypt'] == encrypt &&
        saved['chunkBytes'] == newChunkBytes;
    if (saved != null && !resume) node.store.removeSetting(key);
    return storeFrom(
      null,
      open: open,
      size: size,
      name: name,
      encrypt: encrypt,
      onProgress: onProgress,
      onChunk: onChunk,
      keepData: keepData,
      resume: resume ? Json.from(saved) : null,
      checkpoint: (state) => node.store.set(key, {
        ...state,
        'fingerprint': fingerprint,
        'size': size,
        'encrypt': encrypt,
        'at': now,
      }),
      done: () => node.store.removeSetting(key),
    );
  }

  /// [store] for a file read from [source] as it is encrypted, a chunk at a
  /// time. [size] must be its exact length, or the import fails as changed.
  /// A large one shows in [transfers], where it can be cancelled.
  Future<Json> storeFrom(
    Stream<List<int>>? source, {
    required int size,
    required String name,
    bool encrypt = true,
    void Function(int completed, int total)? onProgress,
    ChunkSeen? onChunk,
    Stream<List<int>> Function(int offset)? open,
    Json? resume,
    void Function(Json state)? checkpoint,
    void Function()? done,
    bool keepData = true,
  }) async {
    // Unkept data chunks take no room here: only the few list chunks do.
    checkRoom(size, name: name, stored: keepData);
    final trace = TimelineTask()..start('attachment.import');
    final transfer = transfers.start(name, size, upload: true);
    try {
      final bytes = newChunkBytes;
      final List<int>? keyBytes;
      if (resume != null) {
        keyBytes = resume['key'] == null ? null : unb64(resume['key']);
      } else {
        final key = await Chacha20.poly1305Aead().newSecretKey();
        keyBytes = encrypt ? await key.extractBytes() : null;
      }
      // A file that will be listed in a tree keeps its chunks as files.
      final asFile = size > inlineChunks * bytes;
      Future<String> list(Uint8List plain) =>
          node.blobs.encode(plain, keyBytes, asFile: asFile);
      final listing = resume == null
          ? ChunkTreeBuilder(listFanOut(bytes), list)
          : ChunkTreeBuilder.resume(listFanOut(bytes), list, resume['tree']);
      var completed = resume == null ? 0 : resume['offset'] as int;
      onProgress?.call(completed, size);
      transfer.progress(completed);
      final input = source ?? open!(completed);
      // Several chunks seal at once; they are listed in order as each is
      // done. Chunks not kept are only sealed for their hash, on the pool.
      final pending = <(Future<String>, int, int)>[];
      var listed = completed;
      Future<void> next() async {
        final (hash, offset, length) = pending.removeAt(0);
        final name = await hash;
        await listing.add(name);
        listed = offset + length;
        onChunk?.call(name, offset, length);
        onProgress?.call(listed, size);
        transfer.progress(listed);
        // Only whole chunks are recorded, so carrying on starts on one.
        if (checkpoint != null &&
            asFile &&
            listing.count % checkpointChunks == 0 &&
            length == bytes) {
          checkpoint({
            'key': keyBytes == null ? null : b64(keyBytes),
            'chunkBytes': bytes,
            'offset': listed,
            'tree': listing.state,
          });
        }
      }

      try {
        await for (final data in rechunk(input, bytes)) {
          transfer.check();
          final offset = completed;
          completed += data.length;
          if (completed > size) {
            throw StateError('File changed during import');
          }
          pending.add((
            keepData
                ? node.blobs.encode(data, keyBytes, asFile: asFile)
                : node.blobs.sealedHash(data, keyBytes),
            offset,
            data.length,
          ));
          if (pending.length >= sealAhead) await next();
        }
        while (pending.isNotEmpty) {
          await next();
        }
      } catch (_) {
        for (final (hash, _, _) in pending) {
          hash.ignore();
        }
        rethrow;
      }
      if (completed != size) throw StateError('File changed during import');
      final stored = {
        'name': name,
        'size': size,
        ...await listing.finish(),
        'chunkBytes': bytes,
        'key': keyBytes == null ? null : b64(keyBytes),
        // Chunk nonces come from the key and plaintext: a device holding the
        // same plaintext can tell it is the same file without fetching it.
        'nonces': 'derived',
      };
      await indexTree(stored);
      done?.call();
      return stored;
    } finally {
      transfer.finish();
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
          'Storing $name here takes ${_sizeText(needed)}, but OurNet has '
          '${_sizeText(max(0, left))} left of the storage you allowed it. '
          'Allow more in Settings → Storage, or remove files.',
        );
      }
      final path = node.store.path;
      final free = path == null
          ? null
          : NativeDisk.freeBytes(File(path).parent.path);
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
  /// A chunk a synced folder holds counts as here: it is made from the
  /// folder when wanted.
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
    bool shown = false,
    bool keepData = true,
  }) async* {
    final payload = await node.content(object);
    if (payload == null || payload['chunks'] is! List)
      throw StateError('File is not readable by this device');
    final transfer = shown
        ? transfers.start(
            '${payload['name']}',
            payload['size'] as int,
            upload: false,
          )
        : null;
    try {
      yield* _read(object, payload, onProgress, onChunk, transfer, keepData);
    } finally {
      transfer?.finish();
    }
  }

  Stream<List<int>> _read(
    SignedObject object,
    Json payload,
    void Function(int, int)? onProgress,
    ChunkSeen? onChunk,
    Transfer? transfer,
    bool keepData,
  ) async* {
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
        keep: keepData,
      );
      for (var i = 0; i < chunks.length; i++) {
        transfer?.check();
        final plain = await fetch.chunk(i);
        onChunk?.call(chunks[i], size, plain.length);
        size += plain.length;
        if (size > payload['size']) throw StateError('File size exceeded');
        onProgress?.call(size, payload['size'] as int);
        transfer?.progress(size);
        yield plain;
      }
    }
    if (size != payload['size']) throw StateError('File size mismatch');
    await indexTree(payload);
  }

  /// The plaintext of [object]'s file, fetched and decrypted a chunk at a
  /// time as it is read: for writing straight to where it is wanted.
  /// [onChunk] sees each data chunk's hash and where it is in the file.
  ///
  /// [keepData] false keeps none of the fetched data chunks here: for a file
  /// written to a synced folder, from which they can be made again.
  Stream<List<int>> open(
    SignedObject object, {
    void Function(int, int)? onProgress,
    ChunkSeen? onChunk,
    bool keepData = true,
  }) => _plain(
    object,
    onProgress: onProgress,
    onChunk: onChunk,
    shown: true,
    keepData: keepData,
  );

  /// Bounded random access to encrypted file chunks. A deep tree lookup
  /// visits only its ancestor lists; it never streams earlier file bytes.
  Future<Uint8List> readRange(SignedObject object, int offset, int length) =>
      _rangeQueue.run('${object.id}/$offset/$length', () async {
        if (offset < 0 || length < 0 || length > 256 * 1024)
          throw StateError('Invalid file range');
        final payload = await node.content(object);
        final size = payload?['size'];
        if (payload == null ||
            size is! int ||
            offset > size ||
            length > size - offset)
          throw StateError('Range is outside file');
        final key = payload['key'] is String ? unb64(payload['key']) : null;
        final pages = _rangePages[node] ??= LinkedHashMap();
        Future<Uint8List> open(String hash) async {
          final cacheKey = '${object.id}/$hash';
          final cached = pages.remove(cacheKey);
          if (cached != null) {
            pages[cacheKey] = cached;
            return cached;
          }
          final plain = await _Fetch(this, object, key, [
            hash,
          ], asFile: hasChunkTree(payload)).chunk(0);
          pages[cacheKey] = plain;
          while (pages.length > 32) {
            pages.remove(pages.keys.first);
          }
          return plain;
        }

        final bytes = payload['chunkBytes'] as int;
        final out = BytesBuilder(copy: false);
        var at = offset;
        while (at < offset + length) {
          final hash = await chunkHashAt(payload, at ~/ bytes, open);
          final data = await open(hash);
          final start = at % bytes;
          final n = min(offset + length - at, data.length - start);
          if (n <= 0) throw StateError('File chunk is cut short');
          out.add(Uint8List.sublistView(data, start, start + n));
          at += n;
        }
        return out.takeBytes();
      });

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

  /// Whether [source] holds exactly the file of [object]: its chunks, sealed
  /// with the file's key, have the file's chunk names. Only for a file whose
  /// nonces come from its key and plaintext (`nonces: derived`); of a tree
  /// file only the list chunks are fetched, never its data.
  ///
  /// [onChunk] sees each chunk that matches, with where it lies.
  Future<bool> sealsTo(
    Stream<List<int>> source,
    SignedObject object, {
    ChunkSeen? onChunk,
  }) async {
    final payload = await node.content(object);
    if (payload == null ||
        payload['nonces'] != 'derived' ||
        payload['chunkBytes'] is! int) {
      return false;
    }
    final key = payload['key'] == null ? null : unb64(payload['key']);
    final local = StreamIterator(rechunk(source, payload['chunkBytes'] as int));
    final pending = <(Future<String>, String, int, int)>[];
    var offset = 0;
    Future<Uint8List> open(String hash) =>
        _Fetch(this, object, key, [hash], asFile: true).chunk(0);
    Future<bool> next() async {
      final (hash, name, at, length) = pending.removeAt(0);
      if (await hash != name) return false;
      onChunk?.call(name, at, length);
      return true;
    }

    try {
      await for (final segment in chunkSegments(payload, open)) {
        for (final expected in segment) {
          if (!await local.moveNext()) return false;
          final chunk = local.current;
          pending.add((
            node.blobs.sealedHash(chunk, key),
            expected,
            offset,
            chunk.length,
          ));
          offset += chunk.length;
          if (pending.length >= sealAhead && !await next()) return false;
        }
      }
      while (pending.isNotEmpty) {
        if (!await next()) return false;
      }
      // Read to the end: the source checks it did not change meanwhile.
      return !await local.moveNext();
    } finally {
      for (final (hash, _, _, _) in pending) {
        hash.ignore();
      }
      await local.cancel();
    }
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
    await for (final _ in _plain(
      object,
      onProgress: onProgress,
      shown: true,
    )) {}
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
      await for (final data in _plain(
        object,
        onProgress: onProgress,
        shown: true,
      )) {
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
    this.keep = true,
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

  /// Whether fetched chunks are kept at all.
  final bool keep;
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
            keep: keep,
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
