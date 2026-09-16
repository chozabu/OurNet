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
  test('evidence digests follow writes and rolled-back batches', () async {
    final node = Node(await LocalIdentity.create(), Store());
    addTearDown(node.close);
    final store = node.store;
    final object = await node.publish('post', {'text': 'digest'});
    Future<Evidence> handoff(String to) => node.makeEvidence({
      'domain': 'ournet/handoff/2',
      'object': object.id,
      'to': to,
      'parents': [],
      'created': 1,
    });
    expect(store.evidenceDigest(object.id), hash(<String>[]));
    final first = await handoff('one'), second = await handoff('two');
    store.putEvidence(second);
    store.putEvidence(first);
    final ids = [first.id, second.id]..sort();
    expect(store.evidenceDigest(object.id), hash(ids));
    expect(store.hasEvidence(object.id, first.id), isTrue);
    final third = await handoff('three');
    expect(
      () => store.batch(() {
        store.putEvidence(third);
        throw StateError('abandoned');
      }),
      throwsStateError,
    );
    expect(store.hasEvidence(object.id, third.id), isFalse);
    expect(store.evidenceDigest(object.id), hash(ids));
  });

  test('peer inventories match per-object sharing rules', () async {
    final a = Node(await LocalIdentity.create(), Store());
    final b = Node(await LocalIdentity.create(), Store());
    final c = Node(await LocalIdentity.create(), Store());
    addTearDown(() async {
      await a.close();
      await b.close();
      await c.close();
    });
    for (final other in [b, c]) {
      await a.addContact(other.identity.certificate);
      await other.addContact(a.identity.certificate);
    }
    Set<String> expected(Node peer) => {
      for (final id in a.store.ids())
        if (a.canOffer(a.store.get(id)!, peer.identity.certificate, {
          a.store.get(id)!.space,
        }))
          id,
    };
    Set<String> offered(Node peer) =>
        (a.inventory(peerDevice: peer.identity.device)['have'] as Json).keys
            .toSet();
    await a.publish('post', {'text': 'public'});
    await a.publish('post', {'text': 'elsewhere'}, space: 'other');
    await a.publish('message', {'text': 'for b'}, audience: [b.person]);
    await a.publish(
      'message',
      {'text': 'via b'},
      audience: [c.person],
      via: [b.person],
    );
    expect(offered(b), expected(b));
    expect(offered(c), expected(c));
    expect(offered(b), hasLength(4));
    expect(offered(c), hasLength(3));
    // Later writes are picked up; rolled-back ones are not.
    final late = await a.publish(
      'location',
      {'lat': '1', 'lng': '1'},
      audience: [b.person],
      expires: 1,
    );
    expect(offered(b), isNot(contains(late.id)));
    final extra = await b.publish('post', {'text': 'rolled back'});
    expect(
      () => a.store.batch(() {
        a.store.put(extra);
        throw StateError('abandoned');
      }),
      throwsStateError,
    );
    expect(offered(b), expected(b));
    expect(offered(b), isNot(contains(extra.id)));
    expect(a.inventory()['have'], hasLength(a.store.count));
  });
}
