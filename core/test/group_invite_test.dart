import 'package:test/test.dart';
import 'package:ournet_core/ournet_core.dart';

/// Henry owns a group, Alex is in it, and Vero is Alex's friend but not
/// Henry's: the case members adding people is for.
void main() {
  late Node henry, alex, vero, outsider;

  Future<Node> node() async {
    final n = Node(await LocalIdentity.create(), Store());
    addTearDown(n.close);
    return n;
  }

  Future<void> befriend(Node x, Node y) async {
    await x.addContact(y.identity.certificate);
    await y.addContact(x.identity.certificate);
  }

  setUp(() async {
    henry = await node();
    alex = await node();
    vero = await node();
    outsider = await node();
    await befriend(henry, alex);
    await befriend(alex, vero);
    await befriend(alex, outsider);
  });

  Future<EverydayItem> roomOf(Node n) async =>
      (await Everyday(n).rooms()).singleWhere((r) => r.data['note'] != true);

  Future<List<String>> chat(Node n) async => [
    for (final i in await Everyday(n).items(await roomOf(n)))
      i.data['text'] as String,
  ]..sort();

  Future<List<String>> forum(Node n) async {
    final f = RoomForum(n, await roomOf(n));
    await f.load();
    return [for (final p in f.topics) p.data['text'] as String];
  }

  Future<SignedObject> post(Node n, String text) async {
    final room = await roomOf(n);
    return n.publish(
      'room_post',
      {'text': text, 'title': text},
      space: room.object.space,
      audience: await Everyday(n).members(room),
    );
  }

  test('a member adds a friend, who reads the group without its owner '
      'online', () async {
    await Everyday(
      henry,
    ).createRoom('Windsworth', [alex.person], membersInvite: true);
    await Everyday(
      henry,
    ).write({'type': 'note', 'text': 'Hello'}, room: await roomOf(henry));
    await post(henry, 'Walk on Sunday');
    final note = await Notes(
      henry,
    ).create(group: (await roomOf(henry)).object.space, title: 'Packing');
    await syncPair(henry, alex);

    final room = await roomOf(alex);
    expect(Everyday(alex).canInvite(room), isTrue);
    await Everyday(alex).invite(room, [vero.person]);
    // Henry stays offline: Vero hears only from Alex.
    await syncPair(alex, vero);

    final joined = await roomOf(vero);
    expect(
      await Everyday(vero).members(joined),
      {henry.person, alex.person, vero.person}.toList()..sort(),
    );
    expect(await chat(vero), ['Hello']);
    expect(await forum(vero), ['Walk on Sunday']);
    expect((await Notes(vero).get(note.id))?.title, 'Packing');
    // The originals, with their authors: nothing was copied for her.
    final hello = (await Everyday(vero).items(joined)).single;
    expect(hello.object.author, henry.person);
    expect(hello.data['history'], isFalse);

    // What she writes reaches Henry through Alex.
    await Everyday(
      vero,
    ).write({'type': 'note', 'text': 'Hi all'}, room: joined);
    await syncPair(alex, vero);
    await syncPair(henry, alex);
    expect(await chat(henry), ['Hello', 'Hi all']);
    expect(await Everyday(henry).members(await roomOf(henry)), hasLength(3));

    // Henry's next record names her, for builds without invites; once.
    expect(await Everyday(henry).settleInvites(), 1);
    expect(await Everyday(henry).settleInvites(), 0);
    await syncPair(henry, alex);
    final record = await roomOf(alex);
    expect(record.object.author, henry.person);
    expect(record.added, isEmpty);
    expect(record.data['members'], contains(vero.person));

    // Someone outside the group gets nothing from it.
    await syncPair(alex, outsider);
    expect(await Everyday(outsider).rooms(), isEmpty);
    expect(
      outsider.store.allOf(kinds: Everyday.kinds, space: joined.object.space),
      isEmpty,
    );
  });

  test('only the owner adds people unless members may', () async {
    await Everyday(henry).createRoom('Windsworth', [alex.person]);
    await syncPair(henry, alex);
    final room = await roomOf(alex);
    expect(Everyday(alex).canInvite(room), isFalse);
    await expectLater(
      Everyday(alex).invite(room, [vero.person]),
      throwsStateError,
    );
    expect(Everyday(henry).canInvite(await roomOf(henry)), isTrue);
  });

  test('an invite from a member counts only once members may add', () async {
    await Everyday(henry).createRoom('Windsworth', [alex.person]);
    await syncPair(henry, alex);
    final room = await roomOf(alex);
    // Written as a build that ignored the owner's choice would.
    await alex.publish(
      'room_invite',
      {
        'epoch': Everyday(alex).epoch(room),
        'people': [vero.person],
        'certificates': [vero.identity.certificate.toJson()],
        'groupKey': room.data['groupKey'],
      },
      space: room.object.space,
      audience: [henry.person, alex.person, vero.person],
    );
    await syncPair(henry, alex);
    expect(await Everyday(henry).members(await roomOf(henry)), hasLength(2));
  });

  test('a group from before keys lets members add people, with its '
      'history', () async {
    // A group as earlier builds made it: no key, owner adds people.
    final members = [henry.person, alex.person]..sort();
    final data = {
      'room': 'room2:${henry.person}:${randomId()}',
      'owner': henry.person,
      'name': 'Windsworth',
      'members': members,
      'generation': 0,
      'epoch': randomId(),
      'certificates': [
        henry.identity.certificate.toJson(),
        alex.identity.certificate.toJson(),
      ],
    };
    await henry.publish(
      'room',
      data,
      space: data['room'] as String,
      audience: members,
    );
    await Everyday(
      henry,
    ).write({'type': 'note', 'text': 'Before keys'}, room: await roomOf(henry));
    await post(henry, 'Old topic');
    await syncPair(henry, alex);
    expect(Everyday(alex).canInvite(await roomOf(alex)), isFalse);

    final opened = await Everyday(henry).letMembersInvite(await roomOf(henry));
    expect(opened.data['invite'], 'members');
    expect(opened.data['groupKey'], isNotNull);
    await syncPair(henry, alex);
    // Nothing doubles for those already in it.
    expect(await chat(alex), ['Before keys']);
    expect(await forum(alex), ['Old topic']);

    await Everyday(alex).invite(await roomOf(alex), [vero.person]);
    await syncPair(alex, vero);
    expect(await chat(vero), ['Before keys']);
    expect(await forum(vero), ['Old topic']);
  });

  test('a device that does not say which keys it holds is not offered '
      'what it could not open', () async {
    await Everyday(
      henry,
    ).createRoom('Windsworth', [alex.person], membersInvite: true);
    await Everyday(
      henry,
    ).write({'type': 'note', 'text': 'Hello'}, room: await roomOf(henry));
    await syncPair(henry, alex);
    await Everyday(alex).invite(await roomOf(alex), [vero.person]);

    // As a build without group keys asks: only what is addressed to it.
    final inventory = vero.inventoryAfter(peerDevice: alex.identity.device)
      ..remove('groupKeys');
    final offered = await alex.offer(vero.identity.device, inventory);
    expect(
      [for (final item in offered) SignedObject.fromJson(item['object']).kind],
      ['room_invite'],
    );
  });

  test('removing someone gives the group a new key, which people added '
      'later open the history with', () async {
    await befriend(henry, outsider);
    await Everyday(henry).createRoom('Windsworth', [
      alex.person,
      outsider.person,
    ], membersInvite: true);
    await Everyday(
      henry,
    ).write({'type': 'note', 'text': 'Hello'}, room: await roomOf(henry));
    await syncPair(henry, alex);
    await syncPair(henry, outsider);
    final before = (await roomOf(henry)).data['groupKey']['id'];

    await Everyday(
      henry,
    ).changeMembers(await roomOf(henry), [alex.person], shareHistory: true);
    final after = await roomOf(henry);
    expect(after.data['groupKey']['id'], isNot(before));
    expect(after.data['invite'], 'members');
    await Everyday(henry).write({'type': 'note', 'text': 'Later'}, room: after);
    await syncPair(henry, alex);
    await syncPair(henry, outsider);
    // Whoever was removed is offered nothing new.
    expect(henry.groups.reaches(after.object.space, outsider.person), isFalse);
    expect([
      for (final o in outsider.store.allOf(
        kinds: ['room_item'],
        space: after.object.space,
      ))
        o.id,
    ], hasLength(1));

    await Everyday(alex).invite(await roomOf(alex), [vero.person]);
    await syncPair(alex, vero);
    expect(await chat(vero), ['Hello', 'Later']);
  });

  test('someone who left can be added again', () async {
    await Everyday(
      henry,
    ).createRoom('Windsworth', [alex.person], membersInvite: true);
    await syncPair(henry, alex);
    await Everyday(alex).invite(await roomOf(alex), [vero.person]);
    await syncPair(alex, vero);
    await Everyday(vero).leave(await roomOf(vero));
    await syncPair(alex, vero);
    expect(await Everyday(alex).members(await roomOf(alex)), hasLength(2));

    await Everyday(alex).invite(await roomOf(alex), [vero.person]);
    await syncPair(alex, vero);
    expect(await Everyday(alex).members(await roomOf(alex)), hasLength(3));
    expect(await Everyday(vero).rooms(), hasLength(1));
  });
}
