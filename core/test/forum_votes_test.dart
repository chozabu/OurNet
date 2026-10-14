import 'package:test/test.dart';
import 'package:ournet_core/ournet_core.dart';

Future<Node> friend(Node a) async {
  final other = Node(await LocalIdentity.create(), Store());
  await a.addContact(other.identity.certificate);
  await other.addContact(a.identity.certificate);
  addTearDown(other.close);
  return other;
}

void main() {
  test('public forum votes travel with the forum; the latest counts', () async {
    final a = Node(await LocalIdentity.create(), Store());
    addTearDown(a.close);
    final b = await friend(a);
    const space = 'forum2:test:votes';
    a.subscribe(space, true);
    b.subscribe(space, true);
    final post = await a.publish('post', {
      'text': 'Hello',
      'title': 'Hi',
    }, space: space);
    await syncPair(a, b);
    final theirs = b.store.get(post.id)!;
    final votesB = ForumVotes(b);
    await votesB.vote(theirs, theirs.data['payload'] as Json, 1);
    final votesA = ForumVotes(a);
    await votesA.vote(post, post.data['payload'] as Json, -1);
    await syncPair(a, b);
    await votesA.catchUp();
    await votesB.catchUp();
    final payload = post.data['payload'] as Json;
    var tally = votesA.tally(post, payload);
    expect((tally.up, tally.down, tally.mine, tally.score), (1, 1, -1, 0));
    expect(votesB.tally(theirs, payload).mine, 1);

    // Changing a vote replaces it; withdrawing it removes it.
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await votesA.vote(post, payload, 1);
    expect(votesA.score(post, payload), 2);
    await syncPair(a, b);
    await votesB.catchUp();
    expect(votesB.score(theirs, payload), 2);
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await votesB.vote(theirs, payload, 0);
    await syncPair(a, b);
    await votesA.catchUp();
    tally = votesA.tally(post, payload);
    expect((tally.up, tally.down, tally.score), (1, 0, 1));

    // Catching up again changes nothing, and blocked people do not count.
    await votesA.catchUp();
    expect(votesA.score(post, payload), 1);
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await votesB.vote(theirs, payload, -1);
    await syncPair(a, b);
    await votesA.catchUp();
    expect(votesA.score(post, payload), 0);
    a.blocked.add(b.person);
    expect(votesA.score(post, payload), 1);
  });

  test('a post starts upvoted by its author, who can take it back', () async {
    final a = Node(await LocalIdentity.create(), Store());
    addTearDown(a.close);
    final b = await friend(a);
    const space = 'forum2:test:own';
    a.subscribe(space, true);
    b.subscribe(space, true);
    final post = await b.publish('post', {'text': 'Mine'}, space: space);
    final payload = post.data['payload'] as Json;
    final theirs = ForumVotes(b);
    expect(theirs.tally(post, payload).mine, 1);
    await syncPair(a, b);
    final votes = ForumVotes(a);
    await votes.catchUp();
    var tally = votes.tally(post, payload);
    expect((tally.up, tally.mine, tally.score), (1, 0, 1));
    await theirs.vote(post, payload, 0);
    expect(theirs.tally(post, payload).mine, 0);
    await syncPair(a, b);
    await votes.catchUp();
    expect(votes.score(post, payload), 0);
    a.blocked.add(b.person);
    expect(votes.score(post, payload), 0);
  });

  test('group forum votes are private and follow shared copies', () async {
    final a = Node(await LocalIdentity.create(), Store());
    addTearDown(a.close);
    final b = await friend(a);
    final outsider = await friend(a);
    final room = await Everyday(a).createRoom('Trip', [b.person]);
    final forum = RoomForum(a, room);
    final topic = await forum.publish({'text': 'Lake?', 'title': 'Camp'});
    await syncPair(a, b);
    final theirs = (await Everyday(b).rooms()).single;
    final theirForum = RoomForum(b, theirs);
    await theirForum.load();
    final post = theirForum.topics.single;
    await ForumVotes(
      b,
    ).vote(post.object, post.data, 1, audience: await theirForum.audience());
    await syncPair(a, b);
    await syncPair(a, outsider);
    expect(outsider.store.objects(kind: 'vote'), isEmpty);

    final votes = ForumVotes(a);
    await votes.catchUp();
    final payload = (await a.content(topic))!;
    final members = (room.data['members'] as List).cast<String>().toSet();
    // The author's own upvote, and the other member's.
    expect(votes.score(topic, payload, voters: members), 2);
    // Someone outside the group does not count.
    expect(votes.score(topic, payload, voters: {a.person}), 1);

    // A copy shared with a later member carries the original's votes.
    final copy = await a.publish(
      'room_post',
      {
        ...payload,
        'history': true,
        'originalAuthor': a.person,
        'copyOf': topic.id,
      },
      space: topic.space,
      audience: await forum.audience(),
    );
    expect(ForumVotes.target(copy, {...payload, 'copyOf': topic.id}), topic.id);
    expect(
      votes.score(copy, {...payload, 'copyOf': topic.id}, voters: members),
      2,
    );
  });

  test('a group thread can put its best replies first', () async {
    final a = Node(await LocalIdentity.create(), Store());
    addTearDown(a.close);
    final b = await friend(a);
    final room = await Everyday(a).createRoom('Trip', [b.person]);
    final forum = RoomForum(a, room);
    final topic = await forum.publish({'text': 'Where?', 'title': 'Camp'});
    final first = await forum.publish({
      'text': 'Lake',
      'parent': topic.id,
      'sent': 1,
    });
    final second = await forum.publish({
      'text': 'Hill',
      'parent': topic.id,
      'sent': 2,
    });
    await forum.load();
    List<String> order(int Function(ForumPost)? score) => [
      for (final p in forum.thread(topic.id, score: score)) p.object.id,
    ];
    expect(order(null), [topic.id, first.id, second.id]);
    final votes = ForumVotes(a);
    await votes.vote(first, {}, -1, audience: await forum.audience());
    expect(order((p) => votes.score(p.object, p.data)), [
      topic.id,
      second.id,
      first.id,
    ]);
  });

  test('hot ranks newer posts above older ones with the same score', () {
    final day = 24 * 3600 * 1000;
    expect(VoteTally.hot(1, 2 * day), greaterThan(VoteTally.hot(1, day)));
    expect(VoteTally.hot(100, 0), greaterThan(VoteTally.hot(1, 0)));
    expect(VoteTally.hot(-5, 0), lessThan(VoteTally.hot(0, 0)));
  });
}
