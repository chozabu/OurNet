import 'dart:io';

import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';

void main() {
  test('the limit and warning default to 20 and 5 GiB and are settings', () {
    final store = Store();
    addTearDown(store.close);
    expect(store.storageLimit, 20 * 1024 * 1024 * 1024);
    expect(store.storageWarning, 5 * 1024 * 1024 * 1024);
    store.set('storageLimit', 1000);
    store.set('storageWarning', 500);
    expect(store.storageLimit, 1000);
    expect(store.storageWarning, 500);
    // Cleared or nonsense values fall back to the defaults.
    store.set('storageLimit', null);
    store.set('storageWarning', -1);
    expect(store.storageLimit, Store.defaultStorageLimit);
    expect(store.storageWarning, Store.defaultStorageWarning);
  });

  test('files count with objects towards the limit', () async {
    final node = Node(await LocalIdentity.create(), Store());
    addTearDown(node.close);
    final store = node.store;
    final post = await node.publish('post', {'text': 'takes some room'});
    final chunk = List<int>.filled(1000, 7);
    store.set('storageLimit', post.wire.length + chunk.length - 1);
    expect(() => store.putBlob(blobHash(chunk), chunk), throwsStateError);
    // Enforced in the database too, for writes that skip [Store.putBlob].
    expect(
      () => store.db.execute('INSERT INTO blobs VALUES (?,?)', [
        blobHash(chunk),
        chunk,
      ]),
      throwsA(isA<Exception>()),
    );
    store.set('storageLimit', post.wire.length + chunk.length);
    store.putBlob(blobHash(chunk), chunk);
    expect(store.storedBytes, post.wire.length + chunk.length);
  });

  test(
    'a profile from before the setting gets the configurable limit',
    () async {
      final directory = await Directory.systemTemp.createTemp('ournet-limit-');
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/profile.db';
      final earlier = Store(path: path);
      // As earlier builds created it: 512 MiB for files alone.
      earlier.db.execute('''
      DROP TRIGGER blob_quota;
      CREATE TRIGGER blob_quota BEFORE INSERT ON blobs
      WHEN NOT EXISTS(SELECT 1 FROM blobs WHERE id=NEW.id)
        AND (SELECT bytes FROM blob_usage WHERE id=1)+length(NEW.bytes)>536870912
      BEGIN SELECT RAISE(ABORT, 'Blob storage limit is 512 MiB'); END;
    ''');
      earlier.close();
      final store = Store(path: path);
      addTearDown(store.close);
      final chunk = List<int>.filled(1000, 1);
      store.set('storageLimit', 999);
      expect(
        () => store.db.execute('INSERT INTO blobs VALUES (?,?)', [
          blobHash(chunk),
          chunk,
        ]),
        throwsA(isA<Exception>()),
      );
    },
  );
}
