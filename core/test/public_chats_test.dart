import 'package:test/test.dart';
import 'package:ournet_core/ournet_core.dart';

void main() {
  late Node a, b, outsider;
  late PublicChats alice, bob;
  setUp(() async {
    a = Node(await LocalIdentity.create(), Store());
    b = Node(await LocalIdentity.create(), Store());
    outsider = Node(await LocalIdentity.create(), Store());
    for (final x in [a, b, outsider]) {
      for (final y in [a, b, outsider]) {
        if (x != y) await x.addContact(y.identity.certificate);
      }
    }
    alice = PublicChats(a, NoteState(a));
    bob = PublicChats(b, NoteState(b));
  });
  tearDown(() async {
    for (final n in [a, b, outsider]) {
      await n.close();
    }
  });

  test('anyone starts a named chat; friends who join talk in it', () async {
    final space = await alice.create('Gardeners', description: 'Grow things');
    expect(PublicChats.isChat(space), isTrue);
    expect(PublicChats.creatorOf(space), a.person);
    expect(alice.owns(space), isTrue);
    expect(alice.joined, [space]);
    expect(alice.info(space)?.name, 'Gardeners');

    await bob.join(space);
    await syncPair(a, b);
    expect(bob.info(space)?.name, 'Gardeners');
    expect(bob.info(space)?.description, 'Grow things');

    await alice.send(space, 'Hello all', name: 'Alice');
    await syncPair(a, b);
    final seen = bob.latest(space);
    expect(seen.single.text, 'Hello all');
    expect(seen.single.name, 'Alice');
    expect(seen.single.object.author, a.person);

    // Unread counts others' messages since this device last read.
    expect(bob.unread(space), 1);
    expect(alice.unread(space), 0);
    bob.markRead(space);
    expect(bob.unread(space), 0);
    await bob.send(space, 'Hi Alice');
    await syncPair(a, b);
    expect(alice.unread(space), 1);
    expect(alice.latest(space).map((m) => m.text), ['Hi Alice', 'Hello all']);

    // Someone not in the chat is not sent it.
    await syncPair(a, outsider);
    expect(PublicChats(outsider, NoteState(outsider)).latest(space), isEmpty);

    // Blocked senders are not shown or counted.
    a.blocked.add(b.person);
    expect(alice.latest(space).map((m) => m.text), ['Hello all']);
    expect(alice.unread(space), 0);
  });

  test(
    'only the creator names a chat, and private copies are ignored',
    () async {
      final space = await alice.create('Book club');
      await bob.join(space);
      await syncPair(a, b);
      await b.publish(PublicChats.recordKind, {
        'name': 'Hijacked',
        'description': '',
      }, space: space);
      await b.publish(
        PublicChats.messageKind,
        {'text': 'Only for Alice'},
        space: space,
        audience: [a.person],
      );
      await syncPair(a, b);
      expect(alice.info(space)?.name, 'Book club');
      expect(alice.latest(space), isEmpty);
    },
  );

  test('the creator can take messages out; others cannot', () async {
    final space = await alice.create('Book club');
    await PublicChats(b, NoteState(b)).join(PublicChats.link(space));
    await syncPair(a, b);
    final spam = await bob.send(space, 'Buy now');
    await bob.send(space, 'Chapter two was good');
    await syncPair(a, b);
    await expectLater(bob.hide(space, spam.id), throwsStateError);
    await b.publish(PublicChats.hideKind, {'object': spam.id}, space: space);
    await syncPair(a, b);
    expect(alice.latest(space), hasLength(2));
    await alice.hide(space, spam.id);
    await syncPair(a, b);
    for (final chats in [alice, bob]) {
      expect(chats.latest(space).map((m) => m.text), ['Chapter two was good']);
    }
  });

  test('chat links round-trip and are found in text', () async {
    final space = await alice.create('Night owls & friends');
    final link = PublicChats.link(space, name: 'Night owls & friends');
    final parsed = PublicChats.parseLink(link)!;
    expect(parsed.space, space);
    expect(parsed.name, 'Night owls & friends');
    expect(PublicChats.parseLink(PublicChats.link(space))!.name, isNull);
    final text = 'Join us: $link. See you there!';
    final found = PublicChats.linkPattern.firstMatch(text)!.group(0)!;
    expect(PublicChats.parseLink(found)!.space, space);
    expect(PublicChats.parseLink('ournet://chat/!!!'), isNull);
    expect(PublicChats.parseLink('ournet://event/a/b'), isNull);
  });

  test('addresses and names are checked', () async {
    expect(PublicChats.isChat('forum2:x:y'), isFalse);
    expect(PublicChats.isChat('chat:x:y:z'), isFalse);
    expect(PublicChats.isChat('chat:'), isFalse);
    await expectLater(alice.join('!!!'), throwsArgumentError);
    await expectLater(alice.create('  '), throwsArgumentError);
    expect(validContent('chat', {'name': '', 'description': ''}), isFalse);
    expect(
      validContent('chat_msg', {'text': 'hi', 'name': 'x' * 101}),
      isFalse,
    );
    expect(validContent('chat_msg', {'text': 'hi', 'reply': 'abc'}), isTrue);
  });
}
