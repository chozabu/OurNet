import 'package:test/test.dart';
import 'package:ournet_core/ournet_core.dart';

Future<Node> person() async {
  final node = Node(await LocalIdentity.create(), Store());
  addTearDown(node.close);
  return node;
}

Future<void> befriend(Node a, Node b) async {
  await a.addContact(b.identity.certificate);
  await b.addContact(a.identity.certificate);
}

/// What [viewer] can read of [owner]'s wall, newest first.
Future<List<String>> wallOf(Node viewer, Node owner) async {
  final wall = Wall(viewer, owner.person);
  await wall.refresh();
  return [for (final p in wall.posts) p.text];
}

void main() {
  test('wall kinds are checked', () {
    expect(validContent('wall_post', {'text': 'Hello'}), isTrue);
    expect(validContent('wall_post', {'text': 'x' * 20001}), isFalse);
    expect(
      validContent('wall_post', {'text': 'Hi', 'title': 'x' * 201}),
      isFalse,
    );
    expect(validContent('wall_post', {'epoch': 0, 'box': 'abc'}), isTrue);
    expect(validContent('wall_post', {'epoch': -1, 'box': 'abc'}), isFalse);
    expect(
      validContent('wall_post', {'epoch': 0, 'box': 'a', 'text': 'b'}),
      isFalse,
    );
    expect(
      validContent('wall_post', {
        'text': '',
        'share': {'object': {}},
      }),
      isTrue,
    );
    expect(validContent('wall_post', {'text': '', 'share': 'x'}), isFalse);
    expect(validContent('wall_comment', {'post': 'p', 'text': 'Hi'}), isTrue);
    expect(validContent('wall_comment', {'text': 'Hi'}), isFalse);
    expect(
      validContent('wall_comment', {'post': 'p', 'epoch': 2, 'box': 'b'}),
      isTrue,
    );
    expect(validContent('wall_hide', {'object': 'o'}), isTrue);
    expect(validContent('wall_hide', {}), isFalse);
    expect(
      validContent('wall_key', {'epoch': 0, 'key': b64(randomBytes(32))}),
      isTrue,
    );
    expect(validContent('wall_key', {'epoch': 0, 'key': 'short'}), isFalse);
  });

  test('only the owner posts or hides on a wall', () async {
    final a = await person(), b = await person();
    await befriend(a, b);
    await Wall(a, a.person).publish('Mine', audience: WallAudience.public);
    // B writes into A's wall as if it were theirs.
    final forged = await b.publish('wall_post', {
      'text': 'Not yours',
    }, space: Walls.space(a.person));
    final hide = await b.publish('wall_hide', {
      'object': forged.id,
    }, space: Walls.space(a.person));
    await syncPair(a, b);
    expect(a.store.get(forged.id), isNull);
    expect(a.store.get(hide.id), isNull);
    expect(await wallOf(b, a), ['Mine']);
    expect(await wallOf(a, a), ['Mine']);
  });

  test(
    'friends read friends-only posts; a follower who is not cannot',
    () async {
      final a = await person(), b = await person(), c = await person();
      await befriend(a, b);
      // C is B's friend only, and follows A's wall by link.
      await befriend(b, c);
      c.followWall(a.person, true);
      expect(Walls.following(b, a.person), isTrue, reason: 'friends follow');
      final wall = Wall(a, a.person);
      await wall.publish('For friends');
      await wall.publish('For everyone', audience: WallAudience.public);
      await syncPair(a, b);
      await syncPair(b, c);
      // Written in the same moment, so in either order.
      expect(
        await wallOf(b, a),
        unorderedEquals(['For everyone', 'For friends']),
      );
      // C holds both posts but can open only the public one.
      expect(
        c.store.objects(kind: Walls.postKind, space: Walls.space(a.person)),
        hasLength(2),
      );
      expect(await wallOf(c, a), ['For everyone']);
      final feed = WallFeed(b);
      await feed.refresh();
      expect(
        {for (final p in feed.posts) p.text: p.audience},
        {
          'For everyone': WallAudience.public,
          'For friends': WallAudience.friends,
        },
      );
    },
  );

  test('a friend added later cannot open earlier posts', () async {
    final a = await person(), b = await person(), d = await person();
    await befriend(a, b);
    final wall = Wall(a, a.person);
    await wall.publish('Before D');
    await syncPair(a, b);
    await befriend(a, d);
    await wall.publish('After D');
    await syncPair(a, b);
    await syncPair(a, d);
    expect(await wallOf(d, a), ['After D']);
    expect(await wallOf(b, a), ['After D', 'Before D']);
  });

  test('a removed friend cannot open new posts', () async {
    final a = await person(), b = await person(), c = await person();
    await befriend(a, b);
    await befriend(a, c);
    await befriend(b, c);
    final wall = Wall(a, a.person);
    await wall.publish('Old news');
    await syncPair(a, b);
    await syncPair(a, c);
    expect(await wallOf(c, a), ['Old news']);
    await a.setContactState(c.person, ContactState.forgotten);
    await wall.publish('New news');
    await syncPair(a, b);
    // C still follows A's wall, and gets the new post through B.
    await syncPair(b, c);
    expect(
      c.store.objects(kind: Walls.postKind, space: Walls.space(a.person)),
      hasLength(2),
    );
    expect(await wallOf(c, a), ['Old news']);
    expect(await wallOf(b, a), ['New news', 'Old news']);
  });

  test('a comment on a friends-only post reads for every reader', () async {
    final a = await person(), b = await person(), c = await person();
    // B and C are both A's friends but not each other's.
    await befriend(a, b);
    await befriend(a, c);
    final wall = Wall(a, a.person);
    await wall.publish('Party on Saturday');
    await syncPair(a, b);
    await syncPair(a, c);
    final theirs = Wall(b, a.person);
    await theirs.refresh();
    final post = theirs.posts.single;
    final first = await theirs.comment(post, 'Count me in');
    await theirs.comment(post, 'Bringing cake', parent: first.id);
    await syncPair(a, b);
    await syncPair(a, c);
    final seen = Wall(c, a.person);
    await seen.refresh();
    final comments = seen.posts.single.comments;
    expect(
      [for (final x in comments) x.text],
      ['Count me in', 'Bringing cake'],
    );
    expect([for (final x in comments) x.depth], [0, 1]);
    expect(comments.first.author, b.person);
    // Sealed: a follower without the key reads none of it.
    final p = c.store.get(first.id)!.data['payload'] as Json;
    expect(p['text'], isNull);
    expect(p['epoch'], post.epoch);
  });

  test('the owner hides comments and deletes their own posts', () async {
    final a = await person(), b = await person();
    await befriend(a, b);
    final wall = Wall(a, a.person);
    final kept = await wall.publish('Kept', audience: WallAudience.public);
    final gone = await wall.publish('Gone', audience: WallAudience.public);
    await syncPair(a, b);
    final theirs = Wall(b, a.person);
    await theirs.refresh();
    final comment = await theirs.comment(theirs.post(kept.id)!, 'Rude');
    await syncPair(a, b);
    await wall.refresh();
    expect(wall.post(kept.id)!.comments, hasLength(1));
    await wall.hide(a.store.get(comment.id)!);
    await wall.hide(gone);
    // Hiding is the owner's: not on someone else's wall.
    expect(() => theirs.hide(gone), throwsStateError);
    await syncPair(a, b);
    await theirs.refresh();
    expect([for (final p in theirs.posts) p.text], ['Kept']);
    expect(theirs.posts.single.comments, isEmpty);
  });

  test(
    'a reshare embeds the verified original, and a tampered one is not shown',
    () async {
      final a = await person(), b = await person(), c = await person();
      await befriend(a, b);
      await befriend(b, c);
      final original = await Wall(
        a,
        a.person,
      ).publish('Worth reading', audience: WallAudience.public);
      await syncPair(a, b);
      final mine = Wall(b, b.person);
      final share = await mine.reshare(original, 'Look');
      // A reshare of the reshare embeds the original, not the chain.
      await syncPair(b, c);
      await Wall(c, c.person).reshare(c.store.get(share.id)!);
      final sent = c.store
          .objects(kind: Walls.postKind, author: c.person)
          .single;
      final embedded = (sent.data['payload'] as Json)['share']['object'];
      expect(SignedObject.fromJson(embedded).id, original.id);
      await mine.refresh();
      final post = mine.posts.single;
      expect(post.text, 'Look');
      expect(post.shared!.author, a.person);
      expect(post.sharedPayload!['text'], 'Worth reading');

      // The same embed with its words changed no longer verifies.
      final json = original.toJson();
      final tampered = {
        ...json,
        'data': {
          ...json['data'] as Json,
          'payload': {'text': 'Something else'},
        },
      };
      await b.publish('wall_post', {
        'text': 'Fake',
        'share': {'object': tampered},
      }, space: Walls.space(b.person));
      await mine.refresh();
      expect([for (final p in mine.posts) p.text], ['Look']);
      // Sealed posts cannot be reshared.
      final secret = await Wall(a, a.person).publish('Only friends');
      expect(() => mine.reshare(secret), throwsStateError);
    },
  );

  test('a wall refreshes from an insertion cursor', () async {
    final a = await person(), b = await person();
    await befriend(a, b);
    final wall = Wall(b, a.person);
    final mine = Wall(a, a.person);
    await mine.publish('One', audience: WallAudience.public);
    await syncPair(a, b);
    await wall.refresh();
    expect([for (final p in wall.posts) p.text], ['One']);
    expect(await wall.refresh(), isFalse);
    // Something written long ago arrives now: taken by insertion order,
    // whatever its time.
    final old = Node(
      a.identity,
      Store(),
      clock: () => DateTime(2020).millisecondsSinceEpoch,
    );
    addTearDown(old.close);
    final early = await Wall(
      old,
      a.person,
    ).publish('From 2020', audience: WallAudience.public);
    b.store.put(early);
    expect(await wall.refresh(), isTrue);
    expect([for (final p in wall.posts) p.text], ['One', 'From 2020']);
    expect(await wall.refresh(), isFalse);
  });

  test('a wall pages back through history', () async {
    final a = await person();
    final wall = Wall(a, a.person);
    for (var i = 0; i < WallView.pageSize + 5; i++) {
      await wall.publish('Post $i', audience: WallAudience.public);
    }
    final view = Wall(a, a.person);
    await view.refresh();
    expect(view.posts, hasLength(WallView.pageSize));
    expect(view.exhausted, isFalse);
    await view.more();
    expect(view.posts, hasLength(WallView.pageSize + 5));
  });

  test('a device linked later is given the wall keys', () async {
    final owner = await LocalIdentity.create();
    final fresh = await LocalIdentity.create();
    final a = Node(owner, Store()), b = await person();
    addTearDown(a.close);
    await befriend(a, b);
    await Wall(a, a.person).publish('Before the new phone');
    final paired = await fresh.enrol(await owner.authorise(fresh.certificate));
    final phone = Node(paired, Store());
    addTearDown(phone.close);
    await a.addContact(paired.certificate);
    await phone.addContact(owner.certificate);
    await syncPair(a, phone);
    await phone.wallKeys.refresh();
    expect(phone.wallKeys.waiting, isTrue);
    expect(() => Wall(phone, a.person).publish('Too soon'), throwsStateError);
    expect(await a.wallKeys.shareOwn(), 1);
    await syncPair(a, phone);
    expect(await wallOf(phone, a), ['Before the new phone']);
    await Wall(phone, a.person).publish('From the phone');
    await syncPair(a, phone);
    await syncPair(a, b);
    expect(await wallOf(b, a), ['From the phone', 'Before the new phone']);
  });

  test('friends\' walls are followed unless unfollowed', () async {
    final store = Store();
    final a = Node(await LocalIdentity.create(), store);
    addTearDown(a.close);
    final b = await person();
    await befriend(a, b);
    expect(Walls.following(a, a.person), isTrue);
    expect(Walls.following(a, b.person), isTrue);
    a.followWall(b.person, false);
    expect(Walls.following(a, b.person), isFalse);
    expect(
      Node(a.identity, store).subscriptions,
      isNot(contains(Walls.space(b.person))),
    );
    a.followWall(b.person, true);
    expect(Walls.following(a, b.person), isTrue);
    await a.setContactState(b.person, ContactState.forgotten);
    // Followed on purpose, so it stays.
    expect(Walls.following(a, b.person), isTrue);
  });

  test('each wall post is an activity row, which comments join', () async {
    final a = await person(), b = await person();
    await befriend(a, b);
    final mine = Wall(a, a.person);
    final hello = await mine.publish('Hello friends');
    await syncPair(a, b);
    final theirs = Wall(b, a.person);
    await theirs.refresh();
    await theirs.comment(theirs.posts.single, 'Hi!');
    final later = await mine.publish('Later', audience: WallAudience.public);
    await syncPair(a, b);
    // New friends have rows of their own.
    Iterable<ActivityEntry> walls(Activity a) =>
        a.entries.where((e) => e.section == ActivitySection.wall);
    final feed = Activity(b);
    await feed.refresh();
    expect({for (final e in walls(feed)) e.post: e.public}, {
      hello.id: false,
      later.id: true,
    });
    final post = walls(feed).firstWhere((e) => e.post == hello.id);
    // What B wrote on this device is not news to it.
    expect(post.items.single.data!['text'], 'Hello friends');

    // The owner's own posts are there too, and the comment joins its post.
    final mineFeed = Activity(a);
    await mineFeed.refresh();
    expect(walls(mineFeed), hasLength(2));
    final row = walls(mineFeed).firstWhere((e) => e.post == hello.id);
    expect(
      row.items.map((i) => i.object.kind),
      unorderedEquals([Walls.commentKind, Walls.postKind]),
    );
    final comment = row.items.firstWhere(
      (i) => i.object.kind == Walls.commentKind,
    );
    expect(comment.data!['text'], 'Hi!');
    expect(comment.author, b.person);
    expect(row.byOthers(a.person), isTrue);
  });

  test('wall links', () {
    final link = Links.wall('abc=', post: 'id1');
    final parsed = Links.parse(link)!;
    expect(parsed.type, 'wall');
    expect(parsed.space, 'wall:abc=');
    expect(parsed.object, 'id1');
    expect(Links.parse(Links.wall('abc='))!.object, isNull);
    expect(
      Links.pattern.firstMatch('see ${Links.wall('abc=')}.')!.group(0),
      Links.wall('abc='),
    );
  });

  test('unseen counts what others posted until it is looked at', () async {
    final a = await person(), b = await person();
    await befriend(a, b);
    await Wall(a, a.person).publish('News');
    await syncPair(a, b);
    final feed = WallFeed(b);
    await feed.refresh();
    expect(feed.unseen(), 1);
    feed.markSeen();
    expect(feed.unseen(), 0);
  });
}
