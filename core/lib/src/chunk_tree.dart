import 'dart:typed_data';

import 'model.dart';
import 'node.dart';

/// A file's chunks are listed in its payload (`chunks`) when there are at most
/// [inlineChunks] of them, the most builds before 0.2.47 accept. A larger file
/// lists them in a tree of list chunks instead: `chunkTree` holds the hashes
/// of up to [maxTreeRoots] list chunks at depth `chunkDepth`, and `chunks` is
/// empty. A list chunk is stored, encrypted and fetched like any other chunk;
/// its plaintext is the raw 32-byte hashes of the level below, up to
/// [listFanOut] of them, and at depth 1 those are the file's data chunks, in
/// order. Every data chunk is at the same depth. Builds that do not know the
/// tree see a file over 64 MiB and refuse its payload, so it stays hidden from
/// them rather than appearing empty.
const inlineChunks = 512;

/// Most list chunks a payload's `chunkTree` holds.
const maxTreeRoots = 512;

/// Deepest tree a payload may declare. Depth 6 at 128 KiB chunks is far
/// beyond any storage; the bound keeps a hostile payload from deep recursion.
const maxTreeDepth = 6;

/// Hashes a list chunk holds at chunk size [chunkBytes].
int listFanOut(int chunkBytes) => chunkBytes ~/ 32;

/// The most data chunks a tree of [roots] list chunks at [depth] can list,
/// saturating rather than overflowing.
int treeCapacity(int roots, int depth, int fanOut) {
  const ceiling = 1 << 52;
  var n = roots;
  for (var i = 0; i < depth; i++) {
    if (n > ceiling ~/ fanOut) return ceiling;
    n *= fanOut;
  }
  return n;
}

final _hash = RegExp(r'^[0-9a-f]{64}$');

/// Whether payload [p] declares a well-formed chunk tree. The file size has
/// no fixed limit: it must only fit the tree it declares.
bool validChunkTree(Json p) {
  final roots = p['chunkTree'], depth = p['chunkDepth'], size = p['size'];
  final bytes = p['chunkBytes'];
  if (roots is! List ||
      roots.isEmpty ||
      roots.length > maxTreeRoots ||
      !roots.every((h) => h is String && _hash.hasMatch(h)) ||
      depth is! int ||
      depth < 1 ||
      depth > maxTreeDepth ||
      !validChunkBytes(bytes) ||
      p['chunks'] is! List ||
      (p['chunks'] as List).isNotEmpty ||
      size is! int ||
      size < 0 ||
      p['name'] is! String ||
      (p['name'] as String).length > 255 ||
      (p['key'] != null && p['key'] is! String)) {
    return false;
  }
  final chunkSize = bytes as int;
  final needed = (size + chunkSize - 1) ~/ chunkSize;
  return needed <= treeCapacity(roots.length, depth, listFanOut(chunkSize));
}

/// Whether payload [p] lists its chunks in a tree.
bool hasChunkTree(Json p) => p['chunkTree'] is List;

/// The plaintext of a list chunk holding [hashes].
Uint8List packHashes(List<String> hashes) {
  final out = Uint8List(hashes.length * 32);
  for (var i = 0; i < hashes.length; i++) {
    final h = hashes[i];
    if (!_hash.hasMatch(h)) throw StateError('Invalid chunk hash');
    for (var j = 0; j < 32; j++) {
      out[i * 32 + j] = int.parse(h.substring(j * 2, j * 2 + 2), radix: 16);
    }
  }
  return out;
}

const _hex = '0123456789abcdef';

/// The hashes a list chunk holds; refuses a malformed or overfull one.
List<String> unpackHashes(List<int> plain, int fanOut) {
  if (plain.isEmpty || plain.length % 32 != 0 || plain.length ~/ 32 > fanOut) {
    throw StateError('Invalid chunk list');
  }
  return [
    for (var i = 0; i < plain.length; i += 32)
      String.fromCharCodes([
        for (var j = i; j < i + 32; j++) ...[
          _hex.codeUnitAt(plain[j] >> 4),
          _hex.codeUnitAt(plain[j] & 15),
        ],
      ]),
  ];
}

/// Builds a file's chunk listing as its chunks are stored, in order: inline
/// for up to [inlineChunks] chunks, otherwise a tree. [store] stores one list
/// chunk's plaintext and returns its hash. Memory stays at a few list chunks
/// per level whatever the file's size.
class ChunkTreeBuilder {
  ChunkTreeBuilder(this.fanOut, this.store);
  final int fanOut;
  final Future<String> Function(Uint8List plain) store;

  /// Pending hashes per level; level 0 holds data chunks.
  final _levels = <List<String>>[[]];
  final _first = <String>[];
  var _count = 0;

  /// Data chunks added so far.
  int get count => _count;

  /// Where the listing has got to, for picking an interrupted import up
  /// again with [ChunkTreeBuilder.resume]: a few list chunks' worth of
  /// hashes per level, whatever the file's size.
  Json get state => {
    'count': _count,
    'first': List<String>.of(_first),
    'levels': [for (final level in _levels) List<String>.of(level)],
  };

  /// A builder carrying on from [state].
  ChunkTreeBuilder.resume(this.fanOut, this.store, Json state) {
    _count = state['count'] as int;
    _first.addAll((state['first'] as List).cast<String>());
    _levels
      ..clear()
      ..addAll([
        for (final level in state['levels'] as List)
          (level as List).cast<String>().toList(),
      ]);
  }

