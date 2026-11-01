import 'model.dart';
import 'node.dart';
import 'public_names.dart';

/// A person's latest ballot on one proposal.
class LiquidBallot {
  final String id;

  /// The option chosen, or null for an abstention.
  final int? choice;
  const LiquidBallot(this.id, this.choice);
  bool get abstain => choice == null;
}

/// A person's latest delegation for one topic: ranked representatives,
/// empty for "nobody here". [transitive] false counts a representative's own
/// ballot only, not whoever they delegate to.
class LiquidDelegation {
  final String id;
  final List<String> to;
  final bool transitive;
  const LiquidDelegation(this.id, this.to, {this.transitive = true});
}

/// How one person's vote was decided: [chain] runs from them to the person
/// whose ballot counts (just them for a direct ballot).
class LiquidVote {
  final List<String> chain;
  final LiquidBallot ballot;
  const LiquidVote(this.chain, this.ballot);
  String get person => chain.first;
  String get voter => chain.last;
  bool get direct => chain.length == 1;
}

/// The result of resolving every ballot and delegation for one proposal.
class LiquidTally {
  /// Everyone whose vote resolved to a ballot (abstentions included).
  final Map<String, LiquidVote> votes;
  final int options;

  /// Hash of the ballots and delegations the count used: two devices with
  /// the same digest counted the same records.
  final String digest;

  LiquidTally(this.votes, this.options, this.digest);

  /// Votes per option, counting only votes [where] allows: a lens such as
  /// "people with at least two contacts", never a change to the record.
  List<int> counts([bool Function(LiquidVote)? where]) {
    final c = List.filled(options, 0);
    for (final v in votes.values) {
      final choice = v.ballot.choice;
      if (choice != null && choice < options && (where?.call(v) ?? true)) {
        c[choice]++;
      }
    }
    return c;
  }

  int abstentions([bool Function(LiquidVote)? where]) => votes.values
      .where((v) => v.ballot.abstain && (where?.call(v) ?? true))
      .length;

  /// How many people each voter's ballot counts for, themselves included.
  Map<String, int> get weights {
    final w = <String, int>{};
    for (final v in votes.values) {
      w[v.voter] = (w[v.voter] ?? 0) + 1;
    }
    return w;
  }
}

/// Liquid democracy for public forums and private groups.
///
/// A `proposal` in a forum's or group's space asks a question with 2 to 10
/// options, under a topic path such as `science/physics` (empty for the whole
/// space). Anyone who can read it votes with a `ballot`: an option, an
/// abstention, or `clear` to hand the vote back to their representatives.
///
/// A `delegation` names up to three ranked representatives for a topic and
/// everything under it, or nobody (`to: []`, which stops inheritance), or is
/// `clear`ed to inherit from the parent topic again. For a proposal in topic
/// T a person's vote is, in order:
///
/// 1. their own ballot, if they cast one (manual always overrides);
/// 2. otherwise the delegation at T or its nearest set ancestor, whose
///    representatives are tried in rank order, each resolved the same way
///    on the same proposal (so a representative's own delegation for T
///    applies), the first that yields a ballot counting;
/// 3. otherwise nothing: they are not counted.
///
/// Anyone already reached while resolving one person is not tried again, so
/// cycles end. Two people who delegate to each other are covered by
/// whichever of them votes; if neither does, neither counts.
///
/// Each person's latest ballot or delegation counts. When a proposal
/// `closes`, records signed after then are ignored. Signed times can be
/// backdated, so the proposer may publish a `tally` with the [LiquidTally.digest]
/// of what they counted; others compare it with their own.
///
/// Every record is public in a public forum, and sealed to the members in a
/// group, as the group's forum posts are. Nothing is hidden or dropped for
/// looking suspicious: [LiquidTally.counts] takes filters (contacts, distance)
/// so people can see how much of a result rests on weakly connected accounts.
class Liquid {
  static const proposalKind = 'proposal';
  static const ballotKind = 'ballot';
  static const delegationKind = 'delegation';
  static const tallyKind = 'tally';

