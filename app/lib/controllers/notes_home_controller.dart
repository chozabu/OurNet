import 'package:flutter/widgets.dart';
import 'package:ournet_core/ournet_core.dart';

/// Notes added to the list each time scrolling nears its end.
const notesPage = 60;

typedef NotesView = ({
  Set<Object?> pins,
  List<EverydayItem> visible,
  List<EverydayItem> pinned,
  List<EverydayItem> others,
});

/// Owns notes filtering, selection and cached presentation independently of
/// application navigation and platform services. Reuse it across data refreshes.
class NotesHomeController {
  final Notes notes;
  NotesHomeController(this.notes);
  static const removedDays = 7;
  String notesFilter = 'All';
  final notesSearch = TextEditingController();
  bool notesGrid = true;

  /// Optimistic list state shown before summaries catch up.
  final hiddenNotes = <String>{};
  final selectedNotes = <String>{};
  final noteObjects = <String, SignedObject?>{};
  final notesSearchFocus = FocusNode();
  final noteChecks = <String, Map<String, bool>>{};

  /// The filtered, sorted notes list and what it was computed from.
  NotesView? notesView;
  Object? notesViewKey;
  List<EverydayItem>? notesViewSource;

  /// Notes shown in Others; grows a page at a time while scrolling.
  int notesShown = notesPage;
  bool emptied(Json p) {
    final at = p['removedAt'] as int?;
    return notes.state.purged(p['entry'], p['removal'] as String?) ||
        (at != null &&
            DateTime.now().millisecondsSinceEpoch - at >
                removedDays * Duration.millisecondsPerDay);
  }

  bool notesMatch(EverydayItem item, String query) {
    final p = item.data;
    final type = p['type'];
    if (type == 'pin') return false;
    final shared = type == 'shared_note';
    final id = p['entry'] as String? ?? '';
    final state = notes.state;
    final removedView = notesFilter == 'Removed';
    if (removedView) {
      if (!shared || p['deleted'] != true) return false;
      if (emptied(p)) return false;
    } else if (p['deleted'] == true || hiddenNotes.contains(id)) {
      return false;
    }
    final archived = shared && state.archived(id);
    if (notesFilter == 'Archive') {
      if (!archived) return false;
    } else if (archived && !removedView && notesFilter != 'Reminders') {
      return false;
    }
    final text = (p['text'] ?? '').toString();
    final link = text.startsWith('http');
    final files = (p['files'] as List? ?? const []).cast<Map>();
    final passes = switch (notesFilter) {
      'Text' => shared && p['checklist'] != true || type == 'note' && !link,
      'Lists' => shared && p['checklist'] == true || type == 'check',
      'Links' => (type == 'note' || shared) && link,
      'Files' =>
        type == 'file' ||
            files.any((f) => f['kind'] == 'image' || f['kind'] == 'drawing'),
      'Voice' => files.any((f) => f['kind'] == 'audio'),
      'Reminders' => shared && state.reminder(id) != null,
      _ when notesFilter.startsWith('label:') =>
        shared && state.labelsOf(id).contains(notesFilter.substring(6)),
      _ => true,
    };
    if (!passes) return false;
    if (query.isEmpty) return true;
    final labelNames = shared
        ? state.labelsOf(id).map((l) => state.labels[l]).join(' ')
        : '';
    return '${p['title'] ?? ''}\n$text\n${p['transcript'] ?? ''}\n${p['name'] ?? ''}\n${p['list'] ?? ''}\n$labelNames'
        .toLowerCase()
        .contains(query);
  }

  /// Where [item] sorts in the notes list (see `NoteState.listKey`); only
  /// notes can be moved, other saved items sort by time.
  String noteListKey(EverydayItem item) {
    final id = '${item.data['entry']}';
    final time = item.data['updated'] as int? ?? item.object.created;
    return item.data['type'] == 'shared_note'
        ? notes.state.listKey(id, time)
        : NoteState.timeKey(time, id);
  }

  /// Filtered and sorted notes. Rebuilding the app for other reasons reuses
  /// the last result; new notes, personal state, the filter, the search and
  /// optimistic hides recompute it. A new filter or search starts again at
  /// the first page.
  NotesView notesViewOf(List<EverydayItem> all, String query) {
    final state = notes.state;
    if (!identical(all, notesViewSource)) {
      notesViewSource = all;
      final byId = <Object?, EverydayItem>{
        for (final i in all)
          if (i.data['type'] == 'shared_note') i.data['entry']: i,
      };
      // Removals the summaries now reflect no longer need hiding.
      hiddenNotes.removeWhere((id) => byId[id]?.data['deleted'] == true);
      selectedNotes.removeWhere((id) => byId[id]?.data['deleted'] != false);
      // Drop optimistic checks the summaries now reflect.
      for (final MapEntry(key: id, value: overrides) in noteChecks.entries) {
        final item = byId[id];
        if (item == null) continue;
        final unchecked = {
          for (final c in (item.data['checks'] as List? ?? const [])) c['id'],
        };
        overrides.removeWhere((id, done) => done != unchecked.contains(id));
      }
    }
    final key = (
      all,
      state.version,
      notesFilter,
      query,
      hiddenNotes.join('\n'),
    );
    final previous = notesViewKey;
    final view = notesView;
    if (previous == key && view != null) return view;
    if (previous is! (Object, int, String, String, String) ||
        previous.$3 != notesFilter ||
        previous.$4 != query) {
      notesShown = notesPage;
    }
    notesViewKey = key;
    final pins = <Object?>{
      for (final i in all)
        if (i.data['type'] == 'pin' && i.data['pinned'] == true)
          i.data['target'],
      for (final i in all)
        if (i.data['type'] == 'shared_note' && state.pinned(i.data['entry']))
          i.data['entry'],
    };
    final visible = all.where((i) => notesMatch(i, query)).toList();
    if (notesFilter == 'Reminders') {
      int at(EverydayItem i) =>
          state.reminder(i.data['entry'])?['at'] as int? ?? 0;
      visible.sort((a, b) => at(a).compareTo(at(b)));
    } else {
      // Newest edit first, with moved notes where they were placed.
      final keys = {for (final i in visible) i: noteListKey(i)};
      visible.sort((a, b) {
        final order = keys[a]!.compareTo(keys[b]!);
        return order == 0
            ? '${a.data['entry']}'.compareTo('${b.data['entry']}')
            : order;
      });
    }
    final pinned = ['Removed', 'Archive'].contains(notesFilter)
        ? <EverydayItem>[]
        : visible.where((i) => pins.contains(i.data['entry'])).toList();
    final pinnedSet = pinned.toSet();
    return notesView = (
      pins: pins,
      visible: visible,
      pinned: pinned,
      others: [
        for (final i in visible)
          if (!pinnedSet.contains(i)) i,
      ],
    );
  }

  void dispose() {
    notesSearch.dispose();
    notesSearchFocus.dispose();
  }
}
