import 'package:test/test.dart';
import 'package:ournet_core/ournet_core.dart';


void main() {
  // A Friday morning.
  final now = DateTime(2026, 10, 2, 10);
  QuickEvent? q(String text) => QuickAdd.parse(text, now: now);
  String show(QuickEvent e) =>
      '${e.title}|${e.start.toString().substring(0, 16)}|${e.end.toString().substring(0, 16)}${e.allDay ? '|all-day' : ''}';

  test('plain text has nothing to add', () {
    expect(q('Dentist'), isNull);
    expect(q('Read chapter 3'), isNull);
  });

  test('a time alone means the next time it comes round', () {
    expect(show(q('Call mum at 3pm')!), 'Call mum|2026-10-02 15:00|2026-10-02 16:00');
    expect(show(q('Breakfast 8am')!), 'Breakfast|2026-10-03 08:00|2026-10-03 09:00');
    expect(show(q('Gym 17:30')!), 'Gym|2026-10-02 17:30|2026-10-02 18:30');
    expect(show(q('Lunch at noon')!), 'Lunch|2026-10-02 12:00|2026-10-02 13:00');
  });

  test('days of the week and relative days', () {
    expect(show(q('Lunch with Sam tomorrow 1pm')!), 'Lunch with Sam|2026-10-03 13:00|2026-10-03 14:00');
    expect(show(q('Pottery on Tuesday at 6pm')!), 'Pottery|2026-10-06 18:00|2026-10-06 19:00');
    expect(show(q('Standup next monday 9:30am')!), 'Standup|2026-10-05 09:30|2026-10-05 10:30');
    expect(show(q('Dinner tonight')!), 'Dinner|2026-10-02 19:00|2026-10-02 20:00');
    expect(show(q('Report in 3 days')!), 'Report|2026-10-05 00:00|2026-10-06 00:00|all-day');
    expect(show(q('Call in 2 hours')!), 'Call|2026-10-02 12:00|2026-10-02 13:00');
  });

  test('dates', () {
    expect(show(q('Birthday party oct 17')!), 'Birthday party|2026-10-17 00:00|2026-10-18 00:00|all-day');
    expect(show(q('Flight 3rd of march 7am')!), 'Flight|2027-03-03 07:00|2027-03-03 08:00');
    expect(show(q('Exam 2026-11-04 9am')!), 'Exam|2026-11-04 09:00|2026-11-04 10:00');
    expect(show(q('Concert on December 12, 2026 at 8pm')!), 'Concert|2026-12-12 20:00|2026-12-12 21:00');
  });

  test('ranges and lengths', () {
    expect(show(q('Workshop tomorrow 3-4pm')!), 'Workshop|2026-10-03 15:00|2026-10-03 16:00');
    expect(show(q('Brunch saturday from 11am to 1pm')!), 'Brunch|2026-10-03 11:00|2026-10-03 13:00');
    expect(show(q('Brunch saturday 11-1pm')!), 'Brunch|2026-10-03 11:00|2026-10-03 13:00');
    expect(show(q('Study tomorrow 2pm for 2 hours')!), 'Study|2026-10-03 14:00|2026-10-03 16:00');
    expect(show(q('Check-in monday 9am for 15 min')!), 'Check-in|2026-10-05 09:00|2026-10-05 09:15');
  });

  test('repeats', () {
    final e = q('Standup every weekday 9am')!;
    expect(e.repeat!.toJson(), {'freq': 'weekly', 'days': [1, 2, 3, 4, 5]});
    expect(e.title, 'Standup');
    expect(e.start.hour, 9);
    final w = q('Pottery every tuesday and thursday at 6pm')!;
    expect(w.repeat!.days, [2, 4]);
    expect(w.start, DateTime(2026, 10, 6, 18));
    expect(q('Rent monthly oct 28')!.repeat!.freq, 'monthly');
    expect(q('Water plants every 2 weeks saturday')!.repeat!.interval, 2);
    expect(q('Stretch every day 7am')!.repeat!.freq, 'daily');
  });

  test('numbers that are not times stay in the title', () {
    expect(q('Chapter 1-2 review'), isNull);
    expect(show(q('Room 101 tomorrow')!), 'Room 101|2026-10-03 00:00|2026-10-04 00:00|all-day');
  });
}
