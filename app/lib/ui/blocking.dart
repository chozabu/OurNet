import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ournet_core/ournet_core.dart';

/// A person's display name.
typedef NameOf = String Function(String person);

/// How [space] reads in a sentence: "cooking", "the cooking chat", "Sam's
/// wall", "this group".
String blockSpaceLabel(String space, NameOf name) {
  if (space.startsWith(PublicChats.prefix)) {
    return 'the ${space.substring(PublicChats.prefix.length)} chat';
  }
  if (Walls.ownerOf(space) case final owner?) return "${name(owner)}'s wall";
  if (space.startsWith('room2:')) return 'this group';
  return space.startsWith('forum2:') ? 'this forum' : space;
}

void _notice(BuildContext context, String text) => ScaffoldMessenger.maybeOf(
  context,
)?.showSnackBar(SnackBar(content: Text(text)));

/// Runs [action], reporting a failure instead of throwing.
Future<void> _attempt(
  BuildContext context,
  Future<void> Function() action, {
  String? done,
}) async {
  try {
    await action();
    if (done != null && context.mounted) _notice(context, done);
  } catch (e) {
    if (context.mounted) _notice(context, 'Could not do that: $e');
  }
}

/// Block, mute and list choices for [person], from their details or a
/// message's menu. [space] is where the message was, for choices that
/// apply only there. [setBlocked] blocks or unblocks everywhere.
Future<void> showBlockChoices(
  BuildContext context,
  Node node,
  String person, {
  String? space,
  required NameOf name,
  required Future<void> Function(String person, bool block) setBlocked,
}) async {
  final who = name(person);
  final blocks = node.blocks;
  final everywhere = node.blocked.contains(person);
  final here = space == null ? null : blockSpaceLabel(space, name);
  final scopeHere = space == null
      ? ScopeState.none
      : blocks.scopeOf(person, space);
  final mutedEverywhere =
      blocks.scopeOf(person, BlockPolicy.everywhere) == ScopeState.mute;
  final hits = blocks.listHits(person);
  final allowed = blocks.allowed(person);
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          ListTile(
            title: Text(who, style: Theme.of(sheet).textTheme.titleMedium),
            subtitle: const Text(
              'Blocking hides them and stops passing on what they write. '
              'Muting only hides them. Either way you stay connected.',
            ),
          ),
          for (final h in hits)
            ListTile(
              leading: const Icon(Icons.flag_outlined),
              title: Text(
                "On ${name(h.entry.owner)}'s "
                '${blocks.listInfo(h.entry.owner, h.entry.list)?.name ?? h.entry.list} list',
              ),
              subtitle: h.entry.reason == null ? null : Text(h.entry.reason!),
            ),
          ListTile(
            leading: Icon(everywhere ? Icons.undo : Icons.block),
            title: Text(everywhere ? 'Unblock everywhere' : 'Block everywhere'),
            onTap: () => Navigator.pop(sheet, 'everywhere'),
          ),
          if (here != null && !everywhere)
            ListTile(
              leading: Icon(
                scopeHere == ScopeState.block ? Icons.undo : Icons.block,
              ),
              title: Text(
                scopeHere == ScopeState.block
                    ? 'Unblock in $here'
                    : 'Block in $here only',
              ),
              onTap: () => Navigator.pop(sheet, 'blockHere'),
            ),
          if (here != null && !everywhere && !mutedEverywhere)
            ListTile(
              leading: Icon(
                scopeHere == ScopeState.mute
                    ? Icons.volume_up_outlined
                    : Icons.volume_off_outlined,
              ),
              title: Text(
                scopeHere == ScopeState.mute
                    ? 'Unmute in $here'
                    : 'Mute in $here',
              ),
              onTap: () => Navigator.pop(sheet, 'muteHere'),
            ),
          if (!everywhere)
            ListTile(
              leading: Icon(
                mutedEverywhere
                    ? Icons.volume_up_outlined
                    : Icons.volume_off_outlined,
              ),
              title: Text(
                mutedEverywhere ? 'Unmute everywhere' : 'Mute everywhere',
              ),
              onTap: () => Navigator.pop(sheet, 'muteEverywhere'),
            ),
          if (hits.isNotEmpty || allowed)
            ListTile(
              leading: Icon(allowed ? Icons.undo : Icons.verified_outlined),
              title: Text(
                allowed
                    ? 'Let block lists hide them again'
                    : 'Always allow (block lists never hide them)',
              ),
              onTap: () => Navigator.pop(sheet, 'allow'),
            ),
          ListTile(
            leading: const Icon(Icons.playlist_add),
            title: const Text('Add to my public block list…'),
            onTap: () => Navigator.pop(sheet, 'list'),
          ),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  switch (choice) {
    case 'everywhere':
      await setBlocked(person, !everywhere);
    case 'blockHere':
      await _attempt(
        context,
        () => blocks.setScope(person, [
          space!,
        ], scopeHere == ScopeState.block ? ScopeState.none : ScopeState.block),
        done: scopeHere == ScopeState.block
            ? 'Unblocked $who in $here'
            : 'Blocked $who in $here',
      );
    case 'muteHere':
      await _attempt(
        context,
        () => blocks.setScope(person, [
          space!,
        ], scopeHere == ScopeState.mute ? ScopeState.none : ScopeState.mute),
        done: scopeHere == ScopeState.mute
            ? 'Unmuted $who in $here'
            : 'Muted $who in $here',
      );
    case 'muteEverywhere':
      await _attempt(
        context,
        () => blocks.setScope(person, [
          BlockPolicy.everywhere,
        ], mutedEverywhere ? ScopeState.none : ScopeState.mute),
        done: mutedEverywhere ? 'Unmuted $who' : 'Muted $who everywhere',
      );
    case 'allow':
      await _attempt(
        context,
        () => blocks.setScope(person, [
          BlockPolicy.everywhere,
        ], allowed ? ScopeState.none : ScopeState.allow),
      );
    case 'list':
      await addToBlockList(context, node, person, space: space, name: name);
  }
}

