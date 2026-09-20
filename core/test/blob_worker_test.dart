import 'dart:io';
import 'dart:typed_data';

import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';

void main() {
  for (final disk in [false, true]) {
    test('local read stops at its byte budget (disk: $disk)', () async {
      final directory = await Directory.systemTemp.createTemp('ournet-budget-');
      final node = Node(
        await LocalIdentity.create(),
        Store(path: disk ? '${directory.path}/test.db' : null),
      );
      try {
        final key = Uint8List(32);
        final hash = await node.blobs.encode(
          Uint8List.fromList([1, 2, 3]),
          key,
        );
        // If the worker walks beyond the budget it returns null for the missing
        // chunk. It must instead reject the oversized prefix immediately.
        await expectLater(
          node.blobs.readLocal([hash, hash, 'missing'], key, limit: 5),
          throwsStateError,
        );
        await expectLater(
          node.blobs.readLocal([hash], key, expectedSize: 4),
          throwsStateError,
        );
        expect(
          await node.blobs.readLocal([hash], key, limit: 3, expectedSize: 3),
          [1, 2, 3],
        );
        expect(
          await node.blobs.readLocal([], key, limit: 0, expectedSize: 0),
          isEmpty,
        );
      } finally {
        await node.close();
        for (final file in await directory.list().toList()) {
          await file.delete();
        }
        await directory.delete();
      }
    });
  }

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
        // Whole-file reads verify and decrypt on their own connection.
        final second = await node.blobs.encode(
          Uint8List.fromList(List.generate(1000, (i) => i % 7)),
          key,
        );
        final whole = await node.blobs.readLocal([hash, second], key);
        expect(whole!.length, plain.length + 1000);
        expect(whole.sublist(0, plain.length), plain);
        expect(await node.blobs.readLocal([hash, 'missing'], key), isNull);
        await expectLater(
          node.blobs.readLocal([hash], Uint8List(32)),
          throwsA(anything),
        );
        node.store.db.execute('UPDATE blobs SET bytes=? WHERE id=?', [
          Uint8List.fromList([...encoded]..[0] ^= 1),
          second,
        ]);
        await expectLater(
          node.blobs.readLocal([hash, second], key),
          throwsA(anything),
        );
        node.store.db.execute('DELETE FROM blobs WHERE id=?', [second]);
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
