import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';

/// The echo plugin (plugins/echo) does one observable thing per event; these
/// tests drive it through the real native host.
void main() {
  final package = File('test/fixtures/echo.ournet-plugin').readAsBytesSync();
  const grants = {'objects', 'identity', 'live', 'tun'};
  late Directory temp;
  final cleanup = <Future<void> Function()>[];

  setUp(() => temp = Directory.systemTemp.createTempSync('ournet-plugins'));
  tearDown(() async {
    for (final c in cleanup.reversed) {
      await c();
    }
    cleanup.clear();
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<(Node, Plugins)> device([String name = 'a']) async {
    final node = Node(await LocalIdentity.create(), Store());
    final plugins = Plugins(
      node,
      directory: '${temp.path}/$name',
      cache: sharedCache,
    );
    cleanup.add(() async {
      await plugins.close();
      await node.close();
    });
    return (node, plugins);
  }

  Future<Json> until(
    Plugins plugins,
    bool Function(Json data) done, {
    String surface = 'Echo',
  }) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!done(plugins.surface('echo', surface))) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Timed out; surface is ${plugins.surface('echo', surface)}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return plugins.surface('echo', surface);
  }

  Future<void> running(Plugins plugins) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (plugins['echo']?.status != PluginStatus.running) {
      if (plugins['echo']?.status == PluginStatus.failed) {
        fail('Failed: ${plugins['echo']!.error}');
      }
      if (DateTime.now().isAfter(deadline)) fail('Did not start');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('the host runs here', () {
    expect(PluginHost.instance, isNotNull);
  });

  test('a package is read and its manifest checked', () {
    final p = PluginPackage.read(package);
    expect(p.manifest.id, 'echo');
    expect(p.manifest.grants, grants);
    expect(p.manifest.kinds.keys, ['x.echo.note']);
    expect(p.manifest.sections.single.id, 'x.echo.echo');
    expect(p.ui, contains('widget Echo'));
    final check = p.manifest.kinds['x.echo.note']!;
    expect(check({'text': 'hi'}), isTrue);
    expect(check({'text': 5}), isFalse);
    expect(check({}), isFalse);
    expect(
      () => PluginPackage.read(Uint8List.fromList([1, 2, 3])),
      throwsFormatException,
    );
  });

  test('a plugin publishes its own kinds and is sent them once', () async {
    final (node, plugins) = await device();
    await plugins.install(PluginPackage.read(package), grants: grants);
    await running(plugins);
    expect(node.registry.sections.single.plugin, 'echo');

    plugins.open('echo', 'Echo', {'scope': 'personal'});
    expect((await until(plugins, (d) => d['me'] != null))['me'], node.person);

    plugins.event('echo', 'Echo', 'publish', {'text': 'first'});
    final published = await until(plugins, (d) => d['published'] != null);
    expect(published['published'], isTrue);
    final object = node.store.get(published['id'] as String)!;
    expect(object.kind, 'x.echo.note');
    expect(object.app, 'echo@0.1.0');
    expect(object.audience, [node.person]);
    expect(
      (await until(
        plugins,
        (d) => (d['seen'] as List?)?.isNotEmpty ?? false,
      ))['seen'],
      ['first'],
    );

    // The manifest's schema is enforced on what it publishes.
    plugins.event('echo', 'Echo', 'invalid', {});
    expect(
      (await until(plugins, (d) => d['refused'] != null))['refused'],
      isTrue,
    );

    plugins.event('echo', 'Echo', 'publish', {'text': 'second'});
    await until(plugins, (d) => (d['seen'] as List?)?.length == 2);
    plugins.event('echo', 'Echo', 'query', {});
    expect((await until(plugins, (d) => d['texts'] != null))['texts'], [
      'second',
      'first',
    ]);
  });

  test('a plugin attaches files to its objects and reads them', () async {
    final (node, plugins) = await device();
    await plugins.install(PluginPackage.read(package), grants: grants);
    await running(plugins);

    plugins.event('echo', 'Echo', 'file', {'text': 'bytes of a file'});
    expect(
      (await until(plugins, (d) => d['fileRead'] != null))['fileRead'],
      'bytes of a file',
    );
    final note = node.store
        .objects(kind: 'x.echo.note', limit: 10)
        .firstWhere((o) => o.app != null);
    final payload = (await node.content(note))!;
    expect(payload['text'], 'with a file');
    expect(payload['name'], 'echo.txt');
    expect(payload['size'], 15);
    expect(payload['chunks'], hasLength(1));
    expect(payload['key'], isA<String>());

    // A picked file comes as a handle; one the host never gave is refused.
    final handle = plugins.addFile('echo', {
      'name': 'picked.txt',
      'size': payload['size'],
      'chunks': payload['chunks'],
      'chunkBytes': payload['chunkBytes'],
      'key': payload['key'],
    })!;
    plugins.event('echo', 'Echo', 'picked', {'file': handle});
    final picked =
        (await until(plugins, (d) => d['pickedId'] != null))['pickedId']
            as String;
    final pickedPayload = (await node.content(node.store.get(picked)!))!;
    expect(pickedPayload['name'], 'picked.txt');
    expect(pickedPayload['text'], 'picked');
    plugins.event('echo', 'Echo', 'picked', {'file': 'f999'});
    expect(
      (await until(
        plugins,
        (d) => '${d['pickedId']}'.startsWith('error'),
      ))['pickedId'],
      contains('store it first'),
    );
  });

  test('timers fire on the plugin thread', () async {
    final (_, plugins) = await device();
    await plugins.install(PluginPackage.read(package), grants: grants);
    await running(plugins);
    plugins.event('echo', 'Echo', 'timer', {});
    expect((await until(plugins, (d) => d['timer'] != null))['timer'], 7);
  });

  test(
    'a looping plugin is stopped, restarts, and keeps its storage',
    () async {
      final (_, plugins) = await device();
      await plugins.install(PluginPackage.read(package), grants: grants);
      await running(plugins);
      final stopped = Completer<void>();
      final watch = plugins.changes.listen((_) {
        if (plugins['echo']!.status == PluginStatus.failed &&
            !stopped.isCompleted) {
          stopped.complete();
        }
      });
      final timer = Stopwatch()..start();
      plugins.event('echo', 'Echo', 'spin', {});
      await stopped.future.timeout(const Duration(seconds: 20));
      await watch.cancel();
      expect(timer.elapsed, lessThan(const Duration(seconds: 10)));
      expect(plugins['echo']!.error, contains('time budget'));

      await plugins.restart('echo');
      await running(plugins);
      plugins.event('echo', 'Echo', 'state', {});
      expect((await until(plugins, (d) => d['starts'] != null))['starts'], 2);
    },
  );

  test('installed plugins start again with the profile', () async {
    final node = Node(await LocalIdentity.create(), Store());
    final first = Plugins(node, directory: temp.path, cache: sharedCache);
    await first.install(PluginPackage.read(package), grants: grants);
    await running(first);
    await first.close();
    final second = Plugins(node, directory: temp.path, cache: sharedCache);
    cleanup.add(() async {
      await second.close();
      await node.close();
    });
    await second.load();
    await running(second);
    second.event('echo', 'Echo', 'state', {});
    expect((await until(second, (d) => d['starts'] != null))['starts'], 2);
  });

  test(
    'a component using an interface it was not granted is refused',
    () async {
      final (_, plugins) = await device();
      // The same code, with a manifest that asks for nothing.
      final archive = ZipDecoder().decodeBytes(package);
      final out = Archive();
      for (final f in archive.files) {
        final bytes = f.readBytes()!;
        if (f.name == 'manifest.json') {
          final m = jsonDecode(utf8.decode(bytes)) as Json..['grants'] = [];
          out.addFile(ArchiveFile.bytes(f.name, utf8.encode(jsonEncode(m))));
        } else {
          out.addFile(ArchiveFile.bytes(f.name, bytes));
        }
      }
      final tampered = PluginPackage.read(
        Uint8List.fromList(ZipEncoder().encodeBytes(out)),
      );
      await plugins.install(tampered, grants: {});
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (plugins['echo']!.status != PluginStatus.failed) {
        expect(DateTime.now().isBefore(deadline), isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(plugins['echo']!.error, contains('not granted'));
      expect(
        () => plugins.install(PluginPackage.read(package), grants: {}),
        throwsStateError,
      );
    },
  );

  test('a newer bundled version updates without asking', () async {
    final (_, plugins) = await device();
    PluginPackage version(String v) {
      final out = Archive();
      for (final f in ZipDecoder().decodeBytes(package).files) {
        final bytes = f.readBytes()!;
        if (f.name == 'manifest.json') {
          final m = jsonDecode(utf8.decode(bytes)) as Json..['version'] = v;
          out.addFile(ArchiveFile.bytes(f.name, utf8.encode(jsonEncode(m))));
        } else {
          out.addFile(ArchiveFile.bytes(f.name, bytes));
        }
      }
      return PluginPackage.read(
        Uint8List.fromList(ZipEncoder().encodeBytes(out)),
      );
    }

    await plugins.install(version('0.1.0'), grants: grants);
    await running(plugins);
    // The same or an older version waits.
    expect(await plugins.updateBundled([version('0.1.0')]), isEmpty);
    expect(await plugins.updateBundled([version('0.0.9')]), isEmpty);
    expect(await plugins.updateBundled([version('0.2.0')]), ['echo']);
    expect(plugins['echo']!.manifest.version, '0.2.0');
    await running(plugins);
    // Switched off, or granted less than it asks for: left alone.
    await plugins.setEnabled('echo', false);
    expect(await plugins.updateBundled([version('0.3.0')]), isEmpty);
    await plugins.uninstall('echo');
    await plugins.install(version('0.1.0'), grants: grants);
    plugins['echo']!.granted.remove('tun');
    expect(await plugins.updateBundled([version('0.3.0')]), isEmpty);
  });

  test('live messages reach the plugin on a friend\'s device', () async {
    final (a, pa) = await device('a');
    final (b, pb) = await device('b');
    pa.link = _Wire(a, b);
    pb.link = _Wire(b, a);
    for (final p in [pa, pb]) {
      await p.install(PluginPackage.read(package), grants: grants);
      await running(p);
    }
    expect(a.registry.capabilities, ['p:echo']);
    pa.event('echo', 'Echo', 'send', {'device': b.identity.device});
    expect((await until(pa, (d) => d['reply'] != null))['reply'], 'echo:ping');
    await pb.setEnabled('echo', false);
    pa.event('echo', 'Echo', 'send', {'device': b.identity.device});
    expect(
      (await until(pa, (d) => '${d['reply']}'.startsWith('error')))['reply'],
      'error: Plugin not running',
    );
  });

  test("datagrams reach the plugin on a friend's device", () async {
    final (a, pa) = await device('a');
    final (b, pb) = await device('b');
    pa.link = _Wire(a, b);
    pb.link = _Wire(b, a);
    for (final p in [pa, pb]) {
      await p.install(PluginPackage.read(package), grants: grants);
      await running(p);
    }
    pa.event('echo', 'Echo', 'datagram', {'device': b.identity.device});
    expect(
      (await until(pb, (d) => d['datagram'] != null))['datagram'],
      'tick from ${a.identity.device.substring(0, 4)}',
    );
  });

  test(
    "on Windows, packets pass through the network helper's pipes",
    () async {
      final helper = File(
        '../native/tun-helper/target/release/ournet-tun.exe',
      ).absolute.path;
      final who = await Process.run('whoami', ['/user', '/fo', 'csv', '/nh']);
      final sid = RegExp(r'S-1-[0-9-]+').firstMatch('${who.stdout}')!.group(0)!;
      final name = 'ournet-tun-test-${DateTime.now().microsecondsSinceEpoch}';
      final loopback = await Process.start(helper, ['loopback', name, sid]);
      final lines = <String>[];
      loopback.stdout
          .transform(const SystemEncoding().decoder)
          .transform(const LineSplitter())
          .listen(lines.add);
      Future<String> line(int n) async {
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (lines.length <= n && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        return lines.length > n ? lines[n] : 'nothing';
      }

      expect(await line(0), 'ready');
      final (_, plugins) = await device();
      plugins.openTun = (_, _) async => {'pipe': name};
      await plugins.install(PluginPackage.read(package), grants: grants);
      await running(plugins);
      plugins.event('echo', 'Echo', 'tun', {});
      expect((await until(plugins, (d) => d['tun'] != null))['tun'], 'open');
      // The helper sent a packet as the system would; echo sends it back
      // reversed, through the pipe.
      final back = await line(1);
      expect(
        back,
        '040302010100'
        '4d0a0200'
        '4d0a0000'
        '11400000'
        '00001800'
        '0045',
      );
      expect(await loopback.exitCode, 0);
    },
    skip:
        Platform.isWindows &&
            File(
              '../native/tun-helper/target/release/ournet-tun.exe',
            ).existsSync()
        ? false
        : 'needs Windows and a built native/tun-helper',
  );

  test("packets pass through a plugin's interface", () async {
    final (_, plugins) = await device();
    Json? opened;
    plugins.openTun = (plugin, settings) async {
      opened = settings;
      return {'memory': true};
    };
    await plugins.install(PluginPackage.read(package), grants: grants);
    await running(plugins);
    plugins.event('echo', 'Echo', 'tun', {});
    expect((await until(plugins, (d) => d['tun'] != null))['tun'], 'open');
    expect(opened, containsPair('address', '10.77.0.1'));
    final back = plugins.tunPackets.first;
    plugins.tunReceive('echo', Uint8List.fromList([1, 2, 3, 4]));
    expect((await back).packet, [4, 3, 2, 1]);
  });
}

/// Delivers live requests straight to the other node's handler, as the
/// network would.
class _Wire implements PluginLink {
  final Node from, to;
  _Wire(this.from, this.to);
  @override
  Future<Json> request(String device, Json request) => to.registry.handler(
    request['type'] as String,
  )!(from.identity.device, request);
  @override
  bool runs(String device, String plugin) => true;
  @override
  Future<bool> datagram(String device, String channel, List<int> data) async {
    to.registry
        .datagramHandler(channel)
        ?.call(from.identity.device, Uint8List.fromList(data));
    return true;
  }
}

/// Compiled plugins, kept between tests: compiling each time is slow.
final sharedCache = '${Directory.systemTemp.path}/ournet-plugin-cache';
