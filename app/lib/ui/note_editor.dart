import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart' show PeerNetwork, Files;
import 'package:share_plus/share_plus.dart';
import '../services/coalesced_task.dart';
import '../services/drafts.dart';
import '../services/image_text.dart';
import '../services/speech.dart';
import 'drawing.dart';
import 'note_attachments.dart';
import 'note_colors.dart';
import 'note_markup.dart';
import 'note_organise.dart';
import 'speech_settings.dart';
import 'sync_status.dart';
import 'voice_recorder.dart';

/// A snapshot of what the editor shows, for note-level undo and redo.
typedef EditorSnapshot = ({
  Map<String, String> texts,
  Map<String, (bool, String?, int)> items,
  String? color,
  String? background,
});

/// Keep-style editor. Writing autosaves after a pause and when leaving; list
/// changes (checks, order, nesting, removal, colour) apply immediately on
/// screen and are published in one batch. Typed text always names the
/// versions it saw, so unseen writing from collaborators stays as a
/// recoverable branch. Attachments (photos, drawings, recordings) and
/// personal organisation (pin, archive, labels, reminders) apply at once.
class NoteEditor extends StatefulWidget {
  final Notes notes;

  /// Null for a new note, which is created once something is written.
  final String? id;
  final bool checklist;
  final DraftStore drafts;
  final PeerNetwork? network;
  final Files? files;
  final Speech? speech;
  final Map<String, String> friends;
  final String Function(String) personName;

  /// Opens friend invitation and returns the updated friend names.
  final Future<Map<String, String>> Function()? addFriend;
  final void Function(String id)? onRemoved;
  final void Function(String id, bool wasPinned)? onArchived;
  final void Function(String id)? onOpenNote;
  final void Function(String message)? notice;

  /// Asked before a reminder is set, e.g. to request notification permission.
  final Future<void> Function()? onReminderSet;

