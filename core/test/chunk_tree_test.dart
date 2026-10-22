import 'dart:typed_data';

import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';

String hashOf(int i) => blobHash([i & 255, i >> 8 & 255, i >> 16 & 255]);

void main() {
  test('list chunks round-trip their hashes and refuse malformed ones', () {
    final hashes = [for (var i = 0; i < 5; i++) hashOf(i)];
    final packed = packHashes(hashes);
    expect(packed, hasLength(5 * 32));
    expect(unpackHashes(packed, 8), hashes);
    expect(() => unpackHashes(packed, 4), throwsStateError); // Overfull.
    expect(() => unpackHashes(packed.sublist(1), 8), throwsStateError);
    expect(() => unpackHashes(Uint8List(0), 8), throwsStateError);
  });

  Future<(Json, Map<String, Uint8List>)> build(int count, int fanOut) async {
    final lists = <String, Uint8List>{};
    final builder = ChunkTreeBuilder(fanOut, (plain) async {
      final hash = blobHash(plain);
      lists[hash] = plain;
      return hash;
    });
    for (var i = 0; i < count; i++) {
      await builder.add(hashOf(i));
    }
    return (await builder.finish(), lists);
  }

  Future<List<String>> walk(Json listing, Map<String, Uint8List> lists) async {
    final out = <String>[];
    await for (final segment in chunkSegments(
      listing,
      (h) async => lists[h]!,
    )) {
      out.addAll(segment);
    }
    return out;
  }

  test(
    'random chunk lookup visits only ancestors, including partial last branches',
    () async {
      for (final (count, fanOut) in [
        (512, 4),
        (600, 4),
        (5000, 32),
        (4097, 8),
        (1500, 3),
      ]) {
        final (listing, lists) = await build(count, fanOut);
        final payload = {...listing, 'chunkBytes': fanOut * 32};
        for (final i in [0, count ~/ 2, count - 1]) {
          var opened = 0;
          final hash = await chunkHashAt(payload, i, (h) async {
            opened++;
            return lists[h]!;
          });
          expect(hash, hashOf(i));
          expect(opened, listing['chunkDepth'] ?? 0);
        }
      }
    },
  );

  test('up to 512 chunks stay inline; more build a tree', () async {
    final (small, _) = await build(inlineChunks, 4096);
    expect(small.keys, ['chunks']);
    expect(small['chunks'], hasLength(inlineChunks));

    final (large, lists) = await build(inlineChunks + 1, 4096);
    expect(large['chunks'], isEmpty);
    expect(large['chunkDepth'], 1);
    expect(large['chunkTree'], hasLength(1));
    expect(await walk({...large, 'chunkBytes': 4096 * 32}, lists), [
      for (var i = 0; i <= inlineChunks; i++) hashOf(i),
    ]);
  });

  test('deep trees list every chunk once, in order, at one depth', () async {
    for (final (count, fanOut) in [(600, 4), (5000, 2), (4097, 8), (1500, 3)]) {
      final (listing, lists) = await build(count, fanOut);
      final depth = listing['chunkDepth'] as int;
      final roots = (listing['chunkTree'] as List).length;
      expect(roots, lessThanOrEqualTo(maxTreeRoots));
      expect(treeCapacity(roots, depth, fanOut), greaterThanOrEqualTo(count));
      final chunkSize = fanOut * 32;
      final payload = {...listing, 'chunkBytes': chunkSize};
      expect(await walk(payload, lists), [
        for (var i = 0; i < count; i++) hashOf(i),
      ], reason: '$count chunks at fan-out $fanOut');
    }
  });

  Json file(Json fields) => {
    'name': 'big.bin',
    'key': null,
    'chunkBytes': 128 * 1024,
    ...fields,
  };

  test('payload checks: inline keeps its 64 MiB cap, a tree has none', () {
    final root = hashOf(1);
    // Inline: as before.
    expect(
      validContent(
        'file',
        file({
          'chunks': [root],
          'size': 100,
        }),
      ),
      isTrue,
    );
    expect(
      validContent(
        'file',
        file({
          'chunks': [root],
          'size': 64 * 1024 * 1024 + 1,
        }),
      ),
      isFalse,
    );
    // A 1 TiB file in a depth-2 tree of one root, which lists up to 4096²
    // chunks of 128 KiB: 2 TiB.
    final big = file({
      'chunks': const [],
      'chunkTree': [root],
      'chunkDepth': 2,
      'size': 1 << 40,
    });
    expect(validContent('file', big), isTrue);
    expect(
      validContent('drive', {
        ...big,
        'entry': 'e',
        'revision': 'r',
        'parents': const [],
        'deleted': false,
        'type': 'file',
      }),
      isTrue,
    );
    // More than the tree can list, chunks beside it, or a bad depth.
    expect(validContent('file', {...big, 'size': (1 << 41) + 1}), isFalse);
    expect(
      validContent('file', {
        ...big,
        'chunks': [root],
      }),
      isFalse,
    );
    expect(validContent('file', {...big, 'chunkDepth': 0}), isFalse);
    expect(validContent('file', {...big, 'chunkDepth': 7}), isFalse);
    expect(validContent('file', {...big, 'chunkTree': const []}), isFalse);
    expect(
      validContent('file', {
        ...big,
        'chunkTree': List.filled(maxTreeRoots + 1, root),
      }),
      isFalse,
    );
    expect(validContent('file', {...big, 'chunkBytes': null}), isFalse);
  });

  test('a store indexes what a tree holds, and whether it is all here', () {
    final store = Store();
    addTearDown(store.close);
    final root = hashOf(1), list = hashOf(2), leaf = hashOf(3);
    expect(store.treeIndexed([root]), isFalse);
    store.indexTree(root, [list]);
    store.indexTree(root, [leaf], complete: true);
    expect(store.treeIndexed([root]), isTrue);
    expect(store.treeHas([root], root), isTrue);
    expect(store.treeHas([root], leaf), isTrue);
    expect(store.treeHas([root], hashOf(4)), isFalse);
    expect(store.treeHas([hashOf(5)], leaf), isFalse);
    expect(store.treeStored([root]), isFalse);
  });
}
