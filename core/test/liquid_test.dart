import 'package:test/test.dart';
import 'package:ournet_core/ournet_core.dart';

Future<Node> friend(Node a) async {
  final other = Node(await LocalIdentity.create(), Store());
  await a.addContact(other.identity.certificate);
  await other.addContact(a.identity.certificate);
  addTearDown(other.close);
  return other;
}

LiquidBallot b(int? choice) =>
    LiquidBallot('b$choice${choice.hashCode}', choice);
LiquidDelegation d(List<String> to, {bool transitive = true}) =>
    LiquidDelegation('d${to.join()}$transitive', to, transitive: transitive);

LiquidTally resolve(
  String topic,
  Map<String, LiquidBallot> ballots,
  Map<String, Map<String, LiquidDelegation?>> delegations, {
  Set<String>? electorate,
}) => Liquid.resolve(
  topic: topic,
  options: 2,
  ballots: ballots,
  delegations: delegations,
  electorate: electorate,
);

void main() {
  group('resolution', () {
    test('a direct ballot overrides any delegation', () {
      final t = resolve(
        '',
        {'a': b(1), 'r': b(0)},
        {
          'a': {
            '': d(['r']),
          },
        },
      );
      expect(t.votes['a']!.direct, isTrue);
      expect(t.counts(), [1, 1]);
    });

    test('topics inherit, override and can be set to nobody', () {
      final delegations = <String, Map<String, LiquidDelegation?>>{
        'a': {
          'science': d(['s']),
          'science/physics/quantum': d(['q']),
          'science/biology': d([]),
        },
      };
      final ballots = {'s': b(0), 'q': b(1)};
      expect(
        resolve('science/physics', ballots, delegations).votes['a']!.voter,
        's',
      );
      expect(
        resolve(
          'science/physics/quantum',
          ballots,
          delegations,
        ).votes['a']!.voter,
        'q',
      );
      expect(
        resolve('science/biology/cells', ballots, delegations).votes['a'],
        isNull,
      );
      expect(resolve('art', ballots, delegations).votes['a'], isNull);
      // A cleared topic falls back to its parent.
      delegations['a']!['science/physics/quantum'] = null;
      expect(
        resolve(
          'science/physics/quantum',
          ballots,
          delegations,
        ).votes['a']!.voter,
        's',
      );
    });

    test('representatives have their own representatives in subtopics', () {
      final t = resolve(
        'science/physics',
        {'c': b(1)},
        {
          'a': {
            'science': d(['b']),
          },
          'b': {
            'science/physics': d(['c']),
          },
        },
      );
      expect(t.votes['a']!.chain, ['a', 'b', 'c']);
      expect(t.weights, {'c': 3});
    });

    test('non-transitive delegation counts the representative alone', () {
      final delegations = {
        'a': {
          '': d(['b'], transitive: false),
        },
        'b': {
          '': d(['c']),
        },
      };
      expect(resolve('', {'c': b(1)}, delegations).votes['a'], isNull);
      expect(
        resolve('', {'b': b(0), 'c': b(1)}, delegations).votes['a']!.voter,
        'b',
      );
    });

    test('mutual and ring delegation: whoever votes covers the rest', () {
      final mutual = {
        'a': {
          '': d(['b']),
        },
        'b': {
          '': d(['a']),
        },
      };
      expect(resolve('', {}, mutual).votes, isEmpty);
      expect(resolve('', {'a': b(0)}, mutual).counts(), [2, 0]);
      expect(resolve('', {'b': b(1)}, mutual).counts(), [0, 2]);
      expect(resolve('', {'a': b(0), 'b': b(1)}, mutual).counts(), [1, 1]);
      final ring = {
        'a': {
          '': d(['b']),
        },
        'b': {
          '': d(['c']),
        },
        'c': {
          '': d(['a']),
        },
      };
      expect(resolve('', {'c': b(1)}, ring).counts(), [0, 3]);
    });

    test('ranked fallback tries the next representative', () {
      final delegations = {
        'a': {
          '': d(['b', 'c']),
        },
        'b': {
          '': d(['a']),
        },
      };
      final t = resolve('', {'c': b(0)}, delegations);
      expect(t.votes['a']!.chain, ['a', 'c']);
      // b reaches c through a's fallback.
      expect(t.votes['b']!.chain, ['b', 'a', 'c']);
    });

    test('abstaining counts for turnout and blocks delegation', () {
      final t = resolve(
        '',
        {'a': b(null), 'r': b(1)},
        {
          'a': {
            '': d(['r']),
          },
        },
      );
      expect(t.counts(), [0, 1]);
      expect(t.abstentions(), 1);
    });

    test('only the electorate counts, and filters are lenses', () {
      final t = resolve(
        '',
        {'r': b(1), 'x': b(0)},
        {
          'a': {
            '': d(['x', 'r']),
          },
        },
        electorate: {'a', 'r'},
      );
      expect(t.votes['a']!.voter, 'r');
      expect(t.counts(), [0, 2]);
      expect(t.counts((v) => v.direct), [0, 1]);
    });

    test('the digest depends only on what was counted', () {
      final ballots = {'r': b(1)};
      final delegations = {
        'a': {
          '': d(['r']),
        },
      };
      expect(
        resolve('', ballots, delegations).digest,
        resolve('', {...ballots}, {...delegations}).digest,
      );
      expect(
        resolve('', ballots, delegations).digest,
        isNot(resolve('', ballots, {}).digest),
      );
    });
  });

  test('topic names become paths', () {
    expect(
      Liquid.topic(' Science / Quantum Physics/'),
      'science/quantum-physics',
    );
    expect(Liquid.topic(''), '');
    expect(Liquid.topic('a/b/c/d/e/f/g'), isNull);
    expect(Liquid.ancestry('a/b'), ['a/b', 'a', '']);
  });

  test('in a public forum, votes and delegations sync and resolve', () async {
    final a = Node(await LocalIdentity.create(), Store());
    addTearDown(a.close);
    final bob = await friend(a);
    const space = 'liquid-test';
    a.subscribe(space, true);
    bob.subscribe(space, true);
    final la = Liquid(a), lb = Liquid(bob);
    final proposal = await la.propose(
      space,
      title: 'Buy a telescope?',
      text: 'For the club',
      topic: 'science/astronomy',
    );
    await la.delegate(space, 'science', [bob.person]);
    await syncPair(a, bob);
    final theirs = bob.store.get(proposal.id)!;
    await lb.vote(theirs, 0);
    await syncPair(a, bob);
    var tally = await la.tally(proposal);
    expect(tally.counts(), [2, 0]);
    expect(tally.votes[a.person]!.chain, [a.person, bob.person]);

    // Voting by hand overrides; clearing hands the vote back.
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await la.vote(proposal, 1);
    expect((await la.tally(proposal)).counts(), [1, 1]);
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await la.clearVote(proposal);
    tally = await la.tally(proposal);
    expect(tally.counts(), [2, 0]);

    // The proposer's checkpoint matches what the other side counts.
    await la.checkpoint(proposal, tally);
    await syncPair(a, bob);
    final checkpoint = (await lb.latestCheckpoint(theirs))!;
    expect(checkpoint['digest'], (await lb.tally(theirs)).digest);
    expect(checkpoint['counts'], [2, 0]);
  });

  test('records after a proposal closes do not count', () async {
    final a = Node(await LocalIdentity.create(), Store());
    addTearDown(a.close);
    final la = Liquid(a);
    final proposal = await la.propose(
      'general',
      text: 'Closed',
      closes: DateTime.now().add(const Duration(milliseconds: 20)),
    );
    await la.vote(proposal, 0);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await la.vote(proposal, 1);
    expect((await la.tally(proposal)).counts(), [1, 0]);
  });

  test('in a private group, records are sealed to its members', () async {
    final a = Node(await LocalIdentity.create(), Store());
    addTearDown(a.close);
    final bob = await friend(a);
    final outsider = await friend(a);
    final room = await Everyday(a).createRoom('Club', [bob.person]);
    final members = (room.data['members'] as List).cast<String>();
    final la = Liquid(a);
    final proposal = await la.propose(
      room.object.space,
      text: 'Meet on Friday?',
      audience: members,
    );
    await la.delegate(room.object.space, '', [bob.person], audience: members);
    await syncPair(a, bob);
    await syncPair(a, outsider);
    expect(outsider.store.objects(kind: Liquid.proposalKind), isEmpty);
    final lb = Liquid(bob);
    await lb.vote(bob.store.get(proposal.id)!, 1);
    await syncPair(a, bob);
    final tally = await la.tally(proposal, electorate: members.toSet());
    expect(tally.counts(), [0, 2]);
  });
}
