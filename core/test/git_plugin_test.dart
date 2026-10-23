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
    plugins.storeFileStream = (source, size, name) async {
      final key = randomBytes(32);
      final tree = ChunkTreeBuilder(
        listFanOut(Plugins.fileChunkBytes),
        (plain) => node.blobs.encode(plain, key),
      );
      var stored = 0;
      await for (final chunk in rechunk(source, Plugins.fileChunkBytes)) {
        stored += chunk.length;
        if (stored > size) throw StateError('Wrong file length');
        await tree.add(await node.blobs.encode(Uint8List.fromList(chunk), key));
      }
      if (stored != size) throw StateError('Wrong file length');
      return {
        'name': name,
        'size': size,
        'chunkBytes': Plugins.fileChunkBytes,
        'key': b64(key),
        ...await tree.finish(),
      };
    };
    plugins.openFileStream = (object) async* {
      final payload = (await node.content(object))!;
      final key = payload['key'] is String
          ? unb64(payload['key'] as String)
          : null;
      Future<Uint8List> read(String hash) async =>
          (await node.blobs.readLocal([hash], key))!;
      await for (final segment in chunkSegments(payload, read)) {
        for (final hash in segment) {
          yield await read(hash);
        }
      }
    };
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

  Future<Json> until(
    Plugins plugins,
    bool Function(Json data) done, {
    Duration limit = const Duration(seconds: 30),
  }) async {
    final deadline = DateTime.now().add(limit);
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
    expect((await post('/plugins/git/files', {})).$1, HttpStatus.unauthorized);
    expect((await post('/plugins/echo/files', key)).$1, HttpStatus.badRequest);
    // Chunked uploads without an exact length cannot claim an unbounded size.
    expect((await post('/plugins/git/files', key)).$1, HttpStatus.badRequest);
    final (status, body) = await post('/plugins/git', key);
    expect(status, HttpStatus.ok);
    expect(body, startsWith('{"repos":[]}'));
  });

  test('a repository holding a script plugin installs as one', () async {
    final (node, plugins, _) = await device();
    await createRepo(plugins, 'game');
    final offered = <PluginOffered>[];
    final watch = plugins.offered.listen(offered.add);
    addTearDown(watch.cancel);

    final work = '${temp.path}/game';
    await ok(['init', work]);
    final archive = PluginPackage.read(
      File('test/fixtures/js-tictactoe.ournet-plugin').readAsBytesSync(),
    );
    for (final MapEntry(:key, :value) in archive.files.entries) {
      File('$work/$key')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(value);
    }
    File('$work/README.md').writeAsStringSync('# Noughts and crosses\n');
    await ok(['add', '.'], dir: work);
    await ok(['commit', '-m', 'A game'], dir: work);
    await ok(['tag', 'v0.1.0'], dir: work);
    await ok(['push', 'ournet://game', 'main', 'v0.1.0'], dir: work);

    final code = await until(plugins, (d) => '${d['plugin']}'.isNotEmpty);
    expect(code['plugin'], 'Noughts and crosses (JS) 0.1.0, a script plugin');
    plugins.event('git', 'Git', 'branch', {'ref': 'refs/tags/v0.1.0'});
    await until(plugins, (d) => d['branch'] == 'refs/tags/v0.1.0');
    plugins.event('git', 'Git', 'install', {});
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (offered.isEmpty) {
      expect(DateTime.now().isBefore(deadline), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final o = offered.single;
    expect(o.from, 'git');
    expect(o.package.manifest.id, 'js-tictactoe');
    expect(o.package.digest, archive.digest);
    final git = o.source['git'] as Map;
    expect(git['repo'], 'game');
    expect(git['ref'], 'refs/tags/v0.1.0');
    expect(git['pusher'], node.person);
    expect(git['commit'], hasLength(40));

    await plugins.install(
      PluginPackage.read(
        File('../app/assets/plugins/js.ournet-plugin').readAsBytesSync(),
      ),
      grants: {},
    );
    await plugins.install(
      o.package,
      grants: o.package.manifest.grants,
      source: o.source,
    );
    expect(plugins['js-tictactoe']!.source, o.source);
    final started = DateTime.now().add(const Duration(seconds: 60));
    while (plugins['js-tictactoe']!.status != PluginStatus.running) {
      expect(DateTime.now().isBefore(started), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }, skip: skip);

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
    final tip = await git(['rev-parse', 'HEAD'], dir: work);
    final tags = await Process.start('git', [
      'update-ref',
      '--stdin',
    ], workingDirectory: work);
    for (var i = 0; i < 130; i++) {
      tags.stdin.writeln(
        'create refs/tags/test$i ${tip.stdout.toString().trim()}',
      );
    }
    await tags.stdin.close();
    expect(await tags.exitCode, 0);
    await ok(['push', 'ournet://demo', 'main', '--tags'], dir: work);

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
    expect(code['refCount'], 131);
    plugins.event('git', 'Git', 'branches', {});
    final firstRefs = await until(
      plugins,
      (d) => (d['branches'] as List?)?.length == 50,
    );
    expect(firstRefs['moreBranches'], isTrue);
    plugins.event('git', 'Git', 'nextBranches', {});
    final nextRefs = await until(plugins, (d) => d['previousBranches'] == true);
    expect(
      (nextRefs['branches'] as List).first,
      isNot((firstRefs['branches'] as List).first),
    );
    plugins.event('git', 'Git', 'branchFilter', {'value': 'test12'});
    await until(plugins, (d) => (d['branches'] as List?)?.length == 11);
    plugins.event('git', 'Git', 'branchFilter', {'value': ''});
    await until(
      plugins,
      (d) =>
          (d['branches'] as List?)?.length == 50 &&
          d['previousBranches'] == false,
    );
    plugins.event('git', 'Git', 'branches', {});

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

  test('Markdown links and image blobs stay pinned to their repository commit', () async {
    final (_, plugins, _) = await device();
    final url = await createRepo(plugins, 'markdown');
    final work = '${temp.path}/markdown';
    await ok(['init', work]);
    File('$work/README.md').writeAsStringSync('# Readme\n[Guide](docs/guide.md)\n![Picture](docs/pic.png)\n');
    Directory('$work/docs').createSync();
    File('$work/docs/guide.md').writeAsStringSync('# Guide\n[Back](../README.md)\n');
    File('$work/docs/pic.png').writeAsBytesSync([1, 2, 3, 4]);
    await ok(['add', '.'], dir: work);
    await ok(['commit', '-m', 'Markdown and image'], dir: work);
    final first = (await git(['rev-parse', 'HEAD'], dir: work)).stdout.toString().trim();
    await ok(['push', url, 'main'], dir: work);
    final shown = await until(plugins, (d) => d['markdownCommit'] == first && '${d['readme']}'.contains('# Readme'));
    expect(shown['markdownDirectory'], '');
    Future<Uint8List> blob(String commit, String path) async {
      final answer = await plugins.local('git', Uint8List.fromList(utf8.encode('${jsonEncode({
        'op': 'blob', 'repo': url, 'commit': commit, 'path': path,
      })}\n')));
      return Uint8List.sublistView(answer, answer.indexOf(10) + 1);
    }
    expect(await blob(first, 'docs/pic.png'), [1, 2, 3, 4]);
    await expectLater(blob(first, '../private'), throwsStateError);
    await expectLater(blob(first, 'docs'), throwsStateError);
    plugins.event('git', 'Git', 'markdownLink', {'target': 'docs/guide.md', 'commit': first});
    final guide = await until(plugins, (d) => d['mode'] == 'file' && (d['file'] as Map?)?['name'] == 'guide.md');
    expect((guide['file'] as Map)['markdown'], true);
    expect(guide['markdownDirectory'], 'docs');
    expect(guide['markdownCommit'], first);
    File('$work/docs/pic.png').writeAsBytesSync([5, 6, 7, 8]);
    await ok(['add', '.'], dir: work);
    await ok(['commit', '-m', 'Replace picture'], dir: work);
    final second = (await git(['rev-parse', 'HEAD'], dir: work)).stdout.toString().trim();
    await ok(['push', url, 'main'], dir: work);
    await until(plugins, (d) => !'${(d['repo'] as Map?)?['notice']}'.contains('Reading'));
    expect(await blob(first, 'docs/pic.png'), [1, 2, 3, 4]);
    // Wait for the new commit's derived object index, independently of UI focus.
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (true) {
      try { expect(await blob(second, 'docs/pic.png'), [5, 6, 7, 8]); break; }
      on StateError { if (DateTime.now().isAfter(deadline)) rethrow; await Future<void>.delayed(const Duration(milliseconds: 20)); }
    }
    expect(plugins.surface('git', 'Git')['markdownCommit'], first);
  }, skip: skip);

  test('deletion retires old pushes and the same name starts fresh', () async {
    final (node, plugins, _) = await device();
    await createRepo(plugins, 'retired');
    await node.publish(
      'x.git.push',
      {
        'repo': 'retired',
        'refs': {'refs/heads/old': 'a' * 40},
        'old': {'refs/heads/old': ''},
        'size': 0,
        'objects': 0,
      },
      space: 'x.git',
      audience: [node.person],
    );
    await until(plugins, (d) => d['empty'] == false);
    plugins.event('git', 'Git', 'tab', {'tab': 'settings'});
    await until(plugins, (d) => d['tab'] == 'settings');
    plugins.event('git', 'Git', 'delete', {});
    await until(
      plugins,
      (d) => '${d['error']}'.contains('Type the repository name'),
    );
    expect(node.store.allOf(kind: 'x.git.delete'), isEmpty);
    plugins.event('git', 'Git', 'deleteName', {'value': 'retired'});
    plugins.event('git', 'Git', 'delete', {});
    final removed = await until(
      plugins,
      (d) => d['mode'] == 'list' && d['empty'] == true,
    );
    expect(removed['repos'], isEmpty);
    expect(node.store.allOf(kind: 'x.git.delete'), hasLength(1));
    await plugins.restart('git');
    await until(plugins, (_) => plugins['git']?.status == PluginStatus.running);
    plugins.open('git', 'Git', {'scope': 'personal'});
    await until(plugins, (d) => d['mode'] == 'list' && d['empty'] == true);
    await createRepo(plugins, 'retired');
    final fresh = await until(plugins, (d) => d['mode'] == 'repo');
    expect(fresh['empty'], isTrue);
    plugins.event('git', 'Git', 'repair', {});
    await until(plugins, (d) => '${d['error']}'.contains('Rebuilding'));
    expect(node.store.allOf(kind: 'x.git.delete'), hasLength(1));
    await plugins.restart('git');
    await until(plugins, (_) => plugins['git']?.status == PluginStatus.running);
    plugins.open('git', 'Git', {'scope': 'personal'});
    final repositories = await until(
      plugins,
      (d) => d['mode'] == 'list' && (d['repos'] as List?)?.length == 1,
    );
    final repo = (repositories['repos'] as List).single as Map;
    plugins.event('git', 'Git', 'open', {'key': repo['key']});
    await until(plugins, (d) => d['mode'] == 'repo' && d['empty'] == true);
  });

  test(
    'a pack larger than the old 16 MiB limit pushes and clones',
    () async {
      final (_, plugins, _) = await device();
      final url = await createRepo(plugins, 'unbounded');
      final work = '${temp.path}/unbounded';
      await ok(['init', work]);
      final random = Random(7);
      final bytes = Uint8List.fromList(
        List.generate(17 * 1024 * 1024, (_) => random.nextInt(256)),
      );
      File('$work/large.bin').writeAsBytesSync(bytes);
      await ok(['add', '.'], dir: work);
      await ok(['commit', '-m', 'Beyond the old limit'], dir: work);
      await ok(['push', url, 'main'], dir: work);
      final shown = await until(
        plugins,
        (d) => (d['entries'] as List?)?.isNotEmpty ?? false,
      );
      expect((shown['entries'] as List).single['name'], 'large.bin');
      expect((shown['last'] as Map)['title'], 'Beyond the old limit');
      expect(
        (shown['repo'] as Map)['notice'],
        isNot(contains('could not be read')),
      );
      await ok(['clone', url, 'unbounded-copy']);
      expect(
        File('${temp.path}/unbounded-copy/large.bin').readAsBytesSync(),
        bytes,
      );
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'thousands of tags span bounded signed ref records',
    () async {
      final (node, plugins, _) = await device();
      final url = await createRepo(plugins, 'many-tags');
      final work = '${temp.path}/tags';
      await ok(['init', work]);
      File('$work/README.md').writeAsStringSync('# Many tags');
      await ok(['add', '.'], dir: work);
      await ok(['commit', '-m', 'Tags'], dir: work);
      final tip = (await git([
        'rev-parse',
        'HEAD',
      ], dir: work)).stdout.toString().trim();
      final tags = await Process.start('git', [
        'update-ref',
        '--stdin',
      ], workingDirectory: work);
      for (var i = 0; i < 1500; i++) {
        tags.stdin.writeln('create refs/tags/v$i $tip');
      }
      await tags.stdin.close();
      expect(await tags.exitCode, 0);
      await ok(['push', url, 'main', '--tags'], dir: work);
      await until(plugins, (d) => d['refCount'] == 1501);
      expect(node.store.allOf(kind: 'x.git.push').length, greaterThan(1));
      final listed = await git(['ls-remote', url], dir: work);
      expect(listed.exitCode, 0);
      expect(
        listed.stdout.toString().trim().split('\n'),
        hasLength(1502),
      ); // HEAD plus refs
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'the real OurNet checkout pack exposes its files and history',
    () async {
      final (_, plugins, _) = await device();
      final url = await createRepo(plugins, 'checkout');
      final source = Directory('..').absolute.path;
      await ok(['push', url, 'main'], dir: source);
      final shown = await until(
        plugins,
        (d) => (d['entries'] as List?)?.isNotEmpty ?? false,
        limit: const Duration(minutes: 5),
      );
      final names = [for (final e in shown['entries'] as List) e['name']];
      expect(names, containsAll(['app', 'core', 'transport', 'plugins']));
      expect(
        (shown['repo'] as Map)['notice'],
        isNot(contains('could not be read')),
      );
      plugins.event('git', 'Git', 'tab', {'tab': 'commits'});
      await until(plugins, (d) => (d['commits'] as List?)?.isNotEmpty ?? false);
      plugins.event('git', 'Git', 'repair', {});
      await until(plugins, (d) => '${d['error']}'.contains('Rebuilding'));
      // Persisted checkpoints and disk entries survive a host restart.
      await plugins.restart('git');
      await until(
        plugins,
        (_) => plugins['git']?.status == PluginStatus.running,
      );
      plugins.open('git', 'Git', {'scope': 'personal'});
      final repos = await until(plugins, (d) => d['mode'] == 'list');
      plugins.event('git', 'Git', 'open', {
        'key': ((repos['repos'] as List).single as Map)['key'],
      });
      await until(
        plugins,
        (d) => (d['entries'] as List?)?.isNotEmpty ?? false,
        limit: const Duration(minutes: 5),
      );
    },
    skip: skip == false && Platform.environment['OURNET_GIT_SCALE'] != '1'
        ? 'Opt in with OURNET_GIT_SCALE=1 to import the real checkout'
        : skip,
    timeout: const Timeout(Duration(minutes: 12)),
  );

  test("a large push travels as the push's file", () async {
    final (node, plugins, _) = await device();
    final url = await createRepo(plugins, 'big');
    final work = '${temp.path}/big';
    await ok(['init', work]);
    // Random bytes do not compress: two chunks of the file.
    final rng = Random(42);
    final random = Uint8List.fromList(
      List.generate(170 * 1024, (_) => rng.nextInt(256)),
    );
    File('$work/blob.bin').writeAsBytesSync(random);
    await ok(['add', '.'], dir: work);
    await ok(['commit', '-m', 'Big'], dir: work);
    await ok(['push', url, 'main'], dir: work);
    final push = node.store.allOf(kind: 'x.git.push').single;
    final payload = (await node.content(push))!;
    expect(payload['chunks'], hasLength(2));
    expect(payload['name'], 'pack');
    await ok(['clone', url, 'big-copy']);
    expect(File('${temp.path}/big-copy/blob.bin').readAsBytesSync(), random);
    final code = await until(
      plugins,
      (d) => (d['entries'] as List?)?.isNotEmpty ?? false,
    );
    expect((code['entries'] as List).single['name'], 'blob.bin');
  }, skip: skip);
}

Stream<Uint8List> rechunk(Stream<List<int>> source, int size) async* {
  var buffer = Uint8List(size);
  var filled = 0;
  await for (final data in source) {
    var at = 0;
    while (at < data.length) {
      final n = min(size - filled, data.length - at);
      buffer.setRange(filled, filled + n, data, at);
      filled += n;
      at += n;
      if (filled == size) {
        yield buffer;
        buffer = Uint8List(size);
        filled = 0;
      }
    }
  }
  if (filled > 0) yield Uint8List.sublistView(buffer, 0, filled);
}
