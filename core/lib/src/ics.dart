import 'calendar.dart';
import 'recurrence.dart';

/// One event read from an iCalendar file.
class IcsEvent {
  final String uid;
  final EventDraft draft;

  /// Occurrences the file removes from a repeating event.
  final exdates = <DateTime>[];

  /// Changed occurrences of it, by the start they had originally.
  final overrides = <(DateTime, EventDraft)>[];
  IcsEvent(this.uid, this.draft);
}

class IcsImport {
  final events = <IcsEvent>[];

  /// Things in the file this reader could not keep, for telling the person.
  final problems = <String>[];
}

/// Reads and writes iCalendar (.ics) files, so events move to and from other
/// calendars. Only what [Calendar] stores is kept: titles, times, location,
/// notes, a simple repeat rule, reminders and busy/free.
class Ics {
  // ---- writing -----------------------------------------------------------

  /// A calendar file holding [events] in the order given: each repeating
  /// event once, with its changed and removed occurrences from [overrides].
  static String write(
    Iterable<CalEvent> events, {
    Iterable<CalEvent> overrides = const [],
    String name = 'OurNet',
  }) {
    final out = StringBuffer();
    void line(String text) {
      // Lines are folded at 75 octets, continuing with a space.
      final units = text.runes.toList();
      var current = StringBuffer();
      var bytes = 0;
      for (final rune in units) {
        final char = String.fromCharCode(rune);
        final size = char.length == 1 && rune < 0x80
            ? 1
            : rune < 0x800
            ? 2
            : rune < 0x10000
            ? 3
            : 4;
        if (bytes + size > 73) {
          out.write('${current.toString()}\r\n');
          current = StringBuffer(' ');
          bytes = 1;
        }
        current.write(char);
        bytes += size;
      }
      out.write('${current.toString()}\r\n');
    }

    line('BEGIN:VCALENDAR');
    line('VERSION:2.0');
    line('PRODID:-//OurNet//Calendar//EN');
    line('CALSCALE:GREGORIAN');
    line('X-WR-CALNAME:${_escape(name)}');
    void event(
      CalEvent e, {
      CalEvent? master,
      List<String> removed = const [],
    }) {
      line('BEGIN:VEVENT');
      line('UID:${master?.entry ?? e.entry}@ournet');
      line('DTSTAMP:${_utc(DateTime.fromMillisecondsSinceEpoch(e.edited))}');
      if (master != null) {
        final key = e.instance!;
        line(
          master.allDay
              ? 'RECURRENCE-ID;VALUE=DATE:${_date(Calendar.parseDay(key))}'
              : 'RECURRENCE-ID:${_utc(DateTime.fromMillisecondsSinceEpoch(int.parse(key)))}',
        );
      }
      if (e.allDay) {
        line('DTSTART;VALUE=DATE:${_date(e.start)}');
        line('DTEND;VALUE=DATE:${_date(e.end)}');
      } else {
        line('DTSTART:${_utc(e.start)}');
        line('DTEND:${_utc(e.end)}');
      }
      line('SUMMARY:${_escape(e.title)}');
      if (e.description.isNotEmpty || e.transcript.isNotEmpty) {
        line(
          'DESCRIPTION:${_escape([e.description, if (e.description.isEmpty) e.transcript].join('\n'))}',
        );
      }
      if (e.location.isNotEmpty) line('LOCATION:${_escape(e.location)}');
      if (e.url.isNotEmpty) line('URL:${e.url}');
      if (!e.busy) line('TRANSP:TRANSPARENT');
      final rule = e.repeat;
      if (rule != null && master == null) {
        line('RRULE:${_rrule(rule, e)}');
        if (removed.isNotEmpty) {
          final dates = [
            for (final k in removed)
              e.allDay
                  ? _date(Calendar.parseDay(k))
                  : _utc(DateTime.fromMillisecondsSinceEpoch(int.parse(k))),
          ].join(',');
          line(e.allDay ? 'EXDATE;VALUE=DATE:$dates' : 'EXDATE:$dates');
        }
      }
      for (final minutes in e.reminders) {
        line('BEGIN:VALARM');
        line('ACTION:DISPLAY');
        line('DESCRIPTION:${_escape(e.title)}');
        line('TRIGGER:-PT${minutes}M');
        line('END:VALARM');
      }
      line('END:VEVENT');
    }

    final overridesBy = <String, List<CalEvent>>{};
    for (final o in overrides) {
      (overridesBy['${o.calendar}|${o.series}'] ??= []).add(o);
    }
    for (final e in events) {
      final mine = overridesBy['${e.calendar}|${e.entry}'] ?? const <CalEvent>[];
      event(
        e,
        removed: [
          for (final o in mine)
            if (o.deleted) o.instance!,
        ],
      );
      for (final o in mine) {
        if (!o.deleted) event(o, master: e);
      }
    }
    line('END:VCALENDAR');
    return out.toString();
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
  static String _date(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}${_two(t.month)}${_two(t.day)}';
  static String _utc(DateTime t) {
    final u = t.toUtc();
    return '${_date(u)}T${_two(u.hour)}${_two(u.minute)}${_two(u.second)}Z';
  }

  static String _escape(String text) => text
      .replaceAll('\\', '\\\\')
      .replaceAll(';', '\\;')
      .replaceAll(',', '\\,')
      .replaceAll('\r\n', '\n')
      .replaceAll('\n', '\\n');

  static const _byDay = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];

