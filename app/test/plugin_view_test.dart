import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/ui/plugin_view.dart';
import 'package:ournet_core/ournet_core.dart';

/// The bundled plugins, run by the real native host and drawn by RFW. Set
/// PLUGIN_SHOTS to a folder to also write each screen as a PNG:
///
///   flutter test test/plugin_view_test.dart --dart-define=PLUGIN_SHOTS=C:/tmp/shots
const _shots = String.fromEnvironment('PLUGIN_SHOTS');

PluginPackage bundled(String id) => PluginPackage.read(
  File('assets/plugins/$id.ournet-plugin').readAsBytesSync(),
);

class Rig {
  final WidgetTester tester;
  final Node node;
  final Plugins plugins;
  final GlobalKey shotKey = GlobalKey();
  Rig(this.tester, this.node, this.plugins);

  static Future<Rig> start(
    WidgetTester tester,
    List<String> ids, {
    bool friend = false,
  }) async {
    await tester.runAsync(_loadFonts);
    final temp = Directory.systemTemp.createTempSync('ournet-plugin-view');
    final (node, plugins) = (await tester.runAsync(() async {
      final node = Node(await LocalIdentity.create(), Store());
      if (friend) {
        final other = await LocalIdentity.create(label: 'Sam');
        await node.addContact(other.certificate);
      }
      final plugins = Plugins(node, directory: temp.path, cache: sharedCache);
      for (final id in ids) {
        final p = bundled(id);
        await plugins.install(p, grants: p.manifest.grants);
      }
      return (node, plugins);
    }))!;
    addTearDown(() async {
      await tester.runAsync(() async {
        await plugins.close();
        await node.close();
        try {
          temp.deleteSync(recursive: true);
        } catch (_) {}
      });
    });
    final rig = Rig(tester, node, plugins);
    for (final id in ids) {
      await rig.until(() => plugins[id]?.status == PluginStatus.running);
    }
    return rig;
  }

