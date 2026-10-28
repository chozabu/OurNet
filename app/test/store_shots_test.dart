import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ournet/ui/app.dart';
import 'package:ournet/ui/calendar_grid.dart';
import 'package:ournet/ui/group_call_screen.dart';
import 'package:ournet/ui/plugins_page.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';
import 'features_test.dart' show settled;
import 'plugin_view_test.dart' show Rig;
import 'support/call_rig.dart' as calls;

/// Draws the app with made-up people for the store listings. Not part of the
/// normal run: set STORE_SHOTS to a folder to write
/// `<folder>/desktop/*.png` and `<folder>/phone/*.png`, then frame them with
/// `python tool/store_shots.py frame <folder>`.
///
///   flutter test test/store_shots_test.dart --dart-define=STORE_SHOTS=C:/tmp/store
const _folder = String.fromEnvironment('STORE_SHOTS');

/// A screen size in logical pixels, and the pixel ratio it is drawn at.
typedef Form = ({String name, Size size, double ratio, String font});

const Form _desktop = (
  name: 'desktop',
  size: Size(1280, 696),
  ratio: 1.25,
  font: 'C:/Windows/Fonts/segoeui.ttf',
);
const Form _phone = (
  name: 'phone',
  size: Size(412, 790),
  ratio: 2,
  font: 'C:/src/flutter/bin/cache/artifacts/material_fonts/roboto-regular.ttf',
);

Future<void> _loadFonts(Form form) async {
  final regular = File(form.font);
  final bold = File(
    form.font
        .replaceFirst('segoeui.ttf', 'segoeuib.ttf')
        .replaceFirst('roboto-regular', 'roboto-medium'),
  );
  Future<ByteData> bytes(File f) async =>
      ByteData.sublistView(await f.readAsBytes());
  for (final family in ['Roboto', 'Segoe UI']) {
    final loader = FontLoader(family)..addFont(bytes(regular));
    if (bold.existsSync()) loader.addFont(bytes(bold));
    await loader.load();
  }
  await (FontLoader(
    'MaterialIcons',
  )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
}

const _capture = ValueKey('capture');

/// Fetches in the root zone: the test's fake clock would otherwise run the
/// HTTP client's own timers, and map tiles never arrive.
class _RootClient extends http.BaseClient {
  final _inner = Zone.root.run(http.Client.new);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Zone.root.run(() => _inner.send(request));
}

/// Lets real work (decoding, the network) and animations run. Unlike
/// pumpAndSettle this ends on a map, which keeps drawing.
Future<void> calm(WidgetTester tester, [int rounds = 8]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

ThemeData _theme() => ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff137d72)),
);

/// A clock the demo people share, set before each thing they write so the
/// history reads like an evening's chat.
DateTime _clock = DateTime.now();
int _now() => _clock.millisecondsSinceEpoch;

/// Today at [h]:[m], or the same time yesterday when that is still ahead.
DateTime _today(int h, [int m = 0]) {
  final now = DateTime.now();
  final t = DateTime(now.year, now.month, now.day, h, m);
  return t.isAfter(now) ? t.subtract(const Duration(days: 1)) : t;
}

class _World {
  final Node me;
  final Map<String, Node> friends;
  final EverydayItem crew;
  _World(this.me, this.friends, this.crew);

  Future<void> close() async {
    await me.close();
    for (final f in friends.values) {
      await f.close();
    }
  }
}