  static String _rrule(Repeat r, CalEvent e) {
    final parts = ['FREQ=${r.freq.toUpperCase()}'];
    if (r.interval != 1) parts.add('INTERVAL=${r.interval}');
    if (r.freq == 'weekly' && r.days.isNotEmpty) {
      parts.add('BYDAY=${([...r.days]..sort()).map((d) => _byDay[d - 1]).join(',')}');
    }
    if (r.freq == 'monthly' && r.monthly != 'day') {
      final start = e.start;
      final nth = r.monthly == 'last' || ((start.day - 1) ~/ 7) + 1 >= 5
          ? -1
          : ((start.day - 1) ~/ 7) + 1;
      parts.add('BYDAY=$nth${_byDay[start.weekday - 1]}');
    }
    if (r.count != null) parts.add('COUNT=${r.count}');
    if (r.until != null) {
      parts.add(
        'UNTIL=${_utc(DateTime.fromMillisecondsSinceEpoch(r.until!))}',
      );
    }
    return parts.join(';');
  }

  // ---- reading -----------------------------------------------------------

  static const maxEvents = 5000;

  static IcsImport read(String text) {
    final result = IcsImport();
    final lines = _unfold(text);
    final byUid = <String, IcsEvent>{};
    final pendingOverrides = <(String, DateTime, EventDraft)>[];
    var i = 0;
    while (i < lines.length) {
      if (lines[i].toUpperCase() != 'BEGIN:VEVENT') {
        i++;
        continue;
      }
      final props = <(String, Map<String, String>, String)>[];
      final alarms = <int>[];
      i++;
      var inAlarm = false;
      while (i < lines.length && lines[i].toUpperCase() != 'END:VEVENT') {
        final upper = lines[i].toUpperCase();
        if (upper == 'BEGIN:VALARM') {
          inAlarm = true;
        } else if (upper == 'END:VALARM') {
          inAlarm = false;
        } else if (inAlarm) {
          final p = _property(lines[i]);
          if (p != null && p.$1 == 'TRIGGER') {
            final minutes = _triggerMinutes(p.$3);
            if (minutes != null) alarms.add(minutes);
          }
        } else {
          final p = _property(lines[i]);
          if (p != null) props.add(p);
        }
        i++;
      }
      i++;
      if (result.events.length + pendingOverrides.length >= maxEvents) {
        result.problems.add('Stopped after $maxEvents events.');
        break;
      }
      _event(result, props, alarms, byUid, pendingOverrides);
    }
    for (final (uid, original, draft) in pendingOverrides) {
      final master = byUid[uid];
      if (master == null) {
        // A changed occurrence whose series is not in the file stands alone.
        result.events.add(IcsEvent(uid, draft..repeat = null));
      } else {
        master.overrides.add((original, draft..repeat = null));
      }
    }
    return result;
  }

  static List<String> _unfold(String text) {
    final raw = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
    final lines = <String>[];
    for (final line in raw) {
      if ((line.startsWith(' ') || line.startsWith('\t')) && lines.isNotEmpty) {
        lines[lines.length - 1] += line.substring(1);
      } else if (line.isNotEmpty) {
        lines.add(line);
      }
    }
    return lines;
  }