  Future<void> show(
    String id,
    String surface, {
    Json context = const {'scope': 'personal'},
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RepaintBoundary(
            key: shotKey,
            child: SizedBox(
              width: 800,
              height: 600,
              child: PluginView(
                plugins: plugins,
                plugin: id,
                surface: surface,
                context: context,
                nameOf: (p) => p == node.person ? 'You' : 'Friend',
                avatar: (p, size) => CircleAvatar(radius: size / 2),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Lets the plugin's thread and the host's messages run until [done].
  Future<void> until(
    bool Function() done, {
    Duration limit = const Duration(seconds: 20),
  }) async {
    final deadline = DateTime.now().add(limit);
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) {
        final texts = [
          for (final e in find.byType(Text).evaluate())
            (e.widget as Text).data ?? '',
        ];
        fail(
          'Timed out. Showing $texts; plugin status ${[for (final p in plugins.installed) '${p.id} ${p.status} ${p.error}']}',
        );
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pump();
  }

  Future<void> untilText(String text) =>
      until(() => find.text(text).evaluate().isNotEmpty);

  Future<void> shot(String name) async {
    if (_shots.isEmpty) return;
    final boundary =
        shotKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await tester.runAsync(() => boundary.toImage(pixelRatio: 1));
    final data = await tester.runAsync(
      () => image!.toByteData(format: ui.ImageByteFormat.png),
    );
    await tester.runAsync(
      () => File('$_shots/$name.png').writeAsBytes(data!.buffer.asUint8List()),
    );
  }
}

Future<void> _loadFonts() async {
  const base = 'C:/src/flutter/bin/cache/artifacts/material_fonts';
  if (!Directory(base).existsSync()) return;
  Future<ByteData> bytes(String name) async =>
      ByteData.sublistView(await File('$base/$name').readAsBytes());
  final roboto = FontLoader('Roboto')
    ..addFont(bytes('roboto-regular.ttf'))
    ..addFont(bytes('roboto-medium.ttf'))
    ..addFont(bytes('roboto-bold.ttf'));
  await roboto.load();
}

void main() {
  testWidgets('the wiki writes, links and keeps history', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final rig = await Rig.start(tester, ['wiki']);
    await rig.show('wiki', 'Wiki');
    await rig.untilText('New page');
    await rig.until(
      () => find.textContaining('No pages yet').evaluate().isNotEmpty,
    );
    await rig.shot('wiki-empty');

    await tester.tap(find.text('New page'));
    await rig.untilText('Save');
    await tester.enterText(find.widgetWithText(TextField, 'Title'), 'Home');
    await tester.enterText(
      find.widgetWithText(TextField, 'Text'),
      '# Welcome\nThis is **our** wiki.\n- See [[Recipes]]',
    );
    await rig.until(() => true);
    await rig.shot('wiki-edit');
    await tester.tap(find.text('Save'));
    await rig.untilText('Welcome');
    expect(find.text('Home'), findsOneWidget);
    await rig.shot('wiki-page');
    final stored = rig.node.store.objects(kind: 'x.wiki.page');
    expect(stored.single.app, 'wiki@0.1.0');

    // A link to a page nobody wrote starts it.
    await tester.tap(find.text('Recipes'));
    await rig.untilText('New page');
    expect(find.text('Recipes'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await rig.untilText('Home');

    await tester.tap(find.text('Home'));
    await rig.untilText('Edit');
    await tester.tap(find.text('Edit'));
    await rig.untilText('Editing');
    await tester.enterText(
      find.widgetWithText(TextField, 'Text'),
      'Second version',
    );
    await tester.tap(find.text('Save'));
    await rig.untilText('History');
    expect(find.text('Second version'), findsOneWidget);
    await tester.tap(find.text('History'));
    await rig.until(
      () => find.textContaining('characters').evaluate().length == 2,
    );
    await rig.shot('wiki-history');
  });

  testWidgets('the microblog posts, likes and replies', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final rig = await Rig.start(tester, ['microblog']);
    await rig.show('microblog', 'Feed', context: const {'scope': 'public'});
    await rig.untilText('Microblog');
    await tester.enterText(find.byType(TextField), 'Hello, *friends*');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await rig.untilText('Reply');
    await tester.tap(find.text('♡ '));
    await rig.untilText('♥ 1');
    await tester.tap(find.text('Reply'));
    await rig.untilText('Your reply');
    await tester.enterText(find.byType(TextField), 'And a reply');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await rig.untilText('Reply · 1');
    await rig.shot('microblog');
  });

  testWidgets('noughts and crosses starts a game with a friend', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final rig = await Rig.start(tester, ['tictactoe'], friend: true);
    await rig.show('tictactoe', 'Games');
    await rig.untilText('New game');
    await tester.tap(find.text('New game'));
    await rig.untilText('Play with…');
    await tester.tap(find.text('Friend'));
    await rig.untilText('Your turn (X)');
    await tester.tap(find.byType(OutlinedButton).at(4));
    await rig.untilText('Their turn');
    expect(find.text('X'), findsOneWidget);
    await rig.shot('tictactoe');
  });

  testWidgets('pong practice draws a moving court', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final rig = await Rig.start(tester, ['pong']);
    await rig.show('pong', 'Pong');
    await rig.untilText('Practise');
    await tester.tap(find.text('Practise'));
    await rig.untilText('Practice');
    final first = rig.plugins.surface('pong', 'Pong')['frame'];
    await rig.until(
      () => rig.plugins.surface('pong', 'Pong')['frame'] != first,
    );
    expect(find.byType(CustomPaint), findsWidgets);
    await rig.shot('pong');
  });

  testWidgets('the friend network shows this device and is off', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final rig = await Rig.start(tester, ['vpn']);
    await rig.show('vpn', 'Vpn');
    await rig.untilText('Turn on');
    expect(find.textContaining('This device: 10.77.'), findsOneWidget);
    await rig.shot('vpn');
  });

  testWidgets('a friend network device opens a page with checks', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final rig = await Rig.start(tester, ['vpn'], friend: true);
    rig.plugins.link = _Unreachable();
    await rig.show('vpn', 'Vpn');
    await rig.untilText('Friend');
    await tester.tap(find.text('Friend'));
    await rig.untilText('Run checks');
    expect(find.text('Connection'), findsOneWidget);
    expect(find.textContaining('Not allowed'), findsOneWidget);
    await tester.tap(find.text('Ping'));
    await rig.until(
      () => find.textContaining('failed: Unreachable').evaluate().isNotEmpty,
    );
    expect(find.textContaining('could not be reached'), findsOneWidget);
    await rig.shot('vpn-device');
    await tester.tap(find.text('‹ Friend network'));
    await rig.untilText('Turn on');
  });
}

/// Says every device runs every plugin, and reaches none of them.
class _Unreachable implements PluginLink {
  @override
  Future<Json> request(String device, Json request) async =>
      throw StateError('Unreachable');
  @override
  bool runs(String device, String plugin) => true;
  @override
  Future<bool> datagram(String device, String channel, List<int> data) async =>
      false;
}

/// Compiled plugins, kept between tests: compiling each time is slow.
final sharedCache = '${Directory.systemTemp.path}/ournet-plugin-cache';
