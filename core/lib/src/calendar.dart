import 'dart:async';
import 'everyday.dart';
import 'ics.dart';
import 'model.dart';
import 'node.dart';
import 'note_state.dart';
import 'recurrence.dart';

/// One version of a calendar entry as stored: an event, a changed occurrence
/// of a repeating event (an *override*), or a record that one was deleted.
class CalEvent {
  final SignedObject object;
  final Json data;

  /// The calendar it belongs to: [Calendar.personal], or a group's room ID.
  final String calendar;
  CalEvent(this.object, this.data) : calendar = object.space;

  /// The entry's stable ID; every edit is a newer version with the same one.
  String get entry => data['event'] as String;
  int get clock => data['clock'] as int;
  bool get deleted => data['deleted'] == true;

  String get title => data['title'] as String? ?? '';
  String get description => data['desc'] as String? ?? '';
  String get location => data['loc'] as String? ?? '';
  String get url => data['url'] as String? ?? '';
  bool get allDay => data['allDay'] == true;
  bool get busy => data['busy'] != false;
  String? get color => data['color'] as String?;
  String? get timezone => data['tz'] as String?;
  List<int> get reminders => [...?(data['reminders'] as List?)?.cast<int>()];
  late final Repeat? repeat = Repeat.fromJson(data['repeat']);

  /// For a repeating event that ends, when its last occurrence starts; null
  /// when it runs for ever or does not repeat. Lets a view skip a series that
  /// finished long before the time shown without walking it.
  late final DateTime? seriesEnd = () {
    final rule = repeat;
    if (rule == null || (rule.count == null && rule.until == null)) return null;
    if (rule.count == null) {
      return DateTime.fromMillisecondsSinceEpoch(rule.until!);
    }
    DateTime? last;
    for (final d in rule.occurrences(start)) {
      last = d;
    }
    return last;
  }();

  /// For an override, the series it changes and which occurrence of it.
  String? get series => data['series'] as String?;
  String? get instance => data['instance'] as String?;
  bool get isOverride => series != null;

  /// A voice note recorded for the event: its transcript is [description]
  /// material, the audio is in the chunks this payload names.
  bool get hasAudio => data['chunks'] is List && data['audio'] is Map;
  String get transcript => data['transcript'] as String? ?? '';

  /// Who wrote this version. History shared with a new member is republished
  /// by the group's owner, so the person it names is the author.
  String get author => data['history'] == true
      ? data['originalAuthor'] as String? ?? object.author
      : object.author;

  /// When the entry was first written, and when this version was.
  int get sent => data['sent'] as int? ?? object.created;
  int get edited => object.created;

  /// When it starts, and (exclusive for all-day events: the midnight after
  /// the last day) when it ends. Worked out once: laying out thousands of
  /// events asks for these constantly, and building a local time is not free.
  late final DateTime start = allDay
      ? Calendar.parseDay(data['day'] as String)
      : DateTime.fromMillisecondsSinceEpoch(data['start'] as int);

  late final DateTime end = allDay
      ? DateTime(start.year, start.month, start.day + (data['days'] as int))
      : DateTime.fromMillisecondsSinceEpoch(data['end'] as int);

  /// The key an occurrence is known by: the original start in milliseconds,
  /// or the date for an all-day event.
  static String keyOf(DateTime start, bool allDay) =>
      allDay ? Calendar.formatDay(start) : '${start.millisecondsSinceEpoch}';

  /// Whether [a] is a newer version than [b]: higher clock, then higher ID.
  static bool newer(CalEvent a, CalEvent b) {
    final order = a.clock.compareTo(b.clock);
    return order > 0 || (order == 0 && a.object.id.compareTo(b.object.id) > 0);
  }
}

/// A single showing of an event on the calendar.
class Occurrence {
  /// What to display: the event itself, or its override for this occurrence.
  final CalEvent event;

  /// The series' own record, for a repeating event; otherwise [event].
  final CalEvent master;

  /// Identifies the occurrence within its series ('' when it does not repeat).
  final String key;
  final DateTime start;

  /// Exclusive for all-day occurrences.
  final DateTime end;
  const Occurrence(this.event, this.master, this.key, this.start, this.end);

  String get calendar => event.calendar;
  bool get allDay => event.allDay;
  bool get repeats => master.repeat != null;
  String get entry => master.entry;

  /// The last day touched, so an event ending at midnight stays on its day.
  DateTime get lastMoment =>
      end.isAfter(start) ? end.subtract(const Duration(milliseconds: 1)) : start;

  /// A stable identity for a view: the calendar, entry and occurrence.
  String get id => '$calendar|$entry|$key';

  /// The days it covers, as local midnights.
  Iterable<DateTime> get days sync* {
    var day = DateTime(start.year, start.month, start.day);
    final last = lastMoment;
    var guard = 0;
    while (!day.isAfter(last) && guard++ < 3700) {
      yield day;
      day = DateTime(day.year, day.month, day.day + 1);
    }
  }
}

/// A person's answer to an event.
enum Rsvp { yes, no, maybe }

/// What a calendar is called, for lists of calendars.
class CalendarInfo {
  final String id, name;
  final bool personal;
  const CalendarInfo(this.id, this.name, this.personal);
}

/// How far an edit of a repeating event reaches.
enum Scope { one, following, all }

/// What a write replaced, so it can be taken back with [Calendar.undo].
class Change {
  /// The entry the change is about (a new series' ID when an edit split one).
  String? entry;