  final Node node;
  Liquid(this.node);

  /// [name] as a topic path: each `/`-separated part as a public name, empty
  /// parts dropped. Null when a part has nothing left or there are too many.
  static String? topic(String name) {
    final parts = <String>[];
    for (final raw in name.split('/')) {
      if (raw.trim().isEmpty) continue;
      final s = PublicNames.slug(raw);
      if (s == null) return null;
      parts.add(s);
    }
    return parts.length > 6 ? null : parts.join('/');
  }

  /// [topic] and each topic above it, most specific first, ending with ''.
  static List<String> ancestry(String topic) {
    final parts = topic.isEmpty ? <String>[] : topic.split('/');
    return [for (var i = parts.length; i >= 0; i--) parts.take(i).join('/')];
  }

  Future<SignedObject> propose(
    String space, {
    required String text,
    String? title,
    String topic = '',
    List<String> options = const ['Yes', 'No'],
    DateTime? closes,
    List<String> audience = const [],
  }) => node.publish(
    proposalKind,
    {
      'text': text,
      'title': ?title,
      'topic': topic,
      'options': options,
      'closes': closes?.millisecondsSinceEpoch ?? 0,
    },
    space: space,
    audience: audience,
  );

  /// Votes [choice] on [proposal], or abstains when [choice] is null.
  Future<SignedObject> vote(SignedObject proposal, int? choice) => node.publish(
    ballotKind,
    {
      'proposal': proposal.id,
      if (choice == null) 'abstain': true else 'choice': choice,
    },
    space: proposal.space,
    audience: proposal.audience,
  );

  /// Withdraws this person's own ballot, so their representatives decide.
  Future<SignedObject> clearVote(SignedObject proposal) => node.publish(
    ballotKind,
    {'proposal': proposal.id, 'clear': true},
    space: proposal.space,
    audience: proposal.audience,
  );

  /// Names representatives for [topic] in [space], in rank order. An empty
  /// list means nobody: this topic and those under it are not delegated.
  Future<SignedObject> delegate(
    String space,
    String topic,
    List<String> to, {
    bool transitive = true,
    List<String> audience = const [],
  }) => node.publish(
    delegationKind,
    {'topic': topic, 'to': to, if (!transitive) 'transitive': false},
    space: space,
    audience: audience,
  );

  /// Removes the delegation for [topic], so the parent topic's applies.
  Future<SignedObject> clearDelegation(
    String space,
    String topic, {
    List<String> audience = const [],
  }) => node.publish(
    delegationKind,
    {'topic': topic, 'clear': true},
    space: space,
    audience: audience,
  );

  /// Every object of [kind] in [space] this device can read with its
  /// payload, newest first.
  Future<List<(SignedObject, Json)>> _read(String kind, String space) async {
    final result = <(SignedObject, Json)>[];
    (int, String)? after;
    while (true) {
      final page = node.store.objects(
        kind: kind,
        space: space,
        after: after,
        limit: 1000,
      );
      for (final o in page) {
        final p = await node.content(o);
        if (p != null) result.add((o, p));
      }
      if (page.length < 1000) break;
      after = (page.last.created, page.last.id);
    }
    return result;
  }

  /// Proposals in [space], newest first.
  Future<List<(SignedObject, Json)>> proposals(String space) =>
      _read(proposalKind, space);

  /// Each person's latest delegation per topic in [space], ignoring any
  /// signed after [before] (when not 0).
  Future<Map<String, Map<String, LiquidDelegation?>>> delegations(
    String space, {
    int before = 0,
  }) async {
    final result = <String, Map<String, LiquidDelegation?>>{};
    for (final (o, p) in await _read(delegationKind, space)) {
      if (before != 0 && o.created > before) continue;
      final byTopic = result[o.author] ??= {};
      final topic = p['topic'] as String;
      if (byTopic.containsKey(topic)) continue;
      // A cleared topic is remembered as null, so older ones stay hidden.
      byTopic[topic] = p['clear'] == true
          ? null
          : LiquidDelegation(
              o.id,
              (p['to'] as List).cast<String>(),
              transitive: p['transitive'] != false,
            );
    }
    return result;
  }