/// Asks which of this person's public lists to put [person] on (or a new
/// one), why, and whether only in [space]; then publishes the entry.
Future<void> addToBlockList(
  BuildContext context,
  Node node,
  String person, {
  String? space,
  required NameOf name,
}) async {
  final lists = node.blocks.listsOf(node.person);
  final listName = TextEditingController(text: lists.isEmpty ? 'Blocked' : '');
  final reason = TextEditingController();
  String? chosen = lists.firstOrNull?.list;
  var onlyHere = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialog) => StatefulBuilder(
      builder: (dialog, setState) => AlertDialog(
        title: Text('Add ${name(person)} to a public list'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Anyone who subscribes to the list can hide or block the '
                'people on it. The list and its reasons are public.',
              ),
              const SizedBox(height: 12),
              if (lists.isNotEmpty)
                DropdownButton<String?>(
                  isExpanded: true,
                  value: chosen,
                  items: [
                    for (final l in lists)
                      DropdownMenuItem(value: l.list, child: Text(l.name)),
                    const DropdownMenuItem(
                      value: null,
                      child: Text('New list…'),
                    ),
                  ],
                  onChanged: (v) => setState(() => chosen = v),
                ),
              if (chosen == null)
                TextField(
                  controller: listName,
                  decoration: const InputDecoration(labelText: 'List name'),
                ),
              TextField(
                controller: reason,
                maxLength: BlockPolicy.maxReason,
                decoration: const InputDecoration(
                  labelText: 'Reason (optional, public)',
                ),
              ),
              if (space != null)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: onlyHere,
                  onChanged: (v) => setState(() => onlyHere = v ?? false),
                  title: Text('Only in ${blockSpaceLabel(space, name)}'),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Add'),
          ),
        ],
      ),
    ),
  );
  if (ok != true || !context.mounted) return;
  await _attempt(context, () async {
    final list = chosen ?? await node.blocks.saveList(listName.text);
    await node.blocks.addEntry(
      list,
      person,
      spaces: onlyHere && space != null ? [space] : null,
      reason: reason.text,
    );
  }, done: 'Added ${name(person)} to your list');
}

