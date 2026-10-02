import 'recurrence.dart';

/// What [QuickAdd.parse] found in a line like "Lunch with Sam tomorrow 1pm".
class QuickEvent {
  /// The text left once the date, time and repeat were taken out.
  final String title;
  final DateTime start, end;

  /// A date with no time: the event lasts the day.
  final bool allDay;
  final Repeat? repeat;
  const QuickEvent(
    this.title,
    this.start,
    this.end, {
    this.allDay = false,
    this.repeat,
  });
}

/// Reads a date, time, length and repeat out of a typed event title, as
/// calendars' "quick add" does. English only; anything it does not
/// recognise stays in the title.
class QuickAdd {
  static const _days = {
    'mon': 1, 'monday': 1, 'tue': 2, 'tues': 2, 'tuesday': 2,
    'wed': 3, 'weds': 3, 'wednesday': 3, 'thu': 4, 'thur': 4, 'thurs': 4,
    'thursday': 4, 'fri': 5, 'friday': 5, 'sat': 6, 'saturday': 6,
    'sun': 7, 'sunday': 7,
  };
  static const _months = {
    'jan': 1, 'january': 1, 'feb': 2, 'february': 2, 'mar': 3, 'march': 3,
    'apr': 4, 'april': 4, 'may': 5, 'jun': 6, 'june': 6, 'jul': 7, 'july': 7,
    'aug': 8, 'august': 8, 'sep': 9, 'sept': 9, 'september': 9, 'oct': 10,
    'october': 10, 'nov': 11, 'november': 11, 'dec': 12, 'december': 12,
  };
  static final _dayNames = _days.keys.join('|');
  static final _monthNames = _months.keys.join('|');

  static final _every = RegExp(
    r'\b(?:every\s+(?:(\d+)\s+)?(day|days|week|weeks|month|months|year|years|weekday|weekdays)'
    r'|every\s+((?:(?:' '$_dayNames' r')(?:\s*(?:,|and|&)\s*)?)+)'
    r'|(daily|weekly|monthly|yearly|annually))\b',
    caseSensitive: false,
  );
  static final _duration = RegExp(
    r'\bfor\s+(\d+(?:\.\d+)?)\s*(hours?|hrs?|h|minutes?|mins?|m)\b',
    caseSensitive: false,
  );
  static final _in = RegExp(
    r'\bin\s+(\d+)\s*(minutes?|mins?|hours?|hrs?|days?|weeks?|months?)\b',
    caseSensitive: false,
  );
  static final _iso = RegExp(r'\b(\d{4})-(\d{2})-(\d{2})\b');
  static final _monthDay = RegExp(
    r'\b(?:on\s+)?(?:(' '$_monthNames' r')\.?\s+(\d{1,2})(?:st|nd|rd|th)?'
    r'|(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?(' '$_monthNames' r')\b\.?)'
    r'(?:,?\s+(\d{4}))?\b',
    caseSensitive: false,
  );
  static final _word = RegExp(
    r'\b(today|tomorrow|tmrw|tmr|tonight|next\s+week|next\s+month)\b',
    caseSensitive: false,
  );
  static final _weekday = RegExp(
    r'\b(?:(?:on|next|this)\s+)?(' '$_dayNames' r')\b',
    caseSensitive: false,
  );
  static final _range = RegExp(
    r'\b(?:from\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*(?:-|–|to|until)\s*'
    r'(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\b',
    caseSensitive: false,
  );
  static final _clock = RegExp(
    r'\b(?:(?:at|@)\s*)?(?:(\d{1,2}):(\d{2})\s*(am|pm)?|(\d{1,2})\s*(am|pm))\b',
    caseSensitive: false,
  );
  static final _bareHour = RegExp(
    r'\b(?:at|@)\s*(\d{1,2})\b',
    caseSensitive: false,
  );
  static final _named = RegExp(r'\b(?:at\s+)?(noon|midday|midnight)\b', caseSensitive: false);

