import 'dart:io';
import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'attacker cannot fabricate a direct origin handoff for another author',
    () async {
      final a = Node(await LocalIdentity.create(), Store()),
          bad = Node(await LocalIdentity.create(), Store()),
          c = Node(await LocalIdentity.create(), Store());
      addTearDown(() async {
        await a.close();
        await bad.close();
        await c.close();
      });
      await c.addContact(bad.identity.certificate);
      final o = await a.publish('post', {'text': 'authentic content'});
      final lie = await bad.makeEvidence({
        'domain': 'ournet/handoff/2',
        'object': o.id,
        'to': c.identity.device,
        'parents': [],
        'created': 1,
      });
      await expectLater(
        c.receive(bad.identity.device, [
          {
            'object': o.toJson(),
            'evidence': [lie.toJson()],
          },
        ]),
        throwsStateError,
      );
      expect(c.store.count, 0);
    },
  );
  test(
    'enrolled device has no root and cannot authorise or revoke devices',
    () async {
      final owner = await LocalIdentity.create(),
          fresh = await LocalIdentity.create();
      final paired = await fresh.enrol(
        await owner.authorise(fresh.certificate),
      );
      expect(paired.person, owner.person);
      expect(paired.root, isNull);
      final restored = await LocalIdentity.restore(
        await paired.exportSecrets(),
      );
      expect(restored.root, isNull);
      await expectLater(paired.authorise(fresh.certificate), throwsStateError);
    },
  );
  test(
    'signed objects are immutable and malformed content cannot be published',
    () async {
      final n = Node(await LocalIdentity.create(), Store());
      addTearDown(n.close);
      final o = await n.publish('post', {'text': 'immutable'});
      expect(
        () => o.data['payload']['text'] = 'changed',
        throwsUnsupportedError,
      );
      expect(await o.valid(), isTrue);
      await expectLater(n.publish('post', {'text': 42}), throwsStateError);
      await expectLater(
        n.publish('post', {'text': 'Invalid date'}, expires: 1 << 60),
        throwsStateError,
      );
      await expectLater(
        n.publish('location', {'lat': 'NaN', 'lng': '0'}),
        throwsStateError,
      );
    },
  );
  test('restart preserves objects, subscriptions and evidence', () async {
    final directory = await Directory.systemTemp.createTemp('ournet-test-');
    final path = '${directory.path}/node.db';
    final identity = await LocalIdentity.create();
    var n = Node(identity, Store(path: path));
    final o = await n.publish('post', {'text': 'survives restart'});
    n.subscribe('science', true);
    await n.close();
    n = Node(identity, Store(path: path));
    expect(n.store.get(o.id), isNotNull);
    expect(n.subscriptions, contains('science'));
    await n.close();
    await directory.delete(recursive: true);
  });
  test('direct votes override delegation and cycles are safe', () async {
    final a = Node(await LocalIdentity.create(), Store()),
        b = Node(await LocalIdentity.create(), Store());
    addTearDown(() async {
      await a.close();
      await b.close();
    });
    final post = await a.publish('post', {'text': 'proposal'});
    final delegated = await a.publish('delegate', {'person': b.person});
    final vote = await b.publish('vote', {'object': post.id, 'value': 1});
    expect(
      effectiveVotes(post.id, 'general', [
        delegated,
        vote,
      ]).values.fold(0, (a, b) => a + b),
      2,
    );
    final direct = await a.publish('vote', {'object': post.id, 'value': -1});
    expect(
      effectiveVotes(post.id, 'general', [delegated, vote, direct])[a.person],
      -1,
    );
    final cycle = await b.publish('delegate', {'person': a.person});
    expect(
      effectiveVotes(post.id, 'general', [
        delegated,
        cycle,
      ]).values.every((v) => v == 0),
      isTrue,
    );
  });
  test(
    'inventory omits private object identifiers for unrelated peers',
    () async {
      final a = Node(await LocalIdentity.create(), Store()),
          b = Node(await LocalIdentity.create(), Store()),
          c = Node(await LocalIdentity.create(), Store());
      addTearDown(() async {
        await a.close();
        await b.close();
        await c.close();
      });
      await a.addContact(b.identity.certificate);
      await a.addContact(c.identity.certificate);
      final private = await a.publish(
        'message',
        {'text': 'secret'},
        audience: [b.person],
      );
      expect(
        (a.inventory(peerDevice: c.identity.device)['have'] as Map).containsKey(
          private.id,
        ),
        isFalse,
      );
    },
  );
}