/// Asks how to use [owner]'s [list], then subscribes to it.
Future<void> subscribeBlockList(
  BuildContext context,
  Node node,
  String owner,
  String list,
  NameOf name,
) async {
  if (owner == node.person) {
    _notice(context, 'That is your own list');
    return;
  }
  final info = node.blocks.listInfo(owner, list);
  var mode = node.blocks.subscriptions[(owner, list)] ?? ListMode.hide;
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialog) => StatefulBuilder(
      builder: (dialog, setState) => AlertDialog(
        title: Text("${name(owner)}'s ${info?.name ?? list} list"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (info != null && info.description.isNotEmpty)
              Text(info.description),
            const SizedBox(height: 8),
            const Text(
              'People you are connected to, and anyone you choose to '
              'allow, are never hidden by a list.',
            ),
            RadioGroup<ListMode>(
              groupValue: mode,
              onChanged: (v) => setState(() => mode = v ?? mode),
              child: const Column(
                children: [
                  RadioListTile(
                    value: ListMode.hide,
                    title: Text('Hide them'),
                    subtitle: Text('With a note you can open'),
                  ),
                  RadioListTile(
                    value: ListMode.block,
                    title: Text('Block them'),
                    subtitle: Text('Hidden, and not passed on'),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Subscribe'),
          ),
        ],
      ),
    ),
  );
  if (ok != true || !context.mounted) return;
  await _attempt(
    context,
    () => node.blocks.subscribe(owner, list, mode: mode),
    done: 'Subscribed',
  );
}

/// Shown in place of something a subscribed block list hides.
class HiddenByList extends StatelessWidget {
  final Node node;
  final BlockHit hit;
  final String objectId;
  final NameOf name;
  const HiddenByList({
    super.key,
    required this.node,
    required this.hit,
    required this.objectId,
    required this.name,
  });

  @override
  Widget build(BuildContext context) {
    final list =
        node.blocks.listInfo(hit.entry.owner, hit.entry.list)?.name ??
        hit.entry.list;
    final small = Theme.of(context).textTheme.bodySmall;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Hidden: on ${name(hit.entry.owner)}'s $list list",
              style: small,
            ),
            if (hit.entry.reason case final reason?) Text(reason, style: small),
            Wrap(
              spacing: 4,
              children: [
                TextButton(
                  onPressed: () => node.blocks.showAnyway(objectId),
                  child: const Text('Show anyway'),
                ),
                TextButton(
                  onPressed: () => _attempt(
                    context,
                    () => node.blocks.setScope(hit.entry.person, [
                      BlockPolicy.everywhere,
                    ], ScopeState.allow),
                  ),
                  child: const Text('Always allow'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Settings > Blocking: personal blocks and mutes, this person's public
/// lists, subscribed lists and people allowed past them.
class BlockingPage extends StatefulWidget {
  final Node node;
  final NameOf name;
  final Future<void> Function(String person, bool block) setBlocked;
  const BlockingPage({
    super.key,
    required this.node,
    required this.name,
    required this.setBlocked,
  });

  @override
  State<BlockingPage> createState() => _BlockingPageState();
}

class _BlockingPageState extends State<BlockingPage> {
  StreamSubscription<void>? _changes;
  Node get node => widget.node;
  NameOf get name => widget.name;

  @override
  void initState() {
    super.initState();
    _changes = node.changes.stream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
  }

  String _stateText(ScopeState s) => switch (s) {
    ScopeState.block => 'Blocked',
    ScopeState.mute => 'Muted',
    ScopeState.allow => 'Allowed',
    ScopeState.none => '',
  };

  Future<void> _addByLink() async {
    final controller = TextEditingController();
    final link = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Subscribe to a block list'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'ournet://blocks/…'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, controller.text),
            child: const Text('Next'),
          ),
        ],
      ),
    );
    if (link == null || !mounted) return;
    final parsed = BlockPolicy.parseLink(link);
    if (parsed == null) {
      _notice(context, 'That is not a block list link');
      return;
    }
    await subscribeBlockList(context, node, parsed.$1, parsed.$2, name);
  }

  Future<void> _newList() async {
    final controller = TextEditingController();
    final description = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('New public block list'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            TextField(
              controller: description,
              decoration: const InputDecoration(
                labelText: 'What is it for? (optional)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _attempt(
      context,
      () =>
          node.blocks.saveList(controller.text, description: description.text),
    );
  }

  @override
  Widget build(BuildContext context) {
    final blocks = node.blocks;
    final blocked = node.blocked.where((p) => p != node.person).toList()
      ..sort((a, b) => name(a).compareTo(name(b)));
    final scoped = blocks.scoped.entries.toList()
      ..sort((a, b) => name(a.key).compareTo(name(b.key)));
    final mine = blocks.listsOf(node.person);
    final subs = blocks.subscriptions.entries.toList();
    final heading = Theme.of(context).textTheme.titleSmall;
    Widget header(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(text, style: heading),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Blocking')),
      body: ListView(
        children: [
          header('Blocked everywhere'),
          if (blocked.isEmpty) const ListTile(title: Text('Nobody')),
          for (final p in blocked)
            ListTile(
              leading: const Icon(Icons.block),
              title: Text(name(p)),
              trailing: TextButton(
                onPressed: () => widget.setBlocked(p, false),
                child: const Text('Unblock'),
              ),
            ),
          header('Blocked, muted or allowed in places'),
          if (scoped.isEmpty) const ListTile(title: Text('Nobody')),
          for (final MapEntry(key: p, value: spaces) in scoped)
            ListTile(
              title: Text(name(p)),
              subtitle: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final MapEntry(key: s, value: state) in spaces.entries)
                    InputChip(
                      label: Text(
                        s == BlockPolicy.everywhere
                            ? '${_stateText(state)} everywhere'
                            : '${_stateText(state)} in ${blockSpaceLabel(s, name)}',
                      ),
                      onDeleted: () => _attempt(
                        context,
                        () => blocks.setScope(p, [s], ScopeState.none),
                      ),
                    ),
                ],
              ),
            ),
          header('My public lists'),
          for (final l in mine)
            ExpansionTile(
              leading: const Icon(Icons.list_alt),
              title: Text(l.name),
              subtitle: l.description.isEmpty ? null : Text(l.description),
              children: [
                ListTile(
                  leading: const Icon(Icons.link),
                  title: const Text('Copy link'),
                  onTap: () {
                    Clipboard.setData(
                      ClipboardData(text: BlockPolicy.link(l.owner, l.list)),
                    );
                    _notice(context, 'Link copied');
                  },
                ),
                for (final e in blocks.entries(l.owner, l.list))
                  ListTile(
                    title: Text(name(e.person)),
                    subtitle: Text(
                      [
                        if (e.spaces != null)
                          'In ${e.spaces!.map((s) => blockSpaceLabel(s, name)).join(', ')}',
                        ?e.reason,
                      ].join(' · '),
                    ),
                    trailing: IconButton(
                      tooltip: 'Take off the list',
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: () => _attempt(
                        context,
                        () => blocks.removeEntry(l.list, e.person),
                      ),
                    ),
                  ),
              ],
            ),
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('New public list'),
            onTap: _newList,
          ),
          header('Subscribed lists'),
          for (final MapEntry(key: (owner, list), value: mode) in subs)
            ListTile(
              leading: const Icon(Icons.shield_outlined),
              title: Text(
                "${name(owner)}'s ${blocks.listInfo(owner, list)?.name ?? list}",
              ),
              subtitle: Text(
                '${blocks.entries(owner, list).length} people · '
                '${mode == ListMode.hide ? 'hidden' : 'blocked'}',
              ),
              trailing: PopupMenuButton<String>(
                onSelected: (v) => _attempt(
                  context,
                  () => v == 'off'
                      ? blocks.unsubscribe(owner, list)
                      : blocks.subscribe(
                          owner,
                          list,
                          mode: v == 'block' ? ListMode.block : ListMode.hide,
                        ),
                ),
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'hide', child: Text('Hide them')),
                  const PopupMenuItem(
                    value: 'block',
                    child: Text('Block them'),
                  ),
                  const PopupMenuItem(value: 'off', child: Text('Unsubscribe')),
                ],
              ),
            ),
          ListTile(
            leading: const Icon(Icons.add_link),
            title: const Text('Subscribe by link'),
            onTap: _addByLink,
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Lists never hide people you are connected to, or anyone you '
              'chose to always allow: they show a note instead. Blocks also '
              'apply to proposals and votes: your counts leave out people you '
              'block.',
            ),
          ),
        ],
      ),
    );
  }
}