  /// Records audio; replaced in tests.
  final Future<VoiceRecording?> Function(BuildContext context)? recordVoice;
  final Duration autosaveDelay;
  const NoteEditor({
    super.key,
    required this.notes,
    this.id,
    this.checklist = false,
    required this.drafts,
    this.network,
    this.files,
    this.speech,
    required this.friends,
    required this.personName,
    this.addFriend,
    this.onRemoved,
    this.onArchived,
    this.onOpenNote,
    this.notice,
    this.onReminderSet,
    this.recordVoice,
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
  final pendingIndent = <String, int>{};
  final pendingDeleted = <String>{};

  /// Removed items brought back by undo, published as an explicit restore.
  final pendingRestored = <String>{};
  String? pendingColor, pendingBackground, pendingFormat;
  final flushing = <String>{};
  final status = ValueNotifier<String>('');
  late final CoalescedTask refresh;
  StreamSubscription<void>? changes;
  Timer? autosave;
  Future<void>? saving;
  late Map<String, String> friends = widget.friends;
  String? error;
  bool loading = true, applying = false, showChecked = true;
  bool formatting = false, attaching = false;
  String? focusedItem;
  late bool checklistMode = widget.checklist;

  final undoStack = <EditorSnapshot>[];
  final redoStack = <EditorSnapshot>[];
  String? lastUndoField;
  DateTime lastUndoAt = DateTime(0);

  String draftKey(String field) => 'note/$id/$field';
  bool get editable =>
      id == null || (note != null && note!.available && !note!.deleted);
  bool get markup => (pendingFormat ?? note?.format) == 'markup';

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
    widget.speech?.addListener(_speechChanged);
    input('title');
    input('text');
    if (id == null) {
      loading = false;
      if (widget.checklist) addItem(focusIt: true, remember: false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !widget.checklist) focusFor('text').requestFocus();
      });
    } else {
      unawaited(load());
    }
  }

  void _speechChanged() {
    if (mounted) setState(() {});
  }

  TextEditingController input(String field) => inputs.putIfAbsent(field, () {
    final controller = field == 'text'
        ? MarkupEditingController()
        : TextEditingController();
    controller.addListener(() => changed(field, controller));
    return controller;
  });
  FocusNode focusFor(String field) => focus.putIfAbsent(field, () {
    final node = FocusNode();
    if (field.startsWith('check:')) {
      node.addListener(() {
        final item = field.split(':')[1];
        if (node.hasFocus && focusedItem != item) {
          setState(() => focusedItem = item);
        } else if (!node.hasFocus && focusedItem == item) {
          // Keep the toolbar steady while focus moves between items.
          Future<void>.delayed(const Duration(milliseconds: 50), () {
            if (mounted && focusedItem == item && !node.hasFocus) {
              setState(() => focusedItem = null);
            }
          });
        }
      });
    } else if (field == 'text') {
      node.addListener(() {
        if (mounted) setState(() {});
      });
    }
    return node;
  });

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
    final now = DateTime.now();
    if (field != lastUndoField ||
        now.difference(lastUndoAt) > const Duration(milliseconds: 1200)) {
      remember(field: field, previous: known[field] ?? '');
    }
    lastUndoField = field;
    lastUndoAt = now;
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

  // ---- Undo ----------------------------------------------------------------

  List<String> get textFields => [
    'title',
    'text',
    for (final f in audioFiles) 'file:$f:transcript',
  ];

  EditorSnapshot snapshot({String? field, String? previous}) {
    final texts = <String, String>{
      for (final f in textFields) f: inputs[f]?.text ?? '',
    };
    final items = <String, (bool, String?, int)>{};
    for (final item in allItems()) {
      items[item] = (isDone(item), keyOf(item), indentOf(item));
      texts['check:$item:text'] = inputs['check:$item:text']?.text ?? '';
    }
    if (field != null) texts[field] = previous ?? '';
    return (
      texts: texts,
      items: items,
      color: pendingColor ?? note?.color,
      background: pendingBackground ?? note?.background,
    );
  }

  void remember({String? field, String? previous}) {
    if (!editable) return;
    undoStack.add(snapshot(field: field, previous: previous));
    if (undoStack.length > 100) undoStack.removeAt(0);
    redoStack.clear();
    if (field == null) lastUndoField = null;
  }

  void undo() {
    if (undoStack.isEmpty || !editable) return;
    redoStack.add(snapshot());
    restore(undoStack.removeLast());
  }

  void redo() {
    if (redoStack.isEmpty || !editable) return;
    undoStack.add(snapshot());
    restore(redoStack.removeLast());
  }

  void restore(EditorSnapshot target) {
    lastUndoField = null;
    final current = allItems().toSet();
    for (final item in current.difference(target.items.keys.toSet())) {
      if (localItems.remove(item) == null) {
        if (!pendingRestored.remove(item)) pendingDeleted.add(item);
      }
      dirty.remove('check:$item:text');
    }
    for (final entry in target.items.entries) {
      final item = entry.key;
      final field = 'check:$item:text';
      if (!current.contains(item)) {
        if (note?.checks.contains(item) ?? false) {
          pendingDeleted.remove(item);
        } else if (note?.heads.containsKey(field) ?? false) {
          pendingRestored.add(item);
          bases[field] = (note!.epoch, note!.parents(field));
        } else {
          localItems[item] = entry.value.$2 ?? orderBetween(null, null);
        }
      }
      final (done, key, indent) = entry.value;
      if (isDone(item) != done) pendingDone[item] = done;
      if (key != null && keyOf(item) != key) setKey(item, key);
      if (indentOf(item) != indent) pendingIndent[item] = indent;
    }
    for (final entry in target.texts.entries) {
      if (inputs[entry.key]?.text == entry.value) continue;
      if (!inputs.containsKey(entry.key) &&
          !entry.key.startsWith('check:') &&
          entry.value.isEmpty) {
        continue;
      }
      setText(entry.key, entry.value, cursor: entry.value.length);
      if (entry.key.startsWith('check:') &&
          localItems.containsKey(entry.key.split(':')[1])) {
        dirty.add(entry.key);
      } else {
        markDirty(entry.key);
      }
    }
    if ((target.color ?? 'default') !=
        (pendingColor ?? note?.color ?? 'default')) {
      pendingColor = target.color ?? 'default';
    }
    if ((target.background ?? 'none') !=
        (pendingBackground ?? note?.background ?? 'none')) {
      pendingBackground = target.background ?? 'none';
    }
    if (target.items.isNotEmpty) checklistMode = true;
    setState(() {});
    scheduleSave(Duration.zero);
  }

  // ---- Items -------------------------------------------------------------

  String? keyOf(String item) =>
      pendingOrder[item] ?? localItems[item] ?? note?.order(item);
  bool isDone(String item) => pendingDone[item] ?? note?.done(item) ?? false;
  int indentOf(String item) => pendingIndent[item] ?? note?.indent(item) ?? 0;

  /// All live items in display order, including unsaved local ones.
  List<String> allItems() {
    final ids = [
      ...?note?.checks.where((c) => !pendingDeleted.contains(c)),
      ...pendingRestored.where((c) => !(note?.checks.contains(c) ?? false)),
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

  String? addItem({
    String? after,
    String text = '',
    bool focusIt = false,
    bool remember = true,
    int? indent,
  }) {
    var order = allItems();
    if (order.length >= Notes.maxChecks) {
      setState(() => error = 'A checklist supports ${Notes.maxChecks} items.');
      return null;
    }
    if (remember) this.remember();
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
    final level = indent ?? (after == null ? 0 : indentOf(after));
    if (level > 0) pendingIndent[item] = level;
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
      final added = addItem(after: after, text: part, remember: false);
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

  void removeItem(
    String item, {
    bool focusPrevious = false,
    bool remember = true,
  }) {
    if (remember) this.remember();
    final order = allItems();
    final index = order.indexOf(item);
    if (localItems.remove(item) == null && !pendingRestored.remove(item)) {
      pendingDeleted.add(item);
    }
    pendingIndent.remove(item);
    dirty.remove('check:$item:text');
    if (id != null) widget.drafts.put(draftKey('check:$item:text'), '', (_) {});
    if (focusPrevious && index > 0) {
      final previous = 'check:${order[index - 1]}:text';
      focusFor(previous).requestFocus();
      inputs[previous]!.selection = TextSelection.collapsed(
        offset: inputs[previous]!.text.length,
      );
    }
    if (mounted) setState(() {});
    scheduleSave(Duration.zero);
  }

  /// Items nested under [item], in order.
  List<String> childrenOf(String item, [List<String>? order]) {
    final items = order ?? allItems();
    final index = items.indexOf(item);
    if (index < 0 || indentOf(item) > 0) return const [];
    return [
      for (var i = index + 1; i < items.length && indentOf(items[i]) > 0; i++)
        items[i],
    ];
  }

  String? parentOf(String item, [List<String>? order]) {
    if (indentOf(item) == 0) return null;
    final items = order ?? allItems();
    for (var i = items.indexOf(item) - 1; i >= 0; i--) {
      if (indentOf(items[i]) == 0) return items[i];
    }
    return null;
  }

  /// Checking an item also checks what is nested under it; unchecking a
  /// nested item unchecks its parent, as in Keep.
  void toggle(String item, bool value) {
    remember();
    setState(() {
      pendingDone[item] = value;
      for (final child in childrenOf(item)) {
        pendingDone[child] = value;
      }
      final parent = parentOf(item);
      if (!value && parent != null && isDone(parent)) {
        pendingDone[parent] = false;
      }
    });
    scheduleSave(Duration.zero);
  }

  bool canIndent(String item) {
    final items = allItems();
    final index = items.indexOf(item);
    return index > 0 && indentOf(item) == 0 && childrenOf(item, items).isEmpty;
  }

  void setIndent(String item, int level) {
    if (level == indentOf(item) || (level > 0 && !canIndent(item))) return;
    remember();
    setState(() => pendingIndent[item] = level);
    scheduleSave(Duration.zero);
  }

  void reorder(int from, int to) {
    final unchecked = allItems().where((i) => !isDone(i)).toList();
    if (from == to || from >= unchecked.length) return;
    final moved = unchecked[from];
    final block = [moved, ...childrenOf(moved, unchecked)];
    final without = [...unchecked]..removeAt(from);
    final anchor = to < without.length ? without[to] : null;
    if (anchor != null && block.contains(anchor)) return;
    remember();
    final remaining = unchecked.where((i) => !block.contains(i)).toList();
    final at = anchor == null ? remaining.length : remaining.indexOf(anchor);
    final previous = at > 0 ? remaining[at - 1] : null;
    final next = at < remaining.length ? remaining[at] : null;
    var low = previous == null ? null : keyOf(previous);
    final high = next == null ? null : keyOf(next);
    if ((previous != null && low == null) ||
        (next != null && high == null) ||
        (low != null && high != null && low.compareTo(high) >= 0)) {
      final full = allItems()..removeWhere(block.contains);
      final position = previous == null ? 0 : full.indexOf(previous) + 1;
      renumber(full..insertAll(position, block));
    } else {
      for (final item in block) {
        final key = orderBetween(low, high);
        setKey(item, key);
        low = key;
      }
    }
    // A nested item moved to the top of the list has no parent.
    if (previous == null && indentOf(moved) > 0) pendingIndent[moved] = 0;
    setState(() {});
    scheduleSave(Duration.zero);
  }

  void uncheckAll() {
    remember();
    setState(() {
      for (final item in allItems().where(isDone)) {
        pendingDone[item] = false;
      }
    });
    scheduleSave(Duration.zero);
  }

  void deleteChecked() {
    remember();
    for (final item in allItems().where(isDone).toList()) {
      removeItem(item, remember: false);
    }
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
      for (final f in next.files)
        if (next.fileMeta(f)['kind'] == 'audio') 'file:$f:transcript',
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
    pendingIndent.removeWhere(
      (item, value) =>
          next.indent(item) == value &&
          !flushing.contains('check:$item:indent'),
    );
    pendingDeleted.removeWhere(
      (item) =>
          !next.checks.contains(item) &&
          !flushing.contains('check:$item:deleted'),
    );
    pendingRestored.removeWhere(
      (item) =>
          next.checks.contains(item) &&
          !flushing.contains('check:$item:deleted'),
    );
    if (pendingColor == (next.color ?? 'default') &&
        !flushing.contains('color')) {
      pendingColor = null;
    }
    if (pendingBackground == (next.background ?? 'none') &&
        !flushing.contains('background')) {
      pendingBackground = null;
    }
    if (pendingFormat == next.format && !flushing.contains('format')) {
      pendingFormat = null;
    }
    (inputs['text'] as MarkupEditingController).enabled = markup;
  }

  bool get hasChanges =>
      dirty.isNotEmpty ||
      localItems.isNotEmpty ||
      pendingDone.isNotEmpty ||
      pendingOrder.isNotEmpty ||
      pendingIndent.isNotEmpty ||
      pendingDeleted.isNotEmpty ||
      pendingRestored.isNotEmpty ||
      pendingColor != null ||
      pendingBackground != null ||
      pendingFormat != null;

  void scheduleSave([Duration? delay]) {
    autosave?.cancel();
    autosave = Timer(delay ?? widget.autosaveDelay, () => unawaited(flush()));
  }

  /// Saves everything changed so far. Calls run one after another. [create]
  /// makes a new note even when nothing has been written (for attachments).
  Future<void> flush({bool create = false}) {
    autosave?.cancel();
    final next = (saving ?? Future<void>.value()).then(
      (_) => _flush(create: create),
    );
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

  Future<void> _flush({bool create = false}) async {
    if (!hasChanges && !(create && id == null)) return;
    status.value = 'Saving…';
    try {
      if (id == null) {
        final title = inputs['title']!.text, text = inputs['text']!.text;
        final items = allItems().map((i) => inputs['check:$i:text']!.text);
        if (!create && '$title$text${items.join()}'.trim().isEmpty) {
          status.value = '';
          return;
        }
        final created = await widget.notes.create(
          stableId: stableId,
          title: title,
          text: text,
          color: pendingColor,
          background: pendingBackground,
          format: pendingFormat,
        );
        id = created.id;
        note = created;
        if (pendingColor == created.color) pendingColor = null;
        if (pendingBackground == created.background) pendingBackground = null;
        if (pendingFormat == created.format) pendingFormat = null;
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
      // A restored item's other fields wait until the restore is published.
      bool waiting(String item) => pendingRestored.contains(item);
      for (final field in dirty) {
        final base = bases[field];
        if (base == null || base.$1 != epoch) continue;
        if (field.startsWith('check:') && waiting(field.split(':')[1])) {
          continue;
        }
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
      for (final item in pendingRestored) {
        final field = 'check:$item:deleted';
        changes.add((
          field: field,
          value: false,
          parents: current.parents(field),
        ));
      }
      void register(String field, Object value) => changes.add((
        field: field,
        value: value,
        parents: current.parents(field),
      ));
      for (final entry in pendingOrder.entries) {
        if (!waiting(entry.key)) {
          register('check:${entry.key}:order', entry.value);
        }
      }
      for (final entry in pendingIndent.entries) {
        if (!waiting(entry.key)) {
          register('check:${entry.key}:indent', entry.value);
        }
      }
      for (final entry in pendingDone.entries) {
        if (!waiting(entry.key)) {
          register('check:${entry.key}:done', entry.value);
        }
      }
      for (final item in pendingDeleted) {
        register('check:$item:deleted', true);
      }
      if (pendingColor != null) register('color', pendingColor!);
      if (pendingBackground != null) register('background', pendingBackground!);
      if (pendingFormat != null) register('format', pendingFormat!);
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
      pendingRestored.isNotEmpty ||
      pendingDone.entries.any((e) => saved['check:${e.key}:done'] != e.value) ||
      pendingOrder.entries.any(
        (e) => saved['check:${e.key}:order'] != e.value,
      ) ||
      pendingIndent.entries.any(
        (e) => saved['check:${e.key}:indent'] != e.value,
      ) ||
      pendingDeleted.any((i) => !saved.containsKey('check:$i:deleted')) ||
      (pendingColor != null && saved['color'] != pendingColor) ||
      (pendingBackground != null && saved['background'] != pendingBackground) ||
      (pendingFormat != null && saved['format'] != pendingFormat);

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
    widget.speech?.removeListener(_speechChanged);
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
                    'Changes take effect as devices reconnect. Removed collaborators can keep received copies. Offline edits from an earlier membership stay in Recovery on devices that received them. Labels, pins, archive and reminders stay personal.',
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
          (field == 'title' ||
              field == 'text' ||
              field.endsWith(':text') ||
              field.endsWith(':transcript')) &&
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
                            (k.startsWith('check:') || k.startsWith('file:')) &&
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
                    field.startsWith('file:')
                        ? 'Restore ${current.file(field.split(':')[1])?.data['name'] ?? 'attachment'}'
                        : 'Restore ${current.value(field.replaceAll(':deleted', ':text')) ?? 'checklist item'}',
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
                      '${widget.personName(version.object.author)} · ${field.startsWith('check:')
                          ? 'list item'
                          : field.startsWith('file:')
                          ? 'transcript'
                          : field}${version.data['epoch'] != current.epoch ? ' · Earlier collaborators' : ''}',
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

  Future<void> archive() async {
    if (!await ensureNote()) return;
    final noteId = id!;
    final archived = widget.notes.state.archived(noteId);
    final wasPinned = widget.notes.pinned(noteId);
    try {
      await widget.notes.state.archive([noteId], !archived);
    } catch (e) {
      report(e);
      return;
    }
    if (archived) {
      setState(() {});
      widget.notice?.call('Note unarchived');
      return;
    }
    if (mounted) await Navigator.maybePop(context);
    widget.onArchived?.call(noteId, wasPinned);
  }

  Future<void> makeCopy() async {
    await flush();
    final noteId = id;
    if (noteId == null) return;
    try {
      final copy = await widget.notes.copy(noteId);
      if (mounted) await Navigator.maybePop(context);
      widget.onOpenNote?.call(copy.id);
    } catch (e) {
      report(e);
    }
  }

  Future<void> labels() async {
    if (!await ensureNote() || !mounted) return;
    await editNoteLabels(context, widget.notes.state, [
      id!,
    ], notice: widget.notice ?? report);
    if (mounted) setState(() {});
  }

  Future<void> reminder() async {
    if (!await ensureNote() || !mounted) return;
    final state = widget.notes.state;
    final chosen = await pickReminder(context, state.reminder(id!));
    if (chosen == null) return;
    try {
      if (chosen.at != null) await widget.onReminderSet?.call();
      await state.setReminder(id!, chosen.at, repeat: chosen.repeat);
    } catch (e) {
      report(e);
    }
    if (mounted) setState(() {});
  }

  Future<void> share() async {
    await flush();
    final current = note;
    final files = widget.files;
    final shared = <XFile>[];
    if (current != null && files != null) {
      for (final f in imageFiles.take(10)) {
        final op = current.file(f)!;
        try {
          final bytes = await files.readBytes(op.object, limit: 16 << 20);
          shared.add(
            XFile.fromData(
              bytes,
              name: op.data['name'] as String?,
              mimeType: current.fileMeta(f)['mime'] as String?,
            ),
          );
        } catch (_) {
          /* Images not on this device yet are left out. */
        }
      }
    }
    try {
      await SharePlus.instance.share(
        ShareParams(
          text: plainText(),
          subject: inputs['title']!.text.trim().isEmpty
              ? null
              : inputs['title']!.text.trim(),
          files: shared.isEmpty ? null : shared,
        ),
      );
    } catch (e) {
      report('Sharing is unavailable: $e');
    }
  }

  String plainText() {
    String plain(String text) => markup ? NoteMarkup.plain(text) : text;
    final lines = <String>[
      if (inputs['title']!.text.trim().isNotEmpty) inputs['title']!.text,
      if (inputs['text']!.text.isNotEmpty) plain(inputs['text']!.text),
      for (final item in allItems())
        '${'    ' * indentOf(item)}${isDone(item) ? '☑' : '☐'} ${inputs['check:$item:text']!.text}',
      for (final f in audioFiles)
        if ((inputs['file:$f:transcript']?.text ?? '').trim().isNotEmpty)
          inputs['file:$f:transcript']!.text,
    ];
    return lines.join('\n');
  }

  void toggleCheckboxes() {
    remember();
    if (checklistMode && allItems().isNotEmpty) {
      final items = allItems();
      final text = [
        if (inputs['text']!.text.isNotEmpty) inputs['text']!.text,
        ...items.map((i) => inputs['check:$i:text']!.text),
      ].join('\n');
      for (final item in items) {
        if (localItems.remove(item) == null && !pendingRestored.remove(item)) {
          pendingDeleted.add(item);
        }
        dirty.remove('check:$item:text');
      }
      setText('text', text, cursor: text.length);
      markDirty('text');
      setState(() => checklistMode = false);
    } else {
      final lines = inputs['text']!.text
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .map((l) => markup ? NoteMarkup.plain(l) : l)
          .toList();
      setText('text', '', cursor: 0);
      if (note?.text.isNotEmpty ?? false) markDirty('text');
      setState(() => checklistMode = true);
      String? after;
      for (final line in lines.take(Notes.maxChecks)) {
        after = addItem(after: after, text: line, remember: false) ?? after;
      }
      if (lines.isEmpty) addItem(focusIt: true, remember: false);
    }
    scheduleSave(Duration.zero);
  }

  // ---- Formatting ---------------------------------------------------------

  void format(TextEditingValue Function(TextEditingValue value) change) {
    if (!editable) return;
    final controller = inputs['text']!;
    if (!markup) {
      pendingFormat = 'markup';
      (controller as MarkupEditingController).enabled = true;
      scheduleSave();
    }
    controller.value = change(controller.value);
    focusFor('text').requestFocus();
    setState(() {});
  }

  // ---- Attachments --------------------------------------------------------

  List<String> get audioFiles => [
    for (final f in note?.files ?? const <String>[])
      if (note!.fileMeta(f)['kind'] == 'audio') f,
  ];
  List<String> get imageFiles => [
    for (final f in note?.files ?? const <String>[])
      if (['image', 'drawing'].contains(note!.fileMeta(f)['kind'])) f,
  ];

  /// Creates a new note first so something can be attached to it.
  Future<bool> ensureNote() async {
    if (id == null) await flush(create: true);
    return id != null && note != null;
  }

  Future<void> withNote(Future<void> Function() action) async {
    if (attaching) return;
    setState(() => attaching = true);
    try {
      if (!await ensureNote()) return;
      await action();
      await load();
    } catch (e) {
      report(e);
    } finally {
      if (mounted) setState(() => attaching = false);
    }
  }

  Future<void> addRecording() async {
    final record = widget.recordVoice ?? recordVoice;
    final recording = await record(context);
    if (recording == null) return;
    await withNote(() async {
      final file = File(recording.path);
      try {
        final attached = await widget.notes.attach(
          id!,
          note!.epoch,
          file.openRead(),
          name: recording.name,
          meta: {
            'kind': 'audio',
            'mime': recording.mime,
            'duration': recording.duration,
          },
        );
        await transcribe(attached);
      } finally {
        if (await file.exists()) await file.delete();
      }
    });
  }

  Future<void> transcribe(String file, {bool replace = false}) async {
    final speech = widget.speech;
    if (speech == null || id == null) return;
    if (speech.engine == 'off') return;
    if (speech.engine == 'whisper' && !await speech.installed(speech.model)) {
      if (!mounted) return;
      final ready = await offerSpeechModel(context, speech);
      if (!ready) return;
    }
    speech.transcribe(id!, file, replace: replace);
  }

  Future<void> addImage(ImageSource source) async {
    final XFile? picked;
    try {
      picked = await ImagePicker().pickImage(source: source);
    } catch (e) {
      report('Images are unavailable: $e');
      return;
    }
    if (picked == null) return;
    await withNote(() async {
      final name = picked!.name;
      final extension = name.split('.').last.toLowerCase();
      await widget.notes.attach(
        id!,
        note!.epoch,
        picked.openRead(),
        name:
            RegExp(
              r'\.(png|jpe?g|webp|gif|bmp)$',
              caseSensitive: false,
            ).hasMatch(name)
            ? name
            : '$name.jpg',
        meta: {
          'kind': 'image',
          'mime': switch (extension) {
            'png' => 'image/png',
            'webp' => 'image/webp',
            'gif' => 'image/gif',
            _ => 'image/jpeg',
          },
        },
      );
    });
  }

  Future<void> addDrawing({String? existing}) async {
    final files = widget.files;
    var strokes = <Stroke>[];
    final current = note;
    if (existing != null && current != null && files != null) {
      final op = current.strokes(existing);
      if (op == null) {
        report('This drawing cannot be edited here.');
        return;
      }
      try {
        strokes = decodeStrokes(await files.readBytes(op.object));
      } catch (e) {
        report('This drawing is not available on this device yet.');
        return;
      }
    }
    if (!mounted) return;
    final result = await editDrawing(context, strokes: strokes);
    if (result == null) return;
    await withNote(() async {
      final latest = note!;
      final file = await widget.notes.attach(
        id!,
        latest.epoch,
        Stream.value(result.png),
        name: 'Drawing.png',
        fileId: existing,
        parents: existing == null
            ? const []
            : latest.parents('file:$existing:meta'),
        meta: {
          'kind': 'drawing',
          'mime': 'image/png',
          'width': result.width,
          'height': result.height,
        },
      );
      await widget.notes.attach(
        id!,
        latest.epoch,
        Stream.value(result.strokes),
        name: 'Drawing.json',
        fileId: file,
        field: 'strokes',
        parents: existing == null
            ? const []
            : latest.parents('file:$existing:strokes'),
        meta: {'version': 1},
      );
    });
  }

  Future<void> removeFile(String file) async {
    final current = note;
    if (current == null || !editable) return;
    final field = 'file:$file:deleted';
    try {
      await widget.notes.edit(
        current.id,
        current.epoch,
        field,
        true,
        current.parents(field),
      );
      widget.speech?.cancel(file);
      await load();
    } catch (e) {
      report(e);
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('Attachment removed'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () async {
              final latest = await widget.notes.get(current.id);
              if (latest == null) return;
              await run(
                () => widget.notes.edit(
                  latest.id,
                  latest.epoch,
                  field,
                  false,
                  latest.parents(field),
                ),
              );
            },
          ),
        ),
      );
  }

  Future<void> addMenu() async {
    final camera =
        !Platform.environment.containsKey('FLUTTER_TEST') &&
        ImagePicker().supportsImageSource(ImageSource.camera);
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (camera)
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Take photo'),
                onTap: () => Navigator.pop(context, 'camera'),
              ),
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text('Add image'),
              onTap: () => Navigator.pop(context, 'image'),
            ),
            ListTile(
              leading: const Icon(Icons.brush_outlined),
              title: const Text('Drawing'),
              onTap: () => Navigator.pop(context, 'drawing'),
            ),
            ListTile(
              leading: const Icon(Icons.mic_none),
              title: const Text('Recording'),
              onTap: () => Navigator.pop(context, 'recording'),
            ),
            ListTile(
              leading: const Icon(Icons.check_box_outlined),
              title: Text(
                checklistMode && allItems().isNotEmpty
                    ? 'Hide checkboxes'
                    : 'Checkboxes',
              ),
              onTap: () => Navigator.pop(context, 'checkboxes'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'camera':
        await addImage(ImageSource.camera);
      case 'image':
        await addImage(ImageSource.gallery);
      case 'drawing':
        await addDrawing();
      case 'recording':
        await addRecording();
      case 'checkboxes':
        toggleCheckboxes();
    }
  }

  Future<void> style() async {
    final chosen = await pickNoteColor(
      context,
      pendingColor ?? note?.color,
      background: pendingBackground ?? note?.background,
      backgrounds: true,
    );
    if (chosen == null || !mounted) return;
    remember();
    setState(() {
      if (chosen.startsWith('background:')) {
        pendingBackground = chosen.substring('background:'.length);
      } else {
        pendingColor = chosen;
      }
    });
    scheduleSave(Duration.zero);
  }

  void openImages(int index) {
    final files = widget.files;
    final current = note;
    if (files == null || current == null) return;
    final images = [for (final f in imageFiles) current.file(f)!];
    unawaited(
      viewNoteImages(
        context,
        files: files,
        images: images,
        initial: index,
        onRemove: editable
            ? (image) =>
                  removeFile((image.data['field'] as String).split(':')[1])
            : null,
        actions: (image) {
          final file = (image.data['field'] as String).split(':')[1];
          return [
            if (editable &&
                current.fileMeta(file)['kind'] == 'drawing' &&
                current.strokes(file) != null)
              IconButton(
                tooltip: 'Edit drawing',
                onPressed: () {
                  Navigator.pop(context);
                  unawaited(addDrawing(existing: file));
                },
                icon: const Icon(Icons.brush_outlined),
              ),
            if (editable && ImageText.supported)
              IconButton(
                tooltip: 'Grab image text',
                onPressed: () {
                  Navigator.pop(context);
                  unawaited(grabText(image));
                },
                icon: const Icon(Icons.document_scanner_outlined),
              ),
          ];
        },
      ),
    );
  }

  /// Adds text recognised in [image] to the end of the note, like Keep.
  Future<void> grabText(EverydayItem image) async {
    final files = widget.files;
    if (files == null) return;
    setState(() => attaching = true);
    try {
      final text = await ImageText.read(
        await files.readBytes(image.object, limit: 32 * 1024 * 1024),
        image.data['name'] as String? ?? 'image.jpg',
      );
      if (!mounted) return;
      if (text.isEmpty) {
        widget.notice?.call('No text found in this image');
        return;
      }
      final controller = inputs['text']!;
      final existing = controller.text.trimRight();
      final combined = existing.isEmpty ? text : '$existing\n\n$text';
      controller.value = TextEditingValue(
        text: combined.substring(0, combined.length.clamp(0, 16384)),
        selection: TextSelection.collapsed(
          offset: combined.length.clamp(0, 16384),
        ),
      );
    } catch (e) {
      report('Could not read text from the image: $e');
    } finally {
      if (mounted) setState(() => attaching = false);
    }
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
    final nested = !checked && indentOf(item) > 0;
    return Padding(
      key: ValueKey(item),
      padding: EdgeInsets.only(top: 1, bottom: 1, left: nested ? 28 : 0),
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
                if (event is! KeyDownEvent) return KeyEventResult.ignored;
                if (event.logicalKey == LogicalKeyboardKey.backspace &&
                    controller.text.isEmpty) {
                  removeItem(item, focusPrevious: true);
                  return KeyEventResult.handled;
                }
                if (event.logicalKey == LogicalKeyboardKey.tab && !checked) {
                  final outdent = HardwareKeyboard.instance.isShiftPressed;
                  if (outdent ? indentOf(item) > 0 : canIndent(item)) {
                    setIndent(item, outdent ? 0 : 1);
                    return KeyEventResult.handled;
                  }
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

  Widget audioClip(String file) {
    final current = note!;
    final field = 'file:$file:transcript';
    final files = widget.files;
    final transcript = TextField(
      controller: input(field),
      focusNode: focusFor(field),
      enabled: editable,
      maxLines: null,
      inputFormatters: [LengthLimitingTextInputFormatter(16384)],
      style: Theme.of(context).textTheme.bodyMedium,
      decoration: const InputDecoration.collapsed(hintText: 'Transcript'),
    );
    if (files == null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            const Icon(Icons.mic_none),
            const SizedBox(width: 8),
            Expanded(child: transcript),
          ],
        ),
      );
    }
    final speech = widget.speech;
    return Padding(
      key: ValueKey('audio/$file'),
      padding: const EdgeInsets.only(bottom: 8),
      child: AudioClip(
        files: files,
        op: current.file(file)!,
        meta: current.fileMeta(file),
        transcript: transcript,
        status: speech?.status[file],
        editable: editable,
        onTranscribe: speech == null
            ? null
            : () => transcribe(file, replace: true),
        onCancelTranscription: speech == null
            ? null
            : () => speech.cancel(file),
        onRemove: () => removeFile(file),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final current = note;
    final theme = Theme.of(context);
    final background =
        noteColor(context, pendingColor ?? current?.color) ??
        theme.colorScheme.surface;
    final pattern = pendingBackground ?? current?.background;
    final items = allItems();
    final unchecked = items.where((i) => !isDone(i)).toList();
    final checked = items.where(isDone).toList();
    final showText =
        !checklistMode || inputs['text']!.text.isNotEmpty || items.isEmpty;
    final state = widget.notes.state;
    final pinned = id != null && state.pinned(id!);
    final archived = id != null && state.archived(id!);
    final labelIds = id == null ? const <String>[] : state.labelsOf(id!);
    final labelNames = state.labels;
    final reminderValue = id == null ? null : state.reminder(id!);
    final images = imageFiles;
    final audio = audioFiles;
    final review =
        current != null &&
        dirty.any((field) {
          final base = bases[field];
          return base != null && base.$1 != current.epoch;
        });
    final textFocused = focus['text']?.hasFocus ?? false;
    final item = focusedItem != null && items.contains(focusedItem)
        ? focusedItem
        : null;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.maybePop(context),
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () =>
            unawaited(flush()),
        const SingleActivator(
          LogicalKeyboardKey.keyZ,
          control: true,
          shift: true,
        ): redo,
        const SingleActivator(LogicalKeyboardKey.keyY, control: true): redo,
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): undo,
        const SingleActivator(LogicalKeyboardKey.keyB, control: true): () =>
            format((v) => NoteMarkup.wrap(v, '**')),
        const SingleActivator(LogicalKeyboardKey.keyI, control: true): () =>
            format((v) => NoteMarkup.wrap(v, '*')),
        const SingleActivator(LogicalKeyboardKey.keyU, control: true): () =>
            format((v) => NoteMarkup.wrap(v, '__')),
      },
      child: Scaffold(
        backgroundColor: background,
        appBar: AppBar(
          backgroundColor: background,
          scrolledUnderElevation: 0,
          actions: [
            IconButton(
              tooltip: pinned ? 'Unpin' : 'Pin',
              onPressed: () async {
                if (!await ensureNote()) return;
                await widget.notes.pin(id!, !pinned);
                if (mounted) setState(() {});
              },
              icon: Icon(pinned ? Icons.push_pin : Icons.push_pin_outlined),
            ),
            IconButton(
              tooltip: 'Remind me',
              onPressed: editable || current != null ? reminder : null,
              icon: Icon(
                reminderValue == null
                    ? Icons.notification_add_outlined
                    : Icons.notifications_active_outlined,
              ),
            ),
            IconButton(
              tooltip: archived ? 'Unarchive' : 'Archive',
              onPressed: archive,
              icon: Icon(
                archived ? Icons.unarchive_outlined : Icons.archive_outlined,
              ),
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
                if (editable && checked.isNotEmpty) ...[
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.check_box_outline_blank),
                    onPressed: uncheckAll,
                    child: const Text('Uncheck all items'),
                  ),
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.playlist_remove),
                    onPressed: deleteChecked,
                    child: const Text('Delete checked items'),
                  ),
                ],
                MenuItemButton(
                  leadingIcon: const Icon(Icons.label_outline),
                  onPressed: labels,
                  child: Text(labelIds.isEmpty ? 'Add label' : 'Change labels'),
                ),
                if (current != null)
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.control_point_duplicate),
                    onPressed: makeCopy,
                    child: const Text('Make a copy'),
                  ),
                MenuItemButton(
                  leadingIcon: const Icon(Icons.share_outlined),
                  onPressed: share,
                  child: const Text('Send'),
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
        body: NoteBackground(
          name: pattern,
          child: Column(
            children: [
              if (attaching) const LinearProgressIndicator(minHeight: 2),
              Expanded(
                child: loading
                    ? const Center(child: CircularProgressIndicator())
                    : Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 760),
                          child: CustomScrollView(
                            key: PageStorageKey('editor/${widget.id}'),
                            slivers: [
                              if (images.isNotEmpty &&
                                  widget.files != null &&
                                  current != null)
                                SliverToBoxAdapter(
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      12,
                                      0,
                                      12,
                                      12,
                                    ),
                                    child: NoteImages(
                                      files: widget.files!,
                                      images: [
                                        for (final f in images)
                                          current.file(f)!,
                                      ],
                                      online: widget.network?.running ?? false,
                                      onOpen: openImages,
                                    ),
                                  ),
                                ),
                              SliverPadding(
                                padding: const EdgeInsets.fromLTRB(
                                  20,
                                  4,
                                  20,
                                  0,
                                ),
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
                                      decoration:
                                          const InputDecoration.collapsed(
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
                                          LengthLimitingTextInputFormatter(
                                            16384,
                                          ),
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
                                          indent: 0,
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
                              if (audio.isNotEmpty && current != null)
                                SliverPadding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    12,
                                    16,
                                    0,
                                  ),
                                  sliver: SliverList.list(
                                    children: [
                                      for (final f in audio) audioClip(f),
                                    ],
                                  ),
                                ),
                              if (labelIds.isNotEmpty || reminderValue != null)
                                SliverPadding(
                                  padding: const EdgeInsets.fromLTRB(
                                    20,
                                    12,
                                    20,
                                    0,
                                  ),
                                  sliver: SliverToBoxAdapter(
                                    child: NoteChips(
                                      labels: [
                                        for (final l in labelIds)
                                          labelNames[l]!,
                                      ],
                                      reminder: reminderValue,
                                      onReminder: reminder,
                                      onRemoveReminder: () async {
                                        await state.setReminder(id!, null);
                                        if (mounted) setState(() {});
                                      },
                                      onRemoveLabel: (name) async {
                                        final label = labelNames.entries
                                            .firstWhere((e) => e.value == name)
                                            .key;
                                        await state.label([id!], label, false);
                                        if (mounted) setState(() {});
                                      },
                                    ),
                                  ),
                                ),
                              const SliverToBoxAdapter(
                                child: SizedBox(height: 48),
                              ),
                            ],
                          ),
                        ),
                      ),
              ),
              if (formatting && textFocused && editable && !checklistMode)
                _formatBar(theme),
              // In the body, not bottomNavigationBar, so it rides above the keyboard.
              SafeArea(
                child: Container(
                  height: 52,
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Add',
                        onPressed: editable && !attaching ? addMenu : null,
                        icon: const Icon(Icons.add_box_outlined),
                      ),
                      IconButton(
                        tooltip: 'Colour and background',
                        onPressed: editable ? style : null,
                        icon: const Icon(Icons.palette_outlined),
                      ),
                      if (item != null && editable)
                        IconButton(
                          tooltip: indentOf(item) > 0
                              ? 'Move item out'
                              : 'Nest item',
                          onPressed: indentOf(item) > 0
                              ? () => setIndent(item, 0)
                              : canIndent(item)
                              ? () => setIndent(item, 1)
                              : null,
                          icon: Icon(
                            indentOf(item) > 0
                                ? Icons.format_indent_decrease
                                : Icons.format_indent_increase,
                          ),
                        )
                      else if (!checklistMode || items.isEmpty)
                        IconButton(
                          tooltip: 'Formatting',
                          isSelected: formatting,
                          onPressed: editable
                              ? () {
                                  setState(() => formatting = !formatting);
                                  focusFor('text').requestFocus();
                                }
                              : null,
                          icon: const Icon(Icons.text_format),
                        ),
                      if (current != null && current.members.length > 1)
                        InkWell(
                          borderRadius: BorderRadius.circular(20),
                          onTap: collaborators,
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: Row(
                              children: [
                                for (final person in current.members.take(3))
                                  Padding(
                                    padding: const EdgeInsets.only(right: 2),
                                    child: PersonAvatar(
                                      name: nameOf(person),
                                      radius: 12,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      const SizedBox(width: 4),
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
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: style,
                              );
                            }
                            final prefix =
                                'Edited ${edited(context, current.updated)} · ';
                            return Align(
                              alignment: Alignment.center,
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
                      IconButton(
                        tooltip: 'Undo',
                        onPressed: undoStack.isEmpty || !editable ? null : undo,
                        icon: const Icon(Icons.undo),
                      ),
                      IconButton(
                        tooltip: 'Redo',
                        onPressed: redoStack.isEmpty || !editable ? null : redo,
                        icon: const Icon(Icons.redo),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _formatBar(ThemeData theme) {
    final level = NoteMarkup.headingAt(inputs['text']!.value);
    Widget button(
      String tooltip,
      Widget icon,
      VoidCallback onPressed, {
      bool selected = false,
    }) => IconButton(
      tooltip: tooltip,
      isSelected: selected,
      onPressed: onPressed,
      icon: icon,
    );
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            button(
              'Heading 1',
              const Text('H1', style: TextStyle(fontWeight: FontWeight.w700)),
              () => format((v) => NoteMarkup.heading(v, level == 1 ? 0 : 1)),
              selected: level == 1,
            ),
            button(
              'Heading 2',
              const Text('H2', style: TextStyle(fontWeight: FontWeight.w600)),
              () => format((v) => NoteMarkup.heading(v, level == 2 ? 0 : 2)),
              selected: level == 2,
            ),
            button(
              'Normal text',
              const Icon(Icons.text_fields),
              () => format((v) => NoteMarkup.heading(v, 0)),
              selected: level == 0,
            ),
            const SizedBox(height: 24, child: VerticalDivider()),
            button(
              'Bold',
              const Icon(Icons.format_bold),
              () => format((v) => NoteMarkup.wrap(v, '**')),
            ),
            button(
              'Italic',
              const Icon(Icons.format_italic),
              () => format((v) => NoteMarkup.wrap(v, '*')),
            ),
            button(
              'Underline',
              const Icon(Icons.format_underlined),
              () => format((v) => NoteMarkup.wrap(v, '__')),
            ),
            button(
              'Clear formatting',
              const Icon(Icons.format_clear),
              () => format((v) {
                final start = v.selection.start, end = v.selection.end;
                if (start < 0 || start == end) {
                  return TextEditingValue(
                    text: NoteMarkup.plain(v.text),
                    selection: TextSelection.collapsed(
                      offset: NoteMarkup.plain(v.text).length,
                    ),
                  );
                }
                final cleared = NoteMarkup.plain(v.text.substring(start, end));
                return TextEditingValue(
                  text: v.text.replaceRange(start, end, cleared),
                  selection: TextSelection(
                    baseOffset: start,
                    extentOffset: start + cleared.length,
                  ),
                );
              }),
            ),
            IconButton(
              tooltip: 'Close formatting',
              onPressed: () => setState(() => formatting = false),
              icon: const Icon(Icons.close),
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
