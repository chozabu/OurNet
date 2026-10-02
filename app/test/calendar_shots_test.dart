import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/controllers/calendar_controller.dart';
import 'package:ournet/ui/calendar_flows.dart';
import 'package:ournet/ui/calendar_page.dart';
import 'package:ournet/ui/event_editor.dart';
import 'package:ournet_core/ournet_core.dart';
import 'chat_features_test.dart' show friends;

/// Draws the calendar's screens to PNG files so layout can be looked at. Not
/// part of the normal run: set CALENDAR_SHOTS to a folder to write them.
///
///   flutter test test/calendar_shots_test.dart --dart-define=CALENDAR_SHOTS=C:/tmp/shots
const _folder = String.fromEnvironment('CALENDAR_SHOTS');

Future<void> _loadFonts() async {
  const base = 'C:/src/flutter/bin/cache/artifacts/material_fonts';
  Future<ByteData> bytes(String name) async =>
      ByteData.sublistView(await File('$base/$name').readAsBytes());
  final roboto = FontLoader('Roboto')
    ..addFont(bytes('roboto-regular.ttf'))
    ..addFont(bytes('roboto-medium.ttf'))
    ..addFont(bytes('roboto-bold.ttf'));
  await roboto.load();
  final icons = FontLoader('MaterialIcons')..addFont(bytes('materialicons-regular.otf'));
  await icons.load();
}

void main() {
  if (_folder.isEmpty) {
    test('screenshots are off', () {}, skip: 'set CALENDAR_SHOTS to a folder');
    return;
  }

  Future<void> shot(WidgetTester tester, GlobalKey key, String name) async {
    final boundary = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await tester.runAsync(() => boundary.toImage(pixelRatio: 1));
    final data = await tester.runAsync(() => image!.toByteData(format: ui.ImageByteFormat.png));
    await tester.runAsync(() => File('$_folder/$name.png').writeAsBytes(data!.buffer.asUint8List()));
  }

  testWidgets('calendar screens', (tester) async {
    await tester.runAsync(_loadFonts);
    final (node, [friend]) = await friends(1);
    await friend.publish('profile', {'name': 'Sam'}, space: '_identity');
    final state = NoteState(node);
    final calendar = Calendar(node, state);
    final room = (await tester.runAsync(
      () => Everyday(node).createRoom('Climbing crew', [friend.person]),
    ))!;
    final now = DateTime.now();
    final monday = DateTime(now.year, now.month, now.day - (now.weekday - 1));
    DateTime at(int dayOffset, int h, [int m = 0]) =>
        DateTime(monday.year, monday.month, monday.day + dayOffset, h, m);
    EventDraft draft(
      String title,
      DateTime start,
      int minutes, {
      Repeat? repeat,
      String? color,
      String location = '',
    }) => EventDraft(
      title: title,
      start: start,
      end: start.add(Duration(minutes: minutes)),
      repeat: repeat,
      color: color,
      location: location,
      reminders: [10],
    );
    await tester.runAsync(() async {
      await calendar.create(Calendar.personal, draft('Standup', at(0, 9), 30, repeat: const Repeat('weekly', days: [1, 2, 3, 4, 5])));
      await calendar.create(Calendar.personal, draft('Design review', at(1, 10), 90, location: 'Room 4'));
      await calendar.create(Calendar.personal, draft('Lunch with Sam', at(1, 12, 30), 60, color: 'tangerine'));
      await calendar.create(Calendar.personal, draft('1:1 with Alex', at(1, 11), 60, color: 'grape'));
      await calendar.create(Calendar.personal, draft('Dentist', at(3, 15), 45, color: 'sage'));
      await calendar.create(Calendar.personal, draft('Deep work', at(2, 13), 180, color: 'peacock'));
      await calendar.create(
        Calendar.personal,
        EventDraft(title: 'Conference', allDay: true, start: at(2, 0), end: at(5, 0), color: 'basil'),
      );
      await calendar.create(
        Calendar.personal,
        EventDraft(title: 'Anna\'s birthday', allDay: true, start: at(4, 0), end: at(5, 0), color: 'flamingo'),
      );
      await calendar.create(room.object.space, draft('Wall night', at(3, 19), 120, repeat: const Repeat('weekly')));
      await calendar.create(room.object.space, draft('Trip planning', at(5, 11), 60));
      await calendar.create(Calendar.personal, draft('Pottery', at(1, 18), 90, repeat: const Repeat('weekly', interval: 2)));
      for (var i = 0; i < 4; i++) {
        await calendar.create(Calendar.personal, draft('Task $i', at(4, 14, i * 15), 30));
      }
    });

    final key = GlobalKey();
    Future<CalendarController> open(CalendarView view, Size size, {String? group}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      final controller = CalendarController(
        node,
        calendar,
        group: group,
        personName: (p) => p == node.person ? 'You' : 'Sam',
      )..view = view;
      await tester.runAsync(controller.refresh);
      final flows = CalendarFlows(controller);
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              useMaterial3: true,
              fontFamily: 'Roboto',
              colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff137d72)),
            ),
            home: Scaffold(body: CalendarPage(controller: controller, flows: flows)),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      return controller;
    }

    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await open(CalendarView.week, const Size(1280, 800));
    await shot(tester, key, 'week-wide');
    await open(CalendarView.week, const Size(390, 800));
    await shot(tester, key, 'week-phone');
    await open(CalendarView.day, const Size(1000, 800));
    await shot(tester, key, 'day');
    await open(CalendarView.month, const Size(1280, 800));
    await shot(tester, key, 'month-wide');
    await open(CalendarView.month, const Size(390, 800));
    await shot(tester, key, 'month-phone');
    await open(CalendarView.schedule, const Size(900, 800));
    await shot(tester, key, 'schedule');
    await open(CalendarView.year, const Size(1100, 800));
    await shot(tester, key, 'year');
    await open(CalendarView.week, const Size(900, 700), group: room.object.space);
    await shot(tester, key, 'group-week');

    // The event form, over the calendar.
    final c = await open(CalendarView.week, const Size(1280, 900));
    final o = c.occurrences(at(1, 0), at(2, 0)).firstWhere((x) => x.event.title == 'Design review');
    unawaited(showEventEditor(tester.element(find.byType(CalendarPage)), controller: c, occurrence: o));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    // ignore: avoid_print
    print('editors: ${find.byType(EventEditor).evaluate().length}');
    await shot(tester, key, 'editor');
  });
}

void unawaited(Future<void> f) {}