  /// The event [text] describes, or null if it names no date or time.
  static QuickEvent? parse(String text, {DateTime? now}) {
    now ??= DateTime.now();
    var rest = text;
    String take(Match m) {
      rest = rest.replaceRange(m.start, m.end, ' ');
      return m.group(0)!;
    }

    Repeat? repeat;
    var anchorDay = false;
    final every = _every.firstMatch(rest);
    int? repeatDay;
    if (every != null) {
      take(every);
      if (every.group(2) != null) {
        final n = int.tryParse(every.group(1) ?? '') ?? 1;
        final unit = every.group(2)!.toLowerCase();
        repeat = switch (unit) {
          'weekday' || 'weekdays' => const Repeat('weekly', days: [1, 2, 3, 4, 5]),
          'day' || 'days' => Repeat('daily', interval: n),
          'week' || 'weeks' => Repeat('weekly', interval: n),
          'month' || 'months' => Repeat('monthly', interval: n),
          _ => Repeat('yearly', interval: n),
        };
      } else if (every.group(3) != null) {
        final picked = {
          for (final m in RegExp(_dayNames, caseSensitive: false).allMatches(every.group(3)!))
            _days[m.group(0)!.toLowerCase()]!,
        }.toList()
          ..sort();
        repeat = Repeat('weekly', days: picked);
        repeatDay = picked.first;
      } else {
        repeat = switch (every.group(4)!.toLowerCase()) {
          'daily' => const Repeat('daily'),
          'weekly' => const Repeat('weekly'),
          'monthly' => const Repeat('monthly'),
          _ => const Repeat('yearly'),
        };
      }
    }

    Duration? length;
    final duration = _duration.firstMatch(rest);
    if (duration != null) {
      take(duration);
      final amount = double.parse(duration.group(1)!);
      final unit = duration.group(2)!.toLowerCase();
      length = Duration(
        minutes: (unit.startsWith('h') ? amount * 60 : amount).round(),
      );
    }

    DateTime? date;
    var relativeTime = false;
    final relative = _in.firstMatch(rest);
    if (relative != null) {
      take(relative);
      final n = int.parse(relative.group(1)!);
      final unit = relative.group(2)!.toLowerCase();
      if (unit.startsWith('m') && !unit.startsWith('mo')) {
        date = now.add(Duration(minutes: n));
        relativeTime = true;
      } else if (unit.startsWith('h')) {
        date = now.add(Duration(hours: n));
        relativeTime = true;
      } else if (unit.startsWith('d')) {
        date = DateTime(now.year, now.month, now.day + n);
      } else if (unit.startsWith('w')) {
        date = DateTime(now.year, now.month, now.day + 7 * n);
      } else {
        date = DateTime(now.year, now.month + n, now.day);
      }
    }
    final iso = date == null ? _iso.firstMatch(rest) : null;
    if (iso != null) {
      take(iso);
      date = DateTime(
        int.parse(iso.group(1)!),
        int.parse(iso.group(2)!),
        int.parse(iso.group(3)!),
      );
    }
    final monthDay = date == null ? _monthDay.firstMatch(rest) : null;
    if (monthDay != null) {
      final month = _months[(monthDay.group(1) ?? monthDay.group(4))!.toLowerCase()]!;
      final day = int.parse(monthDay.group(2) ?? monthDay.group(3)!);
      if (day >= 1 && day <= 31) {
        take(monthDay);
        var year = int.tryParse(monthDay.group(5) ?? '') ?? now.year;
        date = DateTime(year, month, day);
        if (monthDay.group(5) == null &&
            date.isBefore(DateTime(now.year, now.month, now.day))) {
          date = DateTime(year + 1, month, day);
        }
      }
    }
    var tonight = false;
    if (date == null) {
      final word = _word.firstMatch(rest);
      if (word != null) {
        final w = word.group(1)!.toLowerCase();
        take(word);
        final today = DateTime(now.year, now.month, now.day);
        date = switch (w) {
          'today' => today,
          'tonight' => today,
          'tomorrow' || 'tmrw' || 'tmr' => DateTime(now.year, now.month, now.day + 1),
          'next week' => DateTime(now.year, now.month, now.day + 7),
          _ => DateTime(now.year, now.month + 1, now.day),
        };
        tonight = w == 'tonight';
        anchorDay = true;
      }
    }
    if (date == null) {
      final weekday = repeatDay == null ? _weekday.firstMatch(rest) : null;
      final wanted = repeatDay ?? (weekday == null ? null : _days[weekday.group(1)!.toLowerCase()]);
      if (wanted != null) {
        if (weekday != null) take(weekday);
        final today = DateTime(now.year, now.month, now.day);
        var ahead = (wanted - today.weekday + 7) % 7;
        if (ahead == 0 && weekday != null && weekday.group(0)!.toLowerCase().startsWith('next')) {
          ahead = 7;
        }
        date = DateTime(today.year, today.month, today.day + ahead);
        anchorDay = true;
      }
    }

    int? startMinutes, endMinutes;
    int hour24(int h, String? meridian, {int? fallback}) {
      var hour = h % 12;
      final m = meridian?.toLowerCase();
      if (m == 'pm') return hour + 12;
      if (m == 'am') return hour;
      return fallback ?? h;
    }

    final range = _range.firstMatch(rest);
    if (range != null &&
        (range.group(3) != null ||
            range.group(6) != null ||
            range.group(2) != null ||
            range.group(5) != null)) {
      final sh = int.parse(range.group(1)!), eh = int.parse(range.group(4)!);
      if (sh <= 24 && eh <= 24) {
        take(range);
        final sm = int.tryParse(range.group(2) ?? '') ?? 0;
        final em = int.tryParse(range.group(5) ?? '') ?? 0;
        var smer = range.group(3), emer = range.group(6);
        // "3-4pm" is both in the afternoon; "11-1pm" runs across noon.
        if (smer == null && emer != null) {
          smer = (sh % 12 > eh % 12 && sh != 12) ? (emer.toLowerCase() == 'pm' ? 'am' : 'pm') : emer;
        } else if (emer == null && smer != null) {
          emer = (eh % 12 < sh % 12 && eh != 12) ? (smer.toLowerCase() == 'am' ? 'pm' : 'am') : smer;
        }
        startMinutes = hour24(sh, smer) * 60 + sm;
        endMinutes = hour24(eh, emer) * 60 + em;
        if (endMinutes <= startMinutes) endMinutes += 12 * 60;
      }
    }
    if (startMinutes == null) {
      final clock = _clock.firstMatch(rest);
      if (clock != null) {
        final h = int.parse(clock.group(1) ?? clock.group(4)!);
        final mi = int.tryParse(clock.group(2) ?? '') ?? 0;
        if (h <= 24 && mi < 60) {
          take(clock);
          startMinutes = hour24(h, clock.group(3) ?? clock.group(5)) * 60 + mi;
        }
      }
    }
    if (startMinutes == null) {
      final named = _named.firstMatch(rest);
      if (named != null) {
        take(named);
        startMinutes = named.group(1)!.toLowerCase() == 'midnight' ? 0 : 12 * 60;
      }
    }
    if (startMinutes == null) {
      final bare = _bareHour.firstMatch(rest);
      if (bare != null) {
        final h = int.parse(bare.group(1)!);
        if (h >= 1 && h <= 24) {
          take(bare);
          // Nobody means 3 in the morning by "at 3".
          startMinutes = (h >= 1 && h <= 6 ? h + 12 : h) * 60;
        }
      }
    }
    if (startMinutes == null && tonight) startMinutes = 19 * 60;

    final cleaned = _tidy(rest);
    if (date == null && startMinutes == null) {
      // A repeat alone ("gym every monday") already named its day; a bare
      // "every day" has none, and counts as today.
      if (repeat == null) return null;
      date = DateTime(now.year, now.month, now.day);
    }
    if (startMinutes == null && relative != null && relativeTime) {
      final start = date!;
      final end = start.add(length ?? const Duration(hours: 1));
      return QuickEvent(cleaned, start, end, repeat: repeat);
    }
    final base = date ?? DateTime(now.year, now.month, now.day);
    if (startMinutes == null) {
      return QuickEvent(
        cleaned,
        base,
        DateTime(base.year, base.month, base.day + 1),
        allDay: true,
        repeat: repeat,
      );
    }
    var start = DateTime(
      base.year,
      base.month,
      base.day,
      startMinutes ~/ 60 % 24,
      startMinutes % 60,
    );
    // A time with no date means the next time it comes round.
    if (date == null && !anchorDay && start.isBefore(now)) {
      start = DateTime(start.year, start.month, start.day + 1, start.hour, start.minute);
    }
    final end = endMinutes != null
        ? start.add(Duration(minutes: endMinutes - startMinutes))
        : start.add(length ?? const Duration(hours: 1));
    return QuickEvent(cleaned, start, end, repeat: repeat);
  }

  /// Leftover connecting words and spaces removed from the ends.
  static String _tidy(String text) {
    var t = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final trailing = RegExp(
      r'(?:\s+(?:at|on|from|by|until|starting|@|for|in|every|the|next|this))+$',
      caseSensitive: false,
    );
    final leading = RegExp(
      r'^(?:(?:at|on|from|by|until|@|for|in|every|the)\s+)+',
      caseSensitive: false,
    );
    t = t.replaceFirst(trailing, '').replaceFirst(leading, '').trim();
    return t.replaceAll(RegExp(r'^[,;:\-–]+|[,;:\-–]+$'), '').trim();
  }
}
