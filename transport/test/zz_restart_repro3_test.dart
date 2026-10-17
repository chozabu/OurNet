import 'dart:async';

import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';
import 'package:test/test.dart';

/// A dials the stopped C; C's new endpoint is up shortly before that dial's
/// 15 s timeout, and C introduces itself and syncs at a fixed offset from it.
void main() {
  const offsets = [-200, -20, 0, 5, 10, 20, 50, 100];
  for (var round = 0; round < 3; round++) {
    for (final offset in offsets) {
      test('sync at timeout ${offset >= 0 ? '+' : ''}$offset ms (round $round)',
          () async {
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
        var dialEnded = -1;
        String dial = 'pending';
        unawaited(na.request(c.identity.device, {'type': 'pull'}).then(
          (_) => dial = 'ok',
          onError: (Object e) => dial = '${e.runtimeType}',
        ).whenComplete(() => dialEnded = sw.elapsedMilliseconds));
        await Future<void>.delayed(const Duration(milliseconds: 14000));
        nc = PeerNetwork(c);
        await nc.start(local: true);
        final wait = 15000 + offset - sw.elapsedMilliseconds;
        if (wait > 0) await Future<void>.delayed(Duration(milliseconds: wait));
        final began = sw.elapsedMilliseconds;
        await na.addCard(nc.contactCard());
        final s = Stopwatch()..start();
        await nc.sync(a.identity.device);
        final took = s.elapsedMilliseconds;
        final err = nc.syncErrors[a.identity.device];
        print('[off $offset r$round] dial $dial at ${dialEnded}ms; '
            'sync began ${began}ms took ${took}ms err=${err == null ? 'none' : 'yes'}');
      }, timeout: const Timeout(Duration(seconds: 150)));
    }
  }
}
