import 'dart:async';
import 'calendar.dart';
import 'everyday.dart';
import 'model.dart';
import 'node.dart';
import 'notes.dart';
import 'public_chats.dart';
import 'scopes.dart';
import 'store.dart';

/// The kinds of thing the activity feed shows, each a filter of its own.
/// `plugins` holds what plugins list under `activity` in their manifests.
enum ActivitySection { posts, notes, calendar, files, people, chat, plugins }

/// One thing that changed: what arrived about it on one day, merged.
class ActivityItem {
  final SignedObject object;

  /// The readable content; null where the feed does not need it (note
  /// operations, which are shown by their note).
  final Json? data;

  /// Who wrote it: for a copy shared with a new member, the original author.
  final String author;
  final int at;
  ActivityItem(this.object, this.data, this.author, this.at);
}

/// A row of the feed: everything that arrived about one thing (a note, a
/// forum, a group's files, a calendar) on one day, newest first.
class ActivityEntry {
  final String key;
  final ActivitySection section;

  /// Where it happened: a note's ID, a forum, a group's room, a calendar,
  /// `dm:<person>` for a direct conversation, or the person who became a
  /// friend.
  final String space;

  /// The group it belongs to, if any (its room's space).
  final String? group;
  final bool public;

  /// When the newest of it arrived.
  int at = 0;

  /// How many objects arrived.
  int count = 0;

  /// The newest few, newest first.
  final items = <ActivityItem>[];
  final _people = <String, int>{};

  /// For a note: its list projection ([Notes.summary]), for title and state.
  EverydayItem? note;

  ActivityEntry(
    this.key,
    this.section,
    this.space, {
    this.group,
    this.public = false,
  });

  static const kept = 4;

  /// Who did it, most recent first.
  List<String> get people =>
      (_people.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
          .map((e) => e.key)
          .toList();

  /// Whether anyone but [person] did any of it.
  bool byOthers(String person) => _people.keys.any((p) => p != person);

  void _add(ActivityItem item) {
    count++;
    if (item.at > at) at = item.at;
    if ((_people[item.author] ?? -1) < item.at) _people[item.author] = item.at;
    items.add(item);
    items.sort((a, b) => b.at.compareTo(a.at));
    if (items.length > kept) items.removeLast();
  }

  /// Whether the scope switcher's [scope] (null for All) shows this; a group
  /// scope shows [group]'s entries alone.
  bool inScope(ScopeKind? scope, {String? group}) => switch (scope) {
    null => true,
    ScopeKind.group => this.group != null && this.group == group,
    ScopeKind.public => public,
    ScopeKind.personal => !public && this.group == null,
  };
}

/// What happened while you were away: forum posts, note edits, events,
/// files and new friends, newest arrival first (see docs/ACTIVITY.md).
///
/// Read from the store's arrival index, never by scanning history: a first
/// load reads back a bounded number of pages, [more] reads further, and
/// [refresh] takes in only what arrived since. Nothing readable is kept
/// outside memory.
class Activity {
  final Node node;
  final Notes? notes;
  Activity(this.node, {this.notes});

  /// The kinds whose arrival may change the feed, besides plugin kinds
  /// ([shows]).
  static const kinds = {...Store.activityKinds};

  /// Whether the arrival of an object of [kind] may change the feed.
  bool shows(String kind) =>
      kinds.contains(kind) || node.registry.activityOf(kind) != null;

  /// Objects read per call to [more] at most, so a storm of note edits that
  /// merges into a few rows cannot make one call read without end.
  static const maxScanned = 2048;

  final _entries = <String, ActivityEntry>{};
  final _taken = <String>{};
  (int, String)? _oldest, _newest;
  bool _exhausted = false, _loaded = false;
  Future<void> _tail = Future.value();
  List<ActivityEntry>? _sorted;
  String _blocked = '';

  /// Changes whenever [entries] may have.
  int version = 0;

  bool get loaded => _loaded;

  /// Whether everything recorded has been read.
  bool get exhausted => _exhausted;

