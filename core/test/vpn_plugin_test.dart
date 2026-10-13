import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';

/// The VPN plugin (plugins/vpn) between two friends' devices: packets the
/// system hands one device's interface come out of the other's, and only
/// from addresses and people that are allowed.
void main() {
  final package = PluginPackage.read(
    File('test/fixtures/vpn.ournet-plugin').readAsBytesSync(),
  );

  /// The device's address, as the plugin works it out (FNV-1a of its ID).
  List<int> address(String device) {
    var h = 0x811c9dc5;
    for (final b in device.codeUnits) {
      h = ((h ^ b) * 0x01000193) & 0xffffffff;
    }
    return [10, 77, 1 + h % 254, 1 + (h >> 8) % 254];
  }

  /// A minimal IPv4 header from [src] to [dst], then [body].
  Uint8List packet(List<int> src, List<int> dst, List<int> body) =>
      Uint8List.fromList([
        0x45,
        0,
        0,
        20 + body.length,
        0,
        0,
        0,
        0,
        64,
        17,
        0,
        0,
        ...src,
        ...dst,
        ...body,
      ]);

  test('packets cross to an allowed friend and no further', () async {
    final temp = Directory.systemTemp.createTempSync('ournet-vpn');
    final a = Node(await LocalIdentity.create(), Store());
    final b = Node(await LocalIdentity.create(), Store());
    await a.addContact(b.identity.certificate);
    await b.addContact(a.identity.certificate);
    final pa = Plugins(a, directory: '${temp.path}/a', cache: sharedCache);
    final pb = Plugins(b, directory: '${temp.path}/b', cache: sharedCache);
    addTearDown(() async {
      await pa.close();
      await pb.close();
      await a.close();
      await b.close();
      temp.deleteSync(recursive: true);
    });
    pa.link = _Wire(a, b);
    pb.link = _Wire(b, a);
    for (final p in [pa, pb]) {
      p.openTun = (_, settings) async => {'memory': true};
      await p.install(package, grants: package.manifest.grants);
    }
    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 300));
    for (final p in [pa, pb]) {
      while (p['vpn']?.status != PluginStatus.running) {
        if (p['vpn']?.status == PluginStatus.failed) fail('${p['vpn']!.error}');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      p.event('vpn', 'Vpn', 'toggle', {});
    }
    await settle();
    expect(pa.surface('vpn', 'Vpn')['status'], startsWith('On'));

    final ipA = address(a.identity.device), ipB = address(b.identity.device);
    final atB = <Uint8List>[];
    final listening = pb.tunPackets.listen((p) => atB.add(p.packet));
    addTearDown(listening.cancel);

    // a allows b, but b has not allowed a yet.
    pa.event('vpn', 'Vpn', 'allow', {'person': b.person});
    await settle();
    pa.tunReceive('vpn', packet(ipA, ipB, [1, 2, 3]));
    await settle();
    expect(atB, isEmpty);

    pb.event('vpn', 'Vpn', 'allow', {'person': a.person});
    await settle();
    final sent = packet(ipA, ipB, [1, 2, 3]);
    pa.tunReceive('vpn', sent);
    await settle();
    expect(atB, [sent]);

    // A packet claiming another source is refused.
    pa.tunReceive('vpn', packet([10, 77, 9, 9], ipB, [4]));
    await settle();
    expect(atB, hasLength(1));
    pb.open('vpn', 'Vpn', {'scope': 'personal'});
    await settle();
    expect(
      pb.surface('vpn', 'Vpn')['traffic'],
      contains('1 received · 2 refused'),
    );
  });
}

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