  /// Each entry written, with the version it replaced (null if it was new).
  final parts = <(String, String, CalEvent?)>[];
}

/// The editable fields of an event, as a form holds them. [apply] writes them
/// over a stored payload, which keeps any field this build does not know.
class EventDraft {
  String title, description, location, url;
  bool allDay;
  DateTime start;

  /// The end time; for an all-day event the midnight after its last day.
  DateTime end;
  Repeat? repeat;
  List<int> reminders;
  String? color;
  bool busy;
  String? timezone;

  /// Fields that ride along unchanged (a recorded voice note and its text).
  final Json carry;

  /// The payload fields that make up a voice note.
  static const audioFields = [
    'chunks',
    'chunkBytes',
    'key',
    'size',
    'name',
    'audio',
    'transcript',
  ];

  EventDraft({
    this.title = '',
    this.description = '',
    this.location = '',
    this.url = '',
    this.allDay = false,
    required this.start,
    required this.end,
    this.repeat,
    List<int>? reminders,
    this.color,
    this.busy = true,
    this.timezone,
    Json? carry,
  }) : reminders = reminders ?? [],
       carry = carry ?? {};

  EventDraft copy() => EventDraft(
    title: title,
    description: description,
    location: location,
    url: url,
    allDay: allDay,
    start: start,
    end: end,
    repeat: repeat,
    reminders: [...reminders],
    color: color,
    busy: busy,
    timezone: timezone,
    carry: {...carry},
  );

  /// A form for editing one showing of an event: the occurrence's own times,
  /// and for an override its own details.
  factory EventDraft.of(Occurrence o) =>
      EventDraft.from(o.event, start: o.start, end: o.end);

  factory EventDraft.from(CalEvent e, {DateTime? start, DateTime? end}) =>
      EventDraft(
        title: e.title,
        description: e.description,
        location: e.location,
        url: e.url,
        allDay: e.allDay,
        start: start ?? e.start,
        end: end ?? e.end,
        repeat: e.repeat,
        reminders: e.reminders,
        color: e.color,
        busy: e.busy,
        timezone: e.timezone,
        carry: {
          for (final k in audioFields)
            if (e.data[k] != null) k: e.data[k],
        },
      );

  /// Fields that decide when the event is, for telling a move from an edit.
  Json timing() => {
    'allDay': allDay,
    if (allDay) ...{
      'day': Calendar.formatDay(start),
      'days': Calendar.dayCount(start, end),
    } else ...{
      'start': start.millisecondsSinceEpoch,
      'end': end.millisecondsSinceEpoch,
    },
  };

  /// [base] with this draft's fields written over it.
  Json apply(Json base) {
    // A voice note is whatever [carry] holds: removing it from the form must
    // remove it from the event, not leave the stored one behind.
    final data = {...base}
      ..removeWhere((k, _) => audioFields.contains(k))
      ..addAll(carry)
      ..remove('day')
      ..remove('days')
      ..remove('start')
      ..remove('end')
      ..addAll(timing());
    void text(String key, String value, int limit) {
      final v = value.trim();
      if (v.isEmpty) {
        data.remove(key);
      } else {
        data[key] = v.length > limit ? v.substring(0, limit) : v;
      }
    }

    text('title', title, Calendar.maxTitle);
    text('desc', description, Calendar.maxDescription);
    text('loc', location, 300);
    text('url', url, 500);
    if (repeat == null) {
      data.remove('repeat');
    } else {
      data['repeat'] = repeat!.toJson();
    }
    data['reminders'] = [...reminders];
    if (color == null) {
      data.remove('color');
    } else {
      data['color'] = color;
    }
    if (busy) {
      data.remove('busy');
    } else {
      data['busy'] = false;
    }
    if (timezone == null) {
      data.remove('tz');
    } else {
      data['tz'] = timezone;
    }
    return data;
  }
}

/// A calendar person-wide and one per private group.
///
/// The personal calendar is `cal_event` objects in the space `_calendar`,
/// encrypted to this person's own devices. A group's calendar is the same kind
/// in the group's own space, encrypted to its members, like the group forum:
/// no epochs, so whoever is a member now reads what members wrote, and the
/// group's owner republishes history for people who join. Older builds store
/// and relay both without reading them.
///
/// Every edit is a new version of an entry; the highest Lamport clock wins and
/// ties break on object ID, so devices converge whatever order they hear in.
/// A repeating event is one entry holding its rule. Changing or deleting a
/// single occurrence writes a small *override* entry with a fixed ID, so two
/// people changing different occurrences never conflict.
///
/// Reading is incremental: an insertion cursor takes in only what arrived, so
/// a refresh costs the same on a long history as on a new profile.
class Calendar {
  final Node node;
  final NoteState state;
  Calendar(this.node, this.state);

  static const personal = '_calendar';
  static const eventKind = 'cal_event';
  static const rsvpKind = 'cal_rsvp';
  static const maxTitle = 300;
  static const maxDescription = 8000;
  static const maxReminders = 5;

  static final _indexes = Expando<_Index>();
  _Index get _index => _indexes[node] ??= _Index(node);

  /// Changes whenever anything shown may have changed.
  int get version => _index.version;

  /// Lays the calendar out for range queries now, so that the first query
  /// after a change (which would otherwise do it, in the middle of drawing a
  /// frame) finds it done. Call it after [refresh], outside a build.
  void warm() => _index.snapshot;

  /// Whether the first read of history has finished.
  bool get loaded => _index.loaded;

