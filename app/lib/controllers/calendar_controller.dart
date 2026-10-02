import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart' show Files;

import '../services/coalesced_task.dart';
import '../services/speech.dart';
import '../ui/calendar_dates.dart';

enum CalendarView {
  day('Day', 'd'),
  threeDays('3 days', '3'),
  week('Week', 'w'),
  month('Month', 'm'),
  schedule('Schedule', 'a'),
  year('Year', 'y');

  final String label, key;
  const CalendarView(this.label, this.key);

  static CalendarView named(Object? name, CalendarView fallback) =>
      values.where((v) => v.name == name).firstOrNull ?? fallback;
}

/// What the calendar screens show and how: the view, the date in focus, which
/// calendars are on, and this person's preferences. Reads come from the
/// incremental [Calendar] index, never from history, so a refresh costs what
/// arrived. Screens listen and rebuild; occurrences for a range are computed
/// once per change.
class CalendarController extends ChangeNotifier {
  final Node node;
  final Calendar calendar;

  /// Set for a group's own calendar: it shows that calendar alone, with no
  /// switches for others.
  final String? group;
  late final CoalescedTask _refresher;
  StreamSubscription<void>? _changes;
  bool _disposed = false;

  /// Dictation and file storage for voice notes; null where unavailable.
  final Speech? speech;
  final Files? files;

  /// A person's name, for who added an event and who is going.
  final String Function(String person) personName;

  /// Tells the person something short, with an optional action (undo).
  final void Function(String message, {String? action, VoidCallback? onAction})
  notify;

  CalendarController(
    this.node,
    this.calendar, {
    this.group,
    this.speech,
    this.files,
    String Function(String person)? personName,
    void Function(String message, {String? action, VoidCallback? onAction})?
    notify,
  }) : personName = personName ?? ((p) => p),
       notify = notify ?? ((message, {action, onAction}) {}) {
    final v = node.store.setting(_key('view'));
    view = CalendarView.named(v, CalendarView.week);
    firstWeekday = node.store.setting('calFirstDay') as int? ?? 1;
    showWeekends = node.store.setting('calWeekends') != false;
    weekNumbers = node.store.setting('calWeekNumbers') == true;
    defaultReminder = node.store.setting('calReminder') as int? ?? 10;
    defaultMinutes = node.store.setting('calLength') as int? ?? 60;
    _refresher = CoalescedTask(
      refresh,
      (e) => lastError = '$e',
      delay: const Duration(milliseconds: 80),
    );
    _changes = node.changes.stream.listen((_) => _refresher.schedule());
    _refresher.schedule();
  }

  String _key(String name) => group == null ? 'cal/$name' : 'cal/group/$name';

  late CalendarView view;
  DateTime focus = DateTime.now();
  late int firstWeekday;
  late bool showWeekends;
  late bool weekNumbers;

  /// Minutes before an event, for events made here; negative for none.
  late int defaultReminder;
  late int defaultMinutes;
  String? lastError;
  List<CalendarInfo> calendars = const [];
  bool ready = false;

  String query = '';
  List<Occurrence>? results;

  /// The calendars on screen: one group's own, or every calendar switched on.
  Set<String> get active => group != null
      ? {group!}
      : {
          for (final c in calendars)
            if (calendar.shown(c.id)) c.id,
        };

  // ---- navigation --------------------------------------------------------

  void setView(CalendarView next) {
    if (next == view) return;
    view = next;
    node.store.set(_key('view'), next.name);
    notifyListeners();
  }

  void go(DateTime day) {
    focus = day;
    notifyListeners();
  }

  void today() => go(DateTime.now());

  /// Moves a screenful forward or back, by whatever the view covers.
  void step(int direction) {
    focus = switch (view) {
      CalendarView.day => addDays(focus, direction),
      CalendarView.threeDays => addDays(focus, 3 * direction),
      CalendarView.week => addDays(focus, 7 * direction),
      CalendarView.month => addMonths(focus, direction),
      CalendarView.schedule => addDays(focus, 14 * direction),
      CalendarView.year => addMonths(focus, 12 * direction),
    };
    notifyListeners();
  }

  /// The days a time grid shows for the current view and focus.
  List<DateTime> get gridDays {
    final day = dateOnly(focus);
    switch (view) {
      case CalendarView.day:
        return [day];
      case CalendarView.threeDays:
        return [for (var i = 0; i < 3; i++) addDays(day, i)];
      default:
        final start = startOfWeek(day, firstWeekday);
        final week = [for (var i = 0; i < 7; i++) addDays(start, i)];
        return showWeekends ? week : week.where((d) => d.weekday < 6).toList();
    }
  }