  /// Name, parameters and value of a content line.
  static (String, Map<String, String>, String)? _property(String line) {
    var inQuote = false;
    var colon = -1;
    for (var k = 0; k < line.length; k++) {
      final c = line[k];
      if (c == '"') inQuote = !inQuote;
      if (c == ':' && !inQuote) {
        colon = k;
        break;
      }
    }
    if (colon < 1) return null;
    final head = line.substring(0, colon).split(';');
    final params = <String, String>{};
    for (final p in head.skip(1)) {
      final eq = p.indexOf('=');
      if (eq > 0) {
        params[p.substring(0, eq).toUpperCase()] = p.substring(eq + 1).replaceAll('"', '');
      }
    }
    return (head.first.toUpperCase(), params, line.substring(colon + 1));
  }

  static String _unescape(String v) {
    final out = StringBuffer();
    for (var k = 0; k < v.length; k++) {
      final c = v[k];
      if (c == '\\' && k + 1 < v.length) {
        final n = v[++k];
        out.write(n == 'n' || n == 'N' ? '\n' : n);
      } else {
        out.write(c);
      }
    }
    return out.toString();
  }

  /// A value as a time: whether it was a bare date, and the moment. Times
  /// with a zone name are taken as the reader's own local time, as the
  /// zone's rules are not known here.
  static (bool, DateTime)? _time(String value) {
    final m = RegExp(r'^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})?(Z)?)?$')
        .firstMatch(value.trim());
    if (m == null) return null;
    final y = int.parse(m.group(1)!), mo = int.parse(m.group(2)!), d = int.parse(m.group(3)!);
    if (m.group(4) == null) return (true, DateTime(y, mo, d));
    final h = int.parse(m.group(4)!), mi = int.parse(m.group(5)!);
    final s = int.tryParse(m.group(6) ?? '') ?? 0;
    return (
      false,
      m.group(7) == null
          ? DateTime(y, mo, d, h, mi, s)
          : DateTime.utc(y, mo, d, h, mi, s).toLocal(),
    );
  }

  static int? _triggerMinutes(String v) {
    final m = RegExp(r'^(-)?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$')
        .firstMatch(v.trim());
    if (m == null || m.group(1) == null) return null;
    final minutes =
        (int.tryParse(m.group(2) ?? '') ?? 0) * 7 * 1440 +
        (int.tryParse(m.group(3) ?? '') ?? 0) * 1440 +
        (int.tryParse(m.group(4) ?? '') ?? 0) * 60 +
        (int.tryParse(m.group(5) ?? '') ?? 0);
    return minutes <= 40320 * 4 ? minutes : null;
  }

  static void _event(
    IcsImport result,
    List<(String, Map<String, String>, String)> props,
    List<int> alarms,
    Map<String, IcsEvent> byUid,
    List<(String, DateTime, EventDraft)> pendingOverrides,
  ) {
    String? value(String name) =>
        props.where((p) => p.$1 == name).firstOrNull?.$3;
    final title = _unescape(value('SUMMARY') ?? '');
    final start = value('DTSTART') == null ? null : _time(value('DTSTART')!);
    if (start == null) {
      result.problems.add('Skipped "${title.isEmpty ? 'untitled' : title}": no start.');
      return;
    }
    final allDay = start.$1;
    final end = value('DTEND') == null ? null : _time(value('DTEND')!);
    DateTime endAt;
    if (end != null) {
      endAt = end.$2;
    } else if (value('DURATION') != null) {
      final minutes = _triggerMinutes('-${value('DURATION')!.replaceFirst('+', '')}');
      endAt = start.$2.add(Duration(minutes: minutes ?? (allDay ? 1440 : 60)));
    } else {
      endAt = allDay ? DateTime(start.$2.year, start.$2.month, start.$2.day + 1) : start.$2;
    }
    if (endAt.isBefore(start.$2)) endAt = start.$2;
    if (allDay && !endAt.isAfter(start.$2)) {
      endAt = DateTime(start.$2.year, start.$2.month, start.$2.day + 1);
    }
    Repeat? repeat;
    final rrule = value('RRULE');
    if (rrule != null) {
      repeat = _repeat(rrule, start.$2, result, title);
    }
    final draft = EventDraft(
      title: title,
      description: _unescape(value('DESCRIPTION') ?? ''),
      location: _unescape(value('LOCATION') ?? ''),
      url: value('URL') ?? '',
      allDay: allDay,
      start: start.$2,
      end: endAt,
      repeat: repeat,
      reminders: alarms.toSet().take(Calendar.maxReminders).toList(),
      busy: value('TRANSP')?.toUpperCase() != 'TRANSPARENT',
    );
    final uid = value('UID') ?? '${title.hashCode}-${start.$2.millisecondsSinceEpoch}';
    final recurrence = value('RECURRENCE-ID') == null ? null : _time(value('RECURRENCE-ID')!);
    if (recurrence != null) {
      pendingOverrides.add((uid, recurrence.$2, draft));
      return;
    }
    final event = IcsEvent(uid, draft);
    for (final p in props.where((p) => p.$1 == 'EXDATE')) {
      for (final part in p.$3.split(',')) {
        final t = _time(part);
        if (t != null) event.exdates.add(t.$2);
      }
    }
    byUid[uid] = event;
    result.events.add(event);
  }

