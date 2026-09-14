import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';

void main() {
  test(
    'preview requests share work, enforce limits and recover after errors',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ournet-preview-',
      );
      final node = Node(
        await LocalIdentity.create(),
        Store(path: '${directory.path}/test.db'),
      );
      final files = Files(node, PeerNetwork(node));
      try {
        final source = File('${directory.path}/source.bin');
        final bytes = Uint8List.fromList(List.generate(300000, (i) => i % 251));
        await source.writeAsBytes(bytes);
        final progress = <int>[];
        final object = await files.publish(
          source.path,
          audience: [node.person],
          onProgress: (completed, total) {
            expect(total, bytes.length);
            progress.add(completed);
          },
        );
        expect(progress, [0, 131072, 262144, 300000]);
        final first = files.readBytes(object);
        final duplicate = Files(node, PeerNetwork(node)).readBytes(object);
        expect(identical(first, duplicate), isTrue);
        expect(await first, bytes);
        await expectLater(
          files.readBytes(object, limit: 100),
          throwsStateError,
        );
        expect(await files.readBytes(object), bytes);
      } finally {
        await node.close();
        for (final file in await directory.list().toList()) {
          await file.delete();
        }
        await directory.delete();
      }
    },
  );
  test(
    'encrypted multi-chunk attachment transfers over QUIC and denies another friend',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ournet-file-test-',
      );
      final nodes = <Node>[];
      final networks = <PeerNetwork>[];
      try {
        for (var i = 0; i < 3; i++) {
          final node = Node(await LocalIdentity.create(), Store());
          nodes.add(node);
          final network = PeerNetwork(node);
          networks.add(network);
          await network.start(local: true);
        }
        final a = nodes[0], b = nodes[1];
        for (var i = 1; i < 3; i++) {
          await networks[0].addCard(networks[i].contactCard());
          await networks[i].addCard(networks[0].contactCard());
        }
        final source = File('${directory.path}/source.bin');
        final data = Uint8List.fromList(List.generate(300000, (i) => i % 251));
        await source.writeAsBytes(data);
        final object = await Files(
          a,
          networks[0],
        ).publish(source.path, audience: [b.person]);
        final payload = (await a.content(object))!;
        expect(payload['chunks'], hasLength(3));
        expect(
          a.store.blob(payload['chunks'][0]),
          isNot(equals(data.sublist(0, Files.chunkSize))),
        );
        await networks[0].sync(b.identity.device);
        final received = b.store.get(object.id)!;
        final target = File('${directory.path}/received.bin');
        await Files(b, networks[1]).save(received, target.path);
        expect(await target.readAsBytes(), data);
        await expectLater(
          networks[2].request(a.identity.device, {
            'type': 'blob',
            'object': object.id,
            'hash': payload['chunks'][0],
          }),
          throwsA(anything),
        );
        expect(nodes[2].store.get(object.id), isNull);
        expect(
          () => b.store.putBlob(
            payload['chunks'][0],
            Uint8List.fromList([1, 2, 3]),
          ),
          throwsA(anything),
        );
        // A downloaded public file remains available through an admitted
        // holder after its original author's endpoint goes offline.
        final c = nodes[2];
        b.subscribe('files', true);
        c.subscribe('files', true);
        final public = await Files(a, networks[0]).publish(source.path);
        await networks[1].sync(a.identity.device);
        await Files(
          b,
          networks[1],
        ).save(b.store.get(public.id)!, '${directory.path}/cached.bin');
        await networks[0].stop();
        c.contacts.remove(a.identity.device);
        await networks[1].addCard(networks[2].contactCard());
        await networks[2].addCard(networks[1].contactCard());
        await networks[2].sync(b.identity.device);
        await Files(
          c,
          networks[2],
        ).save(c.store.get(public.id)!, '${directory.path}/relayed.bin');
        expect(await File('${directory.path}/relayed.bin').readAsBytes(), data);
      } finally {
        for (final network in networks) {
          await network.stop();
        }
        for (final node in nodes) {
          await node.close();
        }
        // Only the exact files created by this test are removed.
        for (final name in [
          'source.bin',
          'received.bin',
          'received.bin.ournet-part',
          'cached.bin',
          'cached.bin.ournet-part',
          'relayed.bin',
          'relayed.bin.ournet-part',
        ]) {
          final file = File('${directory.path}/$name');
          if (await file.exists()) await file.delete();
        }
        await directory.delete();
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
  test('cached status and object previews use the file key', () async {
    final directory = await Directory.systemTemp.createTemp('ournet-thumb-');
    final node = Node(
      await LocalIdentity.create(),
      Store(path: '${directory.path}/test.db'),
    );
    final files = Files(node, PeerNetwork(node));
    try {
      final source = File('${directory.path}/photo.bin');
      await source.writeAsBytes(List.generate(200000, (i) => i % 7));
      final object = await files.publish(source.path, audience: [node.person]);
      final payload = (await node.content(object))!;
      expect(files.cached(payload), isTrue);
      final missing = {
        ...payload,
        'chunks': [...payload['chunks'], 'f' * 64],
      };
      expect(files.cached(missing), isFalse);
      expect(await files.readPreview(object, 'list'), isNull);
      final rgba = Uint8List(16 * 12 * 4)..fillRange(0, 16 * 12 * 4, 255);
      final encoded = await files.storePreview(object, 'list', rgba, 16, 12);
      expect(await files.readPreview(object, 'list'), encoded);
      expect(await files.readPreview(object, 'other'), isNull);
      // Stored bytes are sealed with this file's key and bound to its ID.
      final sealed = node.store.preview('${object.id}/list')!;
      expect(sealed, isNot(encoded));
      final another = await files.publish(source.path, audience: [node.person]);
      node.store.putPreview('${another.id}/list', sealed);
      expect(await files.readPreview(another, 'list'), isNull);
    } finally {
      await node.close();
      await directory.delete(recursive: true);
    }
  });
}
