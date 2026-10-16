import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
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
    PluginFilePicker? pickFile,
    PluginImage? image,
    String? object,
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
                pickFile: pickFile,
                image: image,
                object: object,
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
  for (final (id, surface, title) in [
    ('device-dashboard', 'Dashboard', 'Device Dashboard'),
    ('remote-input', 'RemoteInput', 'Remote Input'),
  ]) {
    testWidgets('$title draws on a phone and preserves text while updating', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final rig = await Rig.start(tester, [id]);
      await rig.show(id, surface);
      await rig.untilText(title);
      expect(tester.takeException(), isNull);
      if (id == 'device-dashboard' && Platform.isWindows) {
        rig.plugins.event(id, surface, 'local', {});
        await rig.untilText('Memory');
        expect(rig.plugins.surface(id, surface)['processes'], isNotEmpty);
        final process =
            (rig.plugins.surface(id, surface)['processes'] as List).first
                as Map;
        rig.plugins.event(id, surface, 'stop', {'pid': process['pid']});
        await rig.until(
          () => rig.plugins.surface(id, surface)['confirming'] == true,
        );
        await tester.scrollUntilVisible(
          find.text('End this process? Unsaved work may be lost.'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        rig.plugins.event(id, surface, 'cancel', {});
        await rig.until(
          () => rig.plugins.surface(id, surface)['confirming'] == false,
        );
      }
      if (id == 'remote-input') {
        final field = find.byType(TextField);
        await tester.scrollUntilVisible(
          field,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(tester.widget<TextField>(field).maxLength, 16384);
        await tester.enterText(field, 'Dictated text 👋');
        await rig.until(
          () => rig.plugins.surface(id, surface)['text'] == 'Dictated text 👋',
        );
        rig.plugins.event(id, surface, 'clipboard', {});
        await rig.until(
          () => rig.plugins.surface(id, surface)['clipboard'] == true,
        );
        expect(
          (tester.widget<TextField>(field)).controller!.text,
          'Dictated text 👋',
        );
      }
      await rig.shot(id);
      expect(tester.takeException(), isNull);
    });
  }

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
    expect(stored.single.app, 'wiki@0.2.0');

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

  testWidgets('wiki pages hold pictures, run long and open from a link', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final rig = await Rig.start(tester, ['wiki']);
    final picked = <String>[];
    // Stored as the app stores a picked file, before the person picks it.
    final stored = (await tester.runAsync(
      () => rig.plugins.storeFile(
        'cat.png',
        Uint8List.fromList(List.filled(300, 7)),
      ),
    ))!;
    Future<Json?> pick(String plugin, String accept) async {
      picked.add(accept);
      return {
        'file': rig.plugins.addFile(plugin, stored),
        'name': stored['name'],
        'size': stored['size'],
      };
    }

    Widget image(String plugin, String id, double? height) =>
        Text('picture $plugin $id');
    await rig.show('wiki', 'Wiki', pickFile: pick, image: image);
    await rig.untilText('New page');
    await tester.tap(find.text('New page'));
    await rig.untilText('Save');
    await tester.enterText(find.widgetWithText(TextField, 'Title'), 'Cats');
    // Longer than an object holds: the whole text goes in a file.
    final long = '${'Whiskers. ' * 4000}The end.';
    await tester.enterText(find.widgetWithText(TextField, 'Text'), long);
    await rig.until(() => true);
    await tester.tap(find.text('Add a picture'));
    await rig.until(
      () => rig.node.store.objects(kind: 'x.wiki.image').isNotEmpty,
    );
    expect(picked, ['image']);
    final picture = rig.node.store.objects(kind: 'x.wiki.image').single;
    await rig.until(
      () => find
          .textContaining('![cat.png](${picture.id})')
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(find.text('Save'));
    await rig.untilText('picture wiki ${picture.id}');
    expect(find.textContaining('The end.'), findsOneWidget);
    final page = rig.node.store.objects(kind: 'x.wiki.page').single;
    final payload = (await tester.runAsync(() => rig.node.content(page)))!;
    expect(payload['chunks'], isNotEmpty);
    expect((payload['body'] as String).length, lessThan(long.length));
    final file = (await tester.runAsync(() => rig.node.content(picture)))!;
    expect(file['name'], 'cat.png');

    // Search and the activity feed open the plugin at an object.
    await rig.show('wiki', 'Wiki', image: image, object: page.id);
    await rig.until(
      () => find.textContaining('The end.').evaluate().isNotEmpty,
    );
    expect(find.text('Cats'), findsOneWidget);
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

  testWidgets('a microblog post can carry a picture', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final rig = await Rig.start(tester, ['microblog']);
    final stored = (await tester.runAsync(
      () => rig.plugins.storeFile(
        'sky.jpg',
        Uint8List.fromList(List.filled(200, 3)),
      ),
    ))!;
    Future<Json?> pick(String plugin, String accept) async => {
      'file': rig.plugins.addFile(plugin, stored),
      'name': stored['name'],
      'size': stored['size'],
    };
    Widget image(String plugin, String id, double? height) =>
        Text('picture $id');
    await rig.show(
      'microblog',
      'Feed',
      context: const {'scope': 'public'},
      pickFile: pick,
      image: image,
    );
    await rig.untilText('Add a picture');
    await tester.tap(find.text('Add a picture'));
    await rig.until(
      () => find.textContaining('Picture: sky.jpg').evaluate().isNotEmpty,
    );
    // A picture alone is enough to post.
    await tester.enterText(find.byType(TextField), '');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await rig.until(
      () => rig.node.store.objects(kind: 'x.microblog.post').isNotEmpty,
    );
    final post = rig.node.store.objects(kind: 'x.microblog.post').single;
    await rig.untilText('picture ${post.id}');
    expect(find.text('Add a picture'), findsOneWidget);
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

  testWidgets('git shows a pushed repository', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final rig = await Rig.start(tester, ['git']);
    await rig.show('git', 'Git');
    await rig.untilText('New repository');
    await rig.shot('git-empty');
    await tester.tap(find.text('New repository'));
    await rig.untilText('Create');
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'demo');
    await tester.tap(find.text('Create'));
    await rig.untilText('Nothing pushed yet');
    await rig.shot('git-new-repo');

    // A push as git-remote-ournet sends it, packed by real git.
    final pack = await tester.runAsync(_demoPack);
    if (pack == null) return markTestSkipped('git is not installed');
    final request = utf8.encode(
      '${jsonEncode({
        'op': 'push',
        'repo': 'demo',
        'refs': {'refs/heads/main': pack.$1},
        'old': {'refs/heads/main': ''},
        'head': 'refs/heads/main',
      })}\n',
    );
    await tester.runAsync(
      () => rig.plugins.local(
        'git',
        Uint8List.fromList([...request, ...pack.$2]),
      ),
    );
    await rig.untilText('README.md');
    expect(find.textContaining('Hello from'), findsOneWidget);
    await rig.shot('git-code');
    await tester.tap(find.text('notes.txt'));
    await rig.untilText('3 lines, 14 bytes');
    await rig.shot('git-file');
    await tester.tap(find.text('Commits'));
    await rig.untilText('Second');
    await tester.tap(find.text('Second'));
    await rig.untilText('+TWO');
    expect(find.text('-two'), findsOneWidget);
    await rig.shot('git-commit');
    await tester.tap(find.text('Pushes'));
    await rig.untilText('main → ${pack.$1.substring(0, 7)}');
  });
}

