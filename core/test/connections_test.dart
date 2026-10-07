import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';
import 'enrolment_test.dart' show befriend;

/// Friend lists travel like names; a chain of friends is found from them,
/// and a request to connect travels along it and is answered the same way.
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
  });

  tearDown(() async {
    for (final n in [alice, bob, carol, dave]) {
      await n.close();
    }
  });

  Future<void> publishAll() async {
    for (final n in [alice, bob, carol, dave]) {
      await n.connections.publish();
    }
  }

  Future<void> spread() async {
    for (var i = 0; i < 3; i++) {
      await syncPair(alice, bob);
      await syncPair(bob, carol);
      await syncPair(carol, dave);
    }
  }

  test('lists publish once, travel on, and give chains', () async {
    expect(await alice.connections.publish(), isNotNull);
    // Nothing changed: nothing more is written.
    expect(await alice.connections.publish(), isNull);
    await publishAll();
    await spread();
    expect(dave.connections.lists[alice.person]?.friends, {bob.person});
    expect(alice.connections.chain(dave.person), [
      alice.person,
      bob.person,
      carol.person,
      dave.person,
    ]);
    expect(alice.connections.chain(bob.person), [alice.person, bob.person]);
    expect(alice.connections.neighbours(carol.person), {
      bob.person,
      dave.person,
    });
    expect(alice.connections.route(carol.person), [bob.person]);
  });

  test('a one-sided claim does not link people who publish lists', () async {
    await publishAll();
    // Carol says she knows Alice; Alice's own list does not agree.
    await carol.publish(Connections.listKind, {
      'friends': [alice.person, bob.person, dave.person],
      'devices': [carol.identity.certificate.toJson()],
    }, space: Connections.listSpace);
    await spread();
    expect(bob.connections.linked(carol.person, alice.person), isFalse);
    expect(bob.connections.chain(dave.person)?.length, 3);
  });

  test('a request travels the chain and the answer connects both', () async {
    await publishAll();
    await spread();
    final sent = await alice.connections.request(dave.person, text: 'Hi!');
    expect(sent.data['via'], unorderedEquals([bob.person, carol.person]));
    expect((await alice.connections.sentTo(dave.person))?.id, sent.id);
    await spread();
    // The people between relay it without reading it.
    expect(await carol.content(carol.store.get(sent.id)!), isNull);
    final asks = await dave.connections.incoming();
    expect(asks.single.from, alice.person);
    expect(asks.single.text, 'Hi!');
    expect(asks.single.via, [bob.person, carol.person]);

    await dave.connections.accept(asks.single);
    expect(dave.connections.isFriend(alice.person), isTrue);
    expect(await dave.connections.incoming(), isEmpty);
    expect(alice.connections.isFriend(dave.person), isFalse);
    await spread();
    expect(alice.connections.isFriend(dave.person), isTrue);
    // Now they sync directly.
    await dave.publish(
      'message',
      {'text': 'Hello Alice'},
      space: 'dm',
      audience: [alice.person],
    );
    expect(await syncPair(alice, dave), greaterThan(0));
  });

  test('an answer to a request nobody sent admits nobody', () async {
    await publishAll();
    await spread();
    // Dave answers a request Alice never wrote, while briefly admitted.
    await befriend(alice, dave);
    final forged = await dave.publish(
      Connections.requestKind,
      {
        'type': 'accept',
        'request': 'nothing',
        'devices': [dave.identity.certificate.toJson()],
      },
      space: Connections.requestSpace,
      audience: [alice.person],
    );
    await syncPair(alice, dave);
    expect(alice.store.get(forged.id), isNotNull);
    await dave.setContactState(alice.person, ContactState.forgotten);
    alice.contacts.removeWhere((_, c) => c.person == dave.person);
    alice.store.removeContacts(dave.person);
    expect(await alice.connections.settle(), 0);
    expect(alice.connections.isFriend(dave.person), isFalse);
  });

  test('a member asks the owner to add a friend', () async {
    // Bob owns a group with Carol; Carol asks to add Dave, whom Bob does not
    // know.
    final group = Everyday(bob);
    final room = await group.createRoom('Friends', [carol.person]);
    await syncPair(bob, carol);
    final carolsRoom = (await Everyday(carol).rooms()).single;
    await expectLater(
      Everyday(bob).askToAdd(room, [dave.person]),
      throwsStateError,
    );
    await Everyday(carol).askToAdd(carolsRoom, [dave.person]);
    await syncPair(bob, carol);
    final asks = await group.addRequests(room);
    expect(asks.single.people, [dave.person]);
    expect(bob.connections.isFriend(dave.person), isFalse);
    await group.admitRequested(asks.single.certificates, asks.single.people);
    final next = await group.changeMembers(room, [
      carol.person,
      dave.person,
    ], shareHistory: false);
    group.closeAddRequest(asks.single.object);
    expect(await group.addRequests(next), isEmpty);
    expect(await group.members(next), contains(dave.person));
    // Carol passes the room on to Dave.
    await syncPair(bob, carol);
    await syncPair(carol, dave);
    expect(
      (await Everyday(dave).rooms()).map((r) => r.data['name']),
      contains('Friends'),
    );
  });
}
