import 'dart:async';
import 'dart:io';

import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'disk publications yield, verify and decrypt; close drains accepted work',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ournet-publish-',
      );
      final path = '${directory.path}/test.db';
      final identity = await LocalIdentity.create();
      final node = Node(identity, Store(path: path));
      try {
        var timerRan = false;
        Timer.run(() => timerRan = true);
        final object = await node.publish(
          'post',
          {'text': 'Private photo caption'},
          audience: [node.person],
        );
        expect(timerRan, isTrue);
        expect(await object.valid(), isTrue);
        expect((await node.content(object))!['text'], 'Private photo caption');
        expect(
          object.data['payload'].toString(),
          isNot(contains('Private photo caption')),
        );
        // A rejected job must not poison the serial queue.
        await expectLater(node.publish('post', {'text': 42}), throwsStateError);
        final pending = node.publish('post', {'text': 'Saved before close'});
        final closing = node.close();
        await expectLater(
          node.publish('post', {'text': 'Too late'}),
          throwsStateError,
        );
        final saved = await pending;
        await closing;
        final reopened = Store(path: path);
        expect(reopened.get(saved.id), isNotNull);
        reopened.close();
      } finally {
        await node.close();
        await directory.delete(recursive: true);
      }
    },
  );

  test('publication queue has a fixed admission bound', () async {
    final directory = await Directory.systemTemp.createTemp(
      'ournet-publish-bound-',
    );
    final node = Node(
      await LocalIdentity.create(),
      Store(path: '${directory.path}/test.db'),
    );
    addTearDown(() async {
      await node.close();
      await directory.delete(recursive: true);
    });
    final pending = [
      for (var i = 0; i < 32; i++) node.publish('post', {'text': '$i'}),
    ];
    await expectLater(
      node.publish('post', {'text': 'Overflow'}),
      throwsStateError,
    );
    await Future.wait(pending);
    expect(node.store.count, 32);
    await node.close();
  });

  test(
    'disk profiles reconcile with receipts and then offer nothing',
    () async {
      final directory = await Directory.systemTemp.createTemp('ournet-sync-');
      final owner = await LocalIdentity.create();
      final fresh = await LocalIdentity.create();
      final a = Node(owner, Store(path: '${directory.path}/a.db'));
      final b = Node(
        await fresh.enrol(await owner.authorise(fresh.certificate)),
        Store(path: '${directory.path}/b.db'),
      );
      addTearDown(() async {
        await a.close();
        await b.close();
        await directory.delete(recursive: true);
      });
      await a.addContact(b.identity.certificate);
      await b.addContact(owner.certificate);
      for (var i = 0; i < 40; i++) {
        await a.publish('post', {'text': '$i'}, audience: [a.person]);
      }
      await syncPair(a, b, rounds: 20);
      expect(b.store.count, 40);
      for (final id in b.store.ids()) {
        final domains = b.store.evidence(id).map((e) => e.data['domain']);
        expect(domains, containsAll(['ournet/handoff/2', 'ournet/receipt/2']));
        expect(a.store.evidenceDigest(id), b.store.evidenceDigest(id));
      }
      expect(await a.offer(b.identity.device, b.inventory()), isEmpty);
      expect(await b.offer(a.identity.device, a.inventory()), isEmpty);
    },
  );
}
