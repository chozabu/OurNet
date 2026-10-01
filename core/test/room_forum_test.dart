import 'package:test/test.dart';
import 'package:ournet_core/ournet_core.dart';

Future<Node> friend(Node a) async {
  final other = Node(await LocalIdentity.create(), Store());
  await a.addContact(other.identity.certificate);
  await other.addContact(a.identity.certificate);
  addTearDown(other.close);
  return other;
}

Future<SignedObject> post(
  Node node,
  EverydayItem room,
  String text, {
  String? title,
  String? parent,
  int? sent,
}) async => node.publish(
  'room_post',
  {'text': text, 'title': ?title, 'parent': parent, 'sent': ?sent},
  space: room.object.space,
  audience: await Everyday(node).members(room),
);

List<String> texts(Iterable<ForumPost> posts) => [
  for (final p in posts) p.data['text'] as String,
];

void main() {
  test('a group forum is threaded and private to the group', () async {
    final a = Node(await LocalIdentity.create(), Store());
    addTearDown(a.close);
    final b = await friend(a);
    final outsider = await friend(a);
    final room = await Everyday(a).createRoom('Trip', [b.person]);
    final topic = await post(
      a,
      room,
      'Pick a campsite',
      title: 'Campsite',
      sent: 1000,
    );
    await syncPair(a, b);
    final theirs = (await Everyday(b).rooms()).single;
    final reply = await post(
      b,
      theirs,
      'The lake one',
      parent: topic.id,
      sent: 2000,
    );
    await post(a, room, 'Another topic', title: 'Food', sent: 3000);
    await syncPair(a, b);
    await syncPair(a, outsider);

    final forum = RoomForum(a, room);
    await forum.load();
    expect(texts(forum.topics), ['Another topic', 'Pick a campsite']);
    expect(texts(forum.thread(topic.id)), ['Pick a campsite', 'The lake one']);
    expect(forum.replies(topic.id), 1);
    expect(forum.depth(reply.id), 1);
    expect(forum.parentOf(reply.id), topic.id);

    // Another member's device reads the same forum; an outsider reads nothing.
    final other = RoomForum(b, theirs);
    await other.load();
    expect(texts(other.topics), ['Another topic', 'Pick a campsite']);
    expect(outsider.store.objects(kind: 'room_post'), isEmpty);

    // Arrivals are picked up from the cursor.
    await post(b, theirs, 'Nice', parent: reply.id, sent: 4000);
    await syncPair(a, b);
    expect(await forum.refresh(), isTrue);
    expect(texts(forum.thread(topic.id)), [
      'Pick a campsite',
      'The lake one',
      'Nice',
    ]);
    expect(forum.depth(forum.thread(topic.id).last.object.id), 2);
    expect(await forum.refresh(), isFalse);
  });

  test('a new member receives the forum with its threads intact', () async {
    final a = Node(await LocalIdentity.create(), Store());
    addTearDown(a.close);
    final b = await friend(a);
    final c = await friend(a);
    var room = await Everyday(a).createRoom('Trip', [b.person]);
    final topic = await post(
      a,
      room,
      'Pick a campsite',
      title: 'Campsite',
      sent: 1000,
    );
    await post(a, room, 'The lake one', parent: topic.id, sent: 2000);
    await syncPair(a, b);

    room = await Everyday(
      a,
    ).changeMembers(room, [b.person, c.person], shareHistory: true);
    await syncPair(a, b);
    await syncPair(a, c);
    final joined = (await Everyday(c).rooms()).single;
    final newcomer = RoomForum(c, joined);
    await newcomer.load();
    expect(texts(newcomer.topics), ['Pick a campsite']);
    expect(texts(newcomer.thread(newcomer.topics.single.object.id)), [
      'Pick a campsite',
      'The lake one',
    ]);
    // The copies keep their authors and original times.
    expect(newcomer.topics.single.author, a.person);
    expect(newcomer.topics.single.sent, 1000);

    // Members who had the originals do not see everything twice.
    final existing = RoomForum(b, (await Everyday(b).rooms()).single);
    await existing.load();
    expect(texts(existing.topics), ['Pick a campsite']);
    expect(existing.shown.length, 2);
  });

  test('history stays private when it is not shared', () async {
    final a = Node(await LocalIdentity.create(), Store());
    addTearDown(a.close);
    final b = await friend(a);
    final c = await friend(a);
    var room = await Everyday(a).createRoom('Trip', [b.person]);
    await post(a, room, 'Before', title: 'Early', sent: 1000);
    room = await Everyday(
      a,
    ).changeMembers(room, [b.person, c.person], shareHistory: false);
    await syncPair(a, c);
    final joined = (await Everyday(c).rooms()).single;
    final newcomer = RoomForum(c, joined);
    await newcomer.load();
    expect(newcomer.topics, isEmpty);
    await post(a, room, 'After', title: 'Late', sent: 2000);
    await syncPair(a, c);
    expect(await newcomer.refresh(), isTrue);
    expect(texts(newcomer.topics), ['After']);
  });

  test('a removed member can no longer post into the forum', () async {
    final a = Node(await LocalIdentity.create(), Store());
    addTearDown(a.close);
    final b = await friend(a);
    final c = await friend(a);
    var room = await Everyday(a).createRoom('Trip', [b.person, c.person]);
    await syncPair(a, b);
    await syncPair(a, c);
    final theirs = (await Everyday(c).rooms()).single;
    room = await Everyday(
      a,
    ).changeMembers(room, [b.person], shareHistory: true);
    // c still holds the old room and writes to the people it knew about.
    await c.publish(
      'room_post',
      {'text': 'Still here?', 'title': 'Hello', 'parent': null, 'sent': 5000},
      space: theirs.object.space,
      audience: [a.person, c.person],
    );
    await syncPair(a, c);
    final forum = RoomForum(a, room);
    await forum.load();
    expect(forum.topics, isEmpty);
  });
}
