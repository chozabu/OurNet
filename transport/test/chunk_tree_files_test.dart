import 'dart:io';
import 'dart:typed_data';

import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';
import 'package:test/test.dart';

/// Files of more than 512 chunks are listed in a chunk tree. A 1 KiB chunk
/// size builds deep trees from small files: 32 hashes per list chunk.
void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ournet-tree-');
    Files.newChunkBytes = 1024;
  });
  tearDown(() async {
    Files.newChunkBytes = Files.chunkSize;
    await directory.delete(recursive: true);
  });

  Uint8List data(int length) => Uint8List.fromList(
    List.generate(length, (i) => (i * 31 + i ~/ 977) & 255),
  );

  test(
    'a depth-2 tree stores, indexes and reads back on its own device',
    () async {
      final node = Node(await LocalIdentity.create(), Store());
      addTearDown(node.close);
      final files = Files(node, PeerNetwork(node));
      // More than 512 roots × 32 chunks: two levels of list chunks.
      final bytes = data(512 * 32 * 1024 + 4096 + 17);
      final source = File('${directory.path}/big.bin')..writeAsBytesSync(bytes);
      final object = await files.publish(
        source.path,
        drive: {
          'entry': randomId(),
          'revision': randomId(),
          'parents': const [],
          'folder': null,
          'type': 'file',
          'deleted': false,
        },
        audience: [node.person],
      );
      final payload = (await node.content(object))!;
      expect(payload['chunks'], isEmpty);
      expect(payload['chunkDepth'], 2);
      expect(payload['chunkBytes'], 1024);
      final roots = (payload['chunkTree'] as List).cast<String>();
      expect(roots.length, lessThanOrEqualTo(maxTreeRoots));
      expect(node.store.treeIndexed(roots), isTrue);
      expect(files.cached(payload), isTrue);
      final target = '${directory.path}/back.bin';
      await files.save(object, target);
      expect(await File(target).readAsBytes(), bytes);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'another device fetches a tree file, and only chunks the tree holds',
    () async {
      final author = Node(await LocalIdentity.create(), Store());
      final reader = Node(await LocalIdentity.create(), Store());
      final na = PeerNetwork(author), nr = PeerNetwork(reader);
      addTearDown(() async {
        await na.stop();
        await nr.stop();
        await author.close();
        await reader.close();
      });
      for (final n in [na, nr]) {
        await n.start(local: true, automatic: false);
      }
      await na.addCard(nr.contactCard());
      await nr.addCard(na.contactCard());
      final bytes = data(700 * 1024 + 5); // 701 chunks: one level.
      final source = File('${directory.path}/a.bin')..writeAsBytesSync(bytes);
      final object = await Files(
        author,
        na,
      ).publish(source.path, audience: [reader.person]);
      await na.sync(reader.identity.device);
      final mine = reader.store.get(object.id)!;
      final payload = (await reader.content(mine))!;
      expect(payload['chunkDepth'], 1);
      final files = Files(reader, nr);
      expect(files.cached(payload), isFalse);
      final target = '${directory.path}/b.bin';
      await files.save(mine, target);
      expect(await File(target).readAsBytes(), bytes);
      // Having read it all, the reader indexed the tree and holds it.
      expect(files.cached(payload), isTrue);
      final roots = (payload['chunkTree'] as List).cast<String>();
      expect(reader.store.treeIndexed(roots), isTrue);

      // A chunk outside the file's tree is refused, one inside is served.
      final stranger = blobHash([1, 2, 3]);
      await expectLater(
        nr.requestBytes(author.identity.device, {
          'type': 'blobs',
          'object': object.id,
          'hashes': [stranger],
        }),
        throwsA(anything),
      );
      final (header, _) = await nr.requestBytes(author.identity.device, {
        'type': 'blobs',
        'object': object.id,
        'hashes': [roots.first],
      });
      expect((header['sizes'] as List).single, isA<int>());
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'files up to 512 chunks keep the inline list older builds read',
    () async {
      final node = Node(await LocalIdentity.create(), Store());
      addTearDown(node.close);
      final source = File('${directory.path}/s.bin')
        ..writeAsBytesSync(data(512 * 1024));
      final object = await Files(
        node,
        PeerNetwork(node),
      ).publish(source.path, audience: [node.person]);
      final payload = (await node.content(object))!;
      expect(payload['chunks'], hasLength(512));
      expect(payload.containsKey('chunkTree'), isFalse);
    },
  );
}
