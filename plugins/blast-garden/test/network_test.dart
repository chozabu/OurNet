import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet_core/ournet_core.dart';

class Wire implements PluginLink {
  final Node from, to;
  final List<List<int>> sent = [];
  bool drop = false;
  int count = 0;
  Wire(this.from, this.to);
  @override
  bool runs(String device, String plugin) => true;
  @override
  Future<Json> request(String device, Json request) => to.registry.handler(
    request['type'] as String,
  )!(from.identity.device, request);
  void deliver(List<int> data) => to.registry
      .datagramHandler('p:blast-garden')
      ?.call(from.identity.device, Uint8List.fromList(data));
  @override
  Future<bool> datagram(String device, String channel, List<int> data) async {
    expect(data.length, lessThan(1200));
    sent.add(List.of(data));
    if (sent.length > 100) sent.removeAt(0);
    if (!drop && ++count % 3 != 0) {
      to.registry
          .datagramHandler(channel)
          ?.call(from.identity.device, Uint8List.fromList(data));
    }
    return true;
  }
}

void main() {
  for (final coop in [true, false]) {
    test(
      'real hosts: ${coop ? "co-op" : "versus"}, packet loss, restart and leave',
      () async {
        final temp = Directory.systemTemp.createTempSync('blast-network');
        final a = Node(await LocalIdentity.create(), Store());
        final b = Node(await LocalIdentity.create(), Store());
        await a.addContact(b.identity.certificate);
        await b.addContact(a.identity.certificate);
        a.store.set('peerHealth', {
          b.identity.device: {'synced': a.now()},
        });
        b.store.set('peerHealth', {
          a.identity.device: {'synced': b.now()},
        });
        final pa = Plugins(a, directory: '${temp.path}/a');
        final pb = Plugins(b, directory: '${temp.path}/b');
        final ab = Wire(a, b), ba = Wire(b, a);
        pa.link = ab;
        pb.link = ba;
        addTearDown(() async {
          await pa.close();
          await pb.close();
          await a.close();
          await b.close();
          temp.deleteSync(recursive: true);
        });
        final package = PluginPackage.read(
          File(
            '../plugins/blast-garden/dist/blast-garden.ournet-plugin',
          ).readAsBytesSync(),
        );
        for (final p in [pa, pb]) {
          await p.install(package, grants: package.manifest.grants);
        }
        Json data(Plugins p) => p.surface('blast-garden', 'BlastGarden');
        Future<void> until(bool Function() ready) async {
          final end = DateTime.now().add(const Duration(seconds: 30));
          while (!ready()) {
            if (DateTime.now().isAfter(end))
              fail('Timed out: ${data(pa)} ${data(pb)}');
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        }

        void event(Plugins p, String name, [Json args = const {}]) =>
            p.event('blast-garden', 'BlastGarden', name, args);
        await until(
          () => [
            pa,
            pb,
          ].every((p) => p['blast-garden']?.status == PluginStatus.running),
        );
        pa.open('blast-garden', 'BlastGarden', const {'scope': 'personal'});
        pb.open('blast-garden', 'BlastGarden', const {'scope': 'personal'});
        event(pa, coop ? 'coop' : 'versus');
        event(pa, 'invite', {'device': b.identity.device});
        await until(() => (data(pb)['invites'] as List? ?? []).isNotEmpty);
        event(pb, 'accept', {'device': a.identity.device});
        await until(
          () => data(pa)['mode'] == 'game' && data(pb)['mode'] == 'game',
        );
        expect(data(pa)['title'], data(pb)['title']);
        // Cumulative bomb input survives the first dropped packet.
        ba.drop = true;
        event(pb, 'bomb');
        await Future<void>.delayed(const Duration(milliseconds: 180));
        ba.drop = false;
        int guestBombs() {
          if (ab.sent.isEmpty) return 0;
          final bytes = ab.sent.last;
          var count = 0;
          for (var i = 487; i + 5 < bytes.length; i += 6) {
            if (bytes[i + 1] == 1) count++;
          }
          return count;
        }

        await until(() => guestBombs() == 1 && ba.sent.isNotEmpty);
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(
          guestBombs(),
          1,
          reason: 'Repeated input packets must not duplicate a bomb',
        );
        final oldState = List<int>.of(ab.sent.last);
        final oldInput = List<int>.of(ba.sent.last);
        final oldSession = oldState.sublist(1, 9);
        event(pa, 'restart');
        await until(
          () =>
              ab.sent.isNotEmpty &&
              ab.sent.last.sublist(1, 9).toString() != oldSession.toString(),
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
        ab.deliver(oldState);
        ba.deliver(oldInput);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(data(pb)['status'], isNot(contains('Connection lost')));
        expect(data(pb)['timer'], '0:00');
        expect(data(pb)['title'], data(pa)['title']);
        event(pa, 'leave');
        await until(() => data(pb)['status'] == 'Your friend left the game');
        expect(pa['blast-garden']?.status, PluginStatus.running);
        expect(pb['blast-garden']?.status, PluginStatus.running);
      },
    );
  }
}
