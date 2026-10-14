import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';

/// Script plugins (docs/SCRIPTING.md): JavaScript run by the `js` runtime
/// plugin (plugins/js, shipped in app/assets/plugins), through the real
/// native host. Set OURNET_SCRIPT_BENCH=1 to also compare start time, a
/// noughts-and-crosses move and a pong frame against the Rust versions.
void main() {
  final runtime = File(
    '../app/assets/plugins/js.ournet-plugin',
  ).readAsBytesSync();
  final tictactoe = File(
    'test/fixtures/js-tictactoe.ournet-plugin',
  ).readAsBytesSync();
  late Directory temp;
  final cleanup = <Future<void> Function()>[];

  setUp(() => temp = Directory.systemTemp.createTempSync('ournet-scripts'));
  tearDown(() async {
    for (final c in cleanup.reversed) {
      await c();
    }
    cleanup.clear();
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<(Node, Plugins)> device({String? cache}) async {
    final node = Node(await LocalIdentity.create(), Store());
    final plugins = Plugins(
      node,
      directory: '${temp.path}/${node.person.substring(0, 8)}',
      cache: cache ?? sharedCache,
    );
    cleanup.add(() async {
      await plugins.close();
      await node.close();
    });
    return (node, plugins);
  }

  Future<void> status(
    Plugins plugins,
    String id,
    PluginStatus wanted, {
    Duration within = const Duration(seconds: 60),
  }) async {
    final deadline = DateTime.now().add(within);
    while (plugins[id]?.status != wanted) {
      if (wanted != PluginStatus.failed &&
          plugins[id]?.status == PluginStatus.failed) {
        fail('$id failed: ${plugins[id]!.error}');
      }
      if (DateTime.now().isAfter(deadline)) {
        fail('$id is ${plugins[id]?.status}, not $wanted');
      }
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  Future<Json> until(
    Plugins plugins,
    String id,
    String surface,
    bool Function(Json data) done,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!done(plugins.surface(id, surface))) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Timed out; $surface is ${plugins.surface(id, surface)}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    return plugins.surface(id, surface);
  }

  /// A script plugin made here: [main] as `scripts/main.js`.
  PluginPackage script(
    String main, {
    String id = 'probe',
    List<String> grants = const [],
    Map<String, String> more = const {},
  }) => PluginPackage.of({
    'manifest.json': utf8.encode(
      jsonEncode({
        'id': id,
        'name': 'Probe',
        'version': '0.1.0',
        'api': '0.1',
        'runtime': 'js@1',
        'grants': grants,
        'kinds': {
          'note': {
            'text': {'type': 'string', 'max': 100},
          },
        },
      }),
    ),
    'scripts/main.js': utf8.encode(main),
    for (final MapEntry(:key, :value) in more.entries) key: utf8.encode(value),
  });

  test('packages: a script plugin carries scripts, a runtime only code', () {
    final r = PluginPackage.read(runtime);
    expect(r.manifest.provides, 'runtime:js@1');
    expect(r.manifest.isRuntime, isTrue);
    expect(r.wasm, isNotNull);
    final t = PluginPackage.read(tictactoe);
    expect(t.manifest.runtime, 'js@1');
    expect(t.wasm, isNull);
    expect(t.scripts.keys, ['scripts/main.js']);
    expect(t.scripts.values.single, contains('export function onEvent'));
    // A runtime asks for nothing itself.
    expect(
      () => PluginManifest.parse({
        'id': 'bad',
        'name': 'Bad',
        'version': '1.0.0',
        'api': '0.1',
        'provides': 'runtime:js@1',
        'grants': ['live'],
      }),
      throwsFormatException,
    );
    // Scripts and a component do not mix.
    expect(
      () => PluginPackage.of({
        ...t.files,
        'plugin.wasm': Uint8List.fromList([0, 97, 115, 109]),
      }),
      throwsFormatException,
    );
  });

  test('a script plugin waits for its runtime, then runs', () async {
    final (_, plugins) = await device();
    await plugins.install(
      script('''
export function onOpen(surface, context) {
  ournet.ui.update(surface, { scope: context.scope, sum: [1, 2, 3].reduce((a, b) => a + b) });
}
'''),
      grants: {},
    );
    await status(plugins, 'probe', PluginStatus.failed);
    expect(plugins['probe']!.error, contains('js@1'));

    await plugins.install(PluginPackage.read(runtime), grants: {});
    expect(plugins['js']!.status, PluginStatus.stopped);
    await status(plugins, 'probe', PluginStatus.running);
    plugins.open('probe', 'Main', {'scope': 'personal'});
    final shown = await until(
      plugins,
      'probe',
      'Main',
      (d) => d['sum'] != null,
    );
    expect(shown, {'scope': 'personal', 'sum': 6});

    // Without the runtime it stops again.
    await plugins.uninstall('js');
    expect(plugins['probe']!.status, PluginStatus.failed);
  });

  test('grants are held to on every call', () async {
    final (node, plugins) = await device();
    await plugins.install(PluginPackage.read(runtime), grants: {});
    const probe = '''
export function onEvent(surface, name) {
  const tried = {};
  try { tried.published = ournet.publish("x.probe.note", "x.probe", "personal", { text: "hi" }); }
  catch (e) { tried.publish = e.message; }
  tried.me = ournet.me();
  tried.contacts = ournet.contacts().length;
  ournet.ui.update(surface, tried);
}
''';
    await plugins.install(script(probe), grants: {});
    await status(plugins, 'probe', PluginStatus.running);
    plugins.event('probe', 'Main', 'try', {});
    final refused = await until(
      plugins,
      'probe',
      'Main',
      (d) => d['me'] != null,
    );
    expect(refused['publish'], contains('objects was not granted'));
    expect(refused['me'], '');

    await plugins.install(
      script(probe, grants: ['objects', 'identity']),
      grants: {'objects', 'identity'},
    );
    await status(plugins, 'probe', PluginStatus.running);
    plugins.event('probe', 'Main', 'try', {});
    final allowed = await until(
      plugins,
      'probe',
      'Main',
      (d) => d['published'] != null,
    );
    expect(allowed['me'], node.person);
    expect(
      node.store.get(allowed['published'] as String)!.kind,
      'x.probe.note',
    );
  });

  test('handlers that throw are logged; promises settle from timers', () async {
    final (_, plugins) = await device();
    await plugins.install(PluginPackage.read(runtime), grants: {});
    final logged = <String>[];
    final logs = plugins.notices.listen((n) {
      if (n.kind == 'log') logged.add('${n.title}: ${n.body}');
    });
    cleanup.add(logs.cancel);
    await plugins.install(
      script(
        '''
import { twice } from "./lib/maths.js";
let count = 0;
export async function onEvent(surface, name) {
  if (name === "throw") throw new TypeError("on purpose");
  if (name === "wait") {
    const began = Date.now();
    await ournet.sleep(30);
    setTimeout((x) => ournet.ui.update(surface, { later: x }), 5, "set");
    ournet.ui.update(surface, { slept: Date.now() - began >= 25, count: twice(++count) });
  }
  if (name === "read") ournet.ui.update(surface, { asset: ournet.text(ournet.read("assets/words.txt")) });
}
''',
        more: {
          'scripts/lib/maths.js': 'export const twice = (n) => n * 2;',
          'assets/words.txt': 'hello there',
        },
      ),
      grants: {},
    );
    await status(plugins, 'probe', PluginStatus.running);
    plugins.event('probe', 'Main', 'throw', {});
    plugins.event('probe', 'Main', 'wait', {});
    final waited = await until(
      plugins,
      'probe',
      'Main',
      (d) => d['later'] != null,
    );
    expect(waited, {'slept': true, 'count': 2, 'later': 'set'});
    expect(logged.join('\n'), contains('on purpose'));
    expect(plugins['probe']!.status, PluginStatus.running);
    plugins.event('probe', 'Main', 'read', {});
    expect(
      (await until(
        plugins,
        'probe',
        'Main',
        (d) => d['asset'] != null,
      ))['asset'],
      'hello there',
    );
    expect((await plugins.scriptsOf('probe')).keys, [
      'scripts/lib/maths.js',
      'scripts/main.js',
    ]);
  });

  test('a script that does not load fails with its error', () async {
    final (_, plugins) = await device();
    final logged = <String>[];
    final logs = plugins.notices.listen((n) => logged.add(n.body));
    cleanup.add(logs.cancel);
    await plugins.install(PluginPackage.read(runtime), grants: {});
    await plugins.install(script('export function init( {'), grants: {});
    await status(plugins, 'probe', PluginStatus.failed);
    expect(logged.join('\n'), contains('SyntaxError'));
  });

  test('noughts and crosses in JavaScript', () async {
    final (a, plugins) = await device();
    final (b, _) = await device();
    await a.addContact(b.identity.certificate);
    await plugins.install(PluginPackage.read(runtime), grants: {});
    await plugins.install(
      PluginPackage.read(tictactoe),
      grants: {'objects', 'identity'},
    );
    await status(plugins, 'js-tictactoe', PluginStatus.running);
    plugins.open('js-tictactoe', 'Games', {'scope': 'personal'});
    await until(plugins, 'js-tictactoe', 'Games', (d) => d['mode'] == 'lobby');
    plugins.event('js-tictactoe', 'Games', 'start', {'person': b.person});
    await until(plugins, 'js-tictactoe', 'Games', (d) => d['mode'] == 'board');
    plugins.event('js-tictactoe', 'Games', 'play', {'cell': 4});
    final board =
        (await until(
              plugins,
              'js-tictactoe',
              'Games',
              (d) => (d['board'] as Map)['status'] == 'Their turn',
            ))['board']
            as Map;
    expect(((board['rows'] as List)[1] as List)[1], {'i': 4, 'mark': 'X'});
  });

  test(
    'compared with Rust',
    skip: Platform.environment['OURNET_SCRIPT_BENCH'] == null
        ? 'set OURNET_SCRIPT_BENCH=1'
        : false,
    timeout: const Timeout(Duration(minutes: 10)),
    () async {
      final assets = '../app/assets/plugins';
      final rustTicTacToe = File(
        '$assets/tictactoe.ournet-plugin',
      ).readAsBytesSync();
      final rustPong = File('$assets/pong.ournet-plugin').readAsBytesSync();
      final jsPong = File(
        'test/fixtures/js-pong.ournet-plugin',
      ).readAsBytesSync();
      final report = StringBuffer();
      List<double> sorted(List<double> xs) => [...xs]..sort();
      double median(List<double> xs) => sorted(xs)[xs.length ~/ 2];
      double p95(List<double> xs) => sorted(xs)[(xs.length * 0.95).floor()];

      report.writeln(
        'Package size (zipped): '
        'runtime ${runtime.length} B; '
        'tictactoe Rust ${rustTicTacToe.length} B, JS ${tictactoe.length} B; '
        'pong Rust ${rustPong.length} B, JS ${jsPong.length} B',
      );

      // Waits for [done] after [act], woken by the plugin's changes rather
      // than polling (Windows sleeps in 15.6 ms steps); returns the ms.
      Future<double> timed(
        Plugins plugins,
        FutureOr<void> Function() act,
        bool Function() done,
      ) async {
        final reached = Completer<void>();
        final watch = plugins.changes.listen((_) {
          if (!reached.isCompleted && done()) reached.complete();
        });
        final timer = Stopwatch()..start();
        await act();
        if (!reached.isCompleted && done()) reached.complete();
        await reached.future.timeout(const Duration(seconds: 60));
        timer.stop();
        await watch.cancel();
        return timer.elapsedMicroseconds / 1000;
      }

      String stats(List<double> xs, [int digits = 1]) =>
          'median ${median(xs).toStringAsFixed(digits)} '
          '(p95 ${p95(xs).toStringAsFixed(digits)})';

      // Start: install to running, with nothing compiled (cold) and with
      // the compile cache filled (warm: every start after the first). Wall
      // time includes instantiating and `init` (which asks the app for
      // this person); CPU is `init`'s own.
      for (final (name, id, package, grants) in [
        ('tictactoe Rust', 'tictactoe', rustTicTacToe, {'objects', 'identity'}),
        ('tictactoe JS', 'js-tictactoe', tictactoe, {'objects', 'identity'}),
        ('pong Rust', 'pong', rustPong, {'identity', 'live'}),
        ('pong JS', 'js-pong', jsPong, {'identity', 'live'}),
      ]) {
        final cache = '${temp.path}/cache-$id';
        final (_, plugins) = await device(cache: cache);
        if (id.startsWith('js-')) {
          await plugins.install(PluginPackage.read(runtime), grants: {});
        }
        bool up() => plugins[id]?.status == PluginStatus.running;
        final cold = await timed(
          plugins,
          () => plugins.install(PluginPackage.read(package), grants: grants),
          up,
        );
        final warm = <double>[], init = <double>[];
        for (var i = 0; i < 20; i++) {
          warm.add(await timed(plugins, () => plugins.restart(id), up));
          init.add((await plugins.usage(id)).busy.inMicroseconds / 1000);
        }
        report.writeln(
          'Start, $name: cold ${cold.toStringAsFixed(0)} ms; '
          'warm ${stats(warm)} ms; init CPU ${stats(init, 2)} ms',
        );
      }

      // A move: the event, the signed move published, stored, fed back in
      // as new objects and the board shown again. CPU is the plugin's
      // share of that (both calls), waits on the app excluded.
      for (final (name, id, package) in [
        ('tictactoe Rust', 'tictactoe', rustTicTacToe),
        ('tictactoe JS', 'js-tictactoe', tictactoe),
      ]) {
        final (a, plugins) = await device();
        if (id.startsWith('js-')) {
          await plugins.install(PluginPackage.read(runtime), grants: {});
        }
        await plugins.install(
          PluginPackage.read(package),
          grants: {'objects', 'identity'},
        );
        await status(plugins, id, PluginStatus.running);
        plugins.open(id, 'Games', {'scope': 'personal'});
        Json shown() => plugins.surface(id, 'Games');
        final moves = <double>[], cpu = <double>[];
        for (var game = 0; game < 20; game++) {
          final (b, _) = await device();
          await a.addContact(b.identity.certificate);
          await timed(
            plugins,
            () => plugins.event(id, 'Games', 'back', {}),
            () => shown()['mode'] == 'lobby',
          );
          await timed(
            plugins,
            () => plugins.event(id, 'Games', 'start', {'person': b.person}),
            () =>
                shown()['mode'] == 'board' &&
                (shown()['board'] as Map)['opponent'] == b.person,
          );
          final before = (await plugins.usage(id)).busy;
          moves.add(
            await timed(
              plugins,
              () => plugins.event(id, 'Games', 'play', {'cell': game % 9}),
              () => (shown()['board'] as Map)['status'] == 'Their turn',
            ),
          );
          final after = (await plugins.usage(id)).busy;
          cpu.add((after - before).inMicroseconds / 1000);
        }
        report.writeln(
          'Move, $name (${moves.length} games): wall ${stats(moves)} ms; '
          'plugin CPU ${stats(cpu, 2)} ms',
        );
      }

      // Pong frames in practice: the 30 Hz tick steps the ball, draws the
      // court and sends it to the app.
      for (final (name, id, package) in [
        ('pong Rust', 'pong', rustPong),
        ('pong JS', 'js-pong', jsPong),
      ]) {
        final (_, plugins) = await device();
        if (id.startsWith('js-')) {
          await plugins.install(PluginPackage.read(runtime), grants: {});
        }
        await plugins.install(
          PluginPackage.read(package),
          grants: {'identity', 'live'},
        );
        await status(plugins, id, PluginStatus.running);
        var frames = 0;
        final watch = plugins.changes.listen((changed) {
          if (changed == id && plugins.surface(id, 'Pong')['mode'] == 'game') {
            frames++;
          }
        });
        plugins.event(id, 'Pong', 'practice', {});
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final before = await plugins.usage(id);
        final counted = frames;
        await Future<void>.delayed(const Duration(seconds: 10));
        final after = await plugins.usage(id);
        await watch.cancel();
        plugins.event(id, 'Pong', 'leave', {});
        final calls = after.calls - before.calls;
        final busy = (after.busy - before.busy).inMicroseconds / 1000;
        report.writeln(
          'Frame, $name: ${frames - counted} frames in 10 s; '
          'CPU ${(busy / calls).toStringAsFixed(3)} ms a frame '
          '(${(busy / 100).toStringAsFixed(2)}% of one core)',
        );
      }
      // ignore: avoid_print
      print(report);
    },
  );
}

final sharedCache = '${Directory.systemTemp.path}/ournet-plugin-cache';
