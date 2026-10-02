/// How an event repeats, and the dates it falls on.
///
/// A rule is stored in an event as a small map (see [Repeat.toJson]) and is
/// expanded here into wall-clock times: "every Monday at 9" stays at 9 across
/// daylight saving changes. Nothing is stored per occurrence, so a series of
/// any length costs one record.
class Repeat {
  static const frequencies = ['daily', 'weekly', 'monthly', 'yearly'];

  final String freq;
  final int interval;

  /// Weekly: the weekdays (Monday 1 to Sunday 7) it falls on. Empty means
  /// the weekday of the first occurrence.
  final List<int> days;

  /// Monthly: 'day' repeats on the date of the first occurrence, 'weekday' on
  /// the same numbered weekday ("the second Tuesday") and 'last' on the last
  /// such weekday of the month.
  final String monthly;

  /// The last moment (milliseconds since the epoch, inclusive) at which an
  /// occurrence may start, or null for no end.
  final int? until;

  /// The number of occurrences, the first included, or null for no limit.
  final int? count;

  const Repeat(
    this.freq, {
    this.interval = 1,
    this.days = const [],
    this.monthly = 'day',
    this.until,
    this.count,
  });

  static const maxCount = 1000;
  static const maxInterval = 999;

  static Repeat? fromJson(Object? json) {
    if (json is! Map || !valid(json)) return null;
    return Repeat(
      json['freq'] as String,
      interval: json['interval'] as int? ?? 1,
      days: [...?(json['days'] as List?)?.cast<int>()],
      monthly: json['monthly'] as String? ?? 'day',
      until: json['until'] as int?,
      count: json['count'] as int?,
    );
  }

  /// Whether [json] is a rule this build can expand.
  static bool valid(Map json) =>
      frequencies.contains(json['freq']) &&
      (json['interval'] == null ||
          json['interval'] is int &&
              json['interval'] >= 1 &&
              json['interval'] <= maxInterval) &&
      (json['days'] == null ||
          json['days'] is List &&
              (json['days'] as List).length <= 7 &&
              (json['days'] as List).every((d) => d is int && d >= 1 && d <= 7)) &&
      (json['monthly'] == null || ['day', 'weekday', 'last'].contains(json['monthly'])) &&
      (json['until'] == null ||
          json['until'] is int && json['until'] >= 0 && json['until'] < 253402300799999) &&
      (json['count'] == null ||
          json['count'] is int && json['count'] >= 1 && json['count'] <= maxCount);

  Map<String, dynamic> toJson() => {
    'freq': freq,
    if (interval != 1) 'interval': interval,
    if (days.isNotEmpty) 'days': days,
    if (monthly != 'day') 'monthly': monthly,
    'until': ?until,
    'count': ?count,
  };

  Repeat copyWith({
    String? freq,
    int? interval,
    List<int>? days,
    String? monthly,
    int? Function()? until,
    int? Function()? count,
  }) => Repeat(
    freq ?? this.freq,
    interval: interval ?? this.interval,
    days: days ?? this.days,
    monthly: monthly ?? this.monthly,
    until: until == null ? this.until : until(),
    count: count == null ? this.count : count(),
  );

  /// The occurrences in order, as wall-clock times, beginning with [first].
  ///
  /// With [from], occurrences that end the period before it may be skipped
  /// (a series that has run for years is not walked from its start), except
  /// where a [count] makes the number of earlier ones matter. Always lazy:
  /// the caller stops reading at the end of what it shows.
  Iterable<DateTime> occurrences(DateTime first, {DateTime? from}) sync* {
    final end = until == null ? null : DateTime.fromMillisecondsSinceEpoch(until!);
    var produced = 0;
    final skip = count == null && from != null;
    var guard = 0;
    for (final date in _walk(first, skip ? from : null)) {
      if (++guard > 200000) return;
      if (date.isBefore(first)) continue;
      if (end != null && date.isAfter(end)) return;
      if (count != null && produced >= count!) return;
      produced++;
      yield date;
    }
  }

