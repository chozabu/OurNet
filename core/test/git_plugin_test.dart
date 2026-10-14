import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';

/// The Git plugin (plugins/git) through the real native host and the local
/// bridge, driven by real git with `git-remote-ournet` (built by
/// `cargo build --release -p git-remote-ournet` in plugins/). Skipped where
/// either is missing.
void main() {
  final package = File('test/fixtures/git.ournet-plugin').readAsBytesSync();
  const grants = {'objects', 'identity', 'local'};
  final helperDir = Directory('../plugins/target/release').absolute.path;
  final helper = File(
    '$helperDir/git-remote-ournet${Platform.isWindows ? '.exe' : ''}',
  );
  final hasGit = () {
    try {
      return Process.runSync('git', ['--version']).exitCode == 0;
    } catch (_) {
      return false;
    }
  }();
  final skip = !hasGit
      ? 'git is not installed'
      : !helper.existsSync()
      ? 'build git-remote-ournet first (cargo build --release -p git-remote-ournet in plugins/)'
      : false;

  late Directory temp;
  final cleanup = <Future<void> Function()>[];
  setUp(() => temp = Directory.systemTemp.createTempSync('ournet-git'));
  tearDown(() async {
    for (final c in cleanup.reversed) {
      await c();
    }
    cleanup.clear();
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<(Node, Plugins, LocalBridge)> device() async {
    final node = Node(await LocalIdentity.create(), Store());
    final plugins = Plugins(
      node,
      directory: '${temp.path}/plugins',
      cache: '${Directory.systemTemp.path}/ournet-plugin-cache',
    );
    final bridge = LocalBridge(plugins, path: '${temp.path}/bridge.json');
    cleanup.add(() async {
      await bridge.close();
      await plugins.close();
      await node.close();
    });
    await plugins.install(PluginPackage.read(package), grants: grants);
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (plugins['git']?.status != PluginStatus.running) {
      if (plugins['git']?.status == PluginStatus.failed) {
        fail('Failed: ${plugins['git']!.error}');
      }
      if (DateTime.now().isAfter(deadline)) fail('Did not start');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await bridge.sync();
    return (node, plugins, bridge);
  }

  Future<Json> until(Plugins plugins, bool Function(Json data) done) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!done(plugins.surface('git', 'Git'))) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Timed out; surface is ${plugins.surface('git', 'Git')}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return plugins.surface('git', 'Git');
  }

  Future<ProcessResult> git(List<String> args, {String? dir}) async {
    final env = {
      'PATH':
          '$helperDir${Platform.isWindows ? ';' : ':'}${Platform.environment['PATH']}',
      'OURNET_BRIDGE': '${temp.path}/bridge.json',
      'GIT_AUTHOR_NAME': 'Ada',
      'GIT_AUTHOR_EMAIL': 'ada@example.com',
      'GIT_COMMITTER_NAME': 'Ada',
      'GIT_COMMITTER_EMAIL': 'ada@example.com',
      'GIT_TERMINAL_PROMPT': '0',
    };
    return Process.run(
      'git',
      ['-c', 'init.defaultBranch=main', '-c', 'core.autocrlf=false', ...args],
      workingDirectory: dir ?? temp.path,
      environment: env,
    );
  }

  Future<void> ok(List<String> args, {String? dir}) async {
    final r = await git(args, dir: dir);
    expect(r.exitCode, 0, reason: 'git ${args.join(' ')}: ${r.stderr}');
  }

  Future<String> createRepo(Plugins plugins, String name) async {
    plugins.open('git', 'Git', {'scope': 'personal'});
    await until(plugins, (d) => d['mode'] == 'list');
    plugins.event('git', 'Git', 'new', {});
    plugins.event('git', 'Git', 'draftName', {'value': name});
    plugins.event('git', 'Git', 'draftDescription', {'value': 'A test'});
    plugins.event('git', 'Git', 'create', {});
    final shown = await until(plugins, (d) => d['mode'] == 'repo');
    return (shown['repo'] as Map)['url'] as String;
  }

  test('the bridge refuses requests without its key', () async {
    final (_, _, bridge) = await device();
    expect(bridge.port, isNotNull);
    final written = jsonDecode(
      File('${temp.path}/bridge.json').readAsStringSync(),
    );
    expect(written['port'], bridge.port);
    final client = HttpClient();
    addTearDown(client.close);
    Future<(int, String)> post(String path, Map<String, String> headers) async {
      final request = await client.post('127.0.0.1', bridge.port!, path);
      headers.forEach(request.headers.set);
      request.add(utf8.encode('{"op":"repos"}\n'));
      final response = await request.close();
      return (response.statusCode, await utf8.decodeStream(response));
    }

    expect((await post('/plugins/git', {})).$1, HttpStatus.unauthorized);
    expect(
      (await post('/plugins/git', {'authorization': 'Bearer nope'})).$1,
      HttpStatus.unauthorized,
    );
    final key = {'authorization': 'Bearer ${written['token']}'};
    expect(
      (await post('/plugins/git', {...key, 'host': 'evil.example'})).$1,
      HttpStatus.forbidden,
    );
    expect((await post('/plugins/echo', key)).$1, HttpStatus.badRequest);
    final (status, body) = await post('/plugins/git', key);
    expect(status, HttpStatus.ok);
    expect(body, startsWith('{"repos":[]}'));
  });

  test('git pushes to and clones from a repository', () async {
    final (node, plugins, _) = await device();
    final url = await createRepo(plugins, 'demo');
    expect(url, startsWith('ournet://'));

    final work = '${temp.path}/work';
    await ok(['init', work]);
    File(
      '$work/README.md',
    ).writeAsStringSync('# Demo\n\nHello from **git**.\n');
    Directory('$work/src').createSync();
    File('$work/src/a.txt').writeAsStringSync('one\ntwo\nthree\n');
    await ok(['add', '.'], dir: work);
    await ok(['commit', '-m', 'First'], dir: work);
    File('$work/src/a.txt').writeAsStringSync('one\nTWO\nthree\n');
    await ok(['commit', '-am', 'Second'], dir: work);
    await ok(['push', 'ournet://demo', 'main'], dir: work);

    final pushes = node.store.allOf(kind: 'x.git.push');
    expect(pushes, hasLength(1));
    expect(pushes.single.audience, [node.person]);

    // The page reads the pack: files, README and the newest commit.
    final code = await until(
      plugins,
      (d) => (d['entries'] as List?)?.isNotEmpty ?? false,
    );
    expect(
      [for (final e in code['entries'] as List) e['name']],
      ['src', 'README.md'],
    );
    expect(code['readme'], contains('Hello from'));
    expect((code['last'] as Map)['title'], 'Second');

    plugins.event('git', 'Git', 'tab', {'tab': 'commits'});
    final commits = await until(
      plugins,
      (d) => (d['commits'] as List?)?.length == 2,
    );
    final newest = (commits['commits'] as List).first as Map;
    plugins.event('git', 'Git', 'commit', {'sha': newest['sha']});
    final diff = await until(plugins, (d) => d['mode'] == 'commit');
    final lines = [for (final l in diff['diff'] as List) l['text']];
    expect(lines, containsAllInOrder(['Changed src/a.txt', '-two', '+TWO']));

    await ok(['clone', url, 'copy']);
    expect(
      File('${temp.path}/copy/src/a.txt').readAsStringSync(),
      'one\nTWO\nthree\n',
    );
    final log = await git(['log', '--format=%s'], dir: '${temp.path}/copy');
    expect('${log.stdout}'.trim().split('\n'), ['Second', 'First']);

    // A rewritten history is refused unless forced.
    await ok(['commit', '--amend', '-m', 'Rewritten'], dir: work);
    final refused = await git(['push', url, 'main'], dir: work);
    expect(refused.exitCode, isNot(0));
    await ok(['push', url, '+main'], dir: work);
    await ok(['fetch', 'origin'], dir: '${temp.path}/copy');
    final fetched = await git([
      'log',
      '-1',
      '--format=%s',
      'origin/main',
    ], dir: '${temp.path}/copy');
    expect('${fetched.stdout}'.trim(), 'Rewritten');

    plugins.event('git', 'Git', 'tab', {'tab': 'pushes'});
    final history = await until(
      plugins,
      (d) => (d['pushes'] as List?)?.length == 2,
    );
    expect(
      ((history['pushes'] as List).first as Map)['summary'],
      contains('(forced)'),
    );
  }, skip: skip);

  test('a large push travels in chunks', () async {
    final (node, plugins, _) = await device();
    final url = await createRepo(plugins, 'big');
    final work = '${temp.path}/big';
    await ok(['init', work]);
    // Random bytes do not compress: about four chunks.
    final rng = Random(42);
    final random = Uint8List.fromList(
      List.generate(170 * 1024, (_) => rng.nextInt(256)),
    );
    File('$work/blob.bin').writeAsBytesSync(random);
    await ok(['add', '.'], dir: work);
    await ok(['commit', '-m', 'Big'], dir: work);
    await ok(['push', url, 'main'], dir: work);
    expect(node.store.allOf(kind: 'x.git.chunk').length, greaterThan(1));
    await ok(['clone', url, 'big-copy']);
    expect(File('${temp.path}/big-copy/blob.bin').readAsBytesSync(), random);
    final code = await until(
      plugins,
      (d) => (d['entries'] as List?)?.isNotEmpty ?? false,
    );
    expect((code['entries'] as List).single['name'], 'blob.bin');
  }, skip: skip);
}
