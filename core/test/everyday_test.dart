import 'package:test/test.dart';
import 'package:ournet_core/ournet_core.dart';

void main() {
  test('unread group entries are counted from where reading got to', () async {
    final a = Node(await LocalIdentity.create(), Store());
    final b = Node(await LocalIdentity.create(), Store());
    addTearDown(() async {
      await a.close();
      await b.close();
    });
    await a.addContact(b.identity.certificate);
    await b.addContact(a.identity.certificate);
    final room = await Everyday(a).createRoom('Family', [b.person]);
    await syncPair(a, b);
    final theirs = (await Everyday(b).rooms()).single;
    Future<void> say(String text) =>
        Everyday(b).write({'type': 'note', 'text': text}, room: theirs);
    for (final text in ['One', 'Two', 'Three']) {
      await say(text);
    }
    await Everyday(a).write({'type': 'note', 'text': 'Mine'}, room: room);
    await syncPair(a, b);
    final space = room.data['room'] as String;
    // Only what others wrote, as the object-by-object count says.
    expect(a.roomUnread(space), 3);
    expect(
      a.store.unread('room_item', a.person).where((o) => o.space == space),
      hasLength(3),
    );
    a.blocked.add(b.person);
    expect(a.roomUnread(space), 0);
    a.blocked.remove(b.person);

    // Reading moves the floor; only what arrives after it counts.
    await a.markRoomRead(space);
    expect(a.roomUnread(space), 0);
    expect(a.roomReadFloor(space), greaterThan(0));
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await say('Four');
    await syncPair(a, b);
    expect(a.roomUnread(space), 1);
    expect(a.roomUnread(space, cap: 0), 0);
    await a.markRoomRead(space);
    expect(a.roomUnread(space), 0);
  });

  test('private groups converge offline lists and exclude outsiders', () async {
    final a = Node(await LocalIdentity.create(), Store());
    final b = Node(await LocalIdentity.create(), Store());
    final outsider = Node(await LocalIdentity.create(), Store());
    addTearDown(() async {
      await a.close();
      await b.close();
      await outsider.close();
    });
    await a.addContact(b.identity.certificate);
    await b.addContact(a.identity.certificate);
    await a.addContact(outsider.identity.certificate);
    await outsider.addContact(a.identity.certificate);
    final room = await Everyday(a).createRoom('Family', [b.person]);
    await syncPair(a, b);
    final other = (await Everyday(b).rooms()).single;
    await Everyday(a).write({
      'type': 'check',
      'text': 'Milk',
      'list': 'Shopping',
      'done': false,
    }, room: room);
    await Everyday(b).write({
      'type': 'check',
      'text': 'Bread',
      'list': 'Shopping',
      'done': false,
    }, room: other);
    await syncPair(a, b);
    expect((await Everyday(a).items(room)).length, 2);
    final milk = (await Everyday(
      a,
    ).items(room)).firstWhere((i) => i.data['text'] == 'Milk');
    await Everyday(a).write({...milk.data, 'done': true}, room: room);
    await Everyday(b).write({...milk.data, 'done': false}, room: other);
    await syncPair(a, b);
    expect(
      (await Everyday(a).items(room)).map((i) => i.object.id),
      (await Everyday(b).items(other)).map((i) => i.object.id),
    );
    await syncPair(a, outsider);
    expect(await Everyday(outsider).rooms(), isEmpty);
    expect(await Everyday(outsider).records(), isEmpty);
  });
  test(
    'inbox history reaches a newly enrolled device and remains private',
    () async {
      final a = Node(await LocalIdentity.create(), Store());
      await Everyday(a).write({'type': 'note', 'text': 'https://example.com'});
      final fresh = await LocalIdentity.create();
      final paired = await fresh.enrol(
        await a.identity.authorise(fresh.certificate),
      );
      final b = Node(paired, Store());
      addTearDown(() async {
        await a.close();
        await b.close();
      });
      await a.addContact(paired.certificate);
      await b.addContact(a.identity.certificate);
      await Everyday(a).shareHistory();
      await syncPair(a, b);
      expect(
        (await Everyday(b).items()).single.data['text'],
        'https://example.com',
      );
      expect((await Everyday(a).items()).length, 1);
    },
  );
  test('malformed everyday payloads are rejected', () {
    expect(
      validContent('room_item', {
        'entry': 'x',
        'clock': 1,
        'type': 'check',
        'done': 'yes',
      }),
      false,
    );
    expect(
      validContent('room', {
        'name': 'Family',
        'room': 'r',
        'owner': 'p',
        'members': [2],
      }),
      false,
    );
  });
}
