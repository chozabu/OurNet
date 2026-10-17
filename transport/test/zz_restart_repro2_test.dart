import 'dart:async';

import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';
import 'package:test/test.dart';

/// Mirrors app/test/location_share_test.dart "a friend out of reach is tried
/// later": three nodes, automatic sync on, two requests from A to the stopped
/// C (one pooled), C restarted right as they time out, then C syncs with A.
void main() {
  for (var i = 0; i < 8; i++) {
    test('restart $i', () async {
      final a = Node(await LocalIdentity.create(label: 'Pixel'), Store());
      final b = Node(await LocalIdentity.create(label: 'Desk'), Store());
      final c = Node(await LocalIdentity.create(label: 'Away'), Store());
      final na = PeerNetwork(a), nb = PeerNetwork(b);
      var nc = PeerNetwork(c);
      addTearDown(() async {
        await na.stop();
        await nb.stop();
        await nc.stop();
        await a.close();
        await b.close();
        await c.close();
      });
      await na.start(local: true);
      await nb.start(local: true);
      await na.addCard(nb.contactCard());
      await nb.addCard(na.contactCard());
      await na.sync(b.identity.device);
      await nc.start(local: true);
      await na.addCard(nc.contactCard());
      await nc.addCard(na.contactCard());
      await nc.stop();

      final sw = Stopwatch()..start();
      String t() => '${sw.elapsedMilliseconds}ms';
      final first = na.request(c.identity.device, {'type': 'pull'}).then(
        (_) => 'ok',
        onError: (Object e) => '${e.runtimeType}',
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      unawaited(na.sync(b.identity.device));
      final second = na.request(c.identity.device, {'type': 'pull'}).then(
        (_) => 'ok',
        onError: (Object e) => '${e.runtimeType}',
      );
      print('[$i] first: ${await first} at ${t()}');

      nc = PeerNetwork(c);
      await nc.start(local: true);
      await na.addCard(nc.contactCard());
      final s = Stopwatch()..start();
      await nc.sync(a.identity.device);
      print('[$i] C sync with A took ${s.elapsedMilliseconds}ms, '
          'error ${nc.syncErrors[a.identity.device]}, at ${t()}');
      print('[$i] second: ${await second} at ${t()}');
      s.reset();
      try {
        await na.request(c.identity.device, {'type': 'pull'});
        print('[$i] A->C after: ok ${s.elapsedMilliseconds}ms');
      } catch (e) {
        print('[$i] A->C after: ${e.runtimeType} ${s.elapsedMilliseconds}ms');
      }
    }, timeout: const Timeout(Duration(seconds: 150)));
  }
}