Future<_World> _build() async {
  final me = Node(
    await LocalIdentity.create(label: 'Laptop'),
    Store(),
    clock: _now,
  );
  await me.publish('profile', {'name': 'Alex'}, space: '_identity');
  final friends = <String, Node>{};
  for (final name in ['Sam', 'Priya', 'Jo', 'Marcus']) {
    final f = Node(
      await LocalIdentity.create(label: '$name\'s phone'),
      Store(),
      clock: _now,
    );
    await f.publish('profile', {'name': name}, space: '_identity');
    await me.addContact(f.identity.certificate);
    await f.addContact(me.identity.certificate);
    friends[name] = f;
  }
  final sam = friends['Sam']!, priya = friends['Priya']!, jo = friends['Jo']!;
  for (final a in friends.values) {
    for (final b in friends.values) {
      if (a != b) await a.addContact(b.identity.certificate);
    }
  }

  _clock = _today(9, 12);
  final notes = Notes(me);
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
        'Next meet Thursday 7pm at the library cafe\nBring snacks, finish chapter 12',
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

  // The group, its chat and forum.
  final crew = await Everyday(
    me,
  ).createRoom('Climbing crew', [sam.person, priya.person, jo.person]);
  for (final f in [sam, priya, jo]) {
    await syncPair(me, f);
  }
  final network = PeerNetwork(me);
  final files = Files(me, network);
  Future<void> say(Node who, String text, int h, int m) async {
    _clock = _today(h, m);
    await Everyday(who).write({'type': 'note', 'text': text}, room: crew);
    if (who != me) await syncPair(me, who);
  }

  await say(sam, 'Anyone up for the wall on Thursday?', 17, 42);
  await say(priya, 'Yes! I can drive, room for two more', 17, 45);
  await say(jo, 'In. Can someone lend me a chalk bag?', 17, 51);
  await say(
    me,
    'Count me in. I will bring the spare harness and chalk',
    17,
    58,
  );
  _clock = _today(18, 4);
  final everyday = Everyday(me);
  await files.publish(
    File('test/fixtures/store/edale-ridge.jpg').absolute.path,
    audience: crew.object.audience,
    room: crew.object.space,
    text: 'Found this from the Edale walk last month',
    everyday: await everyday.data({
      'type': 'file',
      'epoch': everyday.epoch(crew),
    }),
  );
  await say(sam, 'That ridge! We should do it again before winter', 18, 7);
  await say(
    priya,
    'Peak District trip next month? I made a calendar event',
    18,
    12,
  );
  await say(jo, 'Great, see you all at 7 on Thursday', 18, 15);

  _clock = _today(12, 30);
  await RoomForum(me, crew).publish({
    'title': 'Gear swap',
    'text':
        'List anything you are not using any more. I have a 60 m rope going spare.',
  });
  await RoomForum(sam, crew).publish({
    'title': 'Best crag for beginners?',
    'text':
        'Thinking of bringing my cousin along. Somewhere with easy top-ropes?',
  });
  await RoomForum(priya, crew).publish({
    'title': 'Trip budget',
    'text': 'Cabin is £240 for the weekend, so £60 each plus fuel.',
  });
  for (final f in [sam, priya]) {
    await syncPair(me, f);
  }
  me.subscribe('Local food', true);
  sam.subscribe('Local food', true);
  await sam.publish('post', {
    'title': 'Saturday market has a new bakery stall',
    'text': 'The rye is excellent, get there early.',
  }, space: 'Local food');
  await syncPair(me, sam);

  // A private message or two.
  _clock = _today(16, 20);
  await friends['Marcus']!.publish(
    'message',
    {'text': 'Are we still on for chess tomorrow?'},
    space: '_messages',
    audience: [me.person],
  );
  await syncPair(me, friends['Marcus']!);

  // Files.
  _clock = _today(10, 5);
  final drive = Drive(me);
  await drive.folder('Photos');
  await drive.folder('Documents');
  Json entry(String? folder) => {
    'entry': randomId(),
    'revision': randomId(),
    'folder': folder,
    'type': 'file',
    'deleted': false,
    'parents': [],
  };
  for (final name in [
    'edale-ridge.jpg',
    'sunset-crag.jpg',
    'lake-morning.jpg',
  ]) {
    await files.publish(
      File('test/fixtures/store/$name').absolute.path,
      audience: [me.person],
      drive: entry(null),
    );
  }
  final temp = Directory.systemTemp.createTempSync('ournet-store-files');
  for (final (name, text) in [
    ('Kit list.txt', 'Harness\nShoes\nChalk\nBelay device\n'),
    ('Cabin booking.txt', 'Edale, 14 to 16 November, 4 people\n'),
    ('Route notes.md', '# Stanage\n\n- Hollybush Crack\n- Flying Buttress\n'),
  ]) {
    final f = File('${temp.path}/$name')..writeAsStringSync(text);
    await files.publish(f.path, audience: [me.person], drive: entry(null));
  }
  await files.publish(
    File('test/fixtures/store/sunset-crag.jpg').absolute.path,
    audience: crew.object.audience,
    room: crew.object.space,
    everyday: await everyday.data({
      'type': 'file',
      'epoch': everyday.epoch(crew),
    }),
  );
  temp.deleteSync(recursive: true);
  await network.stop();

  // The calendar.
  final calendar = Calendar(me, NoteState(me));
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
  await event(Calendar.personal, 'Deep work', at(2, 13), 180, color: 'peacock');
  await event(Calendar.personal, 'Dentist', at(3, 15), 45, color: 'sage');
  await event(Calendar.personal, 'Pottery', at(1, 18), 90, color: 'grape');
  await event(
    Calendar.personal,
    'Chess with Marcus',
    at(4, 18),
    90,
    color: 'banana',
  );
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
    crew.object.space,
    'Wall night',
    at(3, 19),
    120,
    repeat: const Repeat('weekly'),
    location: 'The climbing centre',
  );
  await event(crew.object.space, 'Trip planning', at(5, 11), 60);
  await event(
    crew.object.space,
    'Bouldering',
    at(6, 10),
    150,
    location: 'Stanage Edge',
  );

  // Where friends are, as their phones last said.
  final fixAt = DateTime.now().millisecondsSinceEpoch;
  for (final (name, lat, lng, minutes) in [
    ('Sam', 53.3594, -1.6345, 4),
    ('Priya', 53.3298, -1.6555, 12),
    ('Jo', 53.3712, -1.8150, 25),
    ('Marcus', 53.3810, -1.4700, 2),
  ]) {
    me.locations.update(
      friends[name]!.person,
      Fix(
        lat: lat,
        lng: lng,
        at: fixAt - minutes * 60000,
        device: '$name\'s phone',
      ),
    );
  }
  me.store.set('mapView', [
    (53.362 * 1e7).round(),
    (-1.660 * 1e7).round(),
    11000,
  ]);
  return _World(me, friends, crew);
}

