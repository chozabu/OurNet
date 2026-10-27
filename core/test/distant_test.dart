import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';
import 'enrolment_test.dart' show befriend;

/// Messages to someone who is not a friend travel through the friends in
/// between, unread by them, and are answered the same way.
void main() {
  late Node alice, bob, carol, dave;

  setUp(() async {
    alice = Node(await LocalIdentity.create(), Store());
    bob = Node(await LocalIdentity.create(), Store());
    carol = Node(await LocalIdentity.create(), Store());
    dave = Node(await LocalIdentity.create(), Store());
    // alice - bob - carol - dave
    await befriend(alice, bob);
    await befriend(bob, carol);
    await befriend(carol, dave);
    for (final n in [alice, bob, carol, dave]) {
      await n.connections.publish();
    }
    await spread(alice, bob, carol, dave);
  });

  tearDown(() async {
    for (final n in [alice, bob, carol, dave]) {
      await n.close();
    }
  });

  Future<String?> text(Node n, String id) async =>
      (await n.content(n.store.get(id)!))?['text'] as String?;

  test('a message travels the chain, is a request, and is answered', () async {
    expect(alice.distant.isDistant(dave.person), isTrue);
    expect(alice.distant.isDistant(bob.person), isFalse);
    final sent = await alice.distant.send(dave.person, {
      'text': 'Hello Dave',
      'title': 'About the allotment',
    });
    expect(sent.data['via'], unorderedEquals([bob.person, carol.person]));
    await spread(alice, bob, carol, dave);
    // The people between hold it without reading it.
    expect(carol.store.get(sent.id), isNotNull);
    expect(await carol.content(carol.store.get(sent.id)!), isNull);
    expect(await text(dave, sent.id), 'Hello Dave');
    expect(
      (await dave.content(dave.store.get(sent.id)!))?['title'],
      'About the allotment',
    );

    // A request until Dave writes back.
    var peers = dave.distant.conversations();
    expect(peers.single.person, alice.person);
    expect(peers.single.accepted, isFalse);
    expect(alice.distant.conversations().single.accepted, isTrue);

    final reply = await dave.distant.send(alice.person, {'text': 'Hi Alice'});
    expect(reply.data['via'], unorderedEquals([bob.person, carol.person]));
    expect(dave.distant.conversations().single.accepted, isTrue);
    await spread(alice, bob, carol, dave);
    expect(await text(alice, reply.id), 'Hi Alice');
    // Nobody was admitted.
    expect(alice.connections.isFriend(dave.person), isFalse);
    expect(dave.connections.isFriend(alice.person), isFalse);
    // Dave's receipt came back to Alice through the carriers.
    expect(
      alice.store
          .evidence(sent.id)
          .any(
            (e) =>
                e.data['domain'] == 'ournet/receipt/2' &&
                e.certificate.person == dave.person,
          ),
      isTrue,
    );
  });

  test('a sender waits for an answer after a few messages', () async {
    for (var i = 0; i < DistantMessages.maxUnanswered; i++) {
      await alice.distant.send(dave.person, {'text': 'Message $i'});
    }
    expect(alice.distant.remaining(dave.person), 0);
    await expectLater(
      alice.distant.send(dave.person, {'text': 'One more'}),
      throwsStateError,
    );
    await spread(alice, bob, carol, dave);
    await dave.distant.send(alice.person, {'text': 'Yes?'});
    await spread(alice, bob, carol, dave);
    expect(alice.distant.remaining(dave.person), isNull);
    await alice.distant.send(dave.person, {'text': 'One more'});
  });

  test('ignoring a request hides it until they write again', () async {
    await alice.distant.send(dave.person, {'text': 'Hello'});
    await spread(alice, bob, carol, dave);
    dave.distant.ignore(alice.person);
    expect(dave.distant.conversations(), isEmpty);
    await alice.distant.send(dave.person, {'text': 'Hello again'});
    await spread(alice, bob, carol, dave);
    expect(dave.distant.conversations().single.person, alice.person);
  });

  test('blocked senders are dropped, friends are not distant', () async {
    await dave.setContactState(alice.person, ContactState.blocked);
    final sent = await alice.distant.send(dave.person, {'text': 'Hello'});
    await spread(alice, bob, carol, dave);
    expect(dave.store.get(sent.id), isNull);
    expect(dave.distant.conversations(), isEmpty);
    await expectLater(
      alice.distant.send(bob.person, {'text': 'Hi'}),
      throwsStateError,
    );
  });

  test('reactions and read marks to someone distant', () async {
    final sent = await alice.distant.send(dave.person, {'text': 'Hello'});
    await spread(alice, bob, carol, dave);
    await dave.markRead(sent.id);
    await MessageUpdates(dave).react(dave.store.get(sent.id)!, '👍');
    await spread(alice, bob, carol, dave);
    final updates = MessageUpdates(alice);
    await updates.catchUp();
    expect(updates.reactions(sent), {dave.person: '👍'});
  });

  test('a carrier takes only so much a day from a non-friend', () async {
    final devices = await alice.distant.devicesOf(dave.person);
    var offered = 0;
    for (var i = 0; i <= DistantMessages.carriedPerDay; i++) {
      final o = await alice.publish(
        'message',
        {'text': '$i'},
        space: '_messages',
        audience: [dave.person],
        via: [bob.person, carol.person],
        recipients: devices,
      );
      // Carol is not Alice's friend; Bob is.
      if (carol.distant.mayCarry(o)) offered++;
      expect(bob.distant.mayCarry(o), isTrue);
    }
    expect(offered, DistantMessages.carriedPerDay);
  });
}

Future<void> spread(Node alice, Node bob, Node carol, Node dave) async {
  for (var i = 0; i < 3; i++) {
    await syncPair(alice, bob);
    await syncPair(bob, carol);
    await syncPair(carol, dave);
  }
}
