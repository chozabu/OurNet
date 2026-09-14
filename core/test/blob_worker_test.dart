import 'dart:io';
import 'dart:typed_data';

import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'worker stores encrypted chunks across connections and rejects tampering',
    () async {
      final directory = await Directory.systemTemp.createTemp('ournet-worker-');
      final path = '${directory.path}/test.db';
      final node = Node(await LocalIdentity.create(), Store(path: path));
      try {
        final plain = Uint8List.fromList(
          List.generate(128 * 1024, (i) => i % 251),
        );
        final key = Uint8List.fromList(List.generate(32, (i) => i));
        final hash = await node.blobs.encode(plain, key);
        final encoded = node.store.blob(hash)!;
        expect(encoded, isNot(plain));
        expect(await node.blobs.decode(hash, key), plain);
        expect(await node.blobs.decode('missing', key), isNull);
        await expectLater(
          node.blobs.decode(hash, Uint8List(32)),
          throwsStateError,
        );
        await expectLater(
          node.blobs.decode(hash, key, bytes: [1, 2, 3]),
          throwsStateError,
        );
        // A failed job must not poison the worker or replace a verified blob.
        expect(await node.blobs.decode(hash, key), plain);
        final publicHash = await node.blobs.encode(plain, null);
        expect(await node.blobs.decode(publicHash, null), plain);
        expect(
          node.store.db.select('SELECT bytes FROM blob_usage').single['bytes'],
          encoded.length + plain.length,
        );
      } finally {
        await node.close();
        for (final file in await directory.list().toList()) {
          await file.delete();
        }
        await directory.delete();
      }
      await expectLater(
        node.blobs.encode(Uint8List(1), null),
        throwsStateError,
      );
      await node.blobs.close();
    },
  );

  test('close drains accepted worker jobs', () async {
    final node = Node(await LocalIdentity.create(), Store());
    final jobs = List.generate(
      4,
      (i) => node.blobs.encode(Uint8List.fromList([i]), null),
    );
    final closing = node.blobs.close();
    expect(await Future.wait(jobs), hasLength(4));
    await closing;
    await node.close();
  });
}