  // ---- dates -------------------------------------------------------------

  static DateTime parseDay(String day) => DateTime(
    int.parse(day.substring(0, 4)),
    int.parse(day.substring(5, 7)),
    int.parse(day.substring(8, 10)),
  );

  static String formatDay(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-'
      '${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';

  /// Whole calendar days from [a] to [b], at least one.
  static int dayCount(DateTime a, DateTime b) {
    final days =
        DateTime.utc(b.year, b.month, b.day)
            .difference(DateTime.utc(a.year, a.month, a.day))
            .inDays;
    return days < 1 ? 1 : days;
  }

  // ---- reading -----------------------------------------------------------

  /// Brings the index up to date. Cheap when nothing arrived.
  Future<bool> refresh() async {
    await state.refresh();
    return _index.refresh();
  }

  /// Every calendar this person can use: their own, then each group's.
  Future<List<CalendarInfo>> calendars() async {
    final rooms = await Everyday(node).rooms();
    return [
      const CalendarInfo(personal, 'My calendar', true),
      for (final room in rooms)
        if (room.data['note'] != true)
          CalendarInfo(room.object.space, room.data['name'] as String, false),
    ];
  }

  /// Whether a calendar shows in the personal view. On unless turned
  /// off, and that choice follows this person to their other devices.
  bool shown(String calendar) => state.value('calShow', calendar) != false;

  Future<void> setShown(String calendar, bool shown) async {
    await state.set('calShow', calendar, shown);
    _index.touch();
  }

  /// The colour name a calendar was given, or null for its default.
  String? calendarColor(String calendar) {
    final v = state.value('calColor', calendar);
    return v is String && v.isNotEmpty ? v : null;
  }

  Future<void> setCalendarColor(String calendar, String? color) async {
    await state.set('calColor', calendar, color ?? '');
    _index.touch();
  }

  /// This person's own reminders for one event, replacing the event's; an
  /// empty list silences it for them. Null when they have not chosen.
  List<int>? reminderOverride(String entry) {
    final v = state.value('calRemind', entry);
    return v is List ? v.cast<int>() : null;
  }

  /// Sets this person's reminders for an event on all their devices, or with
  /// null goes back to the event's own.
  Future<void> setReminderOverride(String entry, List<int>? minutes) =>
      state.set('calRemind', entry, minutes ?? false);

  /// The reminders in force for an event on this device.
  List<int> remindersFor(CalEvent e) => reminderOverride(e.entry) ?? e.reminders;

  /// Events deleted within [within], newest deletion first, for putting back.
  /// A deletion keeps everything the event said, so nothing is lost until the
  /// device forgets old objects.
  List<CalEvent> deleted({Duration within = const Duration(days: 30)}) {
    final since = DateTime.now().subtract(within).millisecondsSinceEpoch;
    return [
      for (final e in _index.snapshot.deletedEvents)
        if (e.edited >= since && shown(e.calendar)) e,
    ]..sort((a, b) => b.edited.compareTo(a.edited));
  }

  /// Puts back an event listed by [deleted].
  Future<Change> restoreEvent(CalEvent e) async {
    final change = Change()..entry = e.entry;
    await _put(change, e.calendar, _base(e));
    return change;
  }

  /// Every event, a repeating one once, in the calendars the personal view
  /// shows (or all of them with [hidden]). For searching and listing.
  List<CalEvent> events({bool hidden = false}) => [
    for (final e in _index.snapshot.masters.followedBy(_index.snapshot.simple))
      if (hidden || shown(e.calendar)) e,
  ];

  /// The visible occurrences overlapping [from] to [to].
  ///
  /// With no [calendars] this is every calendar the personal view shows;
  /// pass one to see a single calendar whether or not it is switched on.
  List<Occurrence> between(
    DateTime from,
    DateTime to, {
    Set<String>? calendars,
  }) {
    final snapshot = _index.snapshot;
    final allowed = calendars ?? {for (final c in snapshot.calendars) if (shown(c)) c};
    final result = <Occurrence>[];
    snapshot.collect(from, to, allowed, result);
    result.sort(compareOccurrences);
    return result;
  }

  /// Earlier first; all-day before timed on the same day.
  static int compareOccurrences(Occurrence a, Occurrence b) {
    final order = a.start.compareTo(b.start);
    if (order != 0) return order;
    if (a.allDay != b.allDay) return a.allDay ? -1 : 1;
    final end = b.end.compareTo(a.end);
    return end != 0 ? end : a.id.compareTo(b.id);
  }

  /// The event with this entry ID in [calendar], or null if unknown here.
  CalEvent? event(String calendar, String entry) =>
      _index.snapshot.byEntry['$calendar|$entry'];

  /// The occurrence of an event, for opening a link: [key] picks one of a
  /// series, otherwise the next one after [after] (or the first).
  Occurrence? occurrence(
    String calendar,
    String entry, {
    String? key,
    DateTime? after,
  }) => _index.snapshot.occurrence(calendar, entry, key: key, after: after);

  /// Events whose text contains [query], each as its next occurrence after
  /// [from] (or its last, for events in the past), soonest first.
  List<Occurrence> search(String query, {DateTime? from, int limit = 200}) {
    final words = query.toLowerCase().split(RegExp(r'\s+'))
      ..removeWhere((w) => w.isEmpty);
    if (words.isEmpty) return const [];
    final result = <Occurrence>[];
    final now = from ?? DateTime.now();
    for (final e in _index.snapshot.masters.followedBy(
      _index.snapshot.simple,
    )) {
      if (!shown(e.calendar)) continue;
      final text =
          '${e.title}\n${e.description}\n${e.location}\n${e.transcript}'
              .toLowerCase();
      if (!words.every(text.contains)) continue;
      final next = _index.snapshot.occurrence(
        e.calendar,
        e.entry,
        after: now,
      );
      if (next != null) result.add(next);
    }
    result.sort((a, b) {
      final ahead = a.end.isAfter(now), bhead = b.end.isAfter(now);
      if (ahead != bhead) return ahead ? -1 : 1;
      return ahead ? a.start.compareTo(b.start) : b.start.compareTo(a.start);
    });
    return result.take(limit).toList();
  }

  /// Answers people gave to an event or one occurrence of it: the occurrence's
  /// own answer where there is one, otherwise their answer to the whole.
  Map<String, Rsvp> rsvps(String calendar, String entry, String key) =>
      _index.rsvps(calendar, entry, key);

  /// This person's answer, or null.
  Rsvp? myRsvp(String calendar, String entry, String key) =>
      rsvps(calendar, entry, key)[node.person];

  /// The people who can see a calendar's events.
  Future<List<String>> members(String calendar) async {
    if (calendar == personal) return [node.person];
    final room = await _room(calendar);
    return Everyday(node).members(room);
  }

  Future<EverydayItem> _room(String calendar) async {
    final room = (await Everyday(
      node,
    ).rooms()).where((r) => r.object.space == calendar).firstOrNull;
    if (room == null) throw StateError('This group is unavailable.');
    return Everyday(node).current(room);
  }

  // ---- writing -----------------------------------------------------------

  Future<List<String>> _audience(String calendar) async {
    if (calendar == personal) return [node.person];
    final everyday = Everyday(node);
    final room = await _room(calendar);
    await everyday.prepare(room);
    return everyday.members(room);
  }

  /// Publishes a new version of an entry, numbered after everything seen, and
  /// notes what it replaced in [change] so the edit can be undone.
  Future<SignedObject> _put(Change change, String calendar, Json data) async {
    await refresh();
    final entry = data['event'] as String;
    // Read from the index, not the snapshot: laying the snapshot out costs
    // the whole calendar, which an import of thousands must not pay per event.
    change.parts.add((calendar, entry, _index.latest(calendar, entry)));
    final audience = await _audience(calendar);
    final payload = {...data}
      ..remove('history')
      ..remove('originalAuthor')
      ..['clock'] = ++_index.clock
      ..['sent'] = data['sent'] ?? DateTime.now().millisecondsSinceEpoch;
    final object = await node.publish(
      eventKind,
      payload,
      space: calendar,
      audience: audience,
    );
    await refresh();
    return object;
  }

  /// Creates an event.
  Future<Change> create(String calendar, EventDraft draft) async {
    final entry = randomId();
    final change = Change()..entry = entry;
    await _put(change, calendar, draft.apply({'event': entry}));
    return change;
  }

  /// Saves [draft] over an event. [occurrence] is the one being edited, and
  /// [scope] how far the edit reaches when it repeats. The result names the
  /// entry now holding the occurrence (a new series when an edit splits one).
  Future<Change> update(
    Occurrence occurrence,
    EventDraft draft, {
    Scope scope = Scope.all,
  }) async {
    final master = occurrence.master;
    final change = Change()..entry = master.entry;
    final repeating = master.repeat != null;
    if (repeating && scope == Scope.one) {
      await _put(
        change,
        master.calendar,
        draft.apply({
          ..._base(master),
          'event': '${master.entry}~${occurrence.key}',
          'series': master.entry,
          'instance': occurrence.key,
        })..remove('repeat'),
      );
      return change;
    }
    if (repeating &&
        scope == Scope.following &&
        occurrence.start.isAfter(master.start)) {
      final rule = master.repeat!;
      final entry = randomId();
      change.entry = entry;
      // The series ends before this occurrence, and a new one with the
      // changes carries on from it.
      await _put(change, master.calendar, {
        ..._base(master),
        'repeat': rule
            .copyWith(
              until: () => occurrence.start.millisecondsSinceEpoch - 1,
              count: () => null,
            )
            .toJson(),
      });
      var next = draft.repeat ?? rule;
      if (rule.count != null &&
          canonical(draft.repeat?.toJson()) == canonical(rule.toJson())) {
        final left = rule.count! - _before(master, occurrence);
        next = next.copyWith(count: () => left < 1 ? 1 : left);
      }
      await _put(
        change,
        master.calendar,
        (draft.copy()..repeat = next).apply({..._base(master), 'event': entry}),
      );
      await _dropOverrides(change, master, occurrence.start);
      return change;
    }
    // The whole event. An edit of one occurrence of a series that moved it
    // moves the series by as much, as other calendars do.
    final next = repeating ? _moveSeries(occurrence, draft) : draft;
    await _put(change, master.calendar, next.apply(_base(master)));
    if (repeating && draft.allDay != master.allDay) {
      await _dropOverrides(change, master, null);
    }
    return change;
  }

  /// [draft], with the times of the series rather than of one occurrence.
  EventDraft _moveSeries(Occurrence occurrence, EventDraft draft) {
    final master = occurrence.master;
    final next = draft.copy();
    if (draft.allDay != master.allDay) {
      // Toggling all-day applies to the series on its own dates.
      final day = master.start;
      next.start = draft.allDay
          ? DateTime(day.year, day.month, day.day)
          : DateTime(
              day.year,
              day.month,
              day.day,
              draft.start.hour,
              draft.start.minute,
            );
      next.end = draft.allDay
          ? DateTime(
              day.year,
              day.month,
              day.day + dayCount(draft.start, draft.end),
            )
          : next.start.add(draft.end.difference(draft.start));
      return next;
    }
    if (master.allDay) {
      final shift = DateTime.utc(
        draft.start.year,
        draft.start.month,
        draft.start.day,
      ).difference(
        DateTime.utc(
          occurrence.start.year,
          occurrence.start.month,
          occurrence.start.day,
        ),
      ).inDays;
      final s = master.start;
      next.start = DateTime(s.year, s.month, s.day + shift);
      next.end = DateTime(
        next.start.year,
        next.start.month,
        next.start.day + dayCount(draft.start, draft.end),
      );
      return next;
    }
    final shift = draft.start.difference(occurrence.start);
    next.start = master.start.add(shift);
    next.end = next.start.add(draft.end.difference(draft.start));
    return next;
  }

  /// How many occurrences of the series come before [occurrence].
  int _before(CalEvent master, Occurrence occurrence) {
    var n = 0;
    for (final d in master.repeat!.occurrences(master.start)) {
      if (!d.isBefore(occurrence.start)) break;
      n++;
    }
    return n;
  }

  /// The payload an edit starts from: nothing of a deletion.
  Json _base(CalEvent e) => {...e.data, 'event': e.entry}..remove('deleted');

  /// Deletes overrides of [master], or only those for occurrences from
  /// [from] on.
  Future<void> _dropOverrides(
    Change change,
    CalEvent master,
    DateTime? from,
  ) async {
    for (final o in _index.snapshot.overridesOf(
      master.calendar,
      master.entry,
    )) {
      if (o.deleted) continue;
      if (from != null) {
        final key = o.instance ?? '';
        final original = master.allDay
            ? (key.length == 10 ? Calendar.parseDay(key) : null)
            : DateTime.fromMillisecondsSinceEpoch(int.tryParse(key) ?? 0);
        if (original == null || original.isBefore(from)) continue;
      }
      await _put(change, master.calendar, {...o.data, 'deleted': true});
    }
  }

  /// Deletes an event, one occurrence of it, or it and every later one.
  Future<Change> delete(
    Occurrence occurrence, {
    Scope scope = Scope.all,
  }) async {
    final master = occurrence.master;
    final change = Change()..entry = master.entry;
    if (master.repeat != null && scope == Scope.one) {
      await _put(
        change,
        master.calendar,
        {
          ..._base(master),
          'event': '${master.entry}~${occurrence.key}',
          'series': master.entry,
          'instance': occurrence.key,
          'deleted': true,
        }..remove('repeat'),
      );
      return change;
    }
    if (master.repeat != null &&
        scope == Scope.following &&
        occurrence.start.isAfter(master.start)) {
      await _put(change, master.calendar, {
        ..._base(master),
        'repeat': master.repeat!
            .copyWith(
              until: () => occurrence.start.millisecondsSinceEpoch - 1,
              count: () => null,
            )
            .toJson(),
      });
      await _dropOverrides(change, master, occurrence.start);
      return change;
    }
    await _put(change, master.calendar, {..._base(master), 'deleted': true});
    await _dropOverrides(change, master, null);
    return change;
  }

  /// Takes back [change]: each entry it wrote returns to what it was, or is
  /// deleted if the change created it.
  Future<void> undo(Change change) async {
    await refresh();
    final undone = Change();
    // Parts run oldest first; the first recorded for an entry is what it was.
    final first = <String, (String, String, CalEvent?)>{};
    for (final part in change.parts) {
      first.putIfAbsent('${part.$1}|${part.$2}', () => part);
    }
    for (final (calendar, entry, before) in first.values) {
      if (before != null) {
        await _put(undone, calendar, _base(before));
      } else if (_index.latest(calendar, entry) case final now?) {
        await _put(undone, calendar, {...now.data, 'deleted': true});
      }
    }
  }

  /// Moves an event, with its overrides, to another calendar.
  Future<Change> move(CalEvent master, String calendar) async {
    final change = Change()..entry = master.entry;
    if (calendar == master.calendar) return change;
    final entry = randomId();
    change.entry = entry;
    await _put(change, calendar, {..._base(master), 'event': entry});
    for (final o in _index.snapshot.overridesOf(
      master.calendar,
      master.entry,
    )) {
      await _put(change, calendar, {
        ..._base(o),
        'event': '$entry~${o.instance}',
        'series': entry,
        if (o.deleted) 'deleted': true,
      });
    }
    await _put(change, master.calendar, {..._base(master), 'deleted': true});
    await _dropOverrides(change, master, null);
    return change;
  }

  /// Answers an event for this person, for one occurrence or all of them.
  Future<void> respond(
    String calendar,
    String entry,
    Rsvp? response, {
    String? key,
  }) async {
    if (calendar == personal) return;
    await refresh();
    await node.publish(
      rsvpKind,
      {
        'event': entry,
        'instance': ?key,
        'response': response?.name ?? 'none',
      },
      space: calendar,
      audience: await _audience(calendar),
    );
    await refresh();
  }

  /// Adds what an iCalendar file holds to [calendar]. Returns how many events
  /// were created.
  Future<int> importIcs(String calendar, IcsImport file) async {
    var count = 0;
    for (final e in file.events) {
      final change = await create(calendar, e.draft);
      count++;
      final entry = change.entry!;
      final allDay = e.draft.allDay;
      String key(DateTime t) => CalEvent.keyOf(t, allDay);
      for (final t in e.exdates) {
        await _put(Change(), calendar, {
          ...e.draft.apply({}),
          'event': '$entry~${key(t)}',
          'series': entry,
          'instance': key(t),
          'deleted': true,
        }..remove('repeat'));
      }
      for (final (original, draft) in e.overrides) {
        await _put(
          Change(),
          calendar,
          draft.apply({
            'event': '$entry~${key(original)}',
            'series': entry,
            'instance': key(original),
          })..remove('repeat'),
        );
      }
    }
    return count;
  }

  /// Everything in [calendar] as an iCalendar file.
  String exportIcs(String calendar, {String name = 'OurNet'}) {
    final snapshot = _index.snapshot;
    final all = snapshot.latest(calendar).toList();
    return Ics.write(
      [
        for (final e in all)
          if (!e.isOverride && !e.deleted) e,
      ],
      overrides: [
        for (final e in all)
          if (e.isOverride) e,
      ],
      name: name,
    );
  }

  /// One event, with its changed occurrences, as an iCalendar file.
  String exportEvent(CalEvent e) => Ics.write(
    [e],
    overrides: _index.snapshot.overridesOf(e.calendar, e.entry),
    name: e.title,
  );

  // ---- sharing with people and devices ----------------------------------

  /// Republishes this person's personal calendar to the devices admitted now.
  /// A new device otherwise reads nothing written before it.
  Future<int> shareAll() async {
    await refresh();
    var count = 0;
    for (final e in _index.snapshot.latest(personal)) {
      if (e.deleted && !e.isOverride) continue;
      await node.publish(
        eventKind,
        {...e.data},
        space: personal,
        audience: [node.person],
      );
      count++;
    }
    return count;
  }

  /// A group's events as the owner republishes them for people who could not
  /// read the originals. [audience] says who each one goes to (nobody skips
  /// it); [into] is the space to write to when a group moves to a new one.
  /// Returns how many were published.
  static Future<int> reshare(
    Node node,
    EverydayItem room, {
    String? into,
    required List<String> Function(CalEvent) audience,
    GroupKey? seal,
  }) async {
    final index = _indexes[node] ??= _Index(node);
    await index.refresh();
    var count = 0;
    for (final e in index.snapshot.latest(room.object.space).toList()) {
      // A deleted occurrence is passed on too: it is what hides it.
      if (e.deleted && !e.isOverride) continue;
      final readers = audience(e);
      if (readers.isEmpty) continue;
      await node.publish(
        eventKind,
        {...e.data, 'history': true, 'originalAuthor': e.author},
        space: into ?? room.object.space,
        audience: readers,
        seal: seal,
      );
      count++;
    }
    return count;
  }

  // ---- links -------------------------------------------------------------

  /// A link that opens an event in OurNet, for chat, forums and notes.
  static String link(String calendar, String entry, {String? key}) =>
      Uri(
        scheme: 'ournet',
        host: 'event',
        pathSegments: [calendar, entry],
        queryParameters: key == null || key.isEmpty ? null : {'at': key},
      ).toString();

  /// What a link names, or null if [text] is not an event link.
  static ({String calendar, String entry, String? key})? parseLink(
    String text,
  ) {
    final uri = Uri.tryParse(text.trim());
    if (uri == null || uri.scheme != 'ournet' || uri.host != 'event') {
      return null;
    }
    final parts = uri.pathSegments;
    if (parts.length != 2 || parts.any((p) => p.isEmpty)) return null;
    return (calendar: parts[0], entry: parts[1], key: uri.queryParameters['at']);
  }

  /// Event links in [text].
  static final linkPattern = RegExp(r'ournet://event/[^\s<>"\x27]+[^\s<>"\x27.,;:!?)\]}]');
}

// ---------------------------------------------------------------------------

/// What the index knows at one moment, laid out for answering range queries
/// without walking every event.
class _Snapshot {
  final byEntry = <String, CalEvent>{};
  final deletedEvents = <CalEvent>[];
  final masters = <CalEvent>[];
  final simple = <CalEvent>[];
  final _overrides = <String, List<CalEvent>>{};
  final calendars = <String>{};
  final Map<String, List<CalEvent>> _latestBy;
  final _all = <String, CalEvent>{};
  int _maxSpan = 0;

