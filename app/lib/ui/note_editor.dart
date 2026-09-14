import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart' show PeerNetwork;
import '../services/coalesced_task.dart';
import '../services/drafts.dart';
import 'sync_status.dart';

class NoteEditor extends StatefulWidget {
  final Notes notes;
  final String id;
  final DraftStore drafts;
  final PeerNetwork? network;
  final Map<String, String> friends;
  final String Function(String) personName;
  const NoteEditor({
    super.key,
    required this.notes,
    required this.id,
    required this.drafts,
    this.network,
    required this.friends,
    required this.personName,
  });
  @override
  State<NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<NoteEditor> with WidgetsBindingObserver {
  NoteDocument? note;
  final inputs = <String, TextEditingController>{};
  final bases = <String, (String, List<String>)>{};
  final dirty = <String>{}, working = <String>{};
  late final CoalescedTask refresh;
  StreamSubscription<void>? changes;
  String? error;
  bool loading = true, applying = false;
  String draftKey(String field) => 'note/${widget.id}/$field';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    refresh = CoalescedTask(load, (e) {
      if (mounted) setState(() => error = '$e');
    });
    changes = widget.notes.node.changes.stream.listen(
      (_) => refresh.schedule(),
    );
    unawaited(load());
  }

  Future<void> load() async {
    try {
      await widget.drafts.ready;
      final next = await widget.notes.get(widget.id, includeUnavailable: true);
      if (!mounted) return;
      applying = true;
      if (next != null) {
        for (final field in [
          'title',
          'text',
          ...next.checks.map((c) => 'check:$c:text'),
        ]) {
          if (dirty.contains(field)) continue;
          final controller = inputs.putIfAbsent(field, () {
            final c = TextEditingController();
            c.addListener(() {
              if (applying) return;
              dirty.add(field);
              final base = bases[field]!;
              widget.drafts.put(
                draftKey(field),
                jsonEncode({
                  'text': c.text,
                  'epoch': base.$1,
                  'parents': base.$2,
                }),
                (e) {
                  if (mounted) {
                    setState(() => error = 'Draft could not be saved: $e');
                  }
                },
              );
              if (mounted) setState(() {});
            });
            return c;
          });
          bases[field] = (next.epoch, next.parents(field));
          final saved = widget.drafts.values[draftKey(field)];
          if (saved != null && saved.isNotEmpty) {
            final data = jsonDecode(saved) as Map;
            controller.text = data['text'];
            bases[field] = (
              data['epoch'],
              (data['parents'] as List).cast<String>(),
            );
            dirty.add(field);
          } else {
            final value = next.value(field)?.toString() ?? '';
            if (controller.text != value) controller.text = value;
          }
        }
      }
      setState(() {
        note = next;
        loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          loading = false;
        });
      }
    } finally {
      applying = false;
    }
  }

  Future<void> run(String key, Future<void> Function() action) async {
    if (working.contains(key)) return;
    setState(() {
      working.add(key);
      error = null;
    });
    try {
      await action();
      await load();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => working.remove(key));
    }
  }

  Future<void> save() => run('save', () async {
    for (final field in dirty.toList()) {
      final text = inputs[field]!.text;
      final base = bases[field]!;
      await widget.notes.edit(widget.id, base.$1, field, text, base.$2);
      if (inputs[field]!.text == text) {
        dirty.remove(field);
        widget.drafts.put(draftKey(field), '', (_) {});
      }
    }
    await widget.drafts.flush();
  });
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      refresh.schedule();
    } else {
      unawaited(widget.drafts.flush().catchError((Object _) {}));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    changes?.cancel();
    refresh.close();
    unawaited(widget.drafts.flush().catchError((Object _) {}));
    for (final input in inputs.values) {
      input.dispose();
    }
    super.dispose();
  }

  Future<void> collaborators() async {
    final current = note!;
    final owner = current.room.data['owner'] == widget.notes.node.person;
    final selected = current.members.toSet();
    final action = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, change) => AlertDialog(
          title: const Text('Collaborators'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Everyone can edit this same note. New collaborators receive its current contents and competing versions, not its earlier revision history.',
                  ),
                  for (final person in {
                    ...current.members,
                    if (owner) ...widget.friends.keys,
                  })
                    CheckboxListTile(
                      value: selected.contains(person),
                      title: Text(widget.personName(person)),
                      subtitle: person == current.room.data['owner']
                          ? const Text('Owner')
                          : null,
                      onChanged: !owner || person == current.room.data['owner']
                          ? null
                          : (v) => change(() {
                              if (v == true) {
                                selected.add(person);
                              } else {
                                selected.remove(person);
                              }
                            }),
                    ),
                  if (owner && widget.friends.isEmpty)
                    const Text(
                      'Add friends from Friends first, then invite them here.',
                    ),
                  const Text(
                    'Changes take effect as devices reconnect. Removed collaborators can keep received copies. Offline edits from an earlier membership stay in Recovery on devices that received them.',
                  ),
                ],
              ),
            ),
          ),
          actions: [
            if (!owner)
              TextButton(
                onPressed: () => Navigator.pop(context, 'leave'),
                child: const Text('Leave note'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            if (owner)
              FilledButton(
                onPressed: () => Navigator.pop(context, 'save'),
                child: const Text('Save collaborators'),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'leave') {
      await run('members', () => widget.notes.leave(widget.id));
    }
    if (action == 'save' &&
        !(selected.length == current.members.length &&
            selected.containsAll(current.members))) {
      await run(
        'members',
        () => widget.notes.changeMembers(widget.id, selected.toList()),
      );
    }
  }

  Future<void> recovery() async {
    final current = note!;
    final versions = [
      ...current.history,
      ...current.earlier,
    ].where((r) => r.data['value'] is String).toList();
    versions.sort((a, b) => b.object.created.compareTo(a.object.created));
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .75,
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Recovery · received versions on this device'),
            ),
            if (current.available && !current.deleted)
              for (final field
                  in current.heads.keys
                      .where(
                        (k) =>
                            k.startsWith('check:') &&
                            k.endsWith(':deleted') &&
                            current.value(k) == true,
                      )
                      .take(5))
                TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                    run(
                      field,
                      () => widget.notes.edit(
                        current.id,
                        current.epoch,
                        field,
                        false,
                        current.parents(field),
                      ),
                    );
                  },
                  child: Text(
                    'Restore ${current.value(field.replaceAll(':deleted', ':text')) ?? 'checklist item'}',
                  ),
                ),
            Expanded(
              child: ListView.builder(
                itemCount: versions.length,
                itemBuilder: (context, index) {
                  final version = versions[index];
                  final field = version.data['field'] as String;
                  return ListTile(
                    title: Text(
                      version.data['value'],
                      maxLines: 6,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${widget.personName(version.object.author)} · $field${version.data['epoch'] != current.epoch ? ' · Earlier collaborators' : ''}',
                    ),
                    trailing: IconButton(
                      tooltip: 'Copy version',
                      icon: const Icon(Icons.copy),
                      onPressed: () => Clipboard.setData(
                        ClipboardData(text: version.data['value']),
                      ),
                    ),
                    onTap:
                        inputs.containsKey(field) &&
                            current.available &&
                            !current.deleted
                        ? () {
                            bases[field] = (
                              current.epoch,
                              current.parents(field),
                            );
                            inputs[field]!.text = version.data['value'];
                            Navigator.pop(context);
                          }
                        : null,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final current = note;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Note'),
        actions: [
          if (current != null) ...[
            if (current.available)
              IconButton(
                tooltip: 'Collaborators',
                onPressed: working.contains('members') ? null : collaborators,
                icon: const Icon(Icons.person_add_alt),
              ),
            IconButton(
              tooltip: 'Recovery',
              onPressed: recovery,
              icon: const Icon(Icons.history),
            ),
            if (current.available)
              IconButton(
                tooltip: current.deleted ? 'Restore note' : 'Remove note',
                icon: Icon(
                  current.deleted
                      ? Icons.restore_from_trash
                      : Icons.delete_outline,
                ),
                onPressed: () => run(
                  'delete',
                  () => widget.notes.edit(
                    current.id,
                    current.epoch,
                    'deleted',
                    !current.deleted,
                    current.parents('deleted'),
                  ),
                ),
              ),
          ],
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              key: PageStorageKey('editor/${widget.id}'),
              padding: const EdgeInsets.all(20),
              children: [
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (current == null)
                  const Text(
                    'This note is unavailable or you have left it. Any draft is kept on this device.',
                  ),
                if (current != null) ...[
                  if (!current.available || current.deleted)
                    Text(
                      !current.available
                          ? 'You no longer collaborate on this note. Received writing is available in Recovery.'
                          : 'Removed · writing remains in Recovery. Restore to edit.',
                    )
                  else
                    Builder(
                      builder: (context) {
                        final saved =
                            '${current.members.length > 1 ? '${current.members.length} collaborators · ' : ''}Saved locally';
                        return widget.network == null
                            ? Text('$saved · syncs while OurNet is open')
                            : SyncStatus(
                                network: widget.network!,
                                people: current.members,
                                prefix: '$saved · ',
                                offline: '$saved · syncs when connected',
                              );
                      },
                    ),
                  if (current.hasConflicts)
                    const Text(
                      'Competing writing is saved in Recovery. Choose or combine the versions, then save.',
                    ),
                  if (dirty.any((field) => bases[field]?.$1 != current.epoch))
                    TextButton(
                      onPressed: () => setState(() {
                        for (final field in dirty) {
                          bases[field] = (
                            current.epoch,
                            current.parents(field),
                          );
                        }
                      }),
                      child: const Text(
                        'Review draft for current collaborators',
                      ),
                    ),
                ],
                if (inputs.containsKey('title'))
                  TextField(
                    controller: inputs['title'],
                    enabled:
                        current != null &&
                        current.available &&
                        !current.deleted,
                    maxLength: 100,
                    decoration: const InputDecoration(labelText: 'Title'),
                  ),
                if (inputs.containsKey('text'))
                  TextField(
                    controller: inputs['text'],
                    enabled:
                        current != null &&
                        current.available &&
                        !current.deleted,
                    minLines: 3,
                    maxLines: null,
                    maxLength: 16384,
                    decoration: const InputDecoration(labelText: 'Note text'),
                  ),
                if (current != null &&
                    current.available &&
                    !current.deleted) ...[
                  for (final id in current.checks)
                    Row(
                      key: ValueKey(id),
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Checkbox(
                          value: current.value('check:$id:done') == true,
                          onChanged: working.contains(id)
                              ? null
                              : (value) => run(
                                  id,
                                  () => widget.notes.edit(
                                    current.id,
                                    current.epoch,
                                    'check:$id:done',
                                    value!,
                                    current.parents('check:$id:done'),
                                  ),
                                ),
                        ),
                        Expanded(
                          child: TextField(
                            controller: inputs['check:$id:text'],
                            maxLines: null,
                            maxLength: 16384,
                            decoration: const InputDecoration(
                              labelText: 'Checklist item',
                              counterText: '',
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Remove item',
                          icon: const Icon(Icons.close),
                          onPressed: () => run(
                            id,
                            () => widget.notes.edit(
                              current.id,
                              current.epoch,
                              'check:$id:deleted',
                              true,
                              current.parents('check:$id:deleted'),
                            ),
                          ),
                        ),
                      ],
                    ),
                  TextButton.icon(
                    onPressed: working.contains('add')
                        ? null
                        : () => run(
                            'add',
                            () => widget.notes.edit(
                              current.id,
                              current.epoch,
                              'check:${randomId()}:text',
                              '',
                              [],
                            ),
                          ),
                    icon: const Icon(Icons.add),
                    label: const Text('Add checklist item'),
                  ),
                  FilledButton(
                    onPressed: dirty.isEmpty || working.contains('save')
                        ? null
                        : save,
                    child: Text(
                      working.contains('save') ? 'Saving locally…' : 'Save',
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}
