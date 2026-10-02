import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:ournet_core/ournet_core.dart';

/// Date arithmetic, wording and screen layout for the calendar views. Nothing
/// here reads storage, so views can call it freely while building.

const monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August',
  'September', 'October', 'November', 'December',
];
const weekdayNames = [
  'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday',
];

String monthShort(int month) => monthNames[month - 1].substring(0, 3);
String weekdayShort(int weekday) => weekdayNames[weekday - 1].substring(0, 3);

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
DateTime addDays(DateTime d, int days) =>
    DateTime(d.year, d.month, d.day + days, d.hour, d.minute);
bool sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;
int daysBetween(DateTime a, DateTime b) =>
    DateTime.utc(b.year, b.month, b.day)
        .difference(DateTime.utc(a.year, a.month, a.day))
        .inDays;

/// The first day of the week containing [d], for weeks that begin on
/// [firstWeekday] (Monday 1 to Sunday 7).
DateTime startOfWeek(DateTime d, int firstWeekday) =>
    DateTime(d.year, d.month, d.day - (d.weekday - firstWeekday + 7) % 7);

/// The six weeks (42 days) a month grid shows.
List<DateTime> monthGridDays(DateTime month, int firstWeekday) {
  final first = startOfWeek(DateTime(month.year, month.month), firstWeekday);
  return [for (var i = 0; i < 42; i++) addDays(first, i)];
}

/// How many weeks of [monthGridDays] a month needs: four to six.
int monthWeeks(DateTime month, int firstWeekday) {
  final first = startOfWeek(DateTime(month.year, month.month), firstWeekday);
  final last = DateTime(month.year, month.month + 1, 0);
  return (daysBetween(first, last) ~/ 7) + 1;
}

/// ISO 8601 week number.
int weekNumber(DateTime d) {
  final thursday = DateTime.utc(d.year, d.month, d.day + 4 - d.weekday);
  final yearStart = DateTime.utc(thursday.year);
  return 1 + thursday.difference(yearStart).inDays ~/ 7;
}

DateTime addMonths(DateTime d, int months) {
  final target = DateTime(d.year, d.month + months);
  final last = DateTime(target.year, target.month + 1, 0).day;
  return DateTime(target.year, target.month, math.min(d.day, last));
}

// ---- wording ---------------------------------------------------------------

String formatClock(BuildContext context, DateTime t, {bool short = true}) {
  final use24 = MediaQuery.alwaysUse24HourFormatOf(context);
  final time = TimeOfDay.fromDateTime(t);
  if (use24) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }
  final hour = time.hourOfPeriod == 0 ? 12 : time.hourOfPeriod;
  final suffix = time.period == DayPeriod.am ? 'am' : 'pm';
  return short && time.minute == 0
      ? '$hour$suffix'
      : '$hour:${time.minute.toString().padLeft(2, '0')}$suffix';
}

String formatHour(BuildContext context, int hour) {
  if (MediaQuery.alwaysUse24HourFormatOf(context)) {
    return '${hour.toString().padLeft(2, '0')}:00';
  }
  if (hour == 0) return '12 am';
  if (hour == 12) return '12 pm';
  return hour < 12 ? '$hour am' : '${hour - 12} pm';
}

/// "Mon 12 Oct", with the year when it is not [now]'s.
String formatDay(DateTime d, {DateTime? now, bool weekday = true}) {
  now ??= DateTime.now();
  final base = '${d.day} ${monthShort(d.month)}';
  final year = d.year == now.year ? '' : ' ${d.year}';
  return weekday ? '${weekdayShort(d.weekday)} $base$year' : '$base$year';
}

/// "October 2026".
String formatMonth(DateTime d) => '${monthNames[d.month - 1]} ${d.year}';

