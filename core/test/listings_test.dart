import 'package:test/test.dart';
import 'package:ournet_core/ournet_core.dart';

Future<void> befriend(Node x, Node y) async {
  await x.addContact(y.identity.certificate);
  await y.addContact(x.identity.certificate);
}

void main() {
  late Node a, b, c;
  late NoteState sa, sb, sc;
  late Listings la, lb, lc;
  late PublicChats ca, cb;
  setUp(() async {
    a = Node(await LocalIdentity.create(), Store());
    b = Node(await LocalIdentity.create(), Store());
    c = Node(await LocalIdentity.create(), Store());
    // a and c are both friends of b, and not of each other.
    await befriend(a, b);
    await befriend(b, c);
    sa = NoteState(a);
    sb = NoteState(b);
    sc = NoteState(c);
    la = Listings(a, sa);
    lb = Listings(b, sb);
    lc = Listings(c, sc);
    ca = PublicChats(a, sa);
    cb = PublicChats(b, sb);
  });
  tearDown(() async {
    for (final n in [a, b, c]) {
      await n.close();
    }
  });

  test('names make addresses', () {
    expect(PublicNames.slug('Cooking'), 'cooking');
    expect(PublicNames.slug('  #Cooking Club! '), 'cooking-club');
    expect(PublicNames.slug('r/Cooking'), 'cooking');
    expect(PublicNames.slug('a  --  b'), 'a-b');
    expect(PublicNames.slug('files'), isNull);
    expect(PublicNames.slug('!!!'), isNull);
    expect(PublicNames.slug('x' * 61), isNull);
    expect(PublicNames.forumSpace('Cooking'), 'cooking');
    expect(PublicNames.chatSpace('Cooking'), 'chat:cooking');
    // Names cannot reach into addresses that mean something else.
    expect(PublicNames.slug('chat:x'), 'chatx');
    expect(PublicNames.isForumSpace('chat:cooking'), isFalse);
    expect(PublicNames.isForumSpace('_listing'), isFalse);
    expect(PublicNames.forumFrom('forum2:abc:def'), 'forum2:abc:def');
    expect(PublicNames.forumFrom('Cooking'), 'cooking');
  });

  test('a chat called by name is the same chat for everyone', () async {
    final space = await ca.startOrJoin('Gardeners');
    expect(space, 'chat:gardeners');
    expect(PublicChats.isChat(space), isTrue);
    expect(PublicChats.creatorOf(space), isNull);
    expect(ca.owns(space), isFalse);
    expect(ca.info(space)?.name, 'gardeners');
    expect(await cb.join('#Gardeners'), space);
    await syncPair(a, b);
    await ca.send(space, 'Hello', name: 'Alice');
    await syncPair(a, b);
    expect(cb.latest(space).single.text, 'Hello');
    // Nobody owns it, so nobody can remove another's message.
    await expectLater(cb.hide(space, 'x'), throwsStateError);
    expect(PublicChats.link(space), 'ournet://chat/gardeners');
    expect(PublicChats.parseLink('ournet://chat/gardeners')!.space, space);
    expect(PublicChats.parseLink('ournet://chat/Gardeners')!.space, space);
  });

  test('friends see what friends follow, and only friends', () async {
    await sa.subscribe('cooking', true);
    await ca.startOrJoin('gardeners');
    await sa.subscribe('general', true);
    await la.refresh();
    await syncPair(a, b);
    final found = lb.found();
    expect(found.map((l) => l.space).toSet(), {'cooking', 'chat:gardeners'});
    final cooking = found.firstWhere((l) => l.space == 'cooking');
    expect(cooking.type, 'forum');
    expect(cooking.name, 'cooking');
    expect(cooking.people, {a.person});
    expect(found.firstWhere((l) => l.space == 'chat:gardeners').type, 'chat');
    // The default forum is not advertised.
    expect(found.any((l) => l.space == 'general'), isFalse);
    // A person does not see their own.
    expect(la.found(), isEmpty);

    // b is not asked to pass them on: c, a friend of b only, learns nothing.
    await syncPair(b, c);
    expect(lc.found(), isEmpty);
  });

  test('counts friends who follow, and subscribing is how to join', () async {
    await sa.subscribe('cooking', true);
    await sc.subscribe('cooking', true);
    await la.refresh();
    await lc.refresh();
    await syncPair(a, b);
    await syncPair(b, c);
    final cooking = lb.found().single;
    expect(cooking.people, {a.person, c.person});

    await sb.subscribe(cooking.space, true);
    await syncPair(a, b);
    await a.publish('post', {'title': 'Soup', 'text': 'Salt'}, space: 'cooking');
    await syncPair(a, b);
    expect(
      b.store.objects(kind: 'post', space: 'cooking').single.author,
      a.person,
    );
  });

  test('leaving or turning off takes a listing down', () async {
    await sa.subscribe('cooking', true);
    await la.refresh();
    await syncPair(a, b);
    expect(lb.found(), hasLength(1));

    await la.setAdvertised('cooking', false);
    await syncPair(a, b);
    expect(lb.found(), isEmpty);
    // Refreshing does not bring it back while it stays off.
    await la.refresh();
    await syncPair(a, b);
    expect(lb.found(), isEmpty);

    await la.setAdvertised('cooking', true);
    await syncPair(a, b);
    expect(lb.found(), hasLength(1));
    await sa.subscribe('cooking', false);
    await la.refresh();
    await syncPair(a, b);
    expect(lb.found(), isEmpty);
  });

  test('a stranger or a blocked friend is not listed', () async {
    await sa.subscribe('cooking', true);
    await la.refresh();
    await syncPair(a, b);
    expect(lb.found(), hasLength(1));
    b.blocked.add(a.person);
    b.notify();
    expect(lb.found(), isEmpty);
  });

  test('listings are checked', () {
    expect(
      validContent('listing', {'space': 'x', 'type': 'forum', 'name': 'x'}),
      isTrue,
    );
    expect(validContent('listing', {'space': 'x', 'off': true}), isTrue);
    expect(validContent('listing', {'space': 'x', 'type': 'forum'}), isFalse);
    expect(
      validContent('listing', {'space': 'x', 'type': 'other', 'name': 'x'}),
      isFalse,
    );
    expect(
      validContent('listing', {
        'space': 'x',
        'type': 'chat',
        'name': 'x',
        'description': 'y' * 501,
      }),
      isFalse,
    );
    expect(Listings.advertisable('general'), isFalse);
    expect(Listings.advertisable('_keys'), isFalse);
    expect(Listings.advertisable('files'), isFalse);
    expect(Listings.advertisable('chat:cooking'), isTrue);
    expect(Listings.advertisable('forum2:abc:def'), isTrue);
    expect(Listings.advertisable('cooking'), isTrue);
  });

  test('links to forums, posts and messages round-trip', () async {
    final forum = Links.forum('cooking');
    expect(forum, 'ournet://forum/cooking');
    expect(Links.parse(forum)!.space, 'cooking');
    expect(Links.parse('ournet://forum/Cooking')!.space, 'cooking');
    expect(Links.parse('ournet://forum/')?.type, isNull);
    expect(Links.parse(Links.forum('forum2:abc:def'))!.space, 'forum2:abc:def');

    final post = Links.post('cooking', 'abc123', title: 'Best soup?');
    final parsed = Links.parse(post)!;
    expect(parsed.type, 'post');
    expect(parsed.space, 'cooking');
    expect(parsed.object, 'abc123');
    expect(parsed.title, 'Best soup?');
    expect(Links.parse(Links.post('cooking', 'abc123'))!.title, isNull);

    final message = Links.message('chat:gardeners', 'm1');
    expect(Links.parse(message)!.type, 'message');
    // A message link needs a chat; a post link needs a forum.
    expect(Links.parse(Links.message('cooking', 'm1')), isNull);
    expect(Links.parse(Links.post('chat:gardeners', 'p1')), isNull);
    expect(Links.parse('ournet://post/cooking'), isNull);
    expect(Links.parse('ournet://chat/gardeners'), isNull);
    expect(Links.parse('https://example.com/forum/x'), isNull);

    final text = 'See $post, and $forum. Also $message!';
    expect(
      Links.pattern.allMatches(text).map((m) => m.group(0)),
      [post, forum, message],
    );
  });

  test('a link previews what this device holds', () async {
    final root = await a.publish(
      'post',
      {'title': 'Best soup?', 'text': 'Asking for a friend'},
      space: 'cooking',
    );
    final link = Links.parse(Links.post('cooking', root.id))!;
    expect(Links.preview(a, link), 'Best soup?');
    // Not held, so nothing to show.
    expect(Links.preview(b, link), isNull);
    // The wrong space does not borrow another's post.
    expect(
      Links.preview(a, Links.parse(Links.post('baking', root.id))!),
      isNull,
    );
  });
}
