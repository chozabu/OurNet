import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';
import 'enrolment_test.dart' show enrol;

Future<Node> person() async {
  final n = Node(await LocalIdentity.create(), Store());
  addTearDown(n.close);
  return n;
}

Future<void> connect(Node a, Node b) async {
  await a.addContact(b.identity.certificate);
  await b.addContact(a.identity.certificate);
}

void follow(Iterable<Node> nodes, List<String> spaces) {
  for (final n in nodes) {
    for (final s in spaces) {
      n.subscribe(s, true);
    }
  }
}

/// Blocking in some spaces, muting and public block lists: see BlockPolicy.
void main() {
  test('a block in one forum hides and stops relaying there only', () async {
    final a = await person(), b = await person(), c = await person();
    await connect(a, b);
    await connect(b, c);
    follow([a, b, c], ['cooking', 'gardening']);
    final soup = await a.publish('post', {'text': 'soup'}, space: 'cooking');
    final roses = await a.publish('post', {
      'text': 'roses',
    }, space: 'gardening');

    await b.blocks.setScope(a.person, ['cooking'], ScopeState.block);
    expect(b.blocks.blockedIn(a.person, 'cooking'), isTrue);
    expect(b.blocks.blockedIn(a.person, 'gardening'), isFalse);
    expect(b.blocked, isEmpty, reason: 'not blocked everywhere');
    await syncPair(a, b);
    expect(b.store.get(soup.id), isNull);
    expect(b.store.get(roses.id), isNotNull);
    expect(b.visible(roses), isTrue);

    // Not passed on in that forum either.
    await syncPair(b, c);
    expect(c.store.get(soup.id), isNull);
    expect(c.store.get(roses.id), isNotNull);

    // Still connected: direct messages arrive.
    expect(b.allowedPeer(a.identity.device), isTrue);
    final dm = await a.publish(
      'message',
      {'text': 'hi'},
      audience: [b.person],
      space: '_messages',
    );
    await syncPair(a, b);
    expect(await b.content(dm), isNotNull);

    // Lifting it takes the forum's posts in again.
    await b.blocks.setScope(a.person, ['cooking'], ScopeState.none);
    await syncPair(a, b);
    expect(b.store.get(soup.id), isNotNull);
    expect(b.visible(soup), isTrue);
  });

  test(
    'something already held is hidden once its author is blocked there',
    () async {
      final a = await person(), b = await person();
      await connect(a, b);
      follow([a, b], ['cooking']);
      final soup = await a.publish('post', {'text': 'soup'}, space: 'cooking');
      await syncPair(a, b);
      final version = b.blocks.version;
      await b.blocks.setScope(a.person, ['cooking'], ScopeState.block);
      expect(b.blocks.version, isNot(version));
      expect(b.visible(soup), isFalse);
      expect(await b.content(soup), isNull);
    },
  );

  test('a mute hides but still relays and stays connected', () async {
    final a = await person(), b = await person(), c = await person();
    await connect(a, b);
    await connect(b, c);
    follow([a, b, c], ['cooking', 'gardening']);
    final soup = await a.publish('post', {'text': 'soup'}, space: 'cooking');
    final roses = await a.publish('post', {
      'text': 'roses',
    }, space: 'gardening');

    await b.blocks.setScope(a.person, ['cooking'], ScopeState.mute);
    await syncPair(a, b);
    await syncPair(b, c);
    expect(b.store.get(soup.id), isNotNull);
    expect(b.visible(soup), isTrue, reason: 'readable, only hidden');
    expect(b.blocks.hides(soup), isTrue);
    expect(b.blocks.hides(roses), isFalse);
    expect(c.store.get(soup.id), isNotNull, reason: 'still passed on');

    await b.blocks.setScope(a.person, ['*'], ScopeState.mute);
    expect(b.blocks.hides(roses), isTrue);
    expect(b.blocks.hiddenAuthors('gardening'), contains(a.person));

    b.blocks.showAnyway(roses.id);
    expect(b.blocks.hides(roses), isFalse);

    await b.blocks.setScope(a.person, ['*', 'cooking'], ScopeState.none);
    expect(b.blocks.hides(soup), isFalse);
    expect(b.blocks.scopesOf(a.person), isEmpty);
  });

  test(
    'scoped choices and list subscriptions hold on every own device',
    () async {
      final laptop = await person(),
          other = await person(),
          owner = await person();
      await connect(laptop, other);
      final phone = await enrol(laptop);
      addTearDown(phone.close);
      await syncPair(laptop, phone);

      await laptop.blocks.setScope(other.person, ['cooking'], ScopeState.block);
      await laptop.blocks.setScope(other.person, ['*'], ScopeState.mute);
      await laptop.blocks.subscribe(owner.person, 'spam', mode: ListMode.block);
      await syncPair(laptop, phone);
      expect(phone.blocks.blockedIn(other.person, 'cooking'), isTrue);
      expect(phone.blocks.mutedIn(other.person, 'anywhere'), isTrue);
      expect(phone.blocks.subscriptions, {
        (owner.person, 'spam'): ListMode.block,
      });
      expect(
        phone.subscriptions,
        contains(BlockPolicy.space(owner.person, 'spam')),
      );

      // Newest wins: an older choice arriving later changes nothing.
      await phone.blocks.setScope(other.person, ['cooking'], ScopeState.none);
      await phone.blocks.unsubscribe(owner.person, 'spam');
      await syncPair(phone, laptop);
      expect(laptop.blocks.blockedIn(other.person, 'cooking'), isFalse);
      expect(laptop.blocks.subscriptions, isEmpty);
      expect(
        laptop.subscriptions,
        isNot(contains(BlockPolicy.space(owner.person, 'spam'))),
      );

      // Reopening keeps them.
      final reopened = Node(laptop.identity, laptop.store);
      expect(reopened.blocks.mutedIn(other.person, 'x'), isTrue);
    },
  );

  test(
    'in a private group a block only hides, so others still get it',
    () async {
      final a = await person(), b = await person();
      await connect(a, b);
      const group = 'room2:owner:group';
      await b.blocks.setScope(a.person, [group], ScopeState.block);
      expect(b.blocks.blockedIn(a.person, group), isTrue);
      expect(b.blocks.relays(a.person, group), isTrue);
      expect(b.blocks.relays(a.person, 'cooking'), isTrue);
      await b.setContactState(a.person, ContactState.blocked);
      expect(b.blocks.relays(a.person, group), isFalse);
    },
  );

  test('block lists hide or block, never friends or the allowed', () async {
    // The list's owner, a stranger on it, the subscriber, and a friend of
    // the subscriber who is on it too. The stranger's posts reach the
    // subscriber through a relay.
    final owner = await person(), stranger = await person();
    final relay = await person(), me = await person(), pal = await person();
    await connect(owner, me);
    await connect(stranger, relay);
    await connect(relay, me);
    await connect(me, pal);
    follow([stranger, relay, me], ['cooking']);

    final slug = await owner.blocks.saveList(
      'Spam accounts',
      description: 'Sellers',
    );
    expect(slug, 'spam-accounts');
    await owner.blocks.addEntry(slug, stranger.person, reason: 'Ads');
    await owner.blocks.addEntry(slug, pal.person, spaces: ['cooking']);
    expect(owner.blocks.entries(owner.person, slug).length, 2);
    expect(BlockPolicy.parseLink(BlockPolicy.link(owner.person, slug)), (
      owner.person,
      slug,
    ));

    await me.blocks.subscribe(owner.person, slug);
    await syncPair(owner, me);
    expect(me.blocks.listInfo(owner.person, slug)?.name, 'Spam accounts');

    final ad = await stranger.publish('post', {
      'text': 'buy',
    }, space: 'cooking');
    await syncPair(stranger, relay);
    await syncPair(relay, me);
    expect(me.store.get(ad.id), isNotNull, reason: 'hide mode still takes it');
    final hit = me.blocks.listHidden(stranger.person, 'cooking');
    expect(hit?.entry.reason, 'Ads');
    expect(hit?.mode, ListMode.hide);
    expect(me.blocks.hides(ad), isTrue);
    expect(me.visible(ad), isTrue);

    // An admitted friend is only flagged, never hidden.
    expect(me.blocks.listHits(pal.person, 'cooking'), hasLength(1));
    expect(me.blocks.listHidden(pal.person, 'cooking'), isNull);

    // Allowing someone beats every list.
    await me.blocks.setScope(stranger.person, ['*'], ScopeState.allow);
    expect(me.blocks.hides(ad), isFalse);
    await me.blocks.setScope(stranger.person, ['*'], ScopeState.none);
    expect(me.blocks.hides(ad), isTrue);

    // Block mode keeps new posts out.
    await me.blocks.subscribe(owner.person, slug, mode: ListMode.block);
    final again = await stranger.publish('post', {
      'text': 'buy more',
    }, space: 'cooking');
    await syncPair(stranger, relay);
    await syncPair(relay, me);
    expect(me.store.get(again.id), isNull);

    // Taking someone off the list lets them back.
    await owner.blocks.removeEntry(slug, stranger.person);
    await syncPair(owner, me);
    expect(me.blocks.listHits(stranger.person), isEmpty);

    await me.blocks.unsubscribe(owner.person, slug);
    expect(me.blocks.listHits(pal.person), isEmpty);
    expect(
      me.subscriptions,
      isNot(contains(BlockPolicy.space(owner.person, slug))),
    );
  });

  test('only a list owner writes to their list', () async {
    final owner = await person(), other = await person();
    final list = BlockPolicy.space(owner.person, 'spam');
    final forged = await other.publish('block_entry', {
      'person': owner.person,
      'scope': '*',
    }, space: list);
    expect(BlockPolicy.accepted(forged), isFalse);
    expect(PublicNames.isForumSpace(list), isFalse);
  });

  test('the new kinds are checked', () {
    expect(
      validContent('block_scope', {
        'person': 'p',
        'spaces': ['cooking'],
        'mute': true,
      }),
      isTrue,
    );
    expect(
      validContent('block_scope', {
        'person': 'p',
        'spaces': ['cooking'],
        'allow': true,
      }),
      isFalse,
      reason: 'allowing is everywhere',
    );
    expect(
      validContent('block_scope', {'person': 'p', 'spaces': <String>[]}),
      isFalse,
    );
    expect(
      validContent('block_sub', {'owner': 'o', 'list': 'spam', 'mode': 'hide'}),
      isTrue,
    );
    expect(
      validContent('block_sub', {
        'owner': 'o',
        'list': 'Not A Slug',
        'mode': 'hide',
      }),
      isFalse,
    );
    expect(
      validContent('block_entry', {
        'person': 'p',
        'scope': ['cooking'],
        'evidence': List.filled(17, 'id'),
      }),
      isFalse,
    );
    expect(validContent('block_list', {'name': 'Spam'}), isTrue);
  });

  group('liquid voting', () {
    LiquidBallot ballot(String id, int choice) => LiquidBallot(id, choice);

    test(
      'a blocked ballot does not count and a blocked delegate is skipped',
      () {
        final t = Liquid.resolve(
          topic: '',
          options: 2,
          ballots: {'blocked': ballot('x', 0), 'next': ballot('y', 1)},
          delegations: {
            'me': {
              '': const LiquidDelegation('d', ['blocked', 'next']),
            },
            'only': {
              '': const LiquidDelegation('e', ['blocked']),
            },
          },
          excluded: (p) => p == 'blocked',
        );
        expect(t.votes.containsKey('blocked'), isFalse);
        expect(t.votes['me']!.voter, 'next');
        expect(t.votes.containsKey('only'), isFalse);
        expect(t.counts(), [0, 2]);
      },
    );

    test('a tally leaves out people blocked in its space', () async {
      final me = await person(), bad = await person(), good = await person();
      final voter = await person();
      for (final other in [bad, good, voter]) {
        await connect(me, other);
      }
      follow([me, bad, good, voter], ['town']);
      final liquid = Liquid(me);
      final proposal = await liquid.propose('town', text: 'Paint it?');
      for (final other in [bad, good, voter]) {
        await syncPair(me, other);
      }
      await Liquid(bad).vote(proposal, 0);
      await Liquid(good).vote(proposal, 1);
      await Liquid(voter).delegate('town', '', [bad.person, good.person]);
      for (final other in [bad, good, voter]) {
        await syncPair(other, me);
      }
      var tally = await liquid.tally(proposal);
      expect(tally.counts(), [2, 1]);
      expect(tally.excluded, isEmpty);

      await me.blocks.setScope(bad.person, ['town'], ScopeState.block);
      tally = await liquid.tally(proposal);
      expect(tally.counts(), [0, 2]);
      expect(tally.votes[voter.person]!.voter, good.person);
      expect(tally.excluded, {bad.person});
    });
  });
}