void main() {
  if (_folder.isEmpty) {
    test('screenshots are off', () {}, skip: 'set STORE_SHOTS to a folder');
    return;
  }

  for (final form in [_desktop, _phone]) {
    group(form.name, () {
      setUpAll(() => _loadFonts(form));

      void size(WidgetTester tester) {
        // Real shadows, not the test's flat outlines; put back by [done].
        debugDisableShadows = false;
        tester.view.physicalSize = form.size * form.ratio;
        tester.view.devicePixelRatio = form.ratio;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
      }

      Future<void> shot(WidgetTester tester, String name) async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(_capture),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: form.ratio);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('$_folder/${form.name}/$name.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      Future<void> screens(WidgetTester tester) async {
        size(tester);
        // Map tiles come from the real tile server; the map cancels tile
        // loads when it closes, which is not a failure here.
        HttpOverrides.global = null;
        final reportError = FlutterError.onError;
        FlutterError.onError = (details) {
          if (details.library == 'image resource service') {
            // ignore: avoid_print
            print('tile: ${details.exceptionAsString().split('\n').first}');
            return;
          }
          reportError?.call(details);
        };
        final cache = Directory.systemTemp.createTempSync('ournet-store-tiles');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => cache.path,
        );
        // Map labels name no font, which in a test means the box font.
        tester.binding.defaultBinaryMessenger.setMockMessageHandler(
          'flutter/assets',
          (message) async {
            final key = Uri.decodeFull(
              utf8.decode(
                message!.buffer.asUint8List(
                  message.offsetInBytes,
                  message.lengthInBytes,
                ),
              ),
            );
            final bytes = File('build/unit_test_assets/$key').readAsBytesSync();
            if (!key.startsWith('assets/maps/style_')) {
              return ByteData.sublistView(bytes);
            }
            final style = jsonDecode(utf8.decode(bytes)) as Map;
            for (final layer in style['layers'] as List) {
              final layout = (layer as Map)['layout'];
              if (layout is Map && layout.containsKey('text-field')) {
                layout['text-font'] = ['Roboto'];
              }
            }
            return ByteData.sublistView(utf8.encode(jsonEncode(style)));
          },
        );
        final world = (await tester.runAsync(_build))!;
        await tester.pumpWidget(
          RepaintBoundary(
            key: _capture,
            child: OurNetApp(
              node: world.me,
              enablePlatform: false,
              initialTab: Destination.notes,
            ),
          ),
        );
        await settled(tester);

        // Connect, so the status line reads as it does in use.
        final connect = find.text('Connect').evaluate().isNotEmpty
            ? find.text('Connect')
            : find.byTooltip('Connect');
        if (connect.evaluate().isNotEmpty) {
          await tester.tap(connect.first);
          for (var i = 0; i < 20; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 250)),
            );
            await tester.pump();
          }
        }
        await settled(tester);
        await shot(tester, 'notes');

        Future<void> go(String title) async {
          final menu = find.byTooltip('Open navigation menu');
          if (menu.evaluate().isNotEmpty) {
            await tester.tap(menu.first);
            await calm(tester);
          }
          await tester.tap(find.text(title).last);
          await calm(tester);
        }

        Future<void> open(String text) async {
          final f = find.text(text);
          if (f.evaluate().isNotEmpty) {
            await tester.tap(f.first);
            await calm(tester);
          }
        }

        await go('Calendar');
        // Open on the working day, whatever time the shots are taken.
        for (final e in find.byType(Scrollable).evaluate()) {
          final position = (e as StatefulElement).state as ScrollableState;
          if (position.position.axis == Axis.vertical &&
              position.position.maxScrollExtent > 10 * TimeGrid.hourHeight) {
            position.position.jumpTo(8 * TimeGrid.hourHeight);
          }
        }
        await calm(tester);
        await shot(tester, 'calendar');

        await go('Maps');
        // Tiles load and draw off the test's clock; give them real time.
        // Tiles load and draw off the test's clock; give them real time.
        for (var i = 0; i < 220; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 300)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        await shot(tester, 'maps');

        await go('Files');
        await tester.drag(find.text('My drive'), const Offset(0, -260));
        await calm(tester);
        await shot(tester, 'files');

        await go('Forums');
        await open('All forums');
        await shot(tester, 'forums');

        await go('Chat');
        await open('Climbing crew');
        await shot(tester, 'chat');

        await tester.pumpWidget(const SizedBox.shrink());
        // The tile layer keeps a short timer of its own; let it run out.
        await tester.pump(const Duration(seconds: 30));
        await settled(tester);
        await tester.runAsync(world.close);
        tester.binding.defaultBinaryMessenger.setMockMessageHandler(
          'flutter/assets',
          null,
        );
        FlutterError.onError = reportError;
        debugDisableShadows = true;
      }

      testWidgets('app screens', (tester) async {
        await http.runWithClient(() => screens(tester), _RootClient.new);
      });

      testWidgets('call', (tester) async {
        size(tester);
        final rig = calls.Rig()
          ..wire.clock = DateTime.now().subtract(
            const Duration(minutes: 14, seconds: 32),
          );
        final names = ['Sam', 'Priya', 'Jo', 'You'];
        final devs = <calls.Dev>[];
        await tester.runAsync(() async {
          for (final n in names) {
            devs.add(await rig.device(n));
          }
          await rig.introduce(devs);
          for (final d in devs) {
            await d.calls.join(calls.Rig.space);
            await pumpEventQueue(times: 100);
            await Future<void>.delayed(const Duration(milliseconds: 250));
          }
        });
        await tester.pumpWidget(
          RepaintBoundary(
            key: _capture,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: _theme(),
              home: GroupCallScreen(
                calls: devs.last.calls,
                title: 'Climbing crew',
                label: (p) => p.self ? 'You' : rig.wire.devices[p.device]!.name,
                act: (action) => action(),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 1));
        await shot(tester, 'call');
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(rig.close);
        debugDisableShadows = true;
      });

      testWidgets('plugins', (tester) async {
        size(tester);
        final rig = await Rig.start(tester, [
          'wiki',
          'microblog',
          'tictactoe',
          'pong',
          'git',
          'vpn',
          'device-dashboard',
        ]);
        await tester.pumpWidget(
          RepaintBoundary(
            key: _capture,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: _theme(),
              home: Scaffold(
                appBar: AppBar(title: const Text('Plugins')),
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
        debugDisableShadows = true;
      });
    });
  }
}