  /// Newest first.
  List<ActivityEntry> get entries => _sorted ??= _entries.values.toList()
    ..sort((a, b) {
      final by = b.at.compareTo(a.at);
      return by != 0 ? by : a.key.compareTo(b.key);
    });

  /// Arrivals up to this time have been looked at.
  int get seen => node.store.setting('activitySeen') as int? ?? 0;

  /// Whether [e] arrived since the feed was last looked at, from others.
  bool isNew(ActivityEntry e) => e.at > seen && e.byOthers(node.person);

  /// Rows that are new, up to [cap]: the navigation's badge.
  int unseen({int cap = 100}) {
    var n = 0;
    for (final e in entries) {
      if (e.at <= seen) break;
      if (e.byOthers(node.person) && ++n >= cap) break;
    }
    return n;
  }

  /// Everything shown so far has been looked at.
  void markSeen() {
    final newest = entries.firstOrNull?.at ?? 0;
    if (newest > seen) node.store.set('activitySeen', newest);
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  /// Loads the first rows, or takes in what arrived since. True when the
  /// entries changed.
  Future<bool> refresh() => _serial(() async {
    final before = version;
    final blocked = '${node.blocked.toList()..sort()}';
    if (_loaded && blocked != _blocked) _reset();
    _blocked = blocked;
    if (!_loaded) {
      _newest = node.store.newestArrival;
      await _readBack(40);
      _loaded = true;
    } else {
      await _catchUp();
    }
    return version != before;
  });

  /// Reads further back, for about [rows] more rows. True if any were added.
  Future<bool> more({int rows = 30}) => _serial(() async {
    final before = _entries.length;
    await _readBack(rows);
    return _entries.length != before;
  });

  void _reset() {
    _entries.clear();
    _taken.clear();
    _oldest = null;
    _newest = null;
    _exhausted = false;
    _loaded = false;
    _changed();
  }

  void _changed() {
    _sorted = null;
    version++;
  }

  Future<void> _readBack(int rows) async {
    final want = _entries.length + rows;
    final slice = TimeSlice();
    final touched = <ActivityEntry>{};
    var scanned = 0;
    while (!_exhausted && _entries.length < want && scanned < maxScanned) {
      final page = node.store.arrivals(before: _oldest, limit: 256);
      if (page.isEmpty) {
        _exhausted = true;
        break;
      }
      for (final (at, o) in page) {
        _oldest = (at, o.id);
        scanned++;
        await slice.pause();
        if (await _take(at, o) case final e?) touched.add(e);
      }
    }
    await _finish(touched);
  }

  Future<void> _catchUp() async {
    final slice = TimeSlice();
    final touched = <ActivityEntry>{};
    while (true) {
      final page = node.store.arrivals(after: _newest, limit: 256);
      if (page.isEmpty) break;
      for (final (at, o) in page) {
        _newest = (at, o.id);
        await slice.pause();
        if (await _take(at, o) case final e?) touched.add(e);
      }
    }
    await _finish(touched);
  }

  Future<void> _finish(Set<ActivityEntry> touched) async {
    final notes = this.notes;
    if (notes != null) {
      for (final e in touched) {
        if (e.section == ActivitySection.notes && e.key.startsWith('note|')) {
          e.note = await notes.summary(e.space);
        }
      }
    }
    final people = _friends();
    if (touched.isNotEmpty || people) _changed();
  }

  /// New friends, from when each person's first device was added: among the
  /// rows once the feed has read back to then. True if any were added.
  bool _friends() {
    final floor = _exhausted ? 0 : (_oldest?.$1 ?? 0);
    final first = <String, int>{};
    for (final MapEntry(key: device, value: added)
        in node.store.contactsAdded().entries) {
      final person = node.contacts[device]?.person;
      if (person == null ||
          person == node.person ||
          node.blocked.contains(person)) {
        continue;
      }
      final at = first[person];
      if (added.estimated) {
        // Known from before times were kept: never news.
        first[person] = 0;
      } else if (at == null || (at != 0 && added.added < at)) {
        first[person] = added.added;
      }
    }
    var changed = false;
    for (final MapEntry(key: person, value: at) in first.entries) {
      final key = 'people|$person';
      if (at == 0 || at < floor || _entries.containsKey(key)) continue;
      final entry = _entries[key] = ActivityEntry(
        key,
        ActivitySection.people,
        person,
      );
      entry
        ..at = at
        ..count = 1
        .._people[person] = at;
      changed = true;
    }
    return changed;
  }

  /// Adds [o] to its row; returns the row, or null if it shows nowhere.
  Future<ActivityEntry?> _take(int at, SignedObject o) async {
    if (!_taken.add(o.id) || !node.visible(o)) return null;
    // What this device did itself is not news to it.
    if (o.certificate.device == node.identity.device) return null;
    final needsContent = o.kind != 'note_op' && o.kind != 'message';
    final data = needsContent ? await node.content(o) : null;
    if (needsContent && data == null) return null;
    final author =
        (data?['history'] == true ? data!['originalAuthor'] as String? : null) ??
        o.author;
    if (node.blocked.contains(author)) return null;
    final place = _place(o, data);
    if (place == null) return null;
    final (section, space, group) = place;
    final day = _day(at);
    // A plugin's things each get a row: one per page, say, not per wiki.
    // Without a key, a space's objects of the day share one.
    final listing = section == ActivitySection.plugins
        ? node.registry.activityOf(o.kind)
        : null;
    final thing = listing?.key == null ? '' : '|${listing!.keyOf(o, data!)}';
    final key = section == ActivitySection.notes && o.kind == 'note_op'
        ? 'note|$space|$day'
        : '${section.name}|${o.kind}|$space$thing|$day';
    final entry = _entries[key] ??= ActivityEntry(
      key,
      section,
      space,
      group: group,
      public: o.isPublic,
    );
    entry._add(ActivityItem(o, data, author, at));
    return entry;
  }

  /// Which section [o] shows in, where, and in which group; null if it is
  /// not shown (a removed entry, a pin).
  (ActivitySection, String, String?)? _place(SignedObject o, Json? data) {
    final deleted = data?['deleted'] == true;
    switch (o.kind) {
      case 'note_op':
        return (ActivitySection.notes, o.space, Notes.groupOf(o.space));
      case 'post':
        return (ActivitySection.posts, o.space, null);
      case 'room_post':
        return (ActivitySection.posts, o.space, o.space);
      case Calendar.eventKind:
        return (
          ActivitySection.calendar,
          o.space,
          o.space == Calendar.personal ? null : o.space,
        );
      case 'room_item' || 'inbox':
        if (deleted) return null;
        final group = o.kind == 'room_item' ? o.space : null;
        return switch (data?['type']) {
          'note' when group != null => (ActivitySection.chat, o.space, group),
          'note' || 'check' => (ActivitySection.notes, o.space, group),
          'file' => (ActivitySection.files, o.space, group),
          _ => null,
        };
      case 'drive' || 'file':
        if (deleted) return null;
        return (ActivitySection.files, o.space, null);
      case 'message':
        final peer = o.author == node.person
            ? o.audience.where((p) => p != node.person).firstOrNull
            : o.author;
        return peer == null ? null : (ActivitySection.chat, 'dm:$peer', null);
      case PublicChats.messageKind:
        return (ActivitySection.chat, o.space, null);
    }
    if (node.registry.activityOf(o.kind) != null) {
      return (ActivitySection.plugins, o.space, pluginGroup(o));
    }
    return null;
  }

  /// The group a plugin's object belongs to: one shared with several
  /// people in a space that is not the plugin's own (`x.<plugin>…`) is in a
  /// group's space, as plugins publish to a group.
  static String? pluginGroup(SignedObject o) =>
      !o.isPublic && o.audience.length > 1 && !o.space.startsWith('x.')
      ? o.space
      : null;

  /// The start of [at]'s local day: rows merge within a day.
  static int _day(int at) {
    final t = DateTime.fromMillisecondsSinceEpoch(at);
    return DateTime(t.year, t.month, t.day).millisecondsSinceEpoch;
  }
}