/// When an occurrence is, in words: "Mon 12 Oct · 2pm – 3pm".
String describeWhen(BuildContext context, Occurrence o) {
  final now = DateTime.now();
  if (o.allDay) {
    final last = addDays(o.end, -1);
    return sameDay(o.start, last)
        ? '${formatDay(o.start, now: now)} · All day'
        : '${formatDay(o.start, now: now)} – ${formatDay(last, now: now)}';
  }
  final start = formatClock(context, o.start);
  final end = formatClock(context, o.end);
  if (sameDay(o.start, o.end) || (o.end.hour == 0 && o.end.minute == 0 && sameDay(o.start, addDays(o.end, -1)))) {
    return '${formatDay(o.start, now: now)} · $start – $end';
  }
  return '${formatDay(o.start, now: now)} $start – ${formatDay(o.end, now: now)} $end';
}

/// The title to show, with a placeholder for an event with none.
String eventTitle(CalEvent e) => e.title.isEmpty ? '(No title)' : e.title;

/// "10 minutes before", "1 day before", "At the time".
String describeReminder(int minutes) {
  if (minutes == 0) return 'At the time of the event';
  String unit(int n, String word) => '$n $word${n == 1 ? '' : 's'} before';
  if (minutes % 10080 == 0) return unit(minutes ~/ 10080, 'week');
  if (minutes % 1440 == 0) return unit(minutes ~/ 1440, 'day');
  if (minutes % 60 == 0) return unit(minutes ~/ 60, 'hour');
  return unit(minutes, 'minute');
}

// ---- colour ----------------------------------------------------------------

/// Event colours, named as stored. The names are the ones other calendars use.
const eventColors = <String, Color>{
  'tomato': Color(0xffd50000),
  'flamingo': Color(0xffe67c73),
  'tangerine': Color(0xfff4511e),
  'banana': Color(0xfff6bf26),
  'sage': Color(0xff33b679),
  'basil': Color(0xff0b8043),
  'peacock': Color(0xff039be5),
  'blueberry': Color(0xff3f51b5),
  'lavender': Color(0xff7986cb),
  'grape': Color(0xff8e24aa),
  'graphite': Color(0xff616161),
};

Color colorNamed(String? name, [Color fallback = const Color(0xff3f51b5)]) =>
    eventColors[name] ?? fallback;

/// Text that reads on [background].
Color onColor(Color background) =>
    background.computeLuminance() > 0.45 ? const Color(0xff202124) : Colors.white;

