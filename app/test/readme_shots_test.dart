import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/ui/app.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet/ui/plugins_page.dart';
import 'chat_features_test.dart' show friends;
import 'plugin_view_test.dart' show Rig;
import 'features_test.dart' show settled;

/// Draws the app with made-up content for the README's screenshots. Not part
/// of the normal run: set README_SHOTS to a folder to write them.
///
///   flutter test test/readme_shots_test.dart --dart-define=README_SHOTS=C:/tmp/shots
const _folder = String.fromEnvironment('README_SHOTS');

Future<void> _loadFonts() async {
  final font = File('C:/Windows/Fonts/segoeui.ttf');
  if (await font.exists()) {
    for (final family in ['Roboto', 'Segoe UI']) {
      await (FontLoader(family)
            ..addFont(font.readAsBytes().then((b) => ByteData.sublistView(b))))
          .load();
    }
  }
  await (FontLoader(
    'MaterialIcons',
  )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
}

void main() {
  if (_folder.isEmpty) {
    test('screenshots are off', () {}, skip: 'set README_SHOTS to a folder');
    return;
  }
  setUpAll(_loadFonts);

  const capture = ValueKey('capture');
  Future<void> shot(WidgetTester tester, String name) async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(capture),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '$_folder/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  void size(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
  }

  testWidgets('README screens', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    size(tester, const Size(1280, 800));
    final (node, [sam, priya]) = (await tester.runAsync(() => friends(2)))!;
    final room = (await tester.runAsync(() async {
      await node.publish('profile', {'name': 'Alex'}, space: '_identity');
      await sam.publish('profile', {'name': 'Sam'}, space: '_identity');
      await priya.publish('profile', {'name': 'Priya'}, space: '_identity');
      await sam.addContact(priya.identity.certificate);
      await priya.addContact(sam.identity.certificate);

      final notes = Notes(node);
      final moving = await notes.create(
        title: 'Moving flat checklist',
        items: [
          'Pack the kitchen',
          'Return old keys',
          'Housewarming invites',
          'Measure the front room',
          'Cancel the broadband',
        ],
      );
      await notes.edit(
        moving.id,
        moving.epoch,
        'check:${moving.checks[1]}:done',
        true,
        [],
      );
      await notes.pin(moving.id, true);
      await notes.create(
        title: 'Book club',
        text:
            'Next meet Thursday 7pm at the library cafe\n'
            'Bring snacks, finish chapter 12',
        color: 'dusk',
      );
      await notes.create(
        title: 'Ideas for the garden',
        text:
            'Raised bed by the fence\nWildflower corner for bees\n'
            'Ask neighbours about sharing a compost bin',
        color: 'coral',
      );
      final trip = await notes.create(
        title: 'Weekend in the Peak District',
        text: 'Book the cabin near Edale\nPack walking boots and flask',
        color: 'sage',
      );
      await notes.changeMembers(trip.id, [sam.person]);
      await notes.create(
        title: 'Groceries',
        items: ['Oat milk', 'Sourdough', 'Tomatoes', 'Coffee beans'],
        color: 'mint',
      );
      await notes.create(
        title: 'Gift ideas',
        text: 'Mum: pottery class voucher\nDan: the new Murakami',
        color: 'sand',
      );
      await notes.create(
        title: 'Bike service',
        text: 'Chain feels stiff, check brake pads',
        color: 'fog',
      );

      final room = (await Everyday(
        node,
      ).createRoom('Climbing crew', [sam.person, priya.person]));
      await syncPair(node, sam);
      await syncPair(node, priya);
      Future<void> write(Node who, String text) async {
        await Everyday(who).write({'type': 'note', 'text': text}, room: room);
        if (who != node) await syncPair(node, who);
      }

      await write(sam, 'Anyone up for the wall on Thursday?');
      await write(priya, 'Yes! I can drive, room for two more');
      await write(node, 'Count me in. I will bring the spare harness');
      await write(sam, 'Great, see you at 7');
      await write(priya, 'Also: Peak District trip next month?');

      await RoomForum(node, room).publish({
        'title': 'Gear swap',
        'text': 'List anything you are not using any more.',
      });
      await RoomForum(sam, room).publish({
        'title': 'Best crag for beginners?',
        'text': 'Thinking of bringing my cousin along.',
      });
      await syncPair(node, sam);
      node.subscribe('Local food', true);
      sam.subscribe('Local food', true);
      await sam.publish('post', {
        'title': 'Saturday market has a new bakery stall',
        'text': 'The rye is excellent, get there early.',
      }, space: 'Local food');
      await syncPair(node, sam);

      final calendar = Calendar(node, NoteState(node));
      final now = DateTime.now();
      final monday = DateTime(now.year, now.month, now.day - (now.weekday - 1));
      DateTime at(int day, int h, [int m = 0]) =>
          DateTime(monday.year, monday.month, monday.day + day, h, m);
      Future<void> event(
        String space,
        String title,
        DateTime start,
        int minutes, {
        Repeat? repeat,
        String? color,
        String location = '',
      }) => calendar.create(
        space,
        EventDraft(
          title: title,
          start: start,
          end: start.add(Duration(minutes: minutes)),
          repeat: repeat,
          color: color,
          location: location,
        ),
      );
      await event(
        Calendar.personal,
        'Standup',
        at(0, 9),
        30,
        repeat: const Repeat('weekly', days: [1, 2, 3, 4, 5]),
      );
      await event(
        Calendar.personal,
        'Design review',
        at(1, 10),
        90,
        location: 'Room 4',
      );
      await event(
        Calendar.personal,
        'Lunch with Sam',
        at(1, 12, 30),
        60,
        color: 'tangerine',
      );
      await event(
        Calendar.personal,
        'Deep work',
        at(2, 13),
        180,
        color: 'peacock',
      );
      await event(Calendar.personal, 'Dentist', at(3, 15), 45, color: 'sage');
      await event(Calendar.personal, 'Pottery', at(1, 18), 90, color: 'grape');
      await calendar.create(
        Calendar.personal,
        EventDraft(
          title: "Priya's birthday",
          allDay: true,
          start: at(4, 0),
          end: at(5, 0),
          color: 'flamingo',
        ),
      );
      await event(
        room.object.space,
        'Wall night',
        at(3, 19),
        120,
        repeat: const Repeat('weekly'),
        location: 'The climbing centre',
      );
      await event(room.object.space, 'Trip planning', at(5, 11), 60);
      return room;
    }))!;

    await tester.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: OurNetApp(
          node: node,
          enablePlatform: false,
          initialTab: Destination.notes,
        ),
      ),
    );
    await settled(tester);
    await shot(tester, 'notes');

    size(tester, const Size(390, 844));
    await settled(tester);
    await shot(tester, 'notes-phone');
    size(tester, const Size(1280, 800));
    await settled(tester);

    Future<void> go(String title) async {
      await tester.tap(find.text(title).first);
      await settled(tester);
      await settled(tester);
    }

    await go('Chat');
    final crew = find.text('Climbing crew');
    if (crew.evaluate().isNotEmpty) {
      await tester.tap(crew.first);
      await settled(tester);
    }
    await shot(tester, 'chat');

    await go('Forums');
    final all = find.widgetWithText(ListTile, 'All forums');
    if (all.evaluate().isNotEmpty) {
      await tester.tap(all.first);
      await settled(tester);
    }
    await shot(tester, 'forums');

    await go('Calendar');
    await shot(tester, 'calendar');

    expect(tester.takeException(), isNull);
    expect(room.object.space, isNotEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await settled(tester);
    await tester.runAsync(() async {
      await node.close();
      await sam.close();
      await priya.close();
    });
  });

  testWidgets('README plugin list', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    size(tester, const Size(900, 430));
    final rig = await Rig.start(tester, [
      'wiki',
      'microblog',
      'tictactoe',
      'pong',
      'vpn',
    ]);
    await tester.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xff137d72),
            ),
          ),
          home: Scaffold(
            body: PluginsPage(
              plugins: rig.plugins,
              pickPackage: () async => null,
              savePackage: (_, _) async {},
              nameOf: (_) => 'You',
              notice: (_) {},
            ),
          ),
        ),
      ),
    );
    await settled(tester);
    await shot(tester, 'plugins');
  });
}
