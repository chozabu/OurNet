import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';

Future<void> befriend(Node a, Node b) async {
  await a.addContact(b.identity.certificate);
  await b.addContact(a.identity.certificate);
}

/// Everything the pairing screen does once [device] is approved.
Future<void> enrolmentHandover(Node owner, String device) async {
  await owner.shareKeys(history: true);
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
  await enrolmentHandover(owner, device.identity.device);
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

  test('a group a collaborator owns is readable on a new device', () async {
    final owner = Node(await LocalIdentity.create(), Store());
    final member = Node(await LocalIdentity.create(), Store());
    await befriend(owner, member);
    final room = await Everyday(owner).createRoom('Club', [member.person]);
    await Everyday(owner).write({'type': 'note', 'text': 'first'}, room: room);
    await syncPair(owner, member, rounds: 64);
    expect(await Everyday(member).rooms(), hasLength(1));

    // The member's devices grant their own new one the keys they hold, so
    // it need not wait for the owner to re-issue.
    final memberPhone = await enrol(member);
    final seen = await Everyday(memberPhone).rooms();
    expect(seen, hasLength(1));
    expect(
      (await Everyday(memberPhone).items(seen.single)).map((i) => i.data['text']),
      ['first'],
    );

    // Once the owner has learned the new device, it can write there too.
    await syncPair(owner, member, rounds: 64);
    await Everyday(memberPhone)
        .write({'type': 'note', 'text': 'from the phone'}, room: seen.single);
    await syncPair(member, memberPhone, rounds: 64);
    await syncPair(owner, member, rounds: 64);
    expect(
      (await Everyday(owner).items(room)).map((i) => i.data['text']),
      containsAll(['first', 'from the phone']),
    );

    // A re-issue by the owner still works alongside the grants.
    await Everyday(owner).shareRooms();
    await syncPair(owner, member, rounds: 64);
    await syncPair(member, memberPhone, rounds: 64);
    expect(await Everyday(memberPhone).rooms(), hasLength(1));
    expect(
      (await Everyday(memberPhone).items(seen.single)).map((i) => i.data['text']),
      containsAll(['first', 'from the phone']),
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

  test('a new device reads the conversations from before it', () async {
    final laptop = Node(await LocalIdentity.create(), Store());
    final friend = Node(await LocalIdentity.create(), Store());
    await befriend(laptop, friend);
    final theirs = await friend.publish('message', {'text': 'hi from Bob'},
        space: '_messages', audience: [laptop.person]);
    await syncPair(laptop, friend);
    final mine = await laptop.publish('message', {'text': 'hi back'},
        space: '_messages', audience: [friend.person]);
    await syncPair(laptop, friend);

    final phone = await enrol(laptop);
    Future<String?> text(SignedObject o) async =>
        (await phone.content(phone.store.get(o.id)!))?['text'] as String?;
    expect(await text(theirs), 'hi from Bob');
    expect(await text(mine), 'hi back');
    // The originals are unchanged: same objects, same authors.
    expect(phone.store.get(theirs.id)!.author, friend.person);
  });

  test('a message becomes readable when its grant arrives later', () async {
    final laptop = Node(await LocalIdentity.create(), Store());
    final friend = Node(await LocalIdentity.create(), Store());
    await befriend(laptop, friend);
    final message = await friend.publish('message', {'text': 'early'},
        space: '_messages', audience: [laptop.person]);
    await syncPair(laptop, friend);
    final phone = Node(
      await LocalIdentity.create(root: laptop.identity.root, label: 'Phone'),
      Store(),
    );
    await laptop.addContact(phone.identity.certificate);
    await phone.addContact(laptop.identity.certificate);
    await syncPair(laptop, phone, rounds: 64);
    final held = phone.store.get(message.id)!;
    // Asked before any grant: the answer must not stick.
    expect(await phone.content(held), isNull);
    // The automatic pass covers only what arrives from now on; earlier
    // history is handed over when its owner asks.
    expect(await laptop.shareKeys(), 0);
    await syncPair(laptop, phone, rounds: 64);
    expect(await phone.content(held), isNull);

    expect(await laptop.shareKeys(history: true), 1);
    await syncPair(laptop, phone, rounds: 64);
    expect((await phone.content(held))?['text'], 'early');
  });

  test('keys are granted once, and again only for what is new', () async {
    final laptop = Node(await LocalIdentity.create(), Store());
    final friend = Node(await LocalIdentity.create(), Store());
    await befriend(laptop, friend);
    await friend.publish('message', {'text': 'one'},
        space: '_messages', audience: [laptop.person]);
    await syncPair(laptop, friend);
    final phone = await enrol(laptop);
    expect(await laptop.shareKeys(), 0, reason: 'nothing new since pairing');

    // A friend who has not heard of the phone yet writes to the laptop
    // alone; the laptop's next pass grants that message too.
    final late = await friend.publish('message', {'text': 'two'},
        space: '_messages', audience: [laptop.person]);
    expect(
      wrappedFor(late.data['payload'], phone.identity.device),
      isFalse,
    );
    await syncPair(laptop, friend);
    expect(await laptop.shareKeys(), 1);
    expect(await laptop.shareKeys(), 0);
    await syncPair(laptop, phone, rounds: 64);
    expect((await phone.content(phone.store.get(late.id)!))?['text'], 'two');
  });

  test('another person cannot hand this device keys', () async {
    final laptop = Node(await LocalIdentity.create(), Store());
    final friend = Node(await LocalIdentity.create(), Store());
    await befriend(laptop, friend);
    final phone = await enrol(laptop);
    final message = await friend.publish('message', {'text': 'secret'},
        space: '_messages', audience: [laptop.person]);
    await syncPair(laptop, friend);
    // The real key, which the author holds: a grant is still only believed
    // from this person, addressed to them alone.
    final key = await unwrapFor(
      message.data['payload'],
      friend.identity.agreementKey,
      friend.identity.device,
    );
    await friend.publish('keys', {
      'keys': [
        {'object': message.id, 'key': b64(key)},
      ],
    }, space: '_keys', audience: [laptop.person]);
    await syncPair(laptop, friend);
    await syncPair(laptop, phone, rounds: 64);
    expect(await phone.content(phone.store.get(message.id)!), isNull);
  });

  test('forum posts a new device does not follow do not hold back history',
      () async {
    final laptop = Node(await LocalIdentity.create(), Store());
    final friend = Node(await LocalIdentity.create(), Store());
    await befriend(laptop, friend);
    await friend.publish('profile', {'name': 'Bob'}, space: '_identity');
    await syncPair(laptop, friend);
    laptop.subscribe('forum2:x:old', true);
    friend.subscribe('forum2:x:old', true);
    for (var i = 0; i < 40; i++) {
      await friend.publish('post', {'text': 'post $i'}, space: 'forum2:x:old');
    }
    await syncPair(laptop, friend, rounds: 64);
    // Kept, but no longer followed, so a new device never takes them.
    laptop.subscribe('forum2:x:old', false);

    final phone = await enrol(laptop);
    final names = [
      for (final o in phone.store.objects(kind: 'profile'))
        if (o.author == friend.person) o.data['payload']['name'],
    ];
    expect(names, ['Bob']);
  });
}
