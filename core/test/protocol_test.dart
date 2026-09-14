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
}