  Iterable<DateTime> _walk(DateTime first, DateTime? from) sync* {
    final n = interval;
    switch (freq) {
      case 'daily':
        var k = 0;
        if (from != null) {
          final days = _dayNumber(from) - _dayNumber(first);
          k = days > 2 * n ? days ~/ n - 1 : 0;
        }
        while (true) {
          yield _at(first, first.year, first.month, first.day + k * n);
          k++;
        }
      case 'weekly':
        final picked = days.isEmpty ? [first.weekday] : ([...days]..sort());
        // Weeks run Monday to Sunday, counted from the first occurrence's.
        final start = first.day - (first.weekday - 1);
        var k = 0;
        if (from != null) {
          final weeks = (_dayNumber(from) - _dayNumber(first)) ~/ 7;
          k = weeks > 2 * n ? weeks ~/ n - 1 : 0;
        }
        while (true) {
          for (final d in picked) {
            yield _at(first, first.year, first.month, start + k * n * 7 + d - 1);
          }
          k++;
        }
      case 'monthly':
        var k = 0;
        if (from != null) {
          final months =
              (from.year - first.year) * 12 + from.month - first.month;
          k = months > 2 * n ? months ~/ n - 1 : 0;
        }
        final nth = ((first.day - 1) ~/ 7) + 1;
        // A fifth weekday can only mean "the last one", as calendars do.
        final ordinal = monthly == 'last' || nth >= 5 ? -1 : nth;
        while (true) {
          final index = first.month - 1 + k * n;
          final year = first.year + index ~/ 12;
          final month = index % 12 + 1;
          if (monthly != 'day') {
            final day = _nthWeekday(year, month, first.weekday, ordinal);
            if (day != null) yield _at(first, year, month, day);
          } else if (first.day <= _daysIn(year, month)) {
            yield _at(first, year, month, first.day);
          }
          k++;
        }
      default:
        var k = 0;
        if (from != null) {
          final years = from.year - first.year;
          k = years > 2 * n ? years ~/ n - 1 : 0;
        }
        while (true) {
          final year = first.year + k * n;
          if (first.day <= _daysIn(year, first.month)) {
            yield _at(first, year, first.month, first.day);
          }
          k++;
        }
    }
  }

  static DateTime _at(DateTime time, int year, int month, int day) =>
      DateTime(year, month, day, time.hour, time.minute, time.second);

  /// Whole days since a fixed date, with no daylight saving drift.
  static int _dayNumber(DateTime t) =>
      DateTime.utc(t.year, t.month, t.day).millisecondsSinceEpoch ~/ 86400000;

  static int _daysIn(int year, int month) =>
      DateTime.utc(year, month + 1, 0).day;

  /// The date of the [ordinal]th [weekday] of a month, or the last for -1.
  static int? _nthWeekday(int year, int month, int weekday, int ordinal) {
    if (ordinal == -1) {
      final last = DateTime.utc(year, month + 1, 0);
      return last.day - (last.weekday - weekday + 7) % 7;
    }
    final firstDay = DateTime.utc(year, month, 1);
    final day = 1 + (weekday - firstDay.weekday + 7) % 7 + (ordinal - 1) * 7;
    return day <= _daysIn(year, month) ? day : null;
  }

  /// A short description such as "Every 2 weeks on Mon, Wed".
  String describe() {
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final every = interval == 1
        ? switch (freq) {
            'daily' => 'Daily',
            'weekly' => 'Weekly',
            'monthly' => 'Monthly',
            _ => 'Annually',
          }
        : 'Every $interval ${switch (freq) {
            'daily' => 'days',
            'weekly' => 'weeks',
            'monthly' => 'months',
            _ => 'years',
          }}';
    final on = freq == 'weekly' && days.isNotEmpty
        ? ' on ${([...days]..sort()).map((d) => names[d - 1]).join(', ')}'
        : '';
    final end = count != null
        ? ', $count times'
        : until != null
        ? ', until ${_date(DateTime.fromMillisecondsSinceEpoch(until!))}'
        : '';
    return '$every$on$end';
  }

  static String _date(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
}
