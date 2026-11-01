import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ournet_core/ournet_core.dart';

/// Where proposals can be made: a followed public forum or a private group.
class _Place {
  final String space;
  final String label;

  /// The group's room record; null for a public forum.
  final EverydayItem? room;
  const _Place(this.space, this.label, [this.room]);
}

class _Loaded {
  final SignedObject proposal;
  final Json data;
  final LiquidTally tally;
  final Json? checkpoint;
  const _Loaded(this.proposal, this.data, this.tally, this.checkpoint);
}

/// Proposals voted on with liquid delegation: see `Liquid` in core.
///
/// Reads on open and when proposals, ballots or delegations arrive; a
/// tally costs the space's ballots and delegations, not all of history.
class LiquidPage extends StatefulWidget {
  final Node node;
  final String Function(String person) name;
  final List<String> friends;
  const LiquidPage({
    super.key,
    required this.node,
    required this.name,
    required this.friends,
  });

  @override
  State<LiquidPage> createState() => _LiquidPageState();
}

class _LiquidPageState extends State<LiquidPage> {
  late final liquid = Liquid(widget.node);
  late final StreamSubscription<Set<String>> _changes;
  List<_Place> places = [];
  String? space;
  List<String> members = [];
  List<_Loaded> proposals = [];
  Map<String, Map<String, LiquidDelegation?>> delegations = {};
  final _contacts = <String, int>{};

  /// Counts only people with at least this many contacts when above 0.
  int minContacts = 0;
  bool loading = true;
  bool _again = false;
  Future<void>? _loading;

  Node get node => widget.node;
  String get me => node.person;
  _Place? get place => places.where((p) => p.space == space).firstOrNull;
  List<String> get audience => place?.room == null ? const [] : members;

  @override
  void initState() {
    super.initState();
    _changes = node.onChangesTo({
      Liquid.proposalKind,
      Liquid.ballotKind,
      Liquid.delegationKind,
      Liquid.tallyKind,
      'room',
      'friends',
    }, reload);
    reload();
  }

  @override
  void dispose() {
    _changes.cancel();
    super.dispose();
  }

  /// Reloads, once more if asked again meanwhile.
  void reload() {
    _again = true;
    _loading ??= () async {
      try {
        while (_again && mounted) {
          _again = false;
          await _load();
        }
      } finally {
        _loading = null;
      }
    }();
  }

  bool _isForum(String s) =>
      PublicNames.isForumSpace(s) && Walls.ownerOf(s) == null;

  Future<void> _load() async {
    final everyday = Everyday(node);
    final rooms = await everyday.rooms();
    final found = [
      for (final s in node.subscriptions.where(_isForum).toList()..sort())
        _Place(s, s),
      for (final r in rooms)
        _Place(r.object.space, '${r.data['name']} · group', r),
    ];
    final chosen = found.any((p) => p.space == space)
        ? space
        : found.firstOrNull?.space;
    final room = found.where((p) => p.space == chosen).firstOrNull?.room;
    final members = room == null ? <String>[] : await everyday.members(room);
    final loaded = <_Loaded>[];
    var delegations = <String, Map<String, LiquidDelegation?>>{};
    if (chosen != null) {
      delegations = await liquid.delegations(chosen);
      for (final (o, p) in await liquid.proposals(chosen)) {
        loaded.add(
          _Loaded(
            o,
            p,
            await liquid.tally(
              o,
              electorate: room == null ? null : members.toSet(),
            ),
            await liquid.latestCheckpoint(o),
          ),
        );
      }
    }
    _contacts.clear();
    if (!mounted) return;
    setState(() {
      places = found;
      space = chosen;
      this.members = members;
      proposals = loaded;
      this.delegations = delegations;
      loading = false;
    });
  }

  int contacts(String person) => _contacts[person] ??= liquid.contacts(person);

  bool counted(LiquidVote v) =>
      minContacts == 0 || contacts(v.person) >= minContacts;

