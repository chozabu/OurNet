import 'package:test/test.dart';
import 'package:ournet_core/ournet_core.dart';

Future<(Node, Node)> pair() async {
  final a = Node(await LocalIdentity.create(), Store());
  final b = Node(await LocalIdentity.create(), Store());
  await a.addContact(b.identity.certificate);
  await b.addContact(a.identity.certificate);
  addTearDown(() async {
    await a.close();
    await b.close();
  });
  return (a, b);
}

Future<void> say(
  Node node,
  EverydayItem room,
  String text, {
  int? sent,
  String? reply,
}) => Everyday(node).write({
  'type': 'note',
  'text': text,
  'sent': ?sent,
  'reply': ?reply,
}, room: room);

List<String> texts(RoomFeed feed) => [
  for (final i in feed.items) i.data['text'] as String,
];

void main() {
  test(
    'a chat window loads newest first and pages back to the start',
    () async {
      final (a, b) = await pair();
      final room = await Everyday(a).createRoom('Trip', [b.person]);
      const base = 1700000000000;
      for (var i = 0; i < 150; i++) {
        await say(a, room, 'm$i', sent: base + i);
      }
      final feed = RoomFeed(a, room);
      await feed.loadOlder(want: 40);
      expect(feed.items.first.data['text'], 'm149');
      expect(feed.items.length, greaterThanOrEqualTo(40));
      expect(feed.items.length, lessThan(150));
      expect(feed.hasOlder, isTrue);
      while (feed.hasOlder) {
        await feed.loadOlder(want: 40);
      }
      expect(feed.items.length, 150);
      expect(texts(feed), [for (var i = 149; i >= 0; i--) 'm$i']);
    },
  );

  test('refresh adds arrivals; edits keep the original position', () async {
    final (a, b) = await pair();
    final room = await Everyday(a).createRoom('Trip', [b.person]);
    const base = 1700000000000;
    for (var i = 0; i < 100; i++) {
      await say(a, room, 'm$i', sent: base + i);
    }
    final feed = RoomFeed(a, room);
    await feed.loadOlder(want: 20);
    final loaded = feed.items.length;
    expect(await feed.refresh(), isFalse);

    // An edit of something older than the window is not shown out of place.
    final oldest = (await Everyday(a).items(room)).last;
    await Everyday(a).write({...oldest.data, 'text': 'edited'}, room: room);
    expect(await feed.refresh(), isFalse);
    expect(feed.items.length, loaded);

    // New messages from a friend arrive through sync.
    await syncPair(a, b);
    final theirs = (await Everyday(b).rooms()).single;
    await say(b, theirs, 'from b', sent: base + 1000);
    await syncPair(a, b);
    expect(await feed.refresh(), isTrue);
    expect(feed.items.first.data['text'], 'from b');
    expect(feed.items.first.object.author, b.person);

    // The edit is found once paging reaches it, at its original position.
    while (feed.hasOlder) {
      await feed.loadOlder(want: 40);
    }
    expect(feed.items.last.data['text'], 'edited');
    expect(feed.items.length, 101);
    expect(
      feed.entry(oldest.data['entry'])!.data['sent'] ??
          feed.entry(oldest.data['entry'])!.object.created,
      isNotNull,
    );
  });

  test('an edited entry replaces the old version in place', () async {
    final (a, b) = await pair();
    final room = await Everyday(a).createRoom('Trip', [b.person]);
    await say(a, room, 'first', sent: 1000);
    await say(a, room, 'second', sent: 2000);
    final feed = RoomFeed(a, room);
    await feed.loadOlder();
    final first = feed.items.last;
    await Everyday(a).write({...first.data, 'text': 'first!'}, room: room);
    expect(await feed.refresh(), isTrue);
    expect(texts(feed), ['second', 'first!']);
    await Everyday(a).write({...first.data, 'deleted': true}, room: room);
    expect(await feed.refresh(), isTrue);
    expect(feed.items.last.data['deleted'], isTrue);
  });

  test('replies point at entries and reactions follow the entry', () async {
    final (a, b) = await pair();
    final room = await Everyday(a).createRoom('Trip', [b.person]);
    await say(a, room, 'Who has the tent?', sent: 1000);
    await syncPair(a, b);
    final theirs = (await Everyday(b).rooms()).single;
    final question = (await Everyday(b).items(theirs)).single;
    await say(
      b,
      theirs,
      'I do',
      sent: 2000,
      reply: question.data['entry'] as String,
    );
    await MessageUpdates(
      b,
    ).reactToTarget(Everyday.reactionTarget(question), [a.person], '👍');
    await syncPair(a, b);
    final feed = RoomFeed(a, room);
    await feed.loadOlder();
    final answer = feed.items.first;
    expect(answer.data['reply'], question.data['entry']);
    expect(feed.entry(answer.data['reply'])!.data['text'], 'Who has the tent?');
    final updates = MessageUpdates(a);
    await updates.catchUp();
    expect(
      updates.reactionsFor(Everyday.reactionTarget(question), {
        a.person,
        b.person,
      }),
      {b.person: '👍'},
    );
    // The reaction survives an edit, which replaces the object.
    await Everyday(
      a,
    ).write({...question.data, 'text': 'Who has a tent?'}, room: room);
    expect(
      updates.reactionsFor(Everyday.reactionTarget(question), {b.person}),
      {b.person: '👍'},
    );
  });

  test('adding a member restarts the window with the shared history', () async {
    final (a, b) = await pair();
    final c = Node(await LocalIdentity.create(), Store());
    addTearDown(c.close);
    await a.addContact(c.identity.certificate);
    await c.addContact(a.identity.certificate);
    var room = await Everyday(a).createRoom('Trip', [b.person]);
    await say(a, room, 'before', sent: 1000);
    final feed = RoomFeed(a, room);
    await feed.loadOlder();
    expect(texts(feed), ['before']);
    room = await Everyday(
      a,
    ).changeMembers(room, [b.person, c.person], shareHistory: true);
    expect(await feed.refresh(), isTrue);
    expect(texts(feed), ['before']);
    await say(a, room, 'after', sent: 2000);
    expect(await feed.refresh(), isTrue);
    expect(texts(feed), ['after', 'before']);
  });
}