  _Snapshot(this._latestBy) {
    for (final list in _latestBy.values) {
      for (final e in list) {
        _all['${e.calendar}|${e.entry}'] = e;
      }
    }
    for (final entry in _latestBy.entries) {
      for (final e in entry.value) {
        if (e.isOverride) {
          (_overrides['${e.calendar}|${e.series}'] ??= []).add(e);
        }
      }
    }
    for (final entry in _latestBy.entries) {
      for (final e in entry.value) {
        if (e.isOverride) continue;
        if (e.deleted) {
          deletedEvents.add(e);
          continue;
        }
        calendars.add(e.calendar);
        byEntry['${e.calendar}|${e.entry}'] = e;
        if (e.repeat != null) {
          masters.add(e);
        } else {
          simple.add(e);
          final span = e.end.difference(e.start).inMilliseconds;
          if (span > _maxSpan) _maxSpan = span;
        }
      }
    }
    simple.sort((a, b) => a.start.compareTo(b.start));
  }

  /// The newest valid version of an entry, deleted or not.
  CalEvent? version(String calendar, String entry) =>
      _all['$calendar|$entry'];

  /// The newest valid version of each entry in a calendar, deletions too.
  Iterable<CalEvent> latest(String calendar) =>
      _latestBy[calendar] ?? const [];