  Future<void> run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
    reload();
  }

  /// People who could represent someone here: friends, group members and
  /// anyone who has taken part in this space.
  List<String> get candidates {
    final all = <String>{
      ...widget.friends,
      ...members,
      ...delegations.keys,
      for (final l in proposals) ...l.tally.votes.keys,
      for (final l in proposals) l.proposal.author,
    }..remove(me);
    if (place?.room != null) all.retainAll(members);
    return all.toList()
      ..sort((a, b) => widget.name(a).compareTo(widget.name(b)));
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(12),
    children: [
      const Text(
        'Proposals',
        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
      ),
      const Text(
        'Vote yourself, or name representatives per topic who vote for you. '
        'Your own vote always overrides theirs.',
      ),
      const SizedBox(height: 8),
      if (loading) const LinearProgressIndicator(),
      if (!loading && places.isEmpty)
        const Text('Join a public forum or a group to see its proposals.'),
      if (places.isNotEmpty)
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            DropdownButton<String>(
              value: space,
              items: [
                for (final p in places)
                  DropdownMenuItem(value: p.space, child: Text(p.label)),
              ],
              onChanged: (s) {
                setState(() => space = s);
                reload();
              },
            ),
            FilledButton.icon(
              onPressed: () => newProposal(context),
              icon: const Icon(Icons.add),
              label: const Text('New proposal'),
            ),
            OutlinedButton.icon(
              onPressed: () => representatives(context),
              icon: const Icon(Icons.people_outline),
              label: const Text('My representatives'),
            ),
            DropdownButton<int>(
              value: minContacts,
              items: const [
                DropdownMenuItem(value: 0, child: Text('Count everyone')),
                DropdownMenuItem(
                  value: 2,
                  child: Text('Only accounts with 2+ contacts'),
                ),
                DropdownMenuItem(
                  value: 5,
                  child: Text('Only accounts with 5+ contacts'),
                ),
              ],
              onChanged: (v) => setState(() => minContacts = v ?? 0),
            ),
          ],
        ),
      for (final l in proposals) proposalCard(context, l),
    ],
  );

  Widget proposalCard(BuildContext context, _Loaded l) {
    final options = (l.data['options'] as List).cast<String>();
    final topic = l.data['topic'] as String;
    final closes = l.data['closes'] as int;
    final closed = closes != 0 && closes <= node.now();
    final tally = l.tally;
    final counts = tally.counts(counted);
    final all = tally.counts();
    final mine = tally.votes[me];
    final direct = mine != null && mine.direct;
    final weight = (tally.weights[me] ?? 0) - (direct ? 1 : 0);
    final weak = tally.votes.values.where((v) => contacts(v.person) <= 1);
    final theme = Theme.of(context);
    String status() {
      if (mine == null) {
        final rep = Liquid.representation(delegations, me, topic);
        return rep == null
            ? 'You have not voted and have no representative for this topic.'
            : rep.$2.to.isEmpty
            ? 'You have not voted; you chose no representative here.'
            : 'You have not voted, and your representatives have not either.';
      }
      final choice = mine.ballot.abstain
          ? 'abstain'
          : options[mine.ballot.choice!];
      return direct
          ? 'Your vote: $choice'
          : 'Your vote: $choice, via ${mine.chain.skip(1).map(widget.name).join(' → ')}';
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l.data['title'] as String? ?? l.data['text'] as String,
              style: theme.textTheme.titleMedium,
            ),
            Text(
              [
                if (topic.isNotEmpty) topic,
                'by ${widget.name(l.proposal.author)}',
                if (closes != 0)
                  '${closed ? 'closed' : 'closes'} '
                      '${DateTime.fromMillisecondsSinceEpoch(closes).toLocal().toString().substring(0, 16)}',
              ].join(' · '),
              style: theme.textTheme.bodySmall,
            ),
            if (l.data['title'] != null) ...[
              const SizedBox(height: 4),
              Text(l.data['text'] as String, maxLines: 6),
            ],
            const SizedBox(height: 8),
            for (final (i, option) in options.indexed)
              Row(
                children: [
                  Expanded(child: Text(option)),
                  Text(
                    minContacts == 0 || counts[i] == all[i]
                        ? '${all[i]}'
                        : '${counts[i]} (of ${all[i]})',
                  ),
                  const SizedBox(width: 8),
                  if (!closed)
                    direct && mine.ballot.choice == i
                        ? FilledButton(
                            onPressed: null,
                            child: const Text('Voted'),
                          )
                        : OutlinedButton(
                            onPressed: () =>
                                run(() => liquid.vote(l.proposal, i)),
                            child: const Text('Vote'),
                          ),
                ],
              ),
            Text(
              'Abstaining: ${tally.abstentions(counted)}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(status()),
            if (weight > 0)
              Text(
                'You represent $weight other ${weight == 1 ? 'person' : 'people'} here.',
              ),
            if (weak.isNotEmpty)
              Text(
                '${weak.length} of ${tally.votes.length} votes come from '
                'accounts with at most one known contact.',
                style: TextStyle(color: theme.colorScheme.error),
              ),
            if (l.checkpoint case final c?)
              Text(
                c['digest'] == tally.digest
                    ? 'The proposer’s count matches this device’s.'
                    : 'The proposer counted ${c['counts']} from records '
                          'that differ from this device’s.',
                style: theme.textTheme.bodySmall,
              ),
            Wrap(
              spacing: 8,
              children: [
                if (!closed && !(direct && mine.ballot.abstain))
                  TextButton(
                    onPressed: () => run(() => liquid.vote(l.proposal, null)),
                    child: const Text('Abstain'),
                  ),
                if (!closed && direct)
                  TextButton(
                    onPressed: () => run(() => liquid.clearVote(l.proposal)),
                    child: const Text('Let my representative vote'),
                  ),
                TextButton(
                  onPressed: () => showVoters(context, l, options),
                  child: const Text('Who voted'),
                ),
                if (l.proposal.author == me)
                  TextButton(
                    onPressed: () =>
                        run(() => liquid.checkpoint(l.proposal, tally)),
                    child: const Text('Publish my count'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> showVoters(
    BuildContext context,
    _Loaded l,
    List<String> options,
  ) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Who voted'),
      content: SizedBox(
        width: 520,
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final v
                in l.tally.votes.values.toList()
                  ..sort((a, b) => a.chain.length.compareTo(b.chain.length)))
              ListTile(
                dense: true,
                title: Text(
                  '${widget.name(v.person)}: '
                  '${v.ballot.abstain ? 'abstain' : options[v.ballot.choice!]}',
                ),
                subtitle: Text(
                  [
                    if (!v.direct)
                      'via ${v.chain.skip(1).map(widget.name).join(' → ')}',
                    '${contacts(v.person)} contacts',
                  ].join(' · '),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  );

  Future<void> newProposal(BuildContext context) async {
    final space = this.space;
    if (space == null) return;
    final title = TextEditingController(),
        text = TextEditingController(),
        topic = TextEditingController(),
        options = TextEditingController(text: 'Yes\nNo');
    int? days;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('New proposal'),
          content: SizedBox(
            width: 480,
            child: ListView(
              shrinkWrap: true,
              children: [
                TextField(
                  controller: title,
                  decoration: const InputDecoration(labelText: 'Title'),
                ),
                TextField(
                  controller: text,
                  minLines: 2,
                  maxLines: 6,
                  decoration: const InputDecoration(labelText: 'Details'),
                ),
                TextField(
                  controller: topic,
                  decoration: const InputDecoration(
                    labelText: 'Topic (optional)',
                    hintText: 'science/physics',
                  ),
                ),
                TextField(
                  controller: options,
                  minLines: 2,
                  maxLines: 10,
                  decoration: const InputDecoration(
                    labelText: 'Options, one per line (2 to 10)',
                  ),
                ),
                DropdownButton<int?>(
                  value: days,
                  items: const [
                    DropdownMenuItem(value: null, child: Text('Stays open')),
                    DropdownMenuItem(value: 1, child: Text('Closes in a day')),
                    DropdownMenuItem(value: 7, child: Text('Closes in a week')),
                    DropdownMenuItem(
                      value: 30,
                      child: Text('Closes in a month'),
                    ),
                  ],
                  onChanged: (v) => setDialog(() => days = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Propose'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final path = Liquid.topic(topic.text);
    final choices = options.text
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final body = text.text.trim().isEmpty
        ? title.text.trim()
        : text.text.trim();
    if (path == null ||
        choices.length < 2 ||
        choices.length > 10 ||
        body.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'A proposal needs some text, 2 to 10 options and a topic of '
              'at most 6 parts.',
            ),
          ),
        );
      }
      return;
    }
    await run(
      () => liquid.propose(
        space,
        title: title.text.trim().isEmpty ? null : title.text.trim(),
        text: body,
        topic: path,
        options: choices,
        closes: days == null ? null : DateTime.now().add(Duration(days: days!)),
        audience: audience,
      ),
    );
  }

  Future<void> representatives(BuildContext context) async {
    final space = this.space;
    if (space == null) return;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) {
          final mine = delegations[me] ?? const {};
          final topics = mine.keys.where((t) => mine[t] != null).toList()
            ..sort();
          return AlertDialog(
            title: const Text('My representatives'),
            content: SizedBox(
              width: 520,
              child: ListView(
                shrinkWrap: true,
                children: [
                  const Text(
                    'A topic’s representatives also cover the topics under '
                    'it, unless you set those separately. If your first '
                    'choice does not vote, the next one is asked.',
                  ),
                  if (topics.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('Nobody represents you here yet.'),
                    ),
                  for (final t in topics)
                    ListTile(
                      title: Text(t.isEmpty ? 'Everything' : t),
                      subtitle: Text(
                        mine[t]!.to.isEmpty
                            ? 'Nobody (I vote myself)'
                            : [
                                mine[t]!.to.map(widget.name).join(', then '),
                                if (!mine[t]!.transitive)
                                  'their own votes only',
                              ].join(' · '),
                      ),
                      trailing: IconButton(
                        tooltip: 'Remove',
                        icon: const Icon(Icons.close),
                        onPressed: () async {
                          await run(
                            () => liquid.clearDelegation(
                              space,
                              t,
                              audience: audience,
                            ),
                          );
                          await _loading;
                          setDialog(() {});
                        },
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
              FilledButton(
                onPressed: () async {
                  await addRepresentative(context, space);
                  await _loading;
                  setDialog(() {});
                },
                child: const Text('Add'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> addRepresentative(BuildContext context, String space) async {
    final topic = TextEditingController();
    final chosen = <String>[];
    var transitive = true;
    final people = candidates;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('Choose representatives'),
          content: SizedBox(
            width: 480,
            child: ListView(
              shrinkWrap: true,
              children: [
                TextField(
                  controller: topic,
                  decoration: const InputDecoration(
                    labelText: 'Topic (empty for everything)',
                    hintText: 'science/physics',
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  chosen.isEmpty
                      ? 'Nobody chosen: this topic will not be delegated.'
                      : 'In order: ${chosen.map(widget.name).join(', then ')}',
                ),
                CheckboxListTile(
                  value: transitive,
                  onChanged: (v) => setDialog(() => transitive = v ?? true),
                  title: const Text(
                    'Let them pass my vote on to their own representatives',
                  ),
                ),
                for (final p in people)
                  CheckboxListTile(
                    value: chosen.contains(p),
                    onChanged: chosen.length >= 3 && !chosen.contains(p)
                        ? null
                        : (v) => setDialog(
                            () => v == true ? chosen.add(p) : chosen.remove(p),
                          ),
                    title: Text(widget.name(p)),
                    subtitle: Text('${contacts(p)} contacts'),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final path = Liquid.topic(topic.text);
    if (path == null) return;
    await run(
      () => liquid.delegate(
        space,
        path,
        chosen,
        transitive: transitive,
        audience: audience,
      ),
    );
  }
}