  Future<void> add(String hash) async {
    if (_first.length <= inlineChunks) _first.add(hash);
    _count++;
    await _push(hash, 0);
  }

  Future<void> _push(String hash, int level) async {
    if (_levels.length == level) _levels.add([]);
    final pending = _levels[level]..add(hash);
    if (pending.length < fanOut) return;
    final list = await store(packHashes(pending));
    pending.clear();
    await _push(list, level + 1);
  }

  /// The payload fields that list the chunks: `chunks`, and for a tree
  /// `chunkTree` and `chunkDepth`.
  Future<Json> finish() async {
    if (_count <= inlineChunks) return {'chunks': List<String>.of(_first)};
    var level = 0;
    while (true) {
      final top = level == _levels.length - 1;
      final pending = _levels[level];
      if (top && level > 0 && pending.length <= maxTreeRoots) {
        return {
          'chunks': const <String>[],
          'chunkTree': List<String>.of(pending),
          'chunkDepth': level,
        };
      }
      if (pending.isNotEmpty) {
        final list = await store(packHashes(pending));
        pending.clear();
        if (_levels.length == level + 1) _levels.add([]);
        _levels[level + 1].add(list);
      }
      level++;
    }
  }
}

/// Walks a payload's chunk listing, yielding its data chunk hashes a list
/// chunk at a time (all at once when inline). [open] returns a list chunk's
/// plaintext, fetching it if need be. [onList] sees each list chunk's hash as
/// it is reached, for indexing what the file holds.
Stream<List<String>> chunkSegments(
  Json payload,
  Future<Uint8List> Function(String hash) open, {
  void Function(String hash)? onList,
}) async* {
  if (!hasChunkTree(payload)) {
    yield (payload['chunks'] as List).cast<String>();
    return;
  }
  final fanOut = listFanOut(payload['chunkBytes'] as int);
  Stream<List<String>> walk(String hash, int depth) async* {
    onList?.call(hash);
    final entries = unpackHashes(await open(hash), fanOut);
    if (depth == 1) {
      yield entries;
      return;
    }
    for (final child in entries) {
      yield* walk(child, depth - 1);
    }
  }

  for (final root in (payload['chunkTree'] as List).cast<String>()) {
    yield* walk(root, payload['chunkDepth'] as int);
  }
}

/// Finds one data chunk without scanning preceding tree branches. The caller
/// may cache immutable list chunks; a lookup visits only the tree depth.
Future<String> chunkHashAt(
  Json payload,
  int index,
  Future<Uint8List> Function(String hash) open,
) async {
  if (index < 0) throw RangeError.value(index);
  if (!hasChunkTree(payload)) {
    final chunks = payload['chunks'] as List;
    if (index >= chunks.length) throw StateError('Chunk is outside file');
    return chunks[index] as String;
  }
  final fanOut = listFanOut(payload['chunkBytes'] as int);
  final depth = payload['chunkDepth'] as int;
  if (depth < 1 || depth > maxTreeDepth || fanOut < 2)
    throw StateError('Invalid chunk tree');
  var span = 1;
  for (var i = 0; i < depth; i++) {
    span *= fanOut;
  }
  final roots = payload['chunkTree'] as List;
  final root = index ~/ span;
  if (root >= roots.length) throw StateError('Chunk is outside file');
  var hash = roots[root] as String;
  var remainder = index % span;
  for (var level = depth; level > 0; level--) {
    final entries = unpackHashes(await open(hash), fanOut);
    span ~/= fanOut;
    final child = remainder ~/ span;
    if (child >= entries.length) throw StateError('Chunk tree is cut short');
    hash = entries[child];
    remainder %= span;
  }
  return hash;
}

/// Every chunk below list chunk [root] of a tree at [depth], list chunks and
/// data chunks alike, in batches of up to one list chunk's entries.
Stream<List<String>> treeMembers(
  String root,
  int depth,
  int fanOut,
  Future<Uint8List> Function(String hash) open,
) async* {
  final entries = unpackHashes(await open(root), fanOut);
  yield entries;
  if (depth == 1) return;
  for (final child in entries) {
    yield* treeMembers(child, depth - 1, fanOut, open);
  }
}

/// Records what the chunk tree of [payload] holds, from list chunks stored
/// here, so its chunks can be offered to other devices and counted as
/// stored. Returns false when a list chunk is not stored here yet.
Future<bool> indexChunkTree(Node node, Json payload) async {
  if (!hasChunkTree(payload)) return true;
  final roots = (payload['chunkTree'] as List).cast<String>();
  if (node.store.treeIndexed(roots)) return true;
  final key = payload['key'] == null ? null : unb64(payload['key']);
  final fanOut = listFanOut(payload['chunkBytes'] as int);
  Future<Uint8List> open(String hash) async {
    final plain = await node.blobs.decode(hash, key);
    if (plain == null) throw const _Missing();
    return plain;
  }

  try {
    for (final root in roots) {
      if (node.store.treeIndexed([root])) continue;
      await for (final batch in treeMembers(
        root,
        payload['chunkDepth'] as int,
        fanOut,
        open,
      )) {
        node.store.indexTree(root, batch);
      }
      node.store.indexTree(root, const [], complete: true);
    }
    return true;
  } on _Missing {
    return false;
  }
}

class _Missing {
  const _Missing();
}
