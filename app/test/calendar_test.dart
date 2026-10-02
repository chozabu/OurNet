import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/controllers/calendar_controller.dart';
import 'package:ournet/ui/app.dart';
import 'package:ournet/ui/calendar_dates.dart';
import 'package:ournet/ui/calendar_flows.dart';
import 'package:ournet/ui/calendar_page.dart';
import 'package:ournet/ui/event_links.dart';
import 'package:ournet/ui/message_text.dart';
import 'package:ournet_core/ournet_core.dart';
import 'chat_features_test.dart' show friends, wide;
import 'features_test.dart' show settled;

Occurrence occurrence(String title, DateTime start, DateTime end, {bool allDay = false}) {
  final data = {
    'event': title,
    'clock': 1,
    'title': title,
    'allDay': allDay,
    if (allDay) ...{'day': Calendar.formatDay(start), 'days': Calendar.dayCount(start, end)} else ...{
      'start': start.millisecondsSinceEpoch,
      'end': end.millisecondsSinceEpoch,
    },
  };
  final event = CalEvent(_FakeObject(), data);
  return Occurrence(event, event, '', start, end);
}

class _FakeObject implements SignedObject {
  @override
  String get space => Calendar.personal;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Future<void> typeSteady(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
    await tester.pump(const Duration(milliseconds: 250));
  }
}

