import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';

import 'plugins_test.dart' show sharedCache;

/// Signed releases, distribution between friends, pinning and rollback
/// (docs/STORE-PLAN.md), with the echo plugin in the real native host.
void main() {
  final echo = File('test/fixtures/echo.ournet-plugin').readAsBytesSync();
  const grants = {'objects', 'identity', 'live', 'tun'};
  late Directory temp;
  final cleanup = <Future<void> Function()>[];

  setUp(() => temp = Directory.systemTemp.createTempSync('ournet-releases'));
  tearDown(() async {
    for (final c in cleanup.reversed) {
      await c();
    }
    cleanup.clear();
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// Echo's entries with its manifest changed by [edit], and any [extra].
  Map<String, Uint8List> entries(
    void Function(Json manifest) edit, {
    Map<String, Uint8List> extra = const {},
  }) {
    final files = <String, Uint8List>{};
    for (final f in ZipDecoder().decodeBytes(echo).files) {
      if (!f.isFile) continue;
      var bytes = f.readBytes()!;
      if (f.name == 'manifest.json') {
        final m = jsonDecode(utf8.decode(bytes)) as Json;
        edit(m);
        bytes = utf8.encode(jsonEncode(m));
      }
      files[f.name] = bytes;
    }
    return {...files, ...extra};
  }

  Uint8List zip(Map<String, Uint8List> files) {
    final out = Archive();
    for (final MapEntry(:key, :value) in files.entries) {
      out.addFile(ArchiveFile.bytes(key, value));
    }
    return ZipEncoder().encodeBytes(out);
  }

  PluginPackage version(String v, {void Function(Json m)? edit}) =>
      PluginPackage.read(
        zip(
          entries((m) {
            m['version'] = v;
            edit?.call(m);
          }),
        ),
      );

  Future<(Node, Plugins)> device(String name, [Node? friend]) async {
    final node = Node(await LocalIdentity.create(), Store());
    if (friend != null) {
      await node.addContact(friend.identity.certificate);
      await friend.addContact(node.identity.certificate);
    }
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

  /// Syncs [a] and [b] and carries the package chunks [b] lacks.
  Future<void> carry(Node a, Node b) async {
    await syncPair(a, b);
    for (final o in b.store.objects(kind: PluginRelease.packageKind)) {
      for (final h in ((await b.content(o))?['chunks'] as List? ?? [])) {
        final blob = a.store.blob(h as String);
        if (blob != null) b.store.putBlob(h, blob);
      }
    }
  }

  Future<void> until(bool Function() done) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) fail('Timed out');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// Waits for echo to say it has started [n] times: its storage counts.
  Future<void> starts(Plugins plugins, int n) async {
    plugins.event('echo', 'Echo', 'state', {});
    await until(() => plugins.surface('echo', 'Echo')['starts'] == n);
  }

  group('packages', () {
    test('the digest names the contents, not the zip', () {
      final files = entries((_) {});
      final a = PluginPackage.read(zip(files));
      final b = PluginPackage.read(
        zip(Map.fromEntries(files.entries.toList().reversed)),
      );
      expect(a.digest, b.digest);
      expect(
        version('0.1.1').digest,
        isNot(a.digest),
        reason: 'A different manifest is a different package',
      );
    });

    test('unexpected, repeated and oversized entries are refused', () {
      expect(
        () => PluginPackage.read(
          zip(entries((_) {}, extra: {'run.exe': Uint8List(1)})),
        ),
        throwsFormatException,
      );
      expect(
        () => PluginPackage.read(
          zip(entries((_) {}, extra: {'assets/../x': Uint8List(1)})),
        ),
        throwsFormatException,
      );
      // Echo's entries and a second manifest.json in one zip.
      final repeated = _merge(
        zip(entries((_) {})),
        zip({'manifest.json': Uint8List(2)}),
      );
      expect(() => PluginPackage.read(repeated), throwsFormatException);
      expect(
        () => PluginPackage.read(Uint8List(PluginPackage.maxBytes + 1)),
        throwsFormatException,
      );
    });
  });

  test('a release is signed, verified, and refuses another package', () async {
    final (_, plugins) = await device('a');
    final signed = PluginPackage.read(
      await plugins.publish(version('0.2.0'), changes: 'Better'),
    );
    final release = (await plugins.releaseOf(signed))!;
    expect(release.plugin, 'echo');
    expect(release.version, '0.2.0');
    expect(release.changes, 'Better');
    expect(release.publisher, plugins.node.person);

    // The same release over different contents does not check.
    final other = PluginPackage.of({
      ...version('0.2.0', edit: (m) => m['description'] = 'Other').files,
    }, signature: signed.signature);
    await expectLater(plugins.releaseOf(other), throwsFormatException);
    // Nor does a release whose signature was tampered with.
    final forged = jsonDecode(jsonEncode(signed.signature)) as Json;
    (forged['data']['payload'] as Map)['version'] = '9.0.0';
    await expectLater(
      plugins.releaseOf(PluginPackage.of(signed.files, signature: forged)),
      throwsFormatException,
    );
    // A later release must have a later version.
    await expectLater(plugins.publish(version('0.2.0')), throwsStateError);
  });

  test("publishing refuses a version friends' data would not fit", () async {
    final (_, plugins) = await device('a');
    await plugins.publish(version('0.2.0'));
    await expectLater(
      plugins.publish(
        version(
          '0.3.0',
          edit: (m) => (m['kinds']['note'] as Map)['text'] = {
            'type': 'string',
            'max': 10,
            'required': true,
          },
        ),
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('note.text changed'),
        ),
      ),
    );
    // A new optional field is fine.
    await plugins.publish(
      version(
        '0.3.0',
        edit: (m) => (m['kinds']['note'] as Map)['mood'] = {'type': 'string'},
      ),
    );
  });

  test('a friend installs a shared plugin and takes its updates; a failed '
      'update goes back with its storage', () async {
    final (a, pa) = await device('a');
    final (b, pb) = await device('b', a);

    // Shared with b alone: a sealed distribution.
    await pa.publish(version('0.2.0'), people: [b.person]);
    await carry(a, b);
    final shared = (await pb.offers()).single;
    expect(shared.release.version, '0.2.0');
    expect(shared.distribution.author, a.person);
    await pb.installOffer(shared, grants: grants);
    await until(() => pb['echo']?.status == PluginStatus.running);
    expect(pb['echo']!.publisher, a.person);
    expect(b.subscriptions, contains(PluginRelease.space(a.person)));
    await starts(pb, 1);
    expect(await pb.offers(), isEmpty);

    // A public release reaches b through a's release space.
    await pa.publish(version('0.3.0'), changes: 'Faster');
    await carry(a, b);
    final update = (await pb.offers()).single;
    expect(update.release.changes, 'Faster');
    await pb.installOffer(update, grants: grants);
    await until(
      () =>
          pb['echo']?.manifest.version == '0.3.0' &&
          pb['echo']?.status == PluginStatus.running,
    );
    await starts(pb, 2); // Storage carried over.

    // 0.4.0 fails to start (its code reaches further than its manifest
    // says): b goes back to 0.3.0, with the storage 0.3.0 had, and skips it.
    await pa.publish(version('0.4.0', edit: (m) => m['grants'] = []));
    await carry(a, b);
    final broken = (await pb.offers()).single;
    await pb.installOffer(broken, grants: grants);
    await until(
      () =>
          pb['echo']?.manifest.version == '0.3.0' &&
          pb['echo']?.status == PluginStatus.running,
    );
    await starts(pb, 3);
    expect(await pb.offers(), isEmpty, reason: 'The failed release is skipped');
  });

  test('a plugin of the same ID from another publisher replaces the installed '
      'one and nothing it kept', () async {
    final (a, pa) = await device('a');
    final (b, pb) = await device('b', a);
    final (c, pc) = await device('c', b);
    await pa.publish(version('0.2.0'), people: [b.person]);
    await pc.publish(version('5.0.0'), people: [b.person]);
    await carry(a, b);
    await carry(c, b);
    final offers = await pb.offers();
    final fromA = offers.singleWhere((o) => o.release.publisher == a.person);
    await pb.installOffer(fromA, grants: grants);
    await until(() => pb['echo']?.status == PluginStatus.running);
    await pb.restart('echo');
    await until(() => pb['echo']?.status == PluginStatus.running);
    await starts(pb, 2);

    final fromC = (await pb.offers()).single;
    expect(fromC.release.publisher, c.person);
    expect(fromC.replaces, isTrue);
    await pb.installOffer(fromC, grants: grants);
    await until(
      () =>
          pb['echo']?.publisher == c.person &&
          pb['echo']?.status == PluginStatus.running,
    );
    await starts(pb, 1);
  });

  test("live messages for another publisher's plugin are refused", () async {
    final (a, _) = await device('a');
    final (b, pb) = await device('b', a);
    final (c, pc) = await device('c', b);
    await pb.install(
      PluginPackage.read(await pc.publish(version('0.2.0'))),
      grants: grants,
    );
    await until(() => pb['echo']?.status == PluginStatus.running);
    Future<Object?> send(String? publisher) => b.registry
        .handler(Plugins.liveRequest)!(a.identity.device, {
          'type': Plugins.liveRequest,
          'plugin': 'echo',
          'publisher': ?publisher,
          'payload': b64(utf8.encode('ping')),
        })
        .then((r) => r, onError: (Object e) => e);
    expect(await send(null), isA<Json>(), reason: 'Older builds send none');
    expect(await send(c.person), isA<Json>());
    expect(await send(a.person), isA<StateError>());
  });
}

/// One zip holding the entries of [a] and then those of [b], even where
/// both name the same file, which encoders refuse to write.
Uint8List _merge(Uint8List a, Uint8List b) {
  final (first, second) = (_split(a), _split(b));
  final offset = first.locals.length;
  final directory = Uint8List.fromList([
    ...first.directory,
    ..._shift(second.directory, offset),
  ]);
  int count(List<int> zip) => ByteData.sublistView(
    Uint8List.fromList(zip),
  ).getUint16(zip.length - 22 + 10, Endian.little);
  final entries = count(a) + count(b);
  final end = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, entries, Endian.little)
    ..setUint16(10, entries, Endian.little)
    ..setUint32(12, directory.length, Endian.little)
    ..setUint32(16, offset + second.locals.length, Endian.little);
  return Uint8List.fromList([
    ...first.locals,
    ...second.locals,
    ...directory,
    ...end.buffer.asUint8List(),
  ]);
}

({Uint8List locals, Uint8List directory}) _split(List<int> zip) {
  final bytes = Uint8List.fromList(zip);
  final data = ByteData.sublistView(bytes);
  final end = bytes.length - 22;
  final size = data.getUint32(end + 12, Endian.little);
  final start = data.getUint32(end + 16, Endian.little);
  return (
    locals: bytes.sublist(0, start),
    directory: bytes.sublist(start, start + size),
  );
}

/// Central directory entries with their local header offsets moved by [by].
Uint8List _shift(Uint8List directory, int by) {
  final out = Uint8List.fromList(directory);
  final data = ByteData.sublistView(out);
  var at = 0;
  while (at + 46 <= out.length &&
      data.getUint32(at, Endian.little) == 0x02014b50) {
    data.setUint32(
      at + 42,
      data.getUint32(at + 42, Endian.little) + by,
      Endian.little,
    );
    at +=
        46 +
        data.getUint16(at + 28, Endian.little) +
        data.getUint16(at + 30, Endian.little) +
        data.getUint16(at + 32, Endian.little);
  }
  return out;
}
