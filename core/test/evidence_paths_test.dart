import 'dart:io';

import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';

/// Handoff evidence is kept per path: each device holds the chain that brought
/// an object to it and the handoffs it made itself, so how far an object
/// travels is bounded by path depth rather than by how many devices it reaches,
/// and no holder sees the whole delivery tree.
Future<Node> node({LocalIdentity? identity}) async =>
    Node(identity ?? await LocalIdentity.create(), Store());

Future<void> friend(Node a, Node b) async {
  await a.addContact(b.identity.certificate);
  await b.addContact(a.identity.certificate);
}

/// Devices whose signatures [holder] has recorded for [object].
Set<String> signers(Node holder, SignedObject object) => {
  for (final e in holder.store.evidence(object.id)) e.certificate.device,
};

void main() {
  test(
    'a forum post reaches every subscriber, past the old 63 delivery cap',
    () async {
      final author = await node();
      final readers = [for (var i = 0; i < 70; i++) await node()];
      addTearDown(() async {
        await author.close();
        for (final r in readers) {
          await r.close();
        }
      });
      for (final r in readers) {
        await friend(author, r);
      }
      final post = await author.publish('post', {'text': 'to everyone'});
      for (final r in readers) {
        await syncPair(author, r);
      }
      expect(
        [for (final r in readers) r.store.get(post.id) != null],
        [for (final _ in readers) true],
      );
      // A reader holds its own handoff and receipt, not the other 69.
      for (final r in readers) {
        expect(r.store.evidence(post.id), hasLength(2));
      }
      // The author keeps a record of every delivery it made itself.
      expect(author.store.evidence(post.id), hasLength(140));
      for (final r in readers) {
        expect(await syncPair(author, r), 0);
      }
    },
  );

  test('a revocation reaches a direct friend after a busy hub', () async {
    final owner = await node();
    final phone = await node(
      identity: await LocalIdentity.create(
        root: owner.identity.root,
        label: 'Phone',
      ),
    );
    final hub = await node(), lastFriend = await node();
    final hubFriends = [for (var i = 0; i < 70; i++) await node()];
    addTearDown(() async {
      for (final n in [owner, phone, hub, lastFriend, ...hubFriends]) {
        await n.close();
      }
    });
    await friend(owner, phone);
    await friend(owner, hub);
    await friend(hub, lastFriend);
    await friend(owner, lastFriend);
    for (final f in hubFriends) {
      await friend(hub, f);
    }
    await owner.revoke(phone.identity.device);
    await syncPair(owner, hub);
    // The revocation spreads to the hub's other friends first.
    for (final f in hubFriends) {
      await syncPair(hub, f);
    }
    await syncPair(hub, lastFriend);
    expect(lastFriend.revoked, contains(phone.identity.device));
    expect(
      hubFriends.where((f) => !f.revoked.contains(phone.identity.device)),
      isEmpty,
    );
  });

  test(
    'a holder sees its own path and deliveries, not other branches',
    () async {
      final a = await node(),
          b = await node(),
          c = await node(),
          d = await node();
      addTearDown(() async {
        for (final n in [a, b, c, d]) {
          await n.close();
        }
      });
      await friend(a, b);
      await friend(a, c);
      await friend(b, d);
      // b and c are friends too, and both hold the post: still neither learns
      // how the other's copy travelled.
      await friend(b, c);
      final post = await a.publish('post', {'text': 'branching'});
      await syncPair(a, b);
      await syncPair(a, c);
      await syncPair(b, d);
      for (var i = 0; i < 2; i++) {
        await syncPair(a, b);
        await syncPair(a, c);
        await syncPair(b, d);
        await syncPair(b, c);
      }
      final ad = a.identity.device, bd = b.identity.device;
      final cd = c.identity.device, dd = d.identity.device;
      expect(signers(a, post), {ad, bd, cd});
      expect(signers(b, post), {ad, bd, dd});
      expect(signers(c, post), {ad, cd});
      expect(signers(d, post), {ad, bd, dd});
      // d holds the whole chain back to the author, which is what proves it.
      expect(d.store.evidence(post.id), hasLength(4));
      for (final (x, y) in [(a, b), (a, c), (b, d), (b, c)]) {
        expect(await syncPair(x, y), 0);
      }
    },
  );

  test('the author learns delivery through a carrier', () async {
    final a = await node(), b = await node(), c = await node();
    addTearDown(() async {
      for (final n in [a, b, c]) {
        await n.close();
      }
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
    await syncPair(b, c);
    await syncPair(b, c);
    await syncPair(a, b);
    expect(
      a.store
          .evidence(o.id)
          .where(
            (e) =>
                e.data['domain'] == 'ournet/receipt/2' &&
                e.certificate.device == c.identity.device,
          ),
      isNotEmpty,
    );
    expect(await syncPair(a, b), 0);
    expect(await syncPair(b, c), 0);
  });

  test("the author's other device learns delivery it handed on", () async {
    final phone = await node();
    final laptop = await node(
      identity: await LocalIdentity.create(
        root: phone.identity.root,
        label: 'Laptop',
      ),
    );
    final recipient = await node();
    addTearDown(() async {
      for (final n in [phone, laptop, recipient]) {
        await n.close();
      }
    });
    await friend(phone, laptop);
    await friend(laptop, recipient);
    await friend(phone, recipient);
    final o = await phone.publish(
      'message',
      {'text': 'sent from the phone'},
      audience: [recipient.person],
    );
    await syncPair(phone, laptop);
    await syncPair(laptop, recipient);
    await syncPair(laptop, recipient);
    await syncPair(phone, laptop);
    expect(signers(phone, o), contains(recipient.identity.device));
    expect(await syncPair(phone, laptop), 0);
  });

  test('a group member does not learn when other members received', () async {
    final author = await node(), m1 = await node(), m2 = await node();
    addTearDown(() async {
      for (final n in [author, m1, m2]) {
        await n.close();
      }
    });
    await friend(author, m1);
    await friend(author, m2);
    await friend(m1, m2);
    final o = await author.publish(
      'message',
      {'text': 'to both'},
      audience: [m1.person, m2.person],
    );
    await syncPair(author, m1);
    await syncPair(author, m2);
    await syncPair(m1, m2);
    await syncPair(author, m1);
    await syncPair(m1, m2);
    // Each member sees the author's handoff to it and its own receipt.
    expect(signers(m1, o), {author.identity.device, m1.identity.device});
    expect(signers(m2, o), {author.identity.device, m2.identity.device});
    // The author sees both deliveries.
    expect(signers(author, o), {
      author.identity.device,
      m1.identity.device,
      m2.identity.device,
    });
    expect(await syncPair(m1, m2), 0);
  });

  test('a profile from before the evidence index is indexed on open', () async {
    final directory = await Directory.systemTemp.createTemp('ournet-paths-');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/profile.db';
    final a = await node(),
        b = Node(await LocalIdentity.create(), Store(path: path));
    await friend(a, b);
    final post = await a.publish('post', {'text': 'indexed later'});
    await syncPair(a, b);
    final identity = b.identity;
    await b.close();
    await a.close();
    // As an earlier build left it: evidence rows, no index.
    final earlier = Store(path: path);
    earlier.db.execute('''
      DROP TRIGGER evidence_route_added; DROP TRIGGER evidence_route_removed;
      DROP TABLE evidence_routes;
    ''');
    earlier.close();
    final reopened = Node(identity, Store(path: path));
    addTearDown(reopened.close);
    final routes = reopened.store.evidenceRoutes(post.id).toList();
    expect(routes, hasLength(2));
    final receipt = routes.singleWhere((r) => r.receipt);
    final handoff = routes.singleWhere((r) => !r.receipt);
    expect(receipt.signer, identity.device);
    expect(receipt.target, handoff.id);
    expect(handoff.signer, a.identity.device);
    expect(handoff.target, identity.device);
  });

  test('an object is handed on along the shortest chain it came by', () async {
    final a = await node(), b = await node(), c = await node();
    final d = await node(), e = await node();
    addTearDown(() async {
      for (final n in [a, b, c, d, e]) {
        await n.close();
      }
    });
    await friend(a, b);
    await friend(b, c);
    await friend(c, d);
    await friend(a, d);
    await friend(d, e);
    final post = await a.publish('post', {'text': 'two ways in'});
    await syncPair(a, b);
    await syncPair(b, c);
    // d lacks the post when c and a each offer it, so it takes both.
    final fromC = await c.offer(
      d.identity.device,
      d.inventoryAfter(peerDevice: c.identity.device),
    );
    final fromA = await a.offer(
      d.identity.device,
      d.inventoryAfter(peerDevice: a.identity.device),
    );
    await d.receive(c.identity.device, fromC);
    await d.receive(a.identity.device, fromA);
    await syncPair(d, e);
    // a -> d -> e: two handoffs and two receipts, not the six of a -> b -> c.
    expect(e.store.evidence(post.id), hasLength(4));
    expect(signers(e, post), {
      a.identity.device,
      d.identity.device,
      e.identity.device,
    });
  });

  test('a path too long for the receiver is not offered', () async {
    // Each hop adds a handoff and a receipt: 64 devices after the author make
    // a path of 128 records, the most one item may carry.
    final chain = [for (var i = 0; i < 66; i++) await node()];
    addTearDown(() async {
      for (final n in chain) {
        await n.close();
      }
    });
    for (var i = 0; i + 1 < chain.length; i++) {
      await friend(chain[i], chain[i + 1]);
    }
    final post = await chain.first.publish('post', {'text': 'a long way'});
    for (var i = 0; i + 2 < chain.length; i++) {
      await syncPair(chain[i], chain[i + 1]);
    }
    final last = chain[chain.length - 2], next = chain.last;
    expect(last.store.evidence(post.id), hasLength(Node.maxEvidence));
    expect(
      await last.offer(
        next.identity.device,
        next.inventoryAfter(peerDevice: last.identity.device),
      ),
      isEmpty,
    );
    expect(await syncPair(last, next), 0);
    // 66 nodes and about 64 syncs: near 30 s alone, longer beside other suites.
  }, timeout: const Timeout(Duration(seconds: 90)));
}
