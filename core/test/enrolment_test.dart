import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';

Future<void> befriend(Node a, Node b) async {
  await a.addContact(b.identity.certificate);
  await b.addContact(a.identity.certificate);
}

/// Everything the pairing screen does once a device is approved.
Future<void> enrolmentHandover(Node owner) async {
  await Drive(owner).shareHistory();
  await Everyday(owner).shareHistory();
  await Everyday(owner).shareRooms();
  await Notes(owner).shareNotes();
}

Future<Node> enrol(Node owner, {String label = 'Phone'}) async {
  final device = Node(
    await LocalIdentity.create(root: owner.identity.root, label: label),
    Store(),
  );
  await owner.addContact(device.identity.certificate);
  await device.addContact(owner.identity.certificate);
  await enrolmentHandover(owner);
  await syncPair(owner, device, rounds: 128);
  return device;
}

void main() {
  test('a device enrolled later reads the notes and groups made before it', () async {
    final laptop = Node(await LocalIdentity.create(), Store());
    final friend = Node(await LocalIdentity.create(), Store());
    await befriend(laptop, friend);

    await Everyday(laptop).write({'type': 'note', 'text': 'inbox note'});
    final note = await Notes(laptop).create(
      title: 'Shopping',
      items: ['bread', 'wine'],
    );
    await Notes(laptop).state.set('pin', note.id, true);
    final group = await Everyday(laptop).createRoom('Dinner', [friend.person]);
    await Everyday(laptop).write({'type': 'note', 'text': 'bring bread'},
        room: group);
    await Notes(laptop).state.subscribe('forum2:${laptop.person}:abc', true);

    final before = (await Notes(laptop).list()).single;
    final updatedBefore = before.updated, createdBefore = before.created;
    final phone = await enrol(laptop);
    final phoneNotes = Notes(phone);
    await phoneNotes.refresh();

    expect((await Everyday(phone).items()).map((i) => i.data['text']),
        contains('inbox note'));

    final notes = await phoneNotes.list();
    expect(notes, hasLength(1));
    final onPhone = notes.single;
    expect(onPhone.title, 'Shopping');
    expect(onPhone.checks.map(onPhone.itemText), ['bread', 'wine']);
    expect(onPhone.hasConflicts, isFalse);
    expect(phoneNotes.state.pinned(onPhone.id), isTrue);
    // Re-encrypting is not an edit: the list order must not be disturbed.
    expect(onPhone.updated, updatedBefore);
    expect(onPhone.created, createdBefore);
    final back = (await Notes(laptop).list()).single;
    expect(back.updated, updatedBefore);
    expect(back.created, createdBefore);

    // As the groups page lists them: a shared note is a room too.
    final groups = (await Everyday(phone).rooms())
        .where((r) => r.data['note'] != true)
        .toList();
    expect(groups, hasLength(1));
    expect(groups.single.data['name'], 'Dinner');
    expect(
      (await Everyday(phone).items(groups.single)).map((i) => i.data['text']),
      ['bring bread'],
    );

    expect(phone.subscriptions, contains('forum2:${laptop.person}:abc'));
  });

  test('the note keeps working from both devices afterwards', () async {
    final laptop = Node(await LocalIdentity.create(), Store());
    await Notes(laptop).create(title: 'Plans', text: 'first');
    final phone = await enrol(laptop);

    final onPhone = (await Notes(phone).list()).single;
    await Notes(phone).set(onPhone, 'text', 'edited on the phone');
    await syncPair(laptop, phone, rounds: 64);
    expect((await Notes(laptop).list()).single.text, 'edited on the phone');

    final onLaptop = (await Notes(laptop).list()).single;
    await Notes(laptop).set(onLaptop, 'title', 'Plans v2');
    await syncPair(laptop, phone, rounds: 64);
    expect((await Notes(phone).list()).single.title, 'Plans v2');
  });

  test('a re-issue preserves concurrent branches rather than resolving them',
      () async {
    final laptop = Node(await LocalIdentity.create(), Store());
    final tablet = await enrol(laptop, label: 'Tablet');
    await Notes(laptop).create(title: 'Conflict', text: 'base');
    await syncPair(laptop, tablet, rounds: 64);
    await Notes(laptop).set((await Notes(laptop).list()).single, 'text', 'A');
    await Notes(tablet).set((await Notes(tablet).list()).single, 'text', 'B');
    await syncPair(laptop, tablet, rounds: 64);
    expect((await Notes(laptop).list()).single.hasConflicts, isTrue);

    final phone = await enrol(laptop);
    final onPhone = (await Notes(phone).list()).single;
    expect(onPhone.hasConflicts, isTrue,
        reason: 'the branch the owner did not pick must survive re-issue');
    expect(onPhone.text, (await Notes(laptop).list()).single.text);
  });

  test('a group a collaborator owns is re-issued by its owner', () async {
    final owner = Node(await LocalIdentity.create(), Store());
    final member = Node(await LocalIdentity.create(), Store());
    await befriend(owner, member);
    final room = await Everyday(owner).createRoom('Club', [member.person]);
    await Everyday(owner).write({'type': 'note', 'text': 'first'}, room: room);
    await syncPair(owner, member, rounds: 64);
    expect(await Everyday(member).rooms(), hasLength(1));

    // The member's own new device cannot read a record only its owner signs.
    final memberPhone = await enrol(member);
    // The owner learns the new device before it can encrypt anything to it.
    await syncPair(owner, member, rounds: 64);
    expect(await Everyday(memberPhone).rooms(), isEmpty);

    // The owner re-issues, and the member's devices all learn it.
    await Everyday(owner).shareRooms();
    await syncPair(owner, member, rounds: 64);
    await syncPair(member, memberPhone, rounds: 64);
    final seen = await Everyday(memberPhone).rooms();
    expect(seen, hasLength(1));
    expect(
      (await Everyday(memberPhone).items(seen.single)).map((i) => i.data['text']),
      ['first'],
    );
  });

  test('followed forums merge instead of overwriting one another', () async {
    final laptop = Node(await LocalIdentity.create(), Store());
    await Notes(laptop).state.subscribe('forum2:a:one', true);
    final phone = await enrol(laptop);
    final laptopNotes = Notes(laptop), phoneNotes = Notes(phone);
    await phoneNotes.refresh();
    expect(phone.subscriptions, contains('forum2:a:one'));

    await phoneNotes.state.subscribe('forum2:b:two', true);
    await syncPair(laptop, phone, rounds: 64);
    await laptopNotes.refresh();
    expect(laptop.subscriptions, containsAll(['forum2:a:one', 'forum2:b:two']));

    await laptopNotes.state.subscribe('forum2:a:one', false);
    await syncPair(laptop, phone, rounds: 64);
    await phoneNotes.refresh();
    expect(phone.subscriptions, isNot(contains('forum2:a:one')));
    expect(phone.subscriptions, contains('forum2:b:two'));
  });
}
