import 'dart:convert';
import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';

Future<Node> node() async => Node(await LocalIdentity.create(), Store());
Future<void> friend(Node a, Node b) async {
  await a.addContact(b.identity.certificate);
  await b.addContact(a.identity.certificate);
}

void main() {
  test(
    'public objects need no private predecessor and subscriptions filter transfer',
    () async {
      final a = await node(), b = await node(), c = await node();
      addTearDown(() async {
        await a.close();
        await b.close();
        await c.close();
      });
      await friend(a, b);
      await friend(a, c);
      final private = await a.publish(
        'message',
        {'text': 'secret'},
        audience: [b.person],
      );
      final public = await a.publish('post', {'text': 'public'});
      final other = await a.publish('post', {
        'text': 'unsubscribed',
      }, space: 'other');
      await syncPair(a, c);
      expect(c.store.get(public.id), isNotNull);
      expect(c.store.get(private.id), isNull);
      expect(c.store.get(other.id), isNull);
      await syncPair(a, b);
      expect((await b.content(b.store.get(private.id)!))!['text'], 'secret');
    },
  );
  test(
    'encrypted relaying records acknowledged paths and evidence converges',
    () async {
      final a = await node(), b = await node(), c = await node();
      addTearDown(() async {
        await a.close();
        await b.close();
        await c.close();
      });
      await friend(a, b);
      await friend(b, c);
      await a.addContact(c.identity.certificate);
      final o = await a.publish(
        'message',
        {'text': 'through friend'},
        audience: [c.person],
        via: [b.person],
      );
      await syncPair(a, b);
      expect(await b.content(b.store.get(o.id)!), isNull);
      await syncPair(b, c);
      expect((await c.content(c.store.get(o.id)!))!['text'], 'through friend');
      await syncPair(a, b);
      await syncPair(b, c);
      await syncPair(a, b);
      expect(a.store.evidence(o.id).length, greaterThanOrEqualTo(4));
      expect(await syncPair(a, b), 0);
    },
  );
  test(
    'forged author, false receipt and oversized page are rejected',
    () async {
      final a = await node(), b = await node();
      addTearDown(() async {
        await a.close();
        await b.close();
      });
      await friend(a, b);
      await a.publish('post', {'text': 'original'});
      final page = await a.offer(b.identity.device, b.inventory());
      final tampered = jsonDecode(jsonEncode(page)) as List;
      tampered.first['object']['data']['payload']['text'] = 'forged';
      await expectLater(
        b.receive(a.identity.device, tampered),
        throwsStateError,
      );
      expect(b.store.count, 0);
      await expectLater(
        b.receive(a.identity.device, List.filled(33, {})),
        throwsStateError,
      );
      await b.receive(a.identity.device, page);
      expect(b.store.count, 1);
    },
  );
  test(
    'device identities are independent, vault restores and revocation blocks device',
    () async {
      final a = await node(), b = await node();
      final second = Node(
        await LocalIdentity.create(root: a.identity.root, label: 'Phone'),
        Store(),
      );
      addTearDown(() async {
        await a.close();
        await b.close();
        await second.close();
      });
      expect(second.person, a.person);
      expect(second.identity.device, isNot(a.identity.device));
      final restored = await LocalIdentity.restore(
        await second.identity.exportSecrets(),
      );
      expect(restored.device, second.identity.device);
      await friend(a, b);
      await friend(a, second);
      await friend(b, second);
      await a.revoke(second.identity.device);
      await syncPair(a, b);
      expect(b.allowedPeer(second.identity.device), isFalse);
    },
  );
  test(
    'expired location is not offered and blocked person is hidden',
    () async {
      final a = await node(), b = await node();
      addTearDown(() async {
        await a.close();
        await b.close();
      });
      await friend(a, b);
      await a.publish(
        'location',
        {'lat': '51', 'lng': '0'},
        audience: [b.person],
        expires: 1,
      );
      await syncPair(a, b);
      expect(b.store.count, 0);
      final post = await a.publish('post', {'text': 'hello'});
      await syncPair(a, b);
      b.block(a.person, true);
      expect(b.visible(post), isFalse);
    },
  );

  test('evidence relayed by a revoked device does not block sync', () async {
    final laptop = await node(), friendNode = await node();
    final phone = Node(
      await LocalIdentity.create(root: laptop.identity.root, label: 'Phone'),
      Store(),
    );
    addTearDown(() async {
      await laptop.close();
      await friendNode.close();
      await phone.close();
    });
    await friend(laptop, phone);
    await friend(laptop, friendNode);
    await friend(phone, friendNode);
    final post = await friendNode.publish('post', {'text': 'via the phone'});
    await syncPair(friendNode, phone);
    await syncPair(phone, laptop);
    final relayed = laptop.store.evidence(post.id);
    expect(
      relayed.where((e) => e.certificate.device == phone.identity.device),
      isNotEmpty,
    );
    await laptop.revoke(phone.identity.device);
    // The revoked device's evidence, and the receipt that depends on it, go.
    expect(
      laptop.store
          .evidence(post.id)
          .where((e) => e.certificate.device == phone.identity.device),
      isEmpty,
    );
    await syncPair(laptop, friendNode);
    expect(friendNode.revoked, contains(phone.identity.device));
    // Converged: neither side has anything left to offer the other.
    expect(
      await laptop.offer(
        friendNode.identity.device,
        friendNode.inventory(peerDevice: laptop.identity.device),
      ),
      isEmpty,
    );
    expect(
      await friendNode.offer(
        laptop.identity.device,
        laptop.inventory(peerDevice: friendNode.identity.device),
      ),
      isEmpty,
    );
    // A peer that has not yet applied the revocation still sends that
    // evidence; it is ignored rather than rejecting the page.
    expect(
      await laptop.receive(friendNode.identity.device, [
        {
          'object': post.toJson(),
          'evidence': [for (final e in relayed) e.toJson()],
        },
      ]),
      0,
    );
    // Profiles that revoked before withdrawal existed are cleaned on open.
    laptop.store.batch(() => relayed.forEach(laptop.store.putEvidence));
    laptop.store.set('revokedWithdrawn', null);
    final reopened = Node(laptop.identity, laptop.store);
    expect(
      reopened.store
          .evidence(post.id)
          .where((e) => e.certificate.device == phone.identity.device),
      isEmpty,
    );
  });

  test('a rejected item does not block the rest of its page', () async {
    final a = await node(), b = await node();
    addTearDown(() async {
      await a.close();
      await b.close();
    });
    await friend(a, b);
    await a.publish('post', {'text': 'first'});
    await a.publish('post', {'text': 'second'});
    final page = await a.offer(b.identity.device, b.inventory());
    expect(page, hasLength(2));
    final broken = Json.from(page.first)
      ..['object'] = {
        ...page.first['object'],
        'signature': page.last['object']['signature'],
      };
    expect(await b.receive(a.identity.device, [broken, page.last]), isPositive);
    expect(b.store.count, 1);
    // With nothing accepted the rejection is still reported.
    await expectLater(b.receive(a.identity.device, [broken]), throwsStateError);
  });

  test('offered pages fit the receiver\'s encoded page limit', () async {
    final a = Node(
      await LocalIdentity.create(),
      Store(),
      clock: () => 1700000000000,
    );
    final b = await node();
    addTearDown(() async {
      await a.close();
      await b.close();
    });
    await friend(a, b);
    int itemsSize(List<Json> page) =>
        page.fold(0, (n, item) => n + bytes(item).length);
    // Measure one item's fixed overhead, then fill item sizes to exactly the
    // limit, where the list's brackets and commas would exceed it.
    await a.publish('post', {'text': 'x' * 1000});
    final overhead =
        itemsSize(await a.offer(b.identity.device, b.inventory())) - 1000;
    var total = overhead + 1000;
    while (Node.maxPageBytes - total > 2 * (60000 + overhead)) {
      await a.publish('post', {'text': 'x' * 60000});
      total += 60000 + overhead;
    }
    await a.publish('post', {
      'text': 'x' * (Node.maxPageBytes - total - overhead),
    });
    final all = await a.offer(b.identity.device, {
      ...b.inventory(),
      'subscriptions': ['general'],
    });
    expect(bytes(all).length, lessThanOrEqualTo(Node.maxPageBytes));
    await b.receive(a.identity.device, all);
    expect(b.store.count, all.length);
    // The remaining item proves the items alone summed to exactly the limit.
    final rest = await a.offer(b.identity.device, {
      ...b.inventory(),
      'have': {for (final id in b.store.ids()) id: a.store.evidenceDigest(id)},
    });
    expect(rest, hasLength(1));
    expect(itemsSize(all) + itemsSize(rest), Node.maxPageBytes);
  });
}
