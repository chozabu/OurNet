import 'dart:io';
import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'existing blob databases gain accounting without rewriting content',
    () async {
      final directory = await Directory.systemTemp.createTemp('ournet-quota-');
      final path = '${directory.path}/old.db';
      var store = Store(path: path);
      try {
        final bytes = [1, 2, 3];
        final hash = blobHash(bytes);
        store.putBlob(hash, bytes);
        store.db.execute('''
        DROP TRIGGER blob_quota;
        DROP TRIGGER blob_added;
        DROP TRIGGER blob_removed;
        DROP TRIGGER blob_updated;
        DROP TABLE blob_usage;
      ''');
        store.close();
        store = Store(path: path);
        expect(store.blob(hash), bytes);
        expect(
          store.db.select('SELECT bytes FROM blob_usage').single['bytes'],
          3,
        );
        store.putBlob(blobHash([4, 5]), [4, 5]);
        expect(
          store.db.select('SELECT bytes FROM blob_usage').single['bytes'],
          5,
        );
      } finally {
        store.close();
        for (final file in await directory.list().toList()) {
          await file.delete();
        }
        await directory.delete();
      }
    },
  );
  test(
    'blob accounting follows deletes and rolls back with the transaction',
    () {
      final store = Store();
      addTearDown(store.close);
      final bytes = [1, 2, 3];
      final hash = blobHash(bytes);
      int usage() =>
          store.db.select('SELECT bytes FROM blob_usage').single['bytes']
              as int;
      store.putBlob(hash, bytes);
      store.putBlob(hash, bytes);
      expect(usage(), 3);
      store.db.execute('BEGIN');
      store.db.execute('DELETE FROM blobs');
      expect(usage(), 0);
      store.db.execute('ROLLBACK');
      expect(usage(), 3);
      store.db.execute('DELETE FROM blobs');
      expect(usage(), 0);
    },
  );
  test('unchanged settings do not write rows', () {
    final store = Store();
    addTearDown(store.close);
    store.set('lastDestination', 9);
    expect(store.db.updatedRows, 1);
    store.set('lastDestination', 9);
    expect(store.db.updatedRows, 0);
    store.set('lastDestination', 10);
    expect(store.db.updatedRows, 1);
    expect(store.setting('lastDestination'), 10);
    store.set('nullable', null);
    store.set('nullable', null);
    expect(store.db.updatedRows, 0);
  });
}