/// The colour a calendar gets before its owner picks one.
String defaultCalendarColor(String calendar) {
  if (calendar == Calendar.personal) return 'blueberry';
  const pool = ['sage', 'tangerine', 'grape', 'peacock', 'flamingo', 'basil', 'lavender', 'banana'];
  var hash = 0;
  for (final unit in calendar.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return pool[hash % pool.length];
}

// ---- time grid layout --------------------------------------------------------

/// A timed occurrence placed in a day column: where it starts and ends in
/// minutes from midnight, and which of the side-by-side [columns] it takes.
class PlacedEvent {
  final Occurrence occurrence;
  final int startMinute, endMinute;
  int column = 0, columns = 1;

  /// How many columns it may spread across, to the right of its own.
  int span = 1;

  /// Whether it began before this day or runs past it.
  final bool continuesBefore, continuesAfter;
  PlacedEvent(
    this.occurrence,
    this.startMinute,
    this.endMinute,
    this.continuesBefore,
    this.continuesAfter,
  );
}

/// Shortest height an event is drawn at, in minutes, which also decides what
/// counts as overlapping.
const minEventMinutes = 30;

/// Places the timed occurrences that touch [day] side by side where they
/// overlap, as other calendars do: each cluster of overlapping events shares
/// the width, and an event spreads over columns nothing else uses.
List<PlacedEvent> layoutDay(Iterable<Occurrence> occurrences, DateTime day) {
  final midnight = dateOnly(day);
  final next = addDays(midnight, 1);
  final placed = <PlacedEvent>[];
  for (final o in occurrences) {
    if (o.allDay) continue;
    if (!o.start.isBefore(next) || (o.end.isBefore(midnight) || o.end == midnight && o.start != o.end)) {
      continue;
    }
    final startsBefore = o.start.isBefore(midnight);
    final endsAfter = o.end.isAfter(next);
    final start = startsBefore ? 0 : o.start.difference(midnight).inMinutes;
    var end = endsAfter ? 24 * 60 : o.end.difference(midnight).inMinutes;
    if (end - start < minEventMinutes) end = math.min(24 * 60, start + minEventMinutes);
    if (end - start < 1) continue;
    placed.add(PlacedEvent(o, start, end, startsBefore, endsAfter));
  }
  placed.sort((a, b) {
    final order = a.startMinute.compareTo(b.startMinute);
    return order != 0 ? order : b.endMinute.compareTo(a.endMinute);
  });
  var cluster = <PlacedEvent>[];
  var clusterEnd = 0;
  void close() {
    if (cluster.isEmpty) return;
    final columnEnds = <int>[];
    for (final p in cluster) {
      var c = columnEnds.indexWhere((end) => end <= p.startMinute);
      if (c < 0) {
        c = columnEnds.length;
        columnEnds.add(0);
      }
      columnEnds[c] = p.endMinute;
      p.column = c;
    }
    for (final p in cluster) {
      p.columns = columnEnds.length;
    }
    // An event may spread right across columns that nothing else uses.
    for (final p in cluster) {
      var span = 1;
      for (var c = p.column + 1; c < columnEnds.length; c++) {
        final blocked = cluster.any(
          (q) =>
              q != p &&
              q.column == c &&
              q.startMinute < p.endMinute &&
              q.endMinute > p.startMinute,
        );
        if (blocked) break;
        span++;
      }
      p.span = span;
    }
    cluster = [];
  }

  for (final p in placed) {
    if (cluster.isNotEmpty && p.startMinute >= clusterEnd) close();
    cluster.add(p);
    clusterEnd = math.max(clusterEnd, p.endMinute);
  }
  close();
  return placed;
}

// ---- bars (all-day and multi-day events across a row of days) ---------------

/// An event drawn as a bar across [firstColumn] to [lastColumn] of a row of
/// days, on one [lane] below the day numbers.
class Bar {
  final Occurrence occurrence;
  final int firstColumn, lastColumn;
  final bool continuesBefore, continuesAfter;
  int lane = 0;
  Bar(
    this.occurrence,
    this.firstColumn,
    this.lastColumn,
    this.continuesBefore,
    this.continuesAfter,
  );
}

/// Whether an occurrence is drawn as a bar rather than a timed block or line:
/// all-day events, and anything that crosses midnight.
bool isBar(Occurrence o) =>
    o.allDay || daysBetween(o.start, o.lastMoment) >= 1;

/// Lays out the bars for [days] (a row of consecutive days): each takes the
/// highest free lane, longest first, so continuing bars keep their lane.
List<Bar> layoutBars(Iterable<Occurrence> occurrences, List<DateTime> days) {
  final bars = <Bar>[];
  final first = days.first, last = days.last;
  for (final o in occurrences) {
    if (!isBar(o)) continue;
    final startDay = dateOnly(o.start);
    final endDay = dateOnly(o.lastMoment);
    if (endDay.isBefore(first) || startDay.isAfter(last)) continue;
    final from = startDay.isBefore(first) ? 0 : daysBetween(first, startDay);
    final to = endDay.isAfter(last) ? days.length - 1 : daysBetween(first, endDay);
    bars.add(Bar(o, from, to, startDay.isBefore(first), endDay.isAfter(last)));
  }
  bars.sort((a, b) {
    final order = a.firstColumn.compareTo(b.firstColumn);
    if (order != 0) return order;
    final length = (b.lastColumn - b.firstColumn).compareTo(a.lastColumn - a.firstColumn);
    return length != 0 ? length : Calendar.compareOccurrences(a.occurrence, b.occurrence);
  });
  final laneEnds = <int>[];
  for (final bar in bars) {
    var lane = laneEnds.indexWhere((end) => end < bar.firstColumn);
    if (lane < 0) {
      lane = laneEnds.length;
      laneEnds.add(-1);
    }
    laneEnds[lane] = bar.lastColumn;
    bar.lane = lane;
  }
  return bars;
}
