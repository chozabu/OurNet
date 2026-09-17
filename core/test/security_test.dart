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
    'held objects still reject new forged evidence and forged certificates',
    () async {
      final a = Node(await LocalIdentity.create(), Store()),
          c = Node(await LocalIdentity.create(), Store());
      addTearDown(() async {
        await a.close();
        await c.close();
      });
      await a.addContact(c.identity.certificate);
      await c.addContact(a.identity.certificate);
      await a.publish('post', {'text': 'shared'}, audience: [c.person]);
      await syncPair(a, c);
      expect(c.store.count, 1);
      // Stored records skip re-verification; a new record is still checked.
      final page = await a.offer(c.identity.device, {
        ...c.inventory(),
        'have': <String, dynamic>{},
      });
      final item = page.single;
      final handoff = Json.from(item['evidence'].first);
      final forged = {
        ...handoff,
        'data': {...handoff['data'], 'created': 2},
      };
      await expectLater(
        c.receive(a.identity.device, [
          {
            'object': item['object'],
            'evidence': [...item['evidence'], forged],
          },
        ]),
        throwsStateError,
      );
      // A verified certificate does not validate one with another signature.
      final certificate = a.identity.certificate;
      expect(await certificate.valid(), isTrue);
      final other = await LocalIdentity.create();
      expect(
        await DeviceCertificate(
          certificate.data,
          other.certificate.signature,
        ).valid(),
        isFalse,
      );
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
  test('a person cannot revoke another person\'s device', () async {
    final a = Node(await LocalIdentity.create(), Store()),
        bad = Node(await LocalIdentity.create(), Store()),
        c = Node(await LocalIdentity.create(), Store());
    addTearDown(() async {
      await a.close();
      await bad.close();
      await c.close();
    });
    for (final x in [a, bad, c]) {
      for (final y in [a, bad, c]) {
        if (x != y) await x.addContact(y.identity.certificate);
      }
    }
    final proof = <String, dynamic>{
      'domain': 'ournet/revoke/2',
      'person': bad.person,
      'device': a.identity.device,
    };
    await bad.publish('revoke', {
      'proof': proof,
      'signature': await sign(proof, bad.identity.root!),
      'certificate': a.identity.certificate.toJson(),
    }, space: '_identity');
    await syncPair(bad, c);
    expect(c.revoked, isNot(contains(a.identity.device)));
    expect(c.allowedPeer(a.identity.device), isTrue);
    // The owner's own revocation still applies, for peers holding the
    // certificate and for those learning it from the revocation itself.
    final second = await LocalIdentity.create(root: a.identity.root);
    await a.addContact(second.certificate);
    expect(c.contacts, isNot(contains(second.device)));
    await a.revoke(second.device);
    await syncPair(a, c);
    expect(c.revoked, contains(second.device));
  });

  test('a collaborator cannot publish a room over an owner\'s note', () async {
    final a = Node(await LocalIdentity.create(), Store()),
        bad = Node(await LocalIdentity.create(), Store());
    addTearDown(() async {
      await a.close();
      await bad.close();
    });
    await a.addContact(bad.identity.certificate);
    await bad.addContact(a.identity.certificate);
    final alice = Notes(a);
    var note = await alice.create(text: 'Alice text');
    await alice.changeMembers(note.id, [bad.person]);
    await syncPair(a, bad);
    final members = [a.person, bad.person]..sort();
    // Backdated so it is read before the owner's own record.
    final forger = Node(bad.identity, bad.store, clock: () => 1);
    await forger.publish('room', {
      'room': note.id,
      'note': true,
      'owner': bad.person,
      'name': 'taken',
      'members': members,
      'epoch': 'forged',
      'archived': true,
    }, space: note.id, audience: members);
    await syncPair(bad, a);
    note = (await Notes(a).get(note.id))!;
    expect(note.room.data['owner'], a.person);
    expect(note.text, 'Alice text');
    expect((await Notes(a).list()).length, 1);
  });

  test('an order key that blocks insertion is refused and never hangs', () {
    expect(validContent('note_op', {
      'epoch': 'e',
      'field': 'check:one:order',
      'value': 'A0',
      'parents': <String>[],
      'clock': 1,
    }), isFalse);
    expect(orderBetween(null, '0').endsWith('0'), isFalse);
    expect(orderBetween('A', 'A00').compareTo('A') > 0, isTrue);
  });
}