  List<CalEvent> overridesOf(String calendar, String series) =>
      _overrides['$calendar|$series'] ?? const [];

  void collect(
    DateTime from,
    DateTime to,
    Set<String> allowed,
    List<Occurrence> out,
  ) {
    // Simple events are sorted by start: begin where an event that ran as long
    // as the longest could still reach [from].
    var lo = 0, hi = simple.length;
    final earliest = from.subtract(Duration(milliseconds: _maxSpan));
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (simple[mid].start.isBefore(earliest)) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    for (var i = lo; i < simple.length; i++) {
      final e = simple[i];
      if (!e.start.isBefore(to)) break;
      if (!allowed.contains(e.calendar)) continue;
      if (_overlaps(e.start, e.end, from, to)) {
        out.add(Occurrence(e, e, '', e.start, e.end));
      }
    }
    for (final master in masters) {
      if (!allowed.contains(master.calendar)) continue;
      _expand(master, from, to, out);
    }
  }

  static bool _overlaps(DateTime s, DateTime e, DateTime from, DateTime to) =>
      s.isBefore(to) && (e.isAfter(from) || (!e.isAfter(s) && !s.isBefore(from)));

  void _expand(
    CalEvent master,
    DateTime from,
    DateTime to,
    List<Occurrence> out,
  ) {
    final rule = master.repeat!;
    final overrides = {
      for (final o in overridesOf(master.calendar, master.entry))
        if (o.instance != null) o.instance!: o,
    };
    final length = master.end.difference(master.start);
    final days = master.allDay ? master.data['days'] as int : 0;
    final reach = master.allDay
        ? from.subtract(Duration(days: days))
        : from.subtract(length);
    // A series that finished before this time has nothing to generate.
    final over = master.seriesEnd != null && master.seriesEnd!.isBefore(reach);
    for (final first in over
        ? const <DateTime>[]
        : rule.occurrences(master.start, from: reach)) {
      if (!first.isBefore(to)) break;
      final end = master.allDay
          ? DateTime(first.year, first.month, first.day + days)
          : first.add(length);
      final key = CalEvent.keyOf(first, master.allDay);
      if (overrides.containsKey(key)) continue;
      if (_overlaps(first, end, from, to)) {
        out.add(Occurrence(master, master, key, first, end));
      }
    }
    for (final o in overrides.values) {
      if (o.deleted) continue;
      if (_overlaps(o.start, o.end, from, to)) {
        out.add(Occurrence(o, master, o.instance!, o.start, o.end));
      }
    }
  }