  /// Who [person] is represented by for [topic], and the topic that set it:
  /// null when nothing applies.
  static (String, LiquidDelegation)? representation(
    Map<String, Map<String, LiquidDelegation?>> delegations,
    String person,
    String topic,
  ) {
    final mine = delegations[person];
    if (mine == null) return null;
    for (final t in ancestry(topic)) {
      if (mine[t] case final d?) return (t, d);
    }
    return null;
  }

  /// Resolves every vote on [proposal]. [electorate], when given, is who may
  /// vote (a group's members); records from anyone else are ignored, and
  /// representatives outside it are skipped like ones who did not vote.
  Future<LiquidTally> tally(
    SignedObject proposal, {
    Set<String>? electorate,
  }) async {
    final payload = await node.content(proposal) ?? const {};
    final closes = payload['closes'] as int? ?? 0;
    final topic = payload['topic'] as String? ?? '';
    final options = (payload['options'] as List? ?? const []).length;
    final ballots = <String, LiquidBallot?>{};
    for (final (o, p) in await _read(ballotKind, proposal.space)) {
      if (p['proposal'] != proposal.id) continue;
      if (closes != 0 && o.created > closes) continue;
      if (ballots.containsKey(o.author)) continue;
      ballots[o.author] = p['clear'] == true
          ? null
          : LiquidBallot(o.id, p['choice'] as int?);
    }
    final delegations = await this.delegations(proposal.space, before: closes);
    return resolve(
      topic: topic,
      options: options,
      ballots: {
        for (final MapEntry(:key, :value) in ballots.entries)
          if (value != null) key: value,
      },
      delegations: delegations,
      electorate: electorate,
    );
  }

  /// The pure part of [tally]: see the class comment for the rules.
  static LiquidTally resolve({
    required String topic,
    required int options,
    required Map<String, LiquidBallot> ballots,
    required Map<String, Map<String, LiquidDelegation?>> delegations,
    Set<String>? electorate,
  }) {
    bool eligible(String p) => electorate == null || electorate.contains(p);
    final used = <String>{};

    List<String>? walk(String person, Set<String> seen, bool follow) {
      if (!eligible(person) || !seen.add(person)) return null;
      if (ballots.containsKey(person)) return [person];
      if (!follow) return null;
      final rep = representation(delegations, person, topic);
      if (rep == null) return null;
      used.add(rep.$2.id);
      for (final next in rep.$2.to) {
        final rest = walk(next, seen, rep.$2.transitive);
        if (rest != null) return [person, ...rest];
      }
      return null;
    }

    final votes = <String, LiquidVote>{};
    for (final person in {...ballots.keys, ...delegations.keys}) {
      final chain = walk(person, {}, true);
      if (chain != null) {
        votes[person] = LiquidVote(chain, ballots[chain.last]!);
      }
    }
    final digest = hash(
      [
        ...{for (final v in votes.values) v.ballot.id},
        ...used,
      ]..sort(),
    );
    return LiquidTally(votes, options, digest);
  }

  /// Publishes the proposer's count of [proposal] as it stands here.
  Future<SignedObject> checkpoint(SignedObject proposal, LiquidTally tally) =>
      node.publish(
        tallyKind,
        {
          'proposal': proposal.id,
          'digest': tally.digest,
          'counts': tally.counts(),
          'abstain': tally.abstentions(),
          'voters': tally.votes.length,
        },
        space: proposal.space,
        audience: proposal.audience,
      );

  /// The proposer's latest checkpoint for [proposal], if one arrived.
  Future<Json?> latestCheckpoint(SignedObject proposal) async {
    for (final (o, p) in await _read(tallyKind, proposal.space)) {
      if (o.author == proposal.author && p['proposal'] == proposal.id) {
        return p;
      }
    }
    return null;
  }

  /// How many people [person] is linked to in the public friend graph, as
  /// far as this device knows: a signal for weakly connected accounts.
  int contacts(String person) => node.connections.neighbours(person).length;
}