  // ---- data ----------------------------------------------------------------

  int _generation = 0;

  /// Bumped whenever what is shown may differ, to key cached presentation.
  int get generation => _generation;

  /// The calendar's version when this screen last looked. Writes refresh the
  /// shared index themselves, so "did the refresh find anything" would miss
  /// them; what matters is whether the index has moved on from what is shown.
  int _seen = -1;

  Future<void> refresh() async {
    await calendar.refresh();
    // Laying the calendar out costs a little on a long one: do it here, not
    // in the first frame that asks.
    calendar.warm();
    final changed = calendar.version != _seen;
    _seen = calendar.version;
    final next = await calendar.calendars();
    final list = group == null
        ? next
        : next.where((c) => c.id == group).toList();
    final same =
        list.length == calendars.length &&
        [for (final c in list) '${c.id}|${c.name}'].join() ==
            [for (final c in calendars) '${c.id}|${c.name}'].join();
    if (!changed && same && ready) return;
    calendars = list;
    ready = true;
    _generation++;
    if (query.isNotEmpty) results = calendar.search(query);
    if (!_disposed) notifyListeners();
  }

  /// Marks a change this controller made itself (a switch, a preference) so
  /// listeners rebuild.
  void changed() {
    _generation++;
    if (!_disposed) notifyListeners();
  }

  (int, DateTime, DateTime)? _memoKey;
  List<Occurrence> _memo = const [];

  /// The occurrences on screen between [from] and [to].
  List<Occurrence> occurrences(DateTime from, DateTime to) {
    final key = (_generation, from, to);
    if (_memoKey == key) return _memo;
    _memoKey = key;
    return _memo = calendar.between(from, to, calendars: active);
  }

  Future<void> setShown(String id, bool on) async {
    await calendar.setShown(id, on);
    changed();
  }

  void search(String text) {
    query = text.trim();
    results = query.isEmpty ? null : calendar.search(query);
    notifyListeners();
  }

  // ---- naming and colour -----------------------------------------------------

  String nameOf(String id) => calendars
          .where((c) => c.id == id)
          .map((c) => c.name)
          .firstOrNull ??
      (id == Calendar.personal ? 'My calendar' : 'Group');

  String colorNameOfCalendar(String id) =>
      calendar.calendarColor(id) ?? defaultCalendarColor(id);

  Color colorOfCalendar(String id) => colorNamed(colorNameOfCalendar(id));

  /// An event's colour: its own, or its calendar's.
  Color colorOf(CalEvent e) =>
      eventColors[e.color] ?? colorOfCalendar(e.calendar);

  Future<void> setCalendarColor(String id, String? name) async {
    await calendar.setCalendarColor(id, name);
    changed();
  }

  // ---- preferences -----------------------------------------------------------

  void setPreferences({
    int? firstWeekday,
    bool? showWeekends,
    bool? weekNumbers,
    int? defaultReminder,
    int? defaultMinutes,
  }) {
    if (firstWeekday != null) {
      this.firstWeekday = firstWeekday;
      node.store.set('calFirstDay', firstWeekday);
    }
    if (showWeekends != null) {
      this.showWeekends = showWeekends;
      node.store.set('calWeekends', showWeekends);
    }
    if (weekNumbers != null) {
      this.weekNumbers = weekNumbers;
      node.store.set('calWeekNumbers', weekNumbers);
    }
    if (defaultReminder != null) {
      this.defaultReminder = defaultReminder;
      node.store.set('calReminder', defaultReminder);
    }
    if (defaultMinutes != null) {
      this.defaultMinutes = defaultMinutes;
      node.store.set('calLength', defaultMinutes);
    }
    changed();
  }

  /// A new event's form, starting at [start] for the default length.
  EventDraft newDraft({
    DateTime? start,
    DateTime? end,
    bool allDay = false,
  }) {
    final from = start ?? _nextHalfHour();
    return EventDraft(
      start: allDay ? dateOnly(from) : from,
      end: allDay
          ? addDays(dateOnly(end ?? from), 1)
          : end ?? from.add(Duration(minutes: defaultMinutes)),
      allDay: allDay,
      reminders: [if (defaultReminder >= 0 && !allDay) defaultReminder],
    );
  }

  DateTime _nextHalfHour() {
    final now = DateTime.now();
    final base = DateTime(now.year, now.month, now.day, now.hour);
    return now.minute < 30
        ? base.add(const Duration(minutes: 30))
        : base.add(const Duration(hours: 1));
  }

  @override
  void dispose() {
    _disposed = true;
    _changes?.cancel();
    _refresher.close();
    super.dispose();
  }
}