/// Two commits made and packed by git: the tip and the pack, or null
/// without git.
Future<(String, Uint8List)?> _demoPack() async {
  final dir = Directory.systemTemp.createTempSync('ournet-git-view');
  try {
    Future<ProcessResult> git(List<String> args, {String? stdin}) async {
      final p = await Process.start(
        'git',
        ['-c', 'init.defaultBranch=main', '-c', 'core.autocrlf=false', ...args],
        workingDirectory: dir.path,
        environment: {
          'GIT_AUTHOR_NAME': 'Ada',
          'GIT_AUTHOR_EMAIL': 'ada@example.com',
          'GIT_COMMITTER_NAME': 'Ada',
          'GIT_COMMITTER_EMAIL': 'ada@example.com',
        },
      );
      if (stdin != null) p.stdin.write(stdin);
      await p.stdin.close();
      final out = BytesBuilder();
      await p.stdout.forEach(out.add);
      await p.stderr.drain<void>();
      return ProcessResult(p.pid, await p.exitCode, out.takeBytes(), '');
    }

    if ((await git(['init'])).exitCode != 0) return null;
    File(
      '${dir.path}/README.md',
    ).writeAsStringSync('# Demo\n\nHello from git.\n');
    File('${dir.path}/notes.txt').writeAsStringSync('one\ntwo\nthree\n');
    await git(['add', '.']);
    await git(['commit', '-m', 'First']);
    File('${dir.path}/notes.txt').writeAsStringSync('one\nTWO\nthree\n');
    await git(['commit', '-am', 'Second']);
    final tip = utf8
        .decode((await git(['rev-parse', 'HEAD'])).stdout as List<int>)
        .trim();
    final pack = await git([
      'pack-objects',
      '--stdout',
      '--revs',
      '--delta-base-offset',
      '-q',
    ], stdin: '$tip\n');
    return (tip, Uint8List.fromList(pack.stdout as List<int>));
  } catch (_) {
    return null;
  } finally {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  }
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
