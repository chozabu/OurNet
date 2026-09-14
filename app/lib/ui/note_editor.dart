import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart' show PeerNetwork;
import '../services/coalesced_task.dart';
import '../services/drafts.dart';
import 'note_colors.dart';
import 'sync_status.dart';

/// Keep-style editor. Writing autosaves after a pause and when leaving; list
/// changes (checks, order, removal, colour) apply immediately on screen and
/// are published in one batch. Typed text always names the versions it saw, so
/// unseen writing from collaborators stays as a recoverable branch.
class NoteEditor extends StatefulWidget {
  final Notes notes;

  /// Null for a new note, which is created once something is written.
  final String? id;
  final bool checklist;
  final DraftStore drafts;
  final PeerNetwork? network;
  final Map<String, String> friends;
  final String Function(String) personName;

  /// Opens friend invitation and returns the updated friend names.
  final Future<Map<String, String>> Function()? addFriend;
  final void Function(String id)? onRemoved;
  final void Function(String message)? notice;
  final Duration autosaveDelay;
  const NoteEditor({
    super.key,
    required this.notes,
    this.id,
    this.checklist = false,
    required this.drafts,
    this.network,
    required this.friends,
    required this.personName,
    this.addFriend,
    this.onRemoved,
    this.notice,
    this.autosaveDelay = const Duration(milliseconds: 1500),
  });
  @override
  State<NoteEditor> createState() => NoteEditorState();
}

class NoteEditorState extends State<NoteEditor> with WidgetsBindingObserver {
  String? id;
  final stableId = randomId();
  NoteDocument? note;
  final inputs = <String, TextEditingController>{};
  final focus = <String, FocusNode>{};
  final known = <String, String>{};
  final bases = <String, (String, List<String>)>{};
  final dirty = <String>{};

  /// New items not yet in the document: item ID -> order key.
  final localItems = <String, String>{};
  final pendingDone = <String, bool>{};
  final pendingOrder = <String, String>{};
  final pendingDeleted = <String>{};
  String? pendingColor;
  final flushing = <String>{};
  final status = ValueNotifier<String>('');
  late final CoalescedTask refresh;
  StreamSubscription<void>? changes;
  Timer? autosave;
  Future<void>? saving;
  late Map<String, String> friends = widget.friends;
  String? error;
  bool loading = true, applying = false, showChecked = true;
  late bool checklistMode = widget.checklist;
  String draftKey(String field) => 'note/$id/$field';
  bool get editable =>
      id == null || (note != null && note!.available && !note!.deleted);

