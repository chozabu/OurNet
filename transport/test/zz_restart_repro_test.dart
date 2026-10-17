import 'dart:async';

import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';
import 'package:test/test.dart';

void main() {
  for (final delay in [for (var r = 0; r < 3; r++) ...[1000, 7000, 14000, 14900, 15100, 16000]]) {
    test('restart at $delay ms', () async {
      final a = Node(await LocalIdentity.create(), Store());
      final c = Node(await LocalIdentity.create(), Store());
      final na = PeerNetwork(a);
      var nc = PeerNetwork(c);
      addTearDown(() async {
        await na.stop();
        await nc.stop();
        await a.close();
        await c.close();
      });
      await na.start(local: true);
      await nc.start(local: true);
      await na.addCard(nc.contactCard());
      await nc.addCard(na.contactCard());
      await nc.stop();
      final sw = Stopwatch()..start();
      // A dials the stopped C (like the location send).
      final failed = na.request(c.identity.device, {'type': 'pull'}).then(
        (_) => 'ok',
        onError: (Object e) => '${e.runtimeType}',
      );
      await Future<void>.delayed(Duration(milliseconds: delay));
      nc = PeerNetwork(c);
      await nc.start(local: true);
      await na.addCard(nc.contactCard());
      final t = Stopwatch()..start();
      Object? err;
      try {
        await nc.request(a.identity.device, {'type': 'pull'});
      } catch (e) {
        err = e;
      }
      print('[$delay] A dial: ${await Future.any([failed, Future.value('pending')])}');
      print('[$delay] C->A after restart: ${err?.runtimeType ?? 'ok'} in ${t.elapsed}');
      t.reset();
      try {
        await na.request(c.identity.device, {'type': 'pull'});
        print('[$delay] A->C after restart: ok in ${t.elapsed}');
      } catch (e) {
        print('[$delay] A->C after restart: ${e.runtimeType} in ${t.elapsed}');
      }
    }, timeout: const Timeout(Duration(seconds: 120)));
  }
}