  Occurrence? occurrence(
    String calendar,
    String entry, {
    String? key,
    DateTime? after,
  }) {
    final e = byEntry['$calendar|$entry'];
    if (e == null) return null;
    if (e.repeat == null) return Occurrence(e, e, '', e.start, e.end);
    final overrides = overridesOf(calendar, entry);
    if (key != null) {
      for (final o in overrides) {
        if (o.instance == key) {
          return o.deleted ? null : Occurrence(o, e, key, o.start, o.end);
        }
      }
      for (final first in e.repeat!.occurrences(e.start)) {
        final k = CalEvent.keyOf(first, e.allDay);
        if (k == key) {
          final end = e.allDay
              ? DateTime(first.year, first.month, first.day + (e.data['days'] as int))
              : first.add(e.end.difference(e.start));
          return Occurrence(e, e, key, first, end);
        }
        if (first.millisecondsSinceEpoch > (int.tryParse(key) ?? 0) &&
            !e.allDay) {
          break;
        }
        if (e.allDay && first.isAfter(Calendar.parseDay(key))) break;
      }
      return null;
    }
    // The next one after [after], or the last one when the series is over.
    final point = after ?? e.start;
    final found = <Occurrence>[];
    _expand(e, point, point.add(const Duration(days: 366 * 3)), found);
    found.sort(Calendar.compareOccurrences);
    for (final o in found) {
      if (o.end.isAfter(point)) return o;
    }
    // Over: show the last occurrence that ever happened.
    Occurrence? last;
    final rule = e.repeat!;
    var n = 0;
    final length = e.end.difference(e.start);
    for (final first in rule.occurrences(e.start)) {
      if (++n > 5000) break;
      final end = e.allDay
          ? DateTime(first.year, first.month, first.day + (e.data['days'] as int))
          : first.add(length);
      last = Occurrence(e, e, CalEvent.keyOf(first, e.allDay), first, end);
    }
    return last;
  }
}

/// The per-node projection of every calendar object: all versions of each
/// entry, read once and then only what arrives.
class _Index {
  final Node node;
  _Index(this.node);