  static Repeat? _repeat(String rule, DateTime start, IcsImport result, String title) {
    final parts = {
      for (final p in rule.split(';'))
        if (p.contains('='))
          p.substring(0, p.indexOf('=')).toUpperCase(): p.substring(p.indexOf('=') + 1),
    };
    final freq = parts['FREQ']?.toLowerCase();
    if (freq == null || !Repeat.frequencies.contains(freq)) {
      result.problems.add('"$title" repeats in a way OurNet cannot keep; imported once.');
      return null;
    }
    const unsupported = [
      'BYSETPOS',
      'BYWEEKNO',
      'BYYEARDAY',
      'BYHOUR',
      'BYMINUTE',
      'BYSECOND',
    ];
    if (unsupported.any(parts.containsKey) ||
        (parts['BYMONTH'] != null &&
            !(freq == 'yearly' && parts['BYMONTH'] == '${start.month}'))) {
      result.problems.add('"$title" repeats in a way OurNet cannot keep; imported once.');
      return null;
    }
    final interval = int.tryParse(parts['INTERVAL'] ?? '') ?? 1;
    final days = <int>[];
    var monthly = 'day';
    final byDay = parts['BYDAY'];
    if (byDay != null) {
      for (final d in byDay.split(',')) {
        final m = RegExp(r'^([+-]?\d{1,2})?(MO|TU|WE|TH|FR|SA|SU)$').firstMatch(d.trim().toUpperCase());
        if (m == null) continue;
        final weekday = _byDay.indexOf(m.group(2)!) + 1;
        if (freq == 'weekly') {
          days.add(weekday);
        } else if (freq == 'monthly' && m.group(1) != null) {
          monthly = int.parse(m.group(1)!) < 0 ? 'last' : 'weekday';
        }
      }
    }
    if (freq == 'monthly' && parts['BYMONTHDAY'] != null && parts['BYMONTHDAY'] != '${start.day}') {
      result.problems.add('"$title" repeats on a different day each month; imported once.');
      return null;
    }
    int? until;
    if (parts['UNTIL'] != null) {
      final t = _time(parts['UNTIL']!);
      if (t != null) {
        until = t.$1
            ? DateTime(t.$2.year, t.$2.month, t.$2.day, 23, 59, 59).millisecondsSinceEpoch
            : t.$2.millisecondsSinceEpoch;
      }
    }
    final count = int.tryParse(parts['COUNT'] ?? '');
    final candidate = {
      'freq': freq,
      'interval': interval,
      if (days.isNotEmpty) 'days': days,
      'monthly': monthly,
      'until': ?until,
      if (count != null) 'count': count > Repeat.maxCount ? Repeat.maxCount : count,
    };
    if (!Repeat.valid(candidate)) {
      result.problems.add('"$title" repeats in a way OurNet cannot keep; imported once.');
      return null;
    }
    // Weekly on the start's own weekday is the plain rule.
    final parsed = Repeat.fromJson(candidate)!;
    return freq == 'weekly' && days.length == 1 && days.first == start.weekday
        ? parsed.copyWith(days: const [])
        : parsed;
  }
}
