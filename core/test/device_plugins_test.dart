import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';

void main() {
  late Node a, b, friend;
  late Plugins pa, pb;
  late Directory temp;
  final copied = <String>[];
  Future<void> until(bool Function() done) async {
    final end = DateTime.now().add(const Duration(seconds: 45));
    while (!done()) {
      if (DateTime.now().isAfter(end))
        fail(
          'Timed out: ${pb.installed.map((p) => '${p.id}: ${p.status} ${p.error}')}',
        );
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('ournet-device-plugins');
    final identity = await LocalIdentity.create(label: 'Phone');
    var time = DateTime.now().millisecondsSinceEpoch;
    a = Node(identity, _DeviceStore(), clock: () => time++);
    b = Node(
      await LocalIdentity.create(root: identity.root, label: 'Desktop'),
      Store(),
    );
    friend = Node(await LocalIdentity.create(), Store());
    await a.addContact(b.identity.certificate);
    await b.addContact(a.identity.certificate);
    await b.addContact(friend.identity.certificate);
    pa = Plugins(
      a,
      directory: '${temp.path}/a',
      cache: '${Directory.systemTemp.path}/ournet-plugin-cache',
    );
    pb = Plugins(
      b,
      directory: '${temp.path}/b',
      cache: '${Directory.systemTemp.path}/ournet-plugin-cache',
    );
    copied.clear();
    pa.link = _Wire(a, b);
    pb.writeClipboard = (text) async => copied.add(text);
    for (final p in [pa, pb]) {
      for (final id in ['device-dashboard', 'remote-input']) {
        final package = PluginPackage.read(
          File('test/fixtures/$id.ournet-plugin').readAsBytesSync(),
        );
        await p.install(package, grants: package.manifest.grants);
      }
    }
    await until(
      () => [pa, pb].every(
        (p) => p.installed.every((i) => i.status == PluginStatus.running),
      ),
    );
  });
  tearDown(() async {
    await pa.close();
    await pb.close();
    await a.close();
    await b.close();
    await friend.close();
    temp.deleteSync(recursive: true);
  });

  Future<Json> request(String plugin, Node from, Json payload) async {
    final reply =
        await b.registry.handler(Plugins.liveRequest)!(from.identity.device, {
          'type': Plugins.liveRequest,
          'plugin': plugin,
          'payload': b64(utf8.encode(jsonEncode(payload))),
        });
    return (jsonDecode(utf8.decode(unb64(reply['payload']))) as Map)
        .cast<String, dynamic>();
  }

  test(
    'clipboard handoff runs through the controller and encrypted-link contract',
    () async {
      pb.event('remote-input', 'RemoteInput', 'clipboard', {});
      await until(
        () => pb.surface('remote-input', 'RemoteInput')['clipboard'] == true,
      );
      pa.open('remote-input', 'RemoteInput', {'scope': 'personal'});
      pa.event('remote-input', 'RemoteInput', 'select', {
        'device': b.identity.device,
      });
      pa.event('remote-input', 'RemoteInput', 'text', {
        'value': 'From the phone 🎤',
      });
      pa.event('remote-input', 'RemoteInput', 'copy', {});
      await until(() => copied.isNotEmpty);
      expect(copied, ['From the phone 🎤']);
      await until(
        () => pa.surface('remote-input', 'RemoteInput')['busy'] == false,
      );
      expect(
        pa.surface('remote-input', 'RemoteInput')['text'],
        'From the phone 🎤',
      );
      expect(
        pa.surface('remote-input', 'RemoteInput')['targetName'],
        'Selected: Desktop',
      );
      final devices =
          pa.surface('remote-input', 'RemoteInput')['devices'] as List;
      expect(devices.map((d) => d['id']), contains(b.identity.device));
      expect(
        devices.map((d) => d['id']),
        isNot(contains(friend.identity.device)),
      );
    },
  );

  test('clipboard is own-device, opt-in, write-only and bounded', () async {
    await expectLater(
      request('remote-input', a, {'op': 'copy', 'text': 'secret'}),
      throwsA(anything),
    );
    expect(copied, isEmpty);
    pb.event('remote-input', 'RemoteInput', 'clipboard', {});
    await until(
      () => pb.surface('remote-input', 'RemoteInput')['clipboard'] == true,
    );
    await expectLater(
      request('remote-input', friend, {'op': 'copy', 'text': 'friend'}),
      throwsA(anything),
    );
    expect(copied, isEmpty);
    expect(
      await request('remote-input', a, {
        'op': 'copy',
        'text': 'Hello 👋\nVoice input',
      }),
      containsPair('ok', true),
    );
    expect(copied, ['Hello 👋\nVoice input']);
    // Paste checks both permissions before changing the clipboard.
    await expectLater(
      request('remote-input', a, {'op': 'paste', 'text': 'do not paste'}),
      throwsA(anything),
    );
    await expectLater(
      request('remote-input', a, {'op': 'copy', 'text': 'x' * 16385}),
      throwsA(anything),
    );
    await expectLater(
      request('remote-input', a, {'op': 'read'}),
      throwsA(anything),
    );
    expect(copied, hasLength(1));
    pb.event('remote-input', 'RemoteInput', 'disable', {});
    await until(
      () => pb.surface('remote-input', 'RemoteInput')['clipboard'] == false,
    );
    await expectLater(
      request('remote-input', a, {'op': 'copy', 'text': 'revoked'}),
      throwsA(anything),
    );
    expect(copied, hasLength(1));
    // Switching the plugin off stops receiving; on again, it keeps its
    // switches as they were set.
    pb.event('remote-input', 'RemoteInput', 'clipboard', {});
    await until(
      () => pb.surface('remote-input', 'RemoteInput')['clipboard'] == true,
    );
    await pb.setEnabled('remote-input', false);
    await expectLater(
      request('remote-input', a, {'op': 'copy', 'text': 'switched off'}),
      throwsA(anything),
    );
    await pb.setEnabled('remote-input', true);
    await until(() => pb['remote-input']?.status == PluginStatus.running);
    expect(
      await request('remote-input', a, {'op': 'copy', 'text': 'on again'}),
      containsPair('ok', true),
    );
    expect(copied, hasLength(2));
  });

  test(
    'input-rate contact refreshes consume rename history only once',
    () async {
      for (var i = 0; i < 300; i++) {
        await a.renameDevice(b.identity.device, 'Desktop $i');
      }
      pa.event('remote-input', 'RemoteInput', 'select', {
        'device': b.identity.device,
      });
      await until(
        () =>
            pa.surface('remote-input', 'RemoteInput')['targetName'] ==
            'Selected: Desktop 299',
      );
      final store = a.store as _DeviceStore;
      expect(store.namesRead, 300);
      for (var i = 0; i < 30; i++) {
        pa.event('remote-input', 'RemoteInput', 'text', {'value': 'Draft $i'});
      }
      await until(
        () => pa.surface('remote-input', 'RemoteInput')['text'] == 'Draft 29',
      );
      expect(store.namesRead, 300);
      await a.renameDevice(b.identity.device, 'Renamed desktop');
      pa.event('remote-input', 'RemoteInput', 'refresh', {});
      await until(
        () =>
            pa.surface('remote-input', 'RemoteInput')['targetName'] ==
            'Selected: Renamed desktop',
      );
      expect(store.namesRead, 301);
    },
  );

  test(
    'dashboard samples only after opt-in and protects process control',
    () async {
      await expectLater(
        request('device-dashboard', a, {'op': 'snapshot'}),
        throwsA(anything),
      );
      pb.event('device-dashboard', 'Dashboard', 'sharing', {});
      await until(
        () => pb.surface('device-dashboard', 'Dashboard')['sharing'] == true,
      );
      await expectLater(
        request('device-dashboard', friend, {'op': 'snapshot'}),
        throwsA(anything),
      );
      await expectLater(
        request('device-dashboard', a, {'op': 'stop', 'pid': 0, 'started': 0}),
        throwsA(anything),
      );
      if (Platform.isWindows) {
        final report = await request('device-dashboard', a, {
          'op': 'snapshot',
          'processes': true,
        });
        expect(report['memoryTotal'], greaterThan(0));
        expect(report['processes'], hasLength(lessThanOrEqualTo(128)));
        expect(report['gpu'], isNull);
        // Current controllers ask for compact rows and the newer figures.
        final compact = await request('device-dashboard', a, {
          'op': 'snapshot',
          'processes': true,
          'v': 2,
        });
        expect(compact['processes'], isNull);
        final rows = compact['processRows'] as List;
        expect(rows, hasLength(inInclusiveRange(1, 512)));
        expect(rows.first, hasLength(7));
        expect(compact['cores'], greaterThan(0));
        expect(compact['processCount'], greaterThan(0));
        expect(compact['handleCount'], greaterThan(0));
        expect(compact['sharing'], true);
        pb.event('device-dashboard', 'Dashboard', 'control', {});
        await until(
          () => pb.surface('device-dashboard', 'Dashboard')['control'] == true,
        );
        // Never attempt to kill a real process in a test.
        await expectLater(
          request('device-dashboard', a, {
            'op': 'stop',
            'pid': pid,
            'started': 0,
          }),
          throwsA(anything),
        );
        await expectLater(
          request('device-dashboard', a, {
            'op': 'stop',
            'pid': 4294967296,
            'started': 0,
          }),
          throwsA(anything),
        );
      }
      pb.event('device-dashboard', 'Dashboard', 'sharing', {});
      await until(
        () => pb.surface('device-dashboard', 'Dashboard')['sharing'] == false,
      );
      expect(pb.surface('device-dashboard', 'Dashboard')['control'], false);
      await expectLater(
        request('device-dashboard', a, {'op': 'snapshot'}),
        throwsA(anything),
      );
    },
  );
  test('the host refuses device capabilities to devices not certified as '
      "this person's, whatever the plugin decides", () async {
    pb.event('device-dashboard', 'Dashboard', 'sharing', {});
    pb.event('remote-input', 'RemoteInput', 'clipboard', {});
    pb.event('remote-input', 'RemoteInput', 'receiving', {});
    await until(
      () =>
          pb.surface('device-dashboard', 'Dashboard')['sharing'] == true &&
          pb.surface('remote-input', 'RemoteInput')['clipboard'] == true &&
          pb.surface('remote-input', 'RemoteInput')['receiving'] == true,
    );
    // The plugins still take a to be one of this person's devices; the
    // host is told otherwise, and must hold.
    pb.ownDevice = (device) => false;
    for (final (plugin, payload) in [
      ('device-dashboard', {'op': 'snapshot', 'processes': true}),
      ('remote-input', {'op': 'copy', 'text': 'not yours'}),
      ('remote-input', {'op': 'key', 'key': 'escape'}),
    ]) {
      await expectLater(
        request(plugin, a, payload),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('only for your own devices'),
          ),
        ),
      );
    }
    expect(copied, isEmpty);
    expect(pb.remoteSessions, isEmpty);
    // What touches nothing still answers.
    expect(await request('remote-input', a, {'op': 'status'}), {
      'receiving': true,
      'clipboard': true,
    });
    pb.ownDevice = b.ownDevice;
    expect(
      await request('remote-input', a, {'op': 'copy', 'text': 'mine'}),
      containsPair('ok', true),
    );
    expect(copied, ['mine']);
    expect(b.ownDevice(a.identity.device), isTrue);
    expect(b.ownDevice(friend.identity.device), isFalse);
  });

  test('the receiver shows and logs remote sessions locally, and stops '
      'them', () async {
    pb.event('device-dashboard', 'Dashboard', 'sharing', {});
    pb.event('remote-input', 'RemoteInput', 'clipboard', {});
    await until(
      () =>
          pb.surface('device-dashboard', 'Dashboard')['sharing'] == true &&
          pb.surface('remote-input', 'RemoteInput')['clipboard'] == true,
    );
    final changes = <void>[];
    final listening = pb.remoteChanges.listen(changes.add);
    addTearDown(listening.cancel);
    // Sampling may fail off Windows; the use is reported first.
    try {
      await request('device-dashboard', a, {'op': 'snapshot'});
    } on StateError catch (_) {}
    await until(() => pb.remoteSessions.isNotEmpty);
    final viewing = pb.remoteSessions.single;
    expect(viewing.device, a.identity.device);
    expect(viewing.plugin, 'device-dashboard');
    expect(viewing.capabilities, {'system-monitor'});
    expect(viewing.controlling, isFalse);
    await request('remote-input', a, {'op': 'copy', 'text': 'hello'});
    await until(() => pb.remoteSessions.length == 2);
    expect(
      pb.remoteSessions.where((s) => s.controlling).single.plugin,
      'remote-input',
    );
    expect(pb.deviceName(a.identity.device), 'Phone');
    final texts = pb.remoteLog.map((e) => e.text).toList();
    expect(texts, contains('Session started'));
    expect(texts, contains('Started viewing resources and processes'));
    expect(texts, contains('Started sending clipboard text'));
    // Nothing about it is stored or synced: only the copied text left.
    expect(texts.join(), isNot(contains('hello')));
    expect(changes, isNotEmpty);
    await pb.stopRemoteSessions();
    expect(pb.remoteSessions, isEmpty);
    expect(pb.remoteLog.first.text, startsWith('Stopped on this device after'));
    await until(
      () =>
          pb['remote-input']?.status == PluginStatus.running &&
          pb['device-dashboard']?.status == PluginStatus.running,
    );
    // Restarted plugins start with receiving off.
    await expectLater(
      request('remote-input', a, {'op': 'copy', 'text': 'again'}),
      throwsA(anything),
    );
    await expectLater(
      request('device-dashboard', a, {'op': 'snapshot'}),
      throwsA(anything),
    );
    expect(copied, ['hello']);
    expect(pb.remoteLog.length, lessThanOrEqualTo(Plugins.remoteLogLimit));
  });
  test('receiving switches stay as set when the app starts again', () async {
    pb.event('device-dashboard', 'Dashboard', 'sharing', {});
    pb.event('remote-input', 'RemoteInput', 'clipboard', {});
    await until(
      () =>
          pb.surface('device-dashboard', 'Dashboard')['sharing'] == true &&
          pb.surface('remote-input', 'RemoteInput')['clipboard'] == true,
    );
    await pb.close();
    pb = Plugins(
      b,
      directory: '${temp.path}/b',
      cache: '${Directory.systemTemp.path}/ournet-plugin-cache',
    )..writeClipboard = (text) async => copied.add(text);
    await pb.load();
    await until(
      () =>
          pb.surface('device-dashboard', 'Dashboard')['sharing'] == true &&
          pb.surface('remote-input', 'RemoteInput')['clipboard'] == true,
    );
    expect(pb.surface('remote-input', 'RemoteInput')['receiving'], isFalse);
    expect(pb.surface('device-dashboard', 'Dashboard')['control'], isFalse);
    expect(
      await request('remote-input', a, {'op': 'copy', 'text': 'kept'}),
      containsPair('ok', true),
    );
    expect(copied, ['kept']);
    // Switching off is kept too.
    pb.event('remote-input', 'RemoteInput', 'clipboard', {});
    await until(
      () => pb.surface('remote-input', 'RemoteInput')['clipboard'] == false,
    );
    await pb.restart('remote-input');
    await until(() => pb['remote-input']?.status == PluginStatus.running);
    await expectLater(
      request('remote-input', a, {'op': 'copy', 'text': 'off'}),
      throwsA(anything),
    );
    expect(copied, ['kept']);
  });
}

class _Wire implements PluginLink {
  final Node from, to;
  _Wire(this.from, this.to);
  @override
  bool runs(String device, String plugin) => true;
  @override
  Future<Json> request(String device, Json request) =>
      to.registry.handler(Plugins.liveRequest)!(from.identity.device, request);
  @override
  Future<bool> datagram(String device, String channel, List<int> data) async =>
      false;
}

class _DeviceStore extends Store {
  int namesRead = 0;
  @override
  List<(int, SignedObject)> objectsAfter(String kind, int cursor) {
    final page = super.objectsAfter(kind, cursor);
    if (kind == 'device_name') namesRead += page.length;
    return page;
  }
}