  // calendar -> entry -> versions, newest first, a few kept.
  final _versions = <String, Map<String, List<CalEvent>>>{};
  // calendar -> "person|event|instance" -> newest answer
  final _answers = <String, Map<String, (SignedObject, Json)>>{};
  final _unreadable = <String, SignedObject>{};
  int _eventCursor = 0, _rsvpCursor = 0, _keysCursor = 0;
  int clock = 0;
  int version = 0;
  bool loaded = false;
  String _rooms = '';
  Map<String, EverydayItem> _roomMap = {};
  String _blocked = '';
  _Snapshot? _snapshot;
  Future<void>? _running;
  int _settled = -1;

  static const _kept = 6;

  _Snapshot get snapshot => _snapshot ??= _build();

  void touch() {
    version++;
  }

  Future<bool> refresh() async {
    final before = version;
    if (_settled == node.store.insertionCursor &&
        _blocked == '${node.blocked.toList()..sort()}') {
      final signature = await _roomSignature();
      if (signature == _rooms) return false;
    }
    await (_running ??= _run().whenComplete(() => _running = null));
    return version != before;
  }

  Future<String> _roomSignature() async {
    final rooms = await Everyday(node).rooms();
    return '${[
      for (final r in rooms)
        '${r.object.space}|${r.data['generation']}|${r.data['epoch']}|${r.data['owner']}|${(r.data['members'] as List).join(',')}',
    ]..sort()}';
  }

  Future<void> _run() async {
    final target = node.store.insertionCursor;
    final slice = TimeSlice();
    var changed = false;
    final blocked = '${node.blocked.toList()..sort()}';
    if (blocked != _blocked) {
      // Blocking someone stores nothing, so nothing arrives to notice it.
      _blocked = blocked;
      changed = true;
    }
    // Objects that could not be read yet may be readable after a key grant.
    while (true) {
      final page = node.store.insertedOfKind(_keysCursor, 'keys');
      if (page.isEmpty) break;
      _keysCursor = page.last.$1;
      if (_unreadable.isNotEmpty) {
        for (final o in _unreadable.values.toList()) {
          if (await _take(o)) changed = true;
        }
      }
    }
    while (true) {
      final page = node.store.insertedOfKind(_eventCursor, Calendar.eventKind);
      if (page.isEmpty) break;
      for (final (cursor, o) in page) {
        _eventCursor = cursor;
        await slice.pause();
        if (await _take(o)) changed = true;
      }
    }
    while (true) {
      final page = node.store.insertedOfKind(_rsvpCursor, Calendar.rsvpKind);
      if (page.isEmpty) break;
      for (final (cursor, o) in page) {
        _rsvpCursor = cursor;
        await slice.pause();
        if (await _take(o)) changed = true;
      }
    }
    final signature = await _roomSignature();
    if (signature != _rooms) {
      _rooms = signature;
      _roomMap = {
        for (final r in await Everyday(node).rooms()) r.object.space: r,
      };
      changed = true;
    }
    _settled = target;
    loaded = true;
    if (changed) {
      _snapshot = null;
      version++;
    }
  }

  Future<bool> _take(SignedObject o) async {
    if (o.isPublic || !node.visible(o)) return false;
    final p = await node.content(o);
    if (p == null) {
      _unreadable[o.id] = o;
      return false;
    }
    _unreadable.remove(o.id);
    if (o.kind == Calendar.rsvpKind) {
      final key = '${o.author}|${p['event']}|${p['instance'] ?? ''}';
      final book = _answers[o.space] ??= {};
      final old = book[key];
      if (old != null &&
          (old.$1.created > o.created ||
              (old.$1.created == o.created && old.$1.id.compareTo(o.id) > 0))) {
        return false;
      }
      book[key] = (o, p);
      return true;
    }
    final e = CalEvent(o, p);
    if (e.clock > clock) clock = e.clock;
    final list = (_versions[e.calendar] ??= {})[e.entry] ??= [];
    if (list.any((v) => v.object.id == o.id)) return false;
    list
      ..add(e)
      ..sort((a, b) => CalEvent.newer(a, b) ? -1 : 1);
    if (list.length > _kept) list.removeRange(_kept, list.length);
    return true;
  }

  /// Whether a version of an entry may count: written by someone entitled to.
  bool _valid(CalEvent e) {
    final o = e.object;
    if (e.calendar == Calendar.personal) {
      return o.author == node.person &&
          o.audience.length == 1 &&
          o.audience.single == node.person;
    }
    final room = _roomMap[e.calendar];
    if (room == null) return false;
    final members = (room.data['members'] as List).cast<String>();
    if (!o.audience.every(members.contains)) return false;
    if (node.blocked.contains(e.author)) return false;
    return e.data['history'] == true
        ? o.author == room.data['owner']
        : members.contains(o.author);
  }

  _Snapshot _build() {
    final latest = <String, List<CalEvent>>{};
    for (final calendar in _versions.entries) {
      for (final versions in calendar.value.values) {
        final winner = versions.where(_valid).firstOrNull;
        if (winner != null) (latest[calendar.key] ??= []).add(winner);
      }
    }
    return _Snapshot(latest);
  }

  /// The newest valid version of an entry, deleted or not.
  CalEvent? latest(String calendar, String entry) =>
      _versions[calendar]?[entry]?.where(_valid).firstOrNull;

  Map<String, Rsvp> rsvps(String calendar, String entry, String key) {
    final room = _roomMap[calendar];
    if (room == null) return const {};
    final members = (room.data['members'] as List).cast<String>();
    final book = _answers[calendar] ?? const {};
    final result = <String, Rsvp>{};
    for (final person in members) {
      final specific = key.isEmpty ? null : book['$person|$entry|$key'];
      final answer = specific ?? book['$person|$entry|'];
      final value = answer?.$2['response'];
      final rsvp = Rsvp.values.where((r) => r.name == value).firstOrNull;
      if (rsvp != null) result[person] = rsvp;
    }
    return result;
  }
}