  @override
  void initState() {
    super.initState();
    id = widget.id;
    WidgetsBinding.instance.addObserver(this);
    refresh = CoalescedTask(load, (e) {
      if (mounted) setState(() => error = '$e');
    });
    changes = widget.notes.node.changes.stream.listen(
      (_) => refresh.schedule(),
    );
    input('title');
    input('text');
    if (id == null) {
      loading = false;
      if (widget.checklist) addItem(focusIt: true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !widget.checklist) focusFor('text').requestFocus();
      });
    } else {
      unawaited(load());
    }
  }

  TextEditingController input(String field) => inputs.putIfAbsent(field, () {
    final controller = TextEditingController();
    controller.addListener(() => changed(field, controller));
    return controller;
  });
  FocusNode focusFor(String field) => focus.putIfAbsent(field, FocusNode.new);

  void setText(String field, String text, {int? cursor}) {
    final controller = input(field);
    applying = true;
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(
        offset: (cursor ?? controller.selection.baseOffset).clamp(
          0,
          text.length,
        ),
      ),
    );
    known[field] = text;
    applying = false;
  }

  void changed(String field, TextEditingController controller) {
    // Selection-only changes also notify; they are not edits.
    if (applying || known[field] == controller.text) return;
    if (field.startsWith('check:') && controller.text.contains('\n')) {
      splitItem(field.split(':')[1], controller);
      return;
    }
    known[field] = controller.text;
    markDirty(field);
  }

  void markDirty(String field) {
    final first = dirty.add(field);
    rememberDraft(field);
    if (first && mounted) setState(() {});
    scheduleSave();
  }

  void rememberDraft(String field) {
    final base = bases[field];
    if (id == null) return;
    widget.drafts.put(
      draftKey(field),
      jsonEncode({
        'text': inputs[field]!.text,
        if (base != null) ...{'epoch': base.$1, 'parents': base.$2},
        if (localItems.containsKey(field.split(':').elementAtOrNull(1)))
          'order': localItems[field.split(':')[1]],
        if (base == null) 'epoch': note?.epoch,
      }),
      (e) {
        if (mounted) setState(() => error = 'Draft could not be saved: $e');
      },
    );
  }

  // ---- Items -------------------------------------------------------------

  String? keyOf(String item) =>
      pendingOrder[item] ?? localItems[item] ?? note?.order(item);
  bool isDone(String item) => pendingDone[item] ?? note?.done(item) ?? false;

  /// All live items in display order, including unsaved local ones.
  List<String> allItems() {
    final ids = [
      ...?note?.checks.where((c) => !pendingDeleted.contains(c)),
      ...localItems.keys.where((c) => !(note?.checks.contains(c) ?? false)),
    ];
    final index = {for (var i = 0; i < ids.length; i++) ids[i]: i};
    return ids..sort((a, b) {
      final order = (keyOf(a) ?? '').compareTo(keyOf(b) ?? '');
      return order != 0 ? order : index[a]!.compareTo(index[b]!);
    });
  }

  void setKey(String item, String key) {
    if (localItems.containsKey(item)) {
      localItems[item] = key;
    } else {
      pendingOrder[item] = key;
    }
  }

  /// Gives every item a compact key in [order]. Needed once for lists written
  /// before item ordering existed, or after concurrent placements collide.
  void renumber(List<String> order) {
    final keys = orderSequence(order.length);
    for (var i = 0; i < order.length; i++) {
      setKey(order[i], keys[i]);
    }
  }

  String? addItem({String? after, String text = '', bool focusIt = false}) {
    var order = allItems();
    if (order.length >= Notes.maxChecks) {
      setState(() => error = 'A checklist supports ${Notes.maxChecks} items.');
      return null;
    }
    checklistMode = true;
    String? before, next;
    if (after == null) {
      before = order
          .map(keyOf)
          .whereType<String>()
          .fold<String?>(
            null,
            (max, k) => max == null || k.compareTo(max) > 0 ? k : max,
          );
    } else {
      var index = order.indexOf(after);
      if (keyOf(after) == null ||
          (index + 1 < order.length && keyOf(order[index + 1]) == null)) {
        renumber(order);
        order = allItems();
        index = order.indexOf(after);
      }
      before = keyOf(after);
      next = index + 1 < order.length ? keyOf(order[index + 1]) : null;
    }
    final item = randomId();
    localItems[item] = orderBetween(before, next);
    final field = 'check:$item:text';
    setText(field, text, cursor: text.length);
    if (text.isNotEmpty) dirty.add(field);
    if (focusIt) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) focusFor(field).requestFocus();
      });
    }
    if (mounted) setState(() {});
    scheduleSave();
    return item;
  }

  void splitItem(String item, TextEditingController controller) {
    final parts = controller.text.split('\n');
    final field = 'check:$item:text';
    setText(field, parts.first, cursor: parts.first.length);
    markDirty(field);
    var after = item;
    String? last;
    for (final part in parts.skip(1)) {
      final added = addItem(after: after, text: part);
      if (added == null) break;
      after = last = added;
    }
    if (last == null) return;
    final lastField = 'check:$last:text';
    // Enter continues at the start of the new item; a paste ends after it.
    inputs[lastField]!.selection = TextSelection.collapsed(
      offset: parts.length == 2 ? 0 : inputs[lastField]!.text.length,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) focusFor(lastField).requestFocus();
    });
  }

  void removeItem(String item, {bool focusPrevious = false}) {
    final order = allItems();
    final index = order.indexOf(item);
    if (localItems.remove(item) == null) pendingDeleted.add(item);
    dirty.remove('check:$item:text');
    if (id != null) widget.drafts.put(draftKey('check:$item:text'), '', (_) {});
    if (focusPrevious && index > 0) {
      final previous = 'check:${order[index - 1]}:text';
      focusFor(previous).requestFocus();
      inputs[previous]!.selection = TextSelection.collapsed(
        offset: inputs[previous]!.text.length,
      );
    }
    setState(() {});
    scheduleSave(Duration.zero);
  }

  void toggle(String item, bool value) {
    setState(() => pendingDone[item] = value);
    scheduleSave(Duration.zero);
  }

  void reorder(int from, int to) {
    final unchecked = allItems().where((i) => !isDone(i)).toList();
    if (from == to) return;
    final moved = unchecked.removeAt(from);
    unchecked.insert(to, moved);
    final previous = to > 0 ? unchecked[to - 1] : null;
    final next = to + 1 < unchecked.length ? unchecked[to + 1] : null;
    final low = previous == null ? null : keyOf(previous);
    final high = next == null ? null : keyOf(next);
    if ((previous != null && low == null) ||
        (next != null && high == null) ||
        (low != null && high != null && low.compareTo(high) >= 0)) {
      final full = allItems()..remove(moved);
      final anchor = previous == null ? 0 : full.indexOf(previous) + 1;
      renumber(full..insert(anchor, moved));
    } else {
      setKey(moved, orderBetween(low, high));
    }
    setState(() {});
    scheduleSave(Duration.zero);
  }

  // ---- Loading and saving -------------------------------------------------

  Future<void> load() async {
    final current = id;
    if (current == null) return;
    try {
      await widget.drafts.ready;
      final next = await widget.notes.get(current, includeUnavailable: true);
      if (!mounted) return;
      setState(() {
        adopt(next);
        loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          loading = false;
        });
      }
    }
  }

  /// Applies a received document without disturbing unsaved local writing.
  void adopt(NoteDocument? next) {
    note = next;
    if (next == null) return;
    if (next.checks.isNotEmpty) checklistMode = true;
    for (final field in [
      'title',
      'text',
      ...next.checks.map((c) => 'check:$c:text'),
    ]) {
      input(field);
      if (dirty.contains(field)) continue;
      bases[field] = (next.epoch, next.parents(field));
      final saved = widget.drafts.values[draftKey(field)];
      if (saved != null && saved.isNotEmpty) {
        final data = jsonDecode(saved) as Map;
        setText(field, data['text']);
        if (data['parents'] != null) {
          bases[field] = (
            data['epoch'],
            (data['parents'] as List).cast<String>(),
          );
        }
        dirty.add(field);
      } else {
        setText(field, next.value(field)?.toString() ?? '');
      }
    }
    // Items typed before the app stopped, which never reached the document.
    final prefix = draftKey('check:');
    for (final entry in widget.drafts.values.entries) {
      if (!entry.key.startsWith(prefix) || entry.value.isEmpty) continue;
      final item = entry.key.substring(prefix.length).split(':').first;
      if (next.heads.containsKey('check:$item:text') ||
          localItems.containsKey(item)) {
        continue;
      }
      final data = jsonDecode(entry.value) as Map;
      if (data['order'] is! String) continue;
      localItems[item] = data['order'];
      setText('check:$item:text', data['text']);
      dirty.add('check:$item:text');
      checklistMode = true;
    }
    localItems.removeWhere(
      (item, _) =>
          next.heads.containsKey('check:$item:text') &&
          !flushing.contains('check:$item:text'),
    );
    pendingDone.removeWhere(
      (item, value) =>
          next.done(item) == value && !flushing.contains('check:$item:done'),
    );
    pendingOrder.removeWhere(
      (item, value) =>
          next.order(item) == value && !flushing.contains('check:$item:order'),
    );
    pendingDeleted.removeWhere(
      (item) =>
          !next.checks.contains(item) &&
          !flushing.contains('check:$item:deleted'),
    );
    if (pendingColor == next.color && !flushing.contains('color')) {
      pendingColor = null;
    }
  }

  bool get hasChanges =>
      dirty.isNotEmpty ||
      localItems.isNotEmpty ||
      pendingDone.isNotEmpty ||
      pendingOrder.isNotEmpty ||
      pendingDeleted.isNotEmpty ||
      pendingColor != null;

  void scheduleSave([Duration? delay]) {
    autosave?.cancel();
    autosave = Timer(delay ?? widget.autosaveDelay, () => unawaited(flush()));
  }

  /// Saves everything changed so far. Calls run one after another.
  Future<void> flush() {
    autosave?.cancel();
    final next = (saving ?? Future<void>.value()).then((_) => _flush());
    saving = next;
    unawaited(
      next.whenComplete(() {
        if (identical(saving, next)) saving = null;
      }),
    );
    return next;
  }

  void report(Object e) {
    if (mounted) {
      setState(() => error = '$e');
    } else {
      widget.notice?.call('$e');
    }
  }

  Future<void> _flush() async {
    if (!hasChanges) return;
    status.value = 'Saving…';
    try {
      if (id == null) {
        final title = inputs['title']!.text, text = inputs['text']!.text;
        final items = allItems().map((i) => inputs['check:$i:text']!.text);
        if ('$title$text${items.join()}'.trim().isEmpty) {
          status.value = '';
          return;
        }
        final created = await widget.notes.create(
          stableId: stableId,
          title: title,
          text: text,
          color: pendingColor,
        );
        id = created.id;
        note = created;
        if (pendingColor == created.color) pendingColor = null;
        for (final field in ['title', 'text']) {
          bases[field] = (created.epoch, created.parents(field));
          if (inputs[field]!.text == created.value(field)) {
            dirty.remove(field);
          } else {
            dirty.add(field);
          }
        }
      }
      final current = note;
      if (current == null || !current.available) return;
      final epoch = current.epoch;
      final changes = <NoteChange>[];
      final written = <String, String>{};
      for (final field in dirty) {
        final base = bases[field];
        if (base == null || base.$1 != epoch) continue;
        written[field] = inputs[field]!.text;
        changes.add((field: field, value: written[field]!, parents: base.$2));
      }
      for (final entry in localItems.entries) {
        final field = 'check:${entry.key}:text';
        written[field] = inputs[field]?.text ?? '';
        changes
          ..add((field: field, value: written[field]!, parents: const []))
          ..add((
            field: 'check:${entry.key}:order',
            value: entry.value,
            parents: const [],
          ));
      }
      for (final entry in pendingOrder.entries) {
        final field = 'check:${entry.key}:order';
        changes.add((
          field: field,
          value: entry.value,
          parents: current.parents(field),
        ));
      }
      for (final entry in pendingDone.entries) {
        final field = 'check:${entry.key}:done';
        changes.add((
          field: field,
          value: entry.value,
          parents: current.parents(field),
        ));
      }
      for (final item in pendingDeleted) {
        final field = 'check:$item:deleted';
        changes.add((
          field: field,
          value: true,
          parents: current.parents(field),
        ));
      }
      if (pendingColor != null) {
        changes.add((
          field: 'color',
          value: pendingColor!,
          parents: current.parents('color'),
        ));
      }
      if (changes.isEmpty) {
        status.value = '';
        return;
      }
      final values = {for (final c in changes) c.field: c.value};
      flushing.addAll(values.keys);
      final List<String?> published;
      try {
        published = await widget.notes.apply(id!, epoch, changes);
      } finally {
        flushing.removeAll(values.keys);
      }
      for (var i = 0; i < changes.length; i++) {
        final field = changes[i].field;
        final text = written[field];
        if (text == null || published[i] == null) continue;
        // This device observed its own write; the next save builds on it.
        bases[field] = (epoch, [published[i]!]);
        if (inputs[field]?.text == text) {
          dirty.remove(field);
          widget.drafts.put(draftKey(field), '', (_) {});
        } else {
          rememberDraft(field);
        }
      }
      final next = await widget.notes.get(id!, includeUnavailable: true);
      void settle() {
        adopt(next);
        error = null;
      }

      mounted ? setState(settle) : settle();
      status.value = 'Saved';
      await widget.drafts.flush();
      if (hasChanges && pendingChangesDiffer(values)) scheduleSave();
    } catch (e) {
      status.value = '';
      report(e);
      if (id != null) unawaited(load());
    }
  }

  /// Whether anything changed while the last batch was being saved.
  bool pendingChangesDiffer(Map<String, Object> saved) =>
      dirty.any((f) => bases[f]?.$1 == note?.epoch) ||
      localItems.isNotEmpty ||
      pendingDone.entries.any((e) => saved['check:${e.key}:done'] != e.value) ||
      pendingOrder.entries.any(
        (e) => saved['check:${e.key}:order'] != e.value,
      ) ||
      pendingDeleted.any((i) => !saved.containsKey('check:$i:deleted')) ||
      (pendingColor != null && saved['color'] != pendingColor);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      refresh.schedule();
    } else {
      unawaited(flush());
      unawaited(widget.drafts.flush().catchError((Object _) {}));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    changes?.cancel();
    refresh.close();
    // Leaving saves; the notes service outlives this screen.
    unawaited(
      flush().whenComplete(() {
        for (final input in inputs.values) {
          input.dispose();
        }
        status.dispose();
      }),
    );
    unawaited(widget.drafts.flush().catchError((Object _) {}));
    for (final node in focus.values) {
      node.dispose();
    }
    super.dispose();
  }

  // ---- Actions -----------------------------------------------------------

  Future<void> run(Future<void> Function() action) async {
    try {
      await action();
      await load();
    } catch (e) {
      report(e);
    }
  }

  Future<void> collaborators() async {
    await flush();
    final current = note;
    if (!mounted || current == null) return;
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
                    if (owner) ...friends.keys,
                  })
                    CheckboxListTile(
                      value: selected.contains(person),
                      secondary: PersonAvatar(name: nameOf(person)),
                      title: Text(nameOf(person)),
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
                  if (owner && widget.addFriend != null)
                    TextButton.icon(
                      onPressed: () async {
                        final updated = await widget.addFriend!();
                        if (!mounted) return;
                        final added = updated.keys.toSet().difference(
                          friends.keys.toSet(),
                        );
                        setState(() => friends = updated);
                        change(() => selected.addAll(added));
                      },
                      icon: const Icon(Icons.person_add_alt),
                      label: const Text('Invite a new friend'),
                    )
                  else if (owner && friends.isEmpty)
                    const Text(
                      'Add friends from Friends first, then invite them here.',
                    ),
                  const SizedBox(height: 8),
                  Text(
                    'Changes take effect as devices reconnect. Removed collaborators can keep received copies. Offline edits from an earlier membership stay in Recovery on devices that received them.',
                    style: Theme.of(context).textTheme.bodySmall,
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
      await run(() => widget.notes.leave(current.id));
    }
    if (action == 'save' &&
        !(selected.length == current.members.length &&
            selected.containsAll(current.members))) {
      await run(
        () => widget.notes.changeMembers(current.id, selected.toList()),
      );
    }
  }

  String nameOf(String person) => person == widget.notes.node.person
      ? 'You'
      : friends[person] ?? widget.personName(person);

  Future<void> recovery() async {
    final current = note!;
    final versions = [...current.history, ...current.earlier].where((r) {
      final field = r.data['field'] as String;
      return r.data['value'] is String &&
          (field == 'title' || field == 'text' || field.endsWith(':text')) &&
          (r.data['value'] as String).isNotEmpty;
    }).toList();
    versions.sort((a, b) => b.object.created.compareTo(a.object.created));
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .75,
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
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
                      '${widget.personName(version.object.author)} · ${field.startsWith('check:') ? 'list item' : field}${version.data['epoch'] != current.epoch ? ' · Earlier collaborators' : ''}',
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

  Future<void> removeNote() async {
    await flush();
    final current = note, noteId = id;
    if (!mounted) return;
    if (current == null || noteId == null) {
      Navigator.maybePop(context);
      return;
    }
    try {
      await widget.notes.edit(
        noteId,
        current.epoch,
        'deleted',
        true,
        current.parents('deleted'),
      );
    } catch (e) {
      report(e);
      return;
    }
    if (mounted) Navigator.maybePop(context);
    widget.onRemoved?.call(noteId);
  }

  String plainText() {
    final lines = <String>[
      if (inputs['title']!.text.trim().isNotEmpty) inputs['title']!.text,
      if (inputs['text']!.text.isNotEmpty) inputs['text']!.text,
      for (final item in allItems())
        '${isDone(item) ? '☑' : '☐'} ${inputs['check:$item:text']!.text}',
    ];
    return lines.join('\n');
  }

  void toggleCheckboxes() {
    if (checklistMode && allItems().isNotEmpty) {
      final items = allItems();
      final text = [
        if (inputs['text']!.text.isNotEmpty) inputs['text']!.text,
        ...items.map((i) => inputs['check:$i:text']!.text),
      ].join('\n');
      for (final item in items) {
        if (localItems.remove(item) == null) pendingDeleted.add(item);
        dirty.remove('check:$item:text');
      }
      setText('text', text, cursor: text.length);
      markDirty('text');
      setState(() => checklistMode = false);
    } else {
      final lines = inputs['text']!.text
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .toList();
      setText('text', '', cursor: 0);
      if (note?.text.isNotEmpty ?? false) markDirty('text');
      setState(() => checklistMode = true);
      String? after;
      for (final line in lines.take(Notes.maxChecks)) {
        after = addItem(after: after, text: line) ?? after;
      }
      if (lines.isEmpty) addItem(focusIt: true);
    }
    scheduleSave(Duration.zero);
  }

  // ---- Layout ------------------------------------------------------------

  String edited(BuildContext context, int millis) {
    final time = DateTime.fromMillisecondsSinceEpoch(millis).toLocal();
    final now = DateTime.now();
    final localizations = MaterialLocalizations.of(context);
    return DateUtils.isSameDay(time, now)
        ? localizations.formatTimeOfDay(TimeOfDay.fromDateTime(time))
        : localizations.formatShortMonthDay(time);
  }

  Widget itemRow(String item, int index, {required bool checked}) {
    final field = 'check:$item:text';
    final controller = input(field), node = focusFor(field);
    final theme = Theme.of(context);
    return Padding(
      key: ValueKey(item),
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (!checked && editable)
            ReorderableDragStartListener(
              index: index,
              child: MouseRegion(
                cursor: SystemMouseCursors.grab,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Icon(
                    Icons.drag_indicator,
                    size: 20,
                    color: theme.colorScheme.outline,
                    semanticLabel: 'Reorder',
                  ),
                ),
              ),
            )
          else
            const SizedBox(width: 28),
          Checkbox(
            value: checked,
            onChanged: editable ? (v) => toggle(item, v!) : null,
          ),
          Expanded(
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onKeyEvent: (_, event) {
                if (event is KeyDownEvent &&
                    event.logicalKey == LogicalKeyboardKey.backspace &&
                    controller.text.isEmpty) {
                  removeItem(item, focusPrevious: true);
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: TextField(
                controller: controller,
                focusNode: node,
                enabled: editable,
                maxLines: null,
                inputFormatters: [LengthLimitingTextInputFormatter(16384)],
                style: checked
                    ? TextStyle(
                        decoration: TextDecoration.lineThrough,
                        color: theme.colorScheme.onSurfaceVariant,
                      )
                    : null,
                decoration: const InputDecoration.collapsed(
                  hintText: 'List item',
                ),
              ),
            ),
          ),
          ListenableBuilder(
            listenable: node,
            builder: (context, _) => node.hasFocus && editable
                ? IconButton(
                    tooltip: 'Remove item',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => removeItem(item),
                  )
                : const SizedBox(width: 40, height: 40),
          ),
        ],
      ),
    );
  }

  Widget banner(String text, {String? action, VoidCallback? onPressed}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Material(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            child: Row(
              children: [
                Expanded(child: Text(text)),
                if (action != null)
                  TextButton(onPressed: onPressed, child: Text(action)),
              ],
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final current = note;
    final theme = Theme.of(context);
    final background =
        noteColor(context, pendingColor ?? current?.color) ??
        theme.colorScheme.surface;
    final items = allItems();
    final unchecked = items.where((i) => !isDone(i)).toList();
    final checked = items.where(isDone).toList();
    final showText =
        !checklistMode || inputs['text']!.text.isNotEmpty || items.isEmpty;
    final pinned = id != null && widget.notes.pinned(id!);
    final review =
        current != null &&
        dirty.any((field) {
          final base = bases[field];
          return base != null && base.$1 != current.epoch;
        });
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.maybePop(context),
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () =>
            unawaited(flush()),
      },
      child: Scaffold(
        backgroundColor: background,
        appBar: AppBar(
          backgroundColor: background,
          scrolledUnderElevation: 0,
          actions: [
            if (id != null)
              IconButton(
                tooltip: pinned ? 'Unpin' : 'Pin',
                onPressed: () => setState(() => widget.notes.pin(id!, !pinned)),
                icon: Icon(pinned ? Icons.push_pin : Icons.push_pin_outlined),
              ),
            if (current != null && current.available)
              IconButton(
                tooltip: 'Collaborators',
                onPressed: collaborators,
                icon: const Icon(Icons.person_add_alt),
              ),
            MenuAnchor(
              alignmentOffset: const Offset(-120, 0),
              builder: (context, menu, _) => IconButton(
                tooltip: 'More',
                onPressed: () => menu.isOpen ? menu.close() : menu.open(),
                icon: const Icon(Icons.more_vert),
              ),
              menuChildren: [
                if (editable)
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.check_box_outlined),
                    onPressed: toggleCheckboxes,
                    child: Text(
                      checklistMode && items.isNotEmpty
                          ? 'Hide checkboxes'
                          : 'Show checkboxes',
                    ),
                  ),
                MenuItemButton(
                  leadingIcon: const Icon(Icons.copy),
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: plainText())),
                  child: const Text('Copy text'),
                ),
                if (current != null)
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.history),
                    onPressed: recovery,
                    child: const Text('Recovery'),
                  ),
                if (current == null || (current.available && !current.deleted))
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.delete_outline),
                    onPressed: removeNote,
                    child: const Text('Remove note'),
                  ),
              ],
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: loading
                  ? const Center(child: CircularProgressIndicator())
                  : Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 760),
                        child: CustomScrollView(
                          key: PageStorageKey('editor/${widget.id}'),
                          slivers: [
                            SliverPadding(
                              padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                              sliver: SliverList.list(
                                children: [
                                  if (error != null)
                                    banner(
                                      error!,
                                      action: 'Dismiss',
                                      onPressed: () =>
                                          setState(() => error = null),
                                    ),
                                  if (id != null && current == null)
                                    banner(
                                      'This note is unavailable or you have left it. Any draft is kept on this device.',
                                    ),
                                  if (current != null && !current.available)
                                    banner(
                                      'You no longer collaborate on this note. Received writing is available in Recovery.',
                                    ),
                                  if (current != null &&
                                      current.available &&
                                      current.deleted)
                                    banner(
                                      'Removed · writing remains in Recovery.',
                                      action: 'Restore',
                                      onPressed: () => run(
                                        () => widget.notes.edit(
                                          current.id,
                                          current.epoch,
                                          'deleted',
                                          false,
                                          current.parents('deleted'),
                                        ),
                                      ),
                                    ),
                                  if (current != null && current.hasConflicts)
                                    banner(
                                      'Competing writing is saved. Choose or combine the versions.',
                                      action: 'Review',
                                      onPressed: recovery,
                                    ),
                                  if (review)
                                    banner(
                                      'Collaborators changed while you were writing.',
                                      action: 'Review draft',
                                      onPressed: () => setState(() {
                                        for (final field in dirty) {
                                          bases[field] = (
                                            current.epoch,
                                            current.parents(field),
                                          );
                                          rememberDraft(field);
                                        }
                                        scheduleSave();
                                      }),
                                    ),
                                  TextField(
                                    key: const ValueKey('note-title'),
                                    controller: inputs['title'],
                                    focusNode: focusFor('title'),
                                    enabled: editable,
                                    minLines: 1,
                                    maxLines: 3,
                                    keyboardType: TextInputType.text,
                                    textInputAction: TextInputAction.next,
                                    inputFormatters: [
                                      FilteringTextInputFormatter.deny(
                                        RegExp(r'[\r\n]'),
                                      ),
                                      LengthLimitingTextInputFormatter(100),
                                    ],
                                    onSubmitted: (_) =>
                                        (showText
                                                ? focusFor('text')
                                                : unchecked.isEmpty
                                                ? focusFor('title')
                                                : focusFor(
                                                    'check:${unchecked.first}:text',
                                                  ))
                                            .requestFocus(),
                                    style: theme.textTheme.titleLarge,
                                    decoration: const InputDecoration.collapsed(
                                      hintText: 'Title',
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  if (showText)
                                    TextField(
                                      key: const ValueKey('note-text'),
                                      controller: inputs['text'],
                                      focusNode: focusFor('text'),
                                      enabled: editable,
                                      minLines: checklistMode ? 1 : 4,
                                      maxLines: null,
                                      inputFormatters: [
                                        LengthLimitingTextInputFormatter(16384),
                                      ],
                                      style: theme.textTheme.bodyLarge,
                                      decoration:
                                          const InputDecoration.collapsed(
                                            hintText: 'Note',
                                          ),
                                    ),
                                  if (showText && checklistMode)
                                    const SizedBox(height: 8),
                                ],
                              ),
                            ),
                            if (checklistMode || items.isNotEmpty) ...[
                              SliverPadding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                sliver: SliverReorderableList(
                                  itemCount: unchecked.length,
                                  onReorderItem: reorder,
                                  proxyDecorator: (child, _, _) => Material(
                                    color: background,
                                    elevation: 4,
                                    borderRadius: BorderRadius.circular(8),
                                    child: child,
                                  ),
                                  itemBuilder: (context, index) => itemRow(
                                    unchecked[index],
                                    index,
                                    checked: false,
                                  ),
                                ),
                              ),
                              if (editable)
                                SliverPadding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                  sliver: SliverToBoxAdapter(
                                    child: ListTile(
                                      dense: true,
                                      contentPadding: const EdgeInsets.only(
                                        left: 36,
                                      ),
                                      leading: const Icon(Icons.add),
                                      title: const Text('List item'),
                                      onTap: () => addItem(
                                        after: unchecked.lastOrNull,
                                        focusIt: true,
                                      ),
                                    ),
                                  ),
                                ),
                              if (checked.isNotEmpty)
                                SliverPadding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                  sliver: SliverToBoxAdapter(
                                    child: ListTile(
                                      dense: true,
                                      contentPadding: const EdgeInsets.only(
                                        left: 36,
                                      ),
                                      leading: Icon(
                                        showChecked
                                            ? Icons.expand_less
                                            : Icons.expand_more,
                                      ),
                                      title: Text(
                                        '${checked.length} checked item${checked.length == 1 ? '' : 's'}',
                                      ),
                                      onTap: () => setState(
                                        () => showChecked = !showChecked,
                                      ),
                                    ),
                                  ),
                                ),
                              if (showChecked)
                                SliverPadding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                  sliver: SliverList.builder(
                                    itemCount: checked.length,
                                    itemBuilder: (context, index) => itemRow(
                                      checked[index],
                                      index,
                                      checked: true,
                                    ),
                                  ),
                                ),
                            ],
                            const SliverToBoxAdapter(
                              child: SizedBox(height: 48),
                            ),
                          ],
                        ),
                      ),
                    ),
            ),
            // In the body, not bottomNavigationBar, so it rides above the keyboard.
            SafeArea(
              child: Container(
                height: 52,
                padding: const EdgeInsets.fromLTRB(4, 0, 12, 4),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Colour',
                      onPressed: editable
                          ? () async {
                              final chosen = await pickNoteColor(
                                context,
                                pendingColor ?? current?.color,
                              );
                              if (chosen == null || !mounted) return;
                              setState(() => pendingColor = chosen);
                              scheduleSave(Duration.zero);
                            }
                          : null,
                      icon: const Icon(Icons.palette_outlined),
                    ),
                    if (current != null && current.members.length > 1)
                      InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: collaborators,
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Row(
                            children: [
                              for (final person in current.members.take(4))
                                Padding(
                                  padding: const EdgeInsets.only(right: 2),
                                  child: PersonAvatar(
                                    name: nameOf(person),
                                    radius: 13,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ValueListenableBuilder(
                        valueListenable: status,
                        builder: (context, saving, _) {
                          final style = theme.textTheme.bodySmall;
                          if (saving == 'Saving…' || current == null) {
                            return Text(
                              saving == 'Saving…'
                                  ? saving
                                  : hasChanges
                                  ? 'Saves as you type'
                                  : '',
                              textAlign: TextAlign.end,
                              style: style,
                            );
                          }
                          final prefix =
                              'Edited ${edited(context, current.updated)} · ';
                          return Align(
                            alignment: Alignment.centerRight,
                            child: widget.network == null
                                ? Text(
                                    '${prefix}syncs while OurNet is open',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: style,
                                  )
                                : SyncStatus(
                                    network: widget.network!,
                                    people: current.members,
                                    prefix: prefix,
                                    offline: '${prefix}saved on this device',
                                    style: style,
                                  ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PersonAvatar extends StatelessWidget {
  final String name;
  final double radius;
  const PersonAvatar({super.key, required this.name, this.radius = 16});
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final palette = [
      colors.primaryContainer,
      colors.secondaryContainer,
      colors.tertiaryContainer,
    ];
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    return Tooltip(
      message: name,
      child: CircleAvatar(
        radius: radius,
        backgroundColor: palette[name.hashCode.abs() % palette.length],
        child: Text(initial, style: TextStyle(fontSize: radius * .9)),
      ),
    );
  }
}
