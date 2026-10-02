import 'package:test/test.dart';
import 'package:ournet_core/ournet_core.dart';

Calendar calendarOf(Node n) => Calendar(n, NoteState(n));

EventDraft draft(
  String title,
  DateTime start, {
  Duration length = const Duration(hours: 1),
  Repeat? repeat,
  bool allDay = false,
}) => EventDraft(
  title: title,
  start: start,
  end: allDay
      ? DateTime(start.year, start.month, start.day + 1)
      : start.add(length),
  allDay: allDay,
  repeat: repeat,
);

Future<List<Node>> friends(int n) async {
  final nodes = [
    for (var i = 0; i < n; i++) Node(await LocalIdentity.create(), Store()),
  ];
  for (final x in nodes) {
    for (final y in nodes) {
      if (x != y) await x.addContact(y.identity.certificate);
    }
    addTearDown(x.close);
  }
  return nodes;
}

List<String> titles(Iterable<Occurrence> o) => [for (final x in o) x.event.title];

String day(DateTime t) => Calendar.formatDay(t);

void main() {
  group('recurrence', () {
    final monday = DateTime(2026, 10, 5, 9);
    List<String> days(Repeat r, {DateTime? first, int take = 5, DateTime? from}) => [
      for (final d in r.occurrences(first ?? monday, from: from).take(take))
        '${d.year}-${d.month}-${d.day} ${d.hour}:${d.minute}',
    ];

    test('daily with an interval', () {
      expect(days(const Repeat('daily', interval: 3), take: 3), [
        '2026-10-5 9:0',
        '2026-10-8 9:0',
        '2026-10-11 9:0',
      ]);
    });

    test('weekly on chosen days, from the first occurrence on', () {
      expect(
        days(const Repeat('weekly', days: [1, 3, 5]), first: DateTime(2026, 10, 7, 9), take: 4),
        ['2026-10-7 9:0', '2026-10-9 9:0', '2026-10-12 9:0', '2026-10-14 9:0'],
      );
    });

    test('every other week uses weeks counted from the first', () {
      expect(
        days(const Repeat('weekly', interval: 2, days: [1, 2]), take: 4),
        ['2026-10-5 9:0', '2026-10-6 9:0', '2026-10-19 9:0', '2026-10-20 9:0'],
      );
    });

    test('monthly by date skips months without it', () {
      expect(
        days(const Repeat('monthly'), first: DateTime(2026, 1, 31, 9), take: 4),
        ['2026-1-31 9:0', '2026-3-31 9:0', '2026-5-31 9:0', '2026-7-31 9:0'],
      );
    });

    test('monthly by weekday: second Tuesday, fourth, and the last', () {
      expect(
        days(
          const Repeat('monthly', monthly: 'weekday'),
          first: DateTime(2026, 10, 13, 9),
          take: 3,
        ),
        ['2026-10-13 9:0', '2026-11-10 9:0', '2026-12-8 9:0'],
      );
      expect(
        days(
          const Repeat('monthly', monthly: 'weekday'),
          first: DateTime(2026, 10, 27, 9),
          take: 3,
        ),
        ['2026-10-27 9:0', '2026-11-24 9:0', '2026-12-22 9:0'],
      );
      expect(
        days(
          const Repeat('monthly', monthly: 'last'),
          first: DateTime(2026, 10, 27, 9),
          take: 3,
        ),
        ['2026-10-27 9:0', '2026-11-24 9:0', '2026-12-29 9:0'],
      );
    });

    test('yearly on 29 February only happens in leap years', () {
      expect(
        days(const Repeat('yearly'), first: DateTime(2024, 2, 29, 9), take: 3),
        ['2024-2-29 9:0', '2028-2-29 9:0', '2032-2-29 9:0'],
      );
    });

    test('count and until end a series', () {
      expect(days(const Repeat('daily', count: 3), take: 10), hasLength(3));
      final until = DateTime(2026, 10, 7, 9).millisecondsSinceEpoch;
      expect(days(Repeat('daily', until: until), take: 10), hasLength(3));
    });

    test('skipping ahead gives the same occurrences as walking', () {
      for (final rule in [
        const Repeat('daily', interval: 3),
        const Repeat('weekly', interval: 2, days: [2, 4]),
        const Repeat('monthly', interval: 2),
        const Repeat('monthly', monthly: 'weekday'),
        const Repeat('yearly'),
      ]) {
        final from = DateTime(2031, 3, 14);
        final walked = rule
            .occurrences(monday)
            .skipWhile((d) => d.isBefore(from))
            .take(6)
            .toList();
        final skipped = rule
            .occurrences(monday, from: from)
            .skipWhile((d) => d.isBefore(from))
            .take(6)
            .toList();
        expect(skipped, walked, reason: rule.describe());
      }
    });

    test('rules round-trip and bad ones are refused', () {
      const rule = Repeat('weekly', interval: 2, days: [1, 5], count: 6);
      expect(Repeat.fromJson(rule.toJson())!.toJson(), rule.toJson());
      expect(Repeat.fromJson({'freq': 'hourly'}), isNull);
      expect(Repeat.fromJson({'freq': 'daily', 'interval': 0}), isNull);
      expect(Repeat.fromJson({'freq': 'weekly', 'days': [9]}), isNull);
    });
  });

  group('personal calendar', () {
    test('create, find by range, edit, delete and undo', () async {
      final n = (await friends(1)).single;
      final cal = calendarOf(n);
      final start = DateTime(2026, 10, 12, 14);
      final made = await cal.create(Calendar.personal, draft('Dentist', start));
      var found = cal.between(DateTime(2026, 10, 12), DateTime(2026, 10, 13));
      expect(titles(found), ['Dentist']);
      expect(cal.between(DateTime(2026, 10, 13), DateTime(2026, 10, 14)), isEmpty);

      final edited = EventDraft.of(found.single)..title = 'Dentist (moved)';
      final change = await cal.update(found.single, edited);
      expect(change.entry, made.entry);
      found = cal.between(DateTime(2026, 10, 12), DateTime(2026, 10, 13));
      expect(titles(found), ['Dentist (moved)']);

      await cal.undo(change);
      expect(titles(cal.between(DateTime(2026, 10, 12), DateTime(2026, 10, 13))), [
        'Dentist',
      ]);

      final gone = await cal.delete(
        cal.between(DateTime(2026, 10, 12), DateTime(2026, 10, 13)).single,
      );
      expect(cal.between(DateTime(2026, 10, 12), DateTime(2026, 10, 13)), isEmpty);
      await cal.undo(gone);
      expect(titles(cal.between(DateTime(2026, 10, 12), DateTime(2026, 10, 13))), [
        'Dentist',
      ]);
    });

    test('all-day and multi-day events show on every day they cover', () async {
      final n = (await friends(1)).single;
      final cal = calendarOf(n);
      await cal.create(
        Calendar.personal,
        EventDraft(
          title: 'Conference',
          allDay: true,
          start: DateTime(2026, 10, 14),
          end: DateTime(2026, 10, 17),
        ),
      );
      for (final d in [14, 15, 16]) {
        expect(
          titles(cal.between(DateTime(2026, 10, d), DateTime(2026, 10, d + 1))),
          ['Conference'],
          reason: 'day $d',
        );
      }
      expect(cal.between(DateTime(2026, 10, 17), DateTime(2026, 10, 18)), isEmpty);
      expect(cal.between(DateTime(2026, 10, 13), DateTime(2026, 10, 14)), isEmpty);
      expect(
        cal.between(DateTime(2026, 10, 14), DateTime(2026, 10, 17)).single.days.length,
        3,
      );
    });

    test('an event that crosses midnight appears on both days', () async {
      final n = (await friends(1)).single;
      final cal = calendarOf(n);
      await cal.create(
        Calendar.personal,
        draft('Night shift', DateTime(2026, 10, 12, 22), length: const Duration(hours: 8)),
      );
      expect(titles(cal.between(DateTime(2026, 10, 13), DateTime(2026, 10, 14))), [
        'Night shift',
      ]);
      // Ending exactly at midnight does not spill into the next day.
      await cal.create(
        Calendar.personal,
        draft('Evening', DateTime(2026, 10, 20, 20), length: const Duration(hours: 4)),
      );
      expect(cal.between(DateTime(2026, 10, 21), DateTime(2026, 10, 22)), isEmpty);
    });

    test('is private to this person, and shared with their other devices', () async {
      final owner = await LocalIdentity.create();
      final fresh = await LocalIdentity.create();
      final paired = await fresh.enrol(await owner.authorise(fresh.certificate));
      final a = Node(owner, Store()),
          b = Node(paired, Store()),
          friend = Node(await LocalIdentity.create(), Store());
      addTearDown(() async {
        await a.close();
        await b.close();
        await friend.close();
      });
      await a.addContact(paired.certificate);
      await b.addContact(owner.certificate);
      await a.addContact(friend.identity.certificate);
      await friend.addContact(owner.certificate);
      final ca = calendarOf(a), cb = calendarOf(b), cf = calendarOf(friend);
      await ca.create(Calendar.personal, draft('Secret', DateTime(2026, 10, 12, 9)));
      await syncPair(a, b);
      await syncPair(a, friend);
      await cb.refresh();
      await cf.refresh();
      final range = [DateTime(2026, 10, 12), DateTime(2026, 10, 13)];
      expect(titles(cb.between(range[0], range[1])), ['Secret']);
      expect(cf.between(range[0], range[1]), isEmpty);
      expect(friend.store.count, 0);

      // Concurrent edits on two devices settle on one version.
      final oa = ca.between(range[0], range[1]).single;
      final ob = cb.between(range[0], range[1]).single;
      await ca.update(oa, EventDraft.of(oa)..title = 'From a');
      await cb.update(ob, EventDraft.of(ob)..title = 'From b');
      await syncPair(a, b);
      await ca.refresh();
      await cb.refresh();
      expect(titles(ca.between(range[0], range[1])), hasLength(1));
      expect(
        titles(ca.between(range[0], range[1])),
        titles(cb.between(range[0], range[1])),
      );
    });

    test('a forged personal event from someone else is ignored', () async {
      final [a, b] = await friends(2);
      // b writes to a's personal space, encrypted to a.
      await b.publish(
        Calendar.eventKind,
        {
          'event': 'x',
          'clock': 1,
          'title': 'Forged',
          'start': DateTime(2026, 10, 12, 9).millisecondsSinceEpoch,
          'end': DateTime(2026, 10, 12, 10).millisecondsSinceEpoch,
        },
        space: Calendar.personal,
        audience: [a.person],
      );
      await syncPair(a, b);
      final cal = calendarOf(a);
      await cal.refresh();
      expect(cal.between(DateTime(2026, 10, 12), DateTime(2026, 10, 13)), isEmpty);
    });

    test('invalid events are refused', () async {
      final n = (await friends(1)).single;
      Future<void> bad(Map<String, dynamic> p) => expectLater(
        n.publish(Calendar.eventKind, p, space: Calendar.personal, audience: [n.person]),
        throwsA(isA<StateError>()),
      );
      await bad({'event': 'a', 'clock': 1, 'start': 10, 'end': 5});
      await bad({'event': 'a', 'clock': 1, 'allDay': true, 'day': 'tomorrow', 'days': 1});
      await bad({'event': 'a', 'clock': 1, 'start': 1, 'end': 2, 'repeat': {'freq': 'x'}});
      await bad({'event': 'a', 'clock': 1, 'start': 1, 'end': 2, 'series': 'a'});
      await bad({'clock': 1, 'start': 1, 'end': 2});
    });
  });

  group('repeating events', () {
    late Node n;
    late Calendar cal;
    final week = [DateTime(2026, 10, 5), DateTime(2026, 11, 2)];
    setUp(() async {
      n = (await friends(1)).single;
      cal = calendarOf(n);
      await cal.create(
        Calendar.personal,
        draft(
          'Standup',
          DateTime(2026, 10, 5, 9),
          repeat: const Repeat('daily', count: 10),
        ),
      );
    });

    List<Occurrence> all() => cal.between(week[0], week[1]);

    test('one entry yields each occurrence', () {
      expect(all(), hasLength(10));
      expect(all().first.start, DateTime(2026, 10, 5, 9));
      expect(all().last.start, DateTime(2026, 10, 14, 9));
      expect(all().every((o) => o.repeats), isTrue);
    });

    test('changing one occurrence leaves the rest', () async {
      final third = all()[2];
      await cal.update(
        third,
        EventDraft.of(third)
          ..title = 'Standup (long)'
          ..start = DateTime(2026, 10, 7, 11)
          ..end = DateTime(2026, 10, 7, 12),
        scope: Scope.one,
      );
      final now = all();
      expect(now, hasLength(10));
      expect(titles(now).where((t) => t == 'Standup (long)'), hasLength(1));
      expect(now.firstWhere((o) => o.event.title == 'Standup (long)').start, DateTime(2026, 10, 7, 11));
      expect(now.firstWhere((o) => o.event.title == 'Standup (long)').key, third.key);
    });

    test('deleting one occurrence hides only it', () async {
      await cal.delete(all()[3], scope: Scope.one);
      expect(all(), hasLength(9));
      expect(all().any((o) => o.start == DateTime(2026, 10, 8, 9)), isFalse);
    });

    test('this and following splits the series and keeps the count', () async {
      final fifth = all()[4];
      final change = await cal.update(
        fifth,
        EventDraft.of(fifth)..title = 'Daily sync',
        scope: Scope.following,
      );
      final now = all();
      expect(now, hasLength(10));
      expect(titles(now.take(4)), everyElement('Standup'));
      expect(titles(now.skip(4)), everyElement('Daily sync'));
      expect(now[4].entry, change.entry);
      expect(now[4].entry, isNot(now[3].entry));
      await cal.undo(change);
      expect(titles(all()), everyElement('Standup'));
      expect(all(), hasLength(10));
    });

    test('deleting this and following ends the series', () async {
      await cal.delete(all()[6], scope: Scope.following);
      expect(all(), hasLength(6));
    });

    test('editing all moves the whole series by the same amount', () async {
      final second = all()[1];
      await cal.update(
        second,
        EventDraft.of(second)
          ..start = DateTime(2026, 10, 6, 10)
          ..end = DateTime(2026, 10, 6, 11),
      );
      expect(all(), hasLength(10));
      expect(all().first.start, DateTime(2026, 10, 5, 10));
      expect(all().every((o) => o.start.hour == 10), isTrue);
    });

    test('deleting the series deletes its overrides too', () async {
      final third = all()[2];
      await cal.update(third, EventDraft.of(third)..title = 'Odd', scope: Scope.one);
      await cal.delete(all().first);
      expect(all(), isEmpty);
    });

    test('an occurrence found by key', () async {
      final fourth = all()[3];
      final found = cal.occurrence(Calendar.personal, fourth.entry, key: fourth.key);
      expect(found!.start, fourth.start);
      expect(cal.occurrence(Calendar.personal, fourth.entry, key: 'nope'), isNull);
      final next = cal.occurrence(
        Calendar.personal,
        fourth.entry,
        after: DateTime(2026, 10, 9, 12),
      );
      expect(next!.start, DateTime(2026, 10, 10, 9));
    });

    test('an open-ended series is only walked as far as it is shown', () async {
      await cal.create(
        Calendar.personal,
        draft('Forever', DateTime(2000, 1, 3, 9), repeat: const Repeat('weekly')),
      );
      final found = cal.between(DateTime(2031, 5, 1), DateTime(2031, 5, 31));
      expect(titles(found).where((t) => t == 'Forever'), hasLength(4));
    });

    test('moves between calendars with its overrides', () async {
      final [a, b] = await friends(2);
      final ea = Everyday(a);
      final room = await ea.createRoom('Team', [b.person]);
      final ca = calendarOf(a);
      await ca.create(Calendar.personal, draft('Run', DateTime(2026, 10, 5, 7), repeat: const Repeat('daily', count: 3)));
      var occ = ca.between(week[0], week[1]);
      await ca.update(occ[1], EventDraft.from(occ[1].event)..title = 'Run (slow)', scope: Scope.one);
      await ca.move(ca.between(week[0], week[1]).first.master, room.object.space);
      expect(ca.between(week[0], week[1], calendars: {Calendar.personal}), isEmpty);
      occ = ca.between(week[0], week[1], calendars: {room.object.space});
      expect(titles(occ), ['Run', 'Run (slow)', 'Run']);
    });
  });

  group('group calendars', () {
    test('are shared with members only, and show in the personal view', () async {
      final [a, b, outsider] = await friends(3);
      final room = await Everyday(a).createRoom('Climbing', [b.person]);
      final space = room.object.space;
      final ca = calendarOf(a), cb = calendarOf(b), co = calendarOf(outsider);
      await ca.create(space, draft('Wall night', DateTime(2026, 10, 12, 19)));
      await ca.create(Calendar.personal, draft('Mine', DateTime(2026, 10, 12, 8)));
      await syncPair(a, b);
      await syncPair(a, outsider);
      for (final c in [cb, co]) {
        await c.refresh();
      }
      final range = [DateTime(2026, 10, 12), DateTime(2026, 10, 13)];
      expect(titles(cb.between(range[0], range[1])), ['Wall night']);
      expect(co.between(range[0], range[1]), isEmpty);
      expect(titles(ca.between(range[0], range[1])), ['Mine', 'Wall night']);

      // Switching a group off hides it from the personal view only.
      await ca.setShown(space, false);
      expect(titles(ca.between(range[0], range[1])), ['Mine']);
      expect(titles(ca.between(range[0], range[1], calendars: {space})), ['Wall night']);
      expect(ca.shown(space), isFalse);
      await ca.setShown(space, true);
      expect(ca.shown(space), isTrue);

      // A member's edit reaches the owner.
      final theirs = cb.between(range[0], range[1]).single;
      await cb.update(theirs, EventDraft.of(theirs)..title = 'Wall night (bring chalk)');
      await syncPair(a, b);
      await ca.refresh();
      expect(titles(ca.between(range[0], range[1], calendars: {space})), [
        'Wall night (bring chalk)',
      ]);
    });

    test('answers to an event are counted per person and occurrence', () async {
      final [a, b] = await friends(2);
      final room = await Everyday(a).createRoom('Climbing', [b.person]);
      final space = room.object.space;
      final ca = calendarOf(a), cb = calendarOf(b);
      final made = await ca.create(
        space,
        draft('Wall night', DateTime(2026, 10, 12, 19), repeat: const Repeat('weekly', count: 3)),
      );
      await syncPair(a, b);
      await cb.refresh();
      await ca.respond(space, made.entry!, Rsvp.yes);
      await cb.respond(space, made.entry!, Rsvp.maybe);
      await cb.respond(space, made.entry!, Rsvp.no, key: '${DateTime(2026, 10, 19, 19).millisecondsSinceEpoch}');
      await syncPair(a, b);
      await ca.refresh();
      final first = '${DateTime(2026, 10, 12, 19).millisecondsSinceEpoch}';
      final second = '${DateTime(2026, 10, 19, 19).millisecondsSinceEpoch}';
      expect(ca.rsvps(space, made.entry!, first), {a.person: Rsvp.yes, b.person: Rsvp.maybe});
      expect(ca.rsvps(space, made.entry!, second), {a.person: Rsvp.yes, b.person: Rsvp.no});
      await cb.respond(space, made.entry!, null);
      await syncPair(a, b);
      await ca.refresh();
      expect(ca.rsvps(space, made.entry!, first), {a.person: Rsvp.yes});
    });

    test('people who join later get the calendar when history is shared', () async {
      final [a, b, c] = await friends(3);
      final ea = Everyday(a);
      var room = await ea.createRoom('Trip', [b.person]);
      final space = room.object.space;
      final ca = calendarOf(a), cc = calendarOf(c);
      await ca.create(space, draft('Flights', DateTime(2026, 10, 12, 6)));
      await syncPair(a, b);
      room = await ea.changeMembers(room, [b.person, c.person], shareHistory: true);
      await syncPair(a, b);
      await syncPair(a, c);
      await cc.refresh();
      final range = [DateTime(2026, 10, 12), DateTime(2026, 10, 13)];
      expect(titles(cc.between(range[0], range[1])), ['Flights']);
      expect(cc.event(space, cc.between(range[0], range[1]).single.entry)!.author, a.person);
    });

    test('without shared history a newcomer sees only what comes next', () async {
      final [a, b, c] = await friends(3);
      final ea = Everyday(a);
      var room = await ea.createRoom('Trip', [b.person]);
      final space = room.object.space;
      final ca = calendarOf(a), cc = calendarOf(c);
      await ca.create(space, draft('Old', DateTime(2026, 10, 12, 6)));
      room = await ea.changeMembers(room, [b.person, c.person], shareHistory: false);
      await ca.create(space, draft('New', DateTime(2026, 10, 12, 7)));
      await syncPair(a, c);
      await cc.refresh();
      expect(titles(cc.between(DateTime(2026, 10, 12), DateTime(2026, 10, 13))), ['New']);
    });

    test('a removed member leaves their events behind', () async {
      final [a, b] = await friends(2);
      final ea = Everyday(a);
      var room = await ea.createRoom('Club', [b.person]);
      final space = room.object.space;
      final ca = calendarOf(a), cb = calendarOf(b);
      await syncPair(a, b);
      await cb.refresh();
      await cb.create(space, draft('Bob\'s quiz', DateTime(2026, 10, 12, 19)));
      await syncPair(a, b);
      await ca.refresh();
      expect(titles(ca.between(DateTime(2026, 10, 12), DateTime(2026, 10, 13))), ['Bob\'s quiz']);
      room = await ea.changeMembers(room, const [], shareHistory: false);
      await ca.refresh();
      expect(titles(ca.between(DateTime(2026, 10, 12), DateTime(2026, 10, 13))), ['Bob\'s quiz']);
    });

    test('a non-member cannot write into a group calendar', () async {
      final [a, b, outsider] = await friends(3);
      final room = await Everyday(a).createRoom('Club', [b.person]);
      final space = room.object.space;
      await outsider.publish(
        Calendar.eventKind,
        {
          'event': 'bad',
          'clock': 5,
          'title': 'Spam',
          'start': DateTime(2026, 10, 12, 9).millisecondsSinceEpoch,
          'end': DateTime(2026, 10, 12, 10).millisecondsSinceEpoch,
        },
        space: space,
        audience: [a.person],
      );
      await syncPair(a, outsider);
      final ca = calendarOf(a);
      await ca.refresh();
      expect(ca.between(DateTime(2026, 10, 12), DateTime(2026, 10, 13)), isEmpty);
    });
  });

  group('voice notes', () {
    final audio = {
      'chunks': ['a' * 64],
      'chunkBytes': 131072,
      'size': 1000,
      'name': 'Voice note.m4a',
      'key': 'abcd',
      'audio': {'mime': 'audio/mp4', 'duration': 4000},
      'transcript': 'Pick up the cake',
    };

    test('stay with the event through edits and go when removed', () async {
      final n = (await friends(1)).single;
      final cal = calendarOf(n);
      final start = DateTime(2026, 10, 12, 9);
      await cal.create(Calendar.personal, draft('Cake', start)..carry.addAll(audio));
      var o = cal.between(DateTime(2026, 10, 12), DateTime(2026, 10, 13)).single;
      expect(o.event.hasAudio, isTrue);
      expect(o.event.transcript, 'Pick up the cake');
      // Editing the title keeps it.
      await cal.update(o, EventDraft.of(o)..title = 'Cake pickup');
      o = cal.between(DateTime(2026, 10, 12), DateTime(2026, 10, 13)).single;
      expect(o.event.hasAudio, isTrue);
      expect(o.event.title, 'Cake pickup');
      // Removing it from the form removes it from the event.
      await cal.update(o, EventDraft.of(o)..carry.clear());
      o = cal.between(DateTime(2026, 10, 12), DateTime(2026, 10, 13)).single;
      expect(o.event.hasAudio, isFalse);
      expect(o.event.data.containsKey('chunks'), isFalse);
    });
  });

  group('links and search', () {
    test('event links round-trip, with awkward calendar IDs', () {
      const calendar = 'room2:abc123:def/456';
      final link = Calendar.link(calendar, 'e1', key: '1700000000000');
      final parsed = Calendar.parseLink(link)!;
      expect(parsed.calendar, calendar);
      expect(parsed.entry, 'e1');
      expect(parsed.key, '1700000000000');
      expect(Calendar.parseLink('https://example.com'), isNull);
      expect(Calendar.parseLink('ournet://event/only-one'), isNull);
      expect(Calendar.parseLink(Calendar.link(Calendar.personal, 'x'))!.key, isNull);
      final text = 'see $link, thanks';
      expect(Calendar.linkPattern.firstMatch(text)!.group(0), link);
    });

    test('search finds text in titles, places and notes', () async {
      final n = (await friends(1)).single;
      final cal = calendarOf(n);
      final soon = DateTime.now().add(const Duration(days: 2));
      await cal.create(
        Calendar.personal,
        draft('Lunch with Sam', soon)..location = 'Cafe Nero',
      );
      await cal.create(Calendar.personal, draft('Dentist', soon));
      expect(titles(cal.search('nero')), ['Lunch with Sam']);
      expect(titles(cal.search('sam lunch')), ['Lunch with Sam']);
      expect(cal.search('zebra'), isEmpty);
    });
  });

  group('iCalendar', () {
    test('exports and imports events, repeats and changed occurrences', () async {
      final n = (await friends(1)).single;
      final cal = calendarOf(n);
      await cal.create(
        Calendar.personal,
        draft(
          'Standup, daily; "quick"',
          DateTime(2026, 10, 5, 9),
          repeat: const Repeat('daily', count: 4),
        )
          ..description = 'Line one\nLine two'
          ..location = 'Room 4'
          ..reminders = [10, 60],
      );
      await cal.create(
        Calendar.personal,
        draft('Holiday', DateTime(2026, 10, 12), allDay: true)..busy = false,
      );
      await cal.create(
        Calendar.personal,
        draft(
          'Pottery',
          DateTime(2026, 10, 7, 18),
          repeat: const Repeat('weekly', days: [3, 5], interval: 2),
        ),
      );
      final week = [DateTime(2026, 10, 5), DateTime(2026, 11, 2)];
      final standups = cal
          .between(week[0], week[1])
          .where((o) => o.event.title.startsWith('Standup'))
          .toList();
      await cal.update(
        standups[1],
        EventDraft.of(standups[1])
          ..title = 'Standup (late)'
          ..start = DateTime(2026, 10, 6, 11)
          ..end = DateTime(2026, 10, 6, 12),
        scope: Scope.one,
      );
      await cal.delete(standups[2], scope: Scope.one);
      final text = cal.exportIcs(Calendar.personal);
      expect(text, contains('BEGIN:VCALENDAR'));
      expect(text, contains('RRULE:FREQ=DAILY;COUNT=4'));
      expect(text, contains('RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=WE,FR'));
      expect(text, contains('EXDATE:'));
      expect(text, contains('RECURRENCE-ID:'));
      expect(text, contains('TRANSP:TRANSPARENT'));
      expect(text.split('\r\n').every((l) => l.length <= 75), isTrue);

      final other = (await friends(1)).single;
      final copy = calendarOf(other);
      final file = Ics.read(text);
      expect(file.problems, isEmpty);
      expect(file.events, hasLength(3));
      expect(await copy.importIcs(Calendar.personal, file), 3);
      final a = cal.between(week[0], week[1]);
      final b = copy.between(week[0], week[1]);
      String shape(Occurrence o) =>
          '${o.event.title}|${o.start}|${o.end}|${o.allDay}|${o.event.busy}|${o.event.location}';
      expect(b.map(shape).toList(), a.map(shape).toList());
      final standup = copy.event(
        Calendar.personal,
        b.firstWhere((o) => o.event.title.startsWith('Standup')).entry,
      )!;
      expect(standup.description, 'Line one\nLine two');
      expect(standup.reminders, [10, 60]);
    });

    test('reads files from other calendars', () {
      const file =
          'BEGIN:VCALENDAR\r\nVERSION:2.0\r\n'
          'BEGIN:VEVENT\r\nUID:a1\r\nDTSTART:20261012T090000Z\r\nDURATION:PT90M\r\n'
          'SUMMARY:Folded\r\n  title that runs on\r\n'
          'RRULE:FREQ=MONTHLY;BYDAY=2MO;COUNT=3\r\n'
          'BEGIN:VALARM\r\nTRIGGER:-PT15M\r\nACTION:DISPLAY\r\nEND:VALARM\r\nEND:VEVENT\r\n'
          'BEGIN:VEVENT\r\nUID:a2\r\nDTSTART;VALUE=DATE:20261101\r\nSUMMARY:Day off\r\nEND:VEVENT\r\n'
          'BEGIN:VEVENT\r\nUID:a3\r\nDTSTART:20261101T100000Z\r\nSUMMARY:Odd\r\n'
          'RRULE:FREQ=MONTHLY;BYSETPOS=1;BYDAY=MO,TU\r\nEND:VEVENT\r\n'
          'END:VCALENDAR\r\n';
      final read = Ics.read(file);
      expect(read.events, hasLength(3));
      final first = read.events.first.draft;
      expect(first.title, 'Folded title that runs on');
      expect(first.end.difference(first.start), const Duration(minutes: 90));
      expect(first.repeat!.monthly, 'weekday');
      expect(first.repeat!.count, 3);
      expect(first.reminders, [15]);
      expect(read.events[1].draft.allDay, isTrue);
      expect(read.events[2].draft.repeat, isNull);
      expect(read.problems, hasLength(1));
    });
  });

  test('a device added later is handed the personal calendar and group events', () async {
    final owner = await LocalIdentity.create();
    final fresh = await LocalIdentity.create();
    final friend = Node(await LocalIdentity.create(), Store());
    final a = Node(owner, Store());
    addTearDown(() async {
      await a.close();
      await friend.close();
    });
    await a.addContact(friend.identity.certificate);
    await friend.addContact(owner.certificate);
    final room = await Everyday(a).createRoom('Club', [friend.person]);
    final ca = calendarOf(a);
    await ca.create(Calendar.personal, draft('Mine', DateTime(2026, 10, 12, 9)));
    await ca.create(room.object.space, draft('Club night', DateTime(2026, 10, 12, 19)));
    final paired = await fresh.enrol(await owner.authorise(fresh.certificate));
    final b = Node(paired, Store());
    addTearDown(b.close);
    await a.addContact(paired.certificate);
    await b.addContact(owner.certificate);
    await b.addContact(friend.identity.certificate);
    await friend.addContact(paired.certificate);
    // Nothing before the device existed can be read until it is handed over.
    await syncPair(a, b);
    final cb = calendarOf(b);
    await cb.refresh();
    final range = [DateTime(2026, 10, 12), DateTime(2026, 10, 13)];
    expect(cb.between(range[0], range[1], calendars: {Calendar.personal, room.object.space}), isEmpty);
    await shareAllHistory(a);
    await syncPair(a, b);
    await cb.refresh();
    expect(
      titles(cb.between(range[0], range[1], calendars: {Calendar.personal, room.object.space})),
      ['Mine', 'Club night'],
    );
  });

  test('deleted events can be listed and put back', () async {
    final n = (await friends(1)).single;
    final cal = calendarOf(n);
    await cal.create(Calendar.personal, draft('Keep me', DateTime(2026, 10, 12, 9), repeat: const Repeat('daily', count: 3)));
    await cal.create(Calendar.personal, draft('Other', DateTime(2026, 10, 12, 11)));
    final range = [DateTime(2026, 10, 12), DateTime(2026, 10, 16)];
    final first = cal.between(range[0], range[1]).firstWhere((o) => o.event.title == 'Keep me');
    await cal.delete(first);
    expect(cal.between(range[0], range[1]).map((o) => o.event.title), ['Other']);
    final gone = cal.deleted();
    expect(gone.map((e) => e.title), ['Keep me']);
    await cal.restoreEvent(gone.single);
    expect(cal.deleted(), isEmpty);
    expect(titles(cal.between(range[0], range[1])).where((t) => t == 'Keep me'), hasLength(3));
    // Only recent deletions are listed.
    final other = cal.between(range[0], range[1]).firstWhere((o) => o.event.title == 'Other');
    await cal.delete(other);
    expect(cal.deleted(within: Duration.zero), isEmpty);
    expect(cal.deleted(), hasLength(1));
  });

  test('a refresh with nothing new does no work', () async {
    final n = (await friends(1)).single;
    final cal = calendarOf(n);
    for (var i = 0; i < 40; i++) {
      await cal.create(Calendar.personal, draft('E$i', DateTime(2026, 10, 1 + i % 28, 9)));
    }
    final version = cal.version;
    expect(await cal.refresh(), isFalse);
    expect(cal.version, version);
    await cal.create(Calendar.personal, draft('One more', DateTime(2026, 10, 2, 9)));
    expect(cal.version, greaterThan(version));
  });
}