void main() {
  group('layout', () {
    final day = DateTime(2026, 10, 12);
    DateTime at(int h, [int m = 0]) => DateTime(2026, 10, 12, h, m);

    test('overlapping events share the width; others keep the full width', () {
      final placed = layoutDay([
        occurrence('A', at(9), at(11)),
        occurrence('B', at(10), at(12)),
        occurrence('C', at(10, 30), at(11)),
        occurrence('D', at(13), at(14)),
      ], day);
      final by = {for (final p in placed) p.occurrence.event.title: p};
      expect(by['A']!.columns, 3);
      expect({by['A']!.column, by['B']!.column, by['C']!.column}, {0, 1, 2});
      expect(by['D']!.columns, 1);
      expect(by['D']!.column, 0);
    });

    test('an event spreads over columns nothing else uses', () {
      final placed = layoutDay([
        occurrence('Long', at(9), at(12)),
        occurrence('Short', at(9), at(10)),
        occurrence('Later', at(10, 30), at(11)),
      ], day);
      final by = {for (final p in placed) p.occurrence.event.title: p};
      expect(by['Long']!.columns, 2);
      expect(by['Short']!.column, isNot(by['Long']!.column));
      expect(by['Later']!.column, by['Short']!.column);
    });

    test('very short events still take room, and midnight crossings are clipped', () {
      final short = layoutDay([occurrence('Ping', at(9), at(9))], day).single;
      expect(short.endMinute - short.startMinute, minEventMinutes);
      final night = occurrence('Night', at(22), DateTime(2026, 10, 13, 6));
      final first = layoutDay([night], day).single;
      expect(first.endMinute, 24 * 60);
      expect(first.continuesAfter, isTrue);
      final second = layoutDay([night], DateTime(2026, 10, 13)).single;
      expect(second.startMinute, 0);
      expect(second.continuesBefore, isTrue);
      // Ending at midnight does not appear on the next day.
      final evening = occurrence('Evening', at(20), DateTime(2026, 10, 13));
      expect(layoutDay([evening], DateTime(2026, 10, 13)), isEmpty);
    });

    test('bars take lanes and run across the days they cover', () {
      final week = [for (var i = 0; i < 7; i++) DateTime(2026, 10, 12 + i)];
      final bars = layoutBars([
        occurrence('Trip', DateTime(2026, 10, 13), DateTime(2026, 10, 17), allDay: true),
        occurrence('Birthday', DateTime(2026, 10, 14), DateTime(2026, 10, 15), allDay: true),
        occurrence('Earlier', DateTime(2026, 10, 9), DateTime(2026, 10, 13), allDay: true),
        occurrence('Meeting', at(9), at(10)),
        occurrence('Overnight', at(22), DateTime(2026, 10, 14, 6)),
      ], week);
      final by = {for (final b in bars) b.occurrence.event.title: b};
      expect(by.containsKey('Meeting'), isFalse);
      expect(by['Trip']!.firstColumn, 1);
      expect(by['Trip']!.lastColumn, 4);
      expect(by['Birthday']!.lane, isNot(by['Trip']!.lane));
      expect(by['Earlier']!.continuesBefore, isTrue);
      expect(by['Earlier']!.firstColumn, 0);
      expect(by['Earlier']!.lastColumn, 0);
      expect(by['Overnight']!.lastColumn, 2);
    });

    test('weeks and months', () {
      expect(startOfWeek(DateTime(2026, 10, 14), 1), DateTime(2026, 10, 12));
      expect(startOfWeek(DateTime(2026, 10, 14), 7), DateTime(2026, 10, 11));
      expect(startOfWeek(DateTime(2026, 10, 10), 6), DateTime(2026, 10, 10));
      expect(monthWeeks(DateTime(2027, 2), 1), 4);
      expect(monthWeeks(DateTime(2026, 2), 1), 5);
      expect(monthWeeks(DateTime(2026, 10), 1), 5);
      expect(monthWeeks(DateTime(2026, 8), 1), 6);
      expect(weekNumber(DateTime(2026, 1, 1)), 1);
      expect(weekNumber(DateTime(2026, 12, 31)), 53);
      expect(weekNumber(DateTime(2027, 1, 3)), 53);
      expect(addMonths(DateTime(2026, 1, 31), 1), DateTime(2026, 2, 28));
      expect(describeReminder(90), '90 minutes before');
      expect(describeReminder(120), '2 hours before');
      expect(describeReminder(1440), '1 day before');
      expect(describeReminder(0), 'At the time of the event');
    });
  });

  group('calendar screen', () {
    final notices = <String>[];
    final made = <CalendarController>[];
    VoidCallback? undo;
    setUp(() {
      notices.clear();
      made.clear();
      undo = null;
    });
    CalendarController controllerFor(Node node, {String? group}) {
      final c = CalendarController(
        node,
        Calendar(node, NoteState(node)),
        group: group,
        personName: (p) => p == node.person ? 'You' : 'Sam',
        notify: (message, {action, onAction}) {
          notices.add(message);
          undo = onAction;
        },
      );
      made.add(c);
      return c;
    }

    /// Stops the screens' refresh timers so the test can end.
    Future<void> done(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      for (final c in made) {
        c.dispose();
      }
    }

    Widget host(CalendarController c, {CalendarFlows? flows}) => MaterialApp(
      home: Scaffold(
        body: CalendarPage(controller: c, flows: flows ?? CalendarFlows(c)),
      ),
    );

    testWidgets('typing a sentence makes an event that can be opened and undone', (tester) async {
      wide(tester);
      final (node, _) = await friends(0);
      final c = controllerFor(node)..view = CalendarView.schedule;
      await tester.runAsync(c.refresh);
      await tester.pumpWidget(host(c));
      await tester.tap(find.text('Create'));
      await typeSteady(tester);
      expect(find.text('New event'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'Add title'), 'Lunch with Sam tomorrow 1pm');
      await tester.pump();
      // The date in the sentence is offered, and used when saving.
      expect(find.byIcon(Icons.auto_awesome), findsOneWidget);
      await tester.tap(find.text('Save'));
      await typeSteady(tester);
      expect(notices, ['Event saved']);
      final tomorrow = DateTime.now().add(const Duration(days: 1));
      final saved = c.calendar.between(
        DateTime(tomorrow.year, tomorrow.month, tomorrow.day),
        DateTime(tomorrow.year, tomorrow.month, tomorrow.day + 1),
      );
      expect(saved.map((o) => o.event.title), ['Lunch with Sam']);
      expect(saved.single.start.hour, 13);
      await tester.pump(const Duration(milliseconds: 400));
      await typeSteady(tester);
      expect(find.text('Lunch with Sam'), findsOneWidget);

      await tester.tap(find.text('Lunch with Sam'));
      await typeSteady(tester);
      expect(find.byTooltip('Delete'), findsOneWidget);
      await tester.tap(find.byTooltip('Delete'));
      await typeSteady(tester);
      expect(notices.last, 'Event deleted');
      expect(c.calendar.between(DateTime(2000), DateTime(2100)), isEmpty);
      // Undo brings it back.
      await tester.runAsync(() async {
        undo!();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await c.refresh();
      });
      expect(c.calendar.between(DateTime(2000), DateTime(2100)).map((o) => o.event.title), ['Lunch with Sam']);
      await done(tester);
    });

    testWidgets('group calendars show in the personal view until switched off', (tester) async {
      wide(tester);
      final (node, [friend]) = await friends(1);
      final room = (await tester.runAsync(
        () => Everyday(node).createRoom('Climbing crew', [friend.person]),
      ))!;
      final c = controllerFor(node)..view = CalendarView.schedule;
      final soon = DateTime.now().add(const Duration(hours: 2));
      await tester.runAsync(() async {
        await c.calendar.create(
          room.object.space,
          EventDraft(title: 'Wall night', start: soon, end: soon.add(const Duration(hours: 2))),
        );
        await c.calendar.create(
          Calendar.personal,
          EventDraft(title: 'Dentist', start: soon, end: soon.add(const Duration(hours: 1))),
        );
        await c.refresh();
      });
      await tester.pumpWidget(host(c));
      await typeSteady(tester);
      expect(find.text('Wall night'), findsOneWidget);
      expect(find.text('Dentist'), findsOneWidget);
      expect(find.text('Climbing crew'), findsWidgets);

      await tester.tap(find.widgetWithText(InkWell, 'Climbing crew').first);
      await typeSteady(tester);
      expect(find.text('Wall night'), findsNothing);
      expect(find.text('Dentist'), findsOneWidget);
      // The choice is remembered by this person's state, not just the screen.
      final fresh = Calendar(node, NoteState(node));
      await tester.runAsync(fresh.refresh);
      expect(fresh.shown(room.object.space), isFalse);
      await done(tester);
    });

    testWidgets('a group calendar shows only that group', (tester) async {
      wide(tester);
      final (node, [friend]) = await friends(1);
      final room = (await tester.runAsync(
        () => Everyday(node).createRoom('Climbing crew', [friend.person]),
      ))!;
      final c = controllerFor(node, group: room.object.space)..view = CalendarView.schedule;
      final soon = DateTime.now().add(const Duration(hours: 2));
      await tester.runAsync(() async {
        await c.calendar.create(
          room.object.space,
          EventDraft(title: 'Wall night', start: soon, end: soon.add(const Duration(hours: 2))),
        );
        await c.calendar.create(
          Calendar.personal,
          EventDraft(title: 'Dentist', start: soon, end: soon.add(const Duration(hours: 1))),
        );
        await c.refresh();
      });
      await tester.pumpWidget(host(c));
      await typeSteady(tester);
      expect(find.text('Wall night'), findsOneWidget);
      expect(find.text('Dentist'), findsNothing);
      // No sidebar of calendars: the group is the calendar.
      expect(find.text('My calendars'), findsNothing);
      await done(tester);
    });

    testWidgets('week view shows events, opens them, and search finds them', (tester) async {
      wide(tester);
      final (node, _) = await friends(0);
      final c = controllerFor(node)..view = CalendarView.week;
      final start = DateTime.now().copyWith(hour: 10, minute: 0, second: 0, millisecond: 0, microsecond: 0);
      await tester.runAsync(() async {
        await c.calendar.create(
          Calendar.personal,
          EventDraft(
            title: 'Pottery class',
            start: start,
            end: start.add(const Duration(hours: 2)),
            location: 'The studio',
          ),
        );
        await c.refresh();
      });
      await tester.pumpWidget(host(c));
      await typeSteady(tester);
      expect(find.text('Pottery class'), findsOneWidget);
      await tester.tap(find.text('Pottery class'));
      await typeSteady(tester);
      expect(find.text('The studio'), findsWidgets);
      await tester.tap(find.byTooltip('Close'));
      await typeSteady(tester);

      await tester.tap(find.byTooltip('Search'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'studio');
      await tester.pump();
      expect(find.text('Pottery class'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'zebra');
      await tester.pump();
      expect(find.textContaining('No events match'), findsOneWidget);
      await done(tester);
    });

    testWidgets('the all-day strip is always there and makes all-day events', (tester) async {
      wide(tester);
      final (node, _) = await friends(0);
      final c = controllerFor(node)..view = CalendarView.week;
      await tester.runAsync(c.refresh);
      await tester.pumpWidget(host(c));
      await typeSteady(tester);
      final strips = find.byTooltip('Add an all-day event');
      expect(strips, findsNWidgets(7));
      await tester.tap(strips.at(2));
      await typeSteady(tester);
      expect(find.text('New event'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value, isTrue);
      await tester.enterText(find.widgetWithText(TextField, 'Add title'), 'Holiday');
      await tester.tap(find.text('Save'));
      await typeSteady(tester);
      final all = c.calendar.between(DateTime(2000), DateTime(2100));
      expect(all.map((o) => o.event.title), ['Holiday']);
      expect(all.single.allDay, isTrue);
      expect(all.single.start, c.gridDays[2]);
      await done(tester);
    });

    testWidgets('event links in text show the event and open it', (tester) async {
      wide(tester);
      final (node, _) = await friends(0);
      final c = controllerFor(node);
      final soon = DateTime.now().add(const Duration(days: 1));
      final change = (await tester.runAsync(() async {
        final made = await c.calendar.create(
          Calendar.personal,
          EventDraft(title: 'Board games', start: soon, end: soon.add(const Duration(hours: 3))),
        );
        await c.refresh();
        return made;
      }))!;
      final flows = CalendarFlows(c);
      final link = Calendar.link(Calendar.personal, change.entry!);
      await tester.pumpWidget(
        EventLinks(
          controller: () => c,
          open: (context, link) => flows.openLink(context, link),
          child: MaterialApp(
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(20),
                child: MessageText('Fancy this? $link and also https://example.com'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Fancy this? '), findsNothing, reason: 'text is rich, not plain');
      expect(find.byType(EventLinkChip), findsOneWidget);
      expect(find.text('Board games'), findsOneWidget);
      await tester.tap(find.byType(EventLinkChip));
      await typeSteady(tester);
      expect(find.byTooltip('Copy link'), findsNothing);
      expect(find.byTooltip('Edit'), findsOneWidget);
      expect(find.text('Board games'), findsWidgets);
      expect(MessageText.plain('see $link now'), 'see 📅 Calendar event now');

      // A link to something this device does not have says so.
      await tester.pumpWidget(
        EventLinks(
          controller: () => c,
          open: (context, link) => flows.openLink(context, link),
          child: MaterialApp(
            home: Scaffold(body: MessageText(Calendar.link('room2:x:y', 'nothing'))),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('not on this device yet'), findsOneWidget);
      await done(tester);
    });
  });

  testWidgets('the calendar is a place in the app, and a tab in each group', (tester) async {
    wide(tester);
    tester.view.physicalSize = const Size(1400, 1000);
    final (node, [friend]) = await friends(1);
    final room = (await tester.runAsync(
      () => Everyday(node).createRoom('Climbing crew', [friend.person]),
    ))!;
    final soon = DateTime.now().add(const Duration(hours: 2));
    await tester.runAsync(() async {
      await Calendar(node, NoteState(node)).create(
        room.object.space,
        EventDraft(title: 'Wall night', start: soon, end: soon.add(const Duration(hours: 2))),
      );
    });
    await tester.pumpWidget(
      OurNetApp(node: node, enablePlatform: false, initialTab: Destination.calendar),
    );
    await settled(tester);
    expect(find.text('Calendar'), findsWidgets);
    expect(find.text('Create'), findsOneWidget);
    expect(find.text('My calendars'), findsOneWidget);
    expect(find.text('Climbing crew'), findsWidgets);

    await tester.tap(find.text('Private groups'));
    await settled(tester);
    await tester.tap(find.text('Climbing crew').last);
    await settled(tester);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Calendar'));
    await typeSteady(tester);
    expect(find.text('Create'), findsNothing, reason: 'a group calendar has no sidebar');
    expect(find.byTooltip('New event'), findsOneWidget);
  });
}
