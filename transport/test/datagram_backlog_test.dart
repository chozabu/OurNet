import 'dart:async';
import 'dart:typed_data';

import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';
import 'package:test/test.dart';

void main() {
  test(
    'blocking a peer while its datagram link opens prevents the send',
    () async {
      final a = Node(await LocalIdentity.create(), Store());
      final b = Node(await LocalIdentity.create(), Store());
      final na = PeerNetwork(a), nb = PeerNetwork(b);
      try {
        await na.start(local: true, automatic: false);
        await nb.start(local: true, automatic: false);
        await Future<void>.delayed(const Duration(seconds: 1));
        await na.addCard(nb.contactCard());
        await nb.addCard(na.contactCard());
        var received = 0;
        b.registry.handleDatagrams('test', (_, _) {
          received++;
        }, owner: 'test');
        final pending = na.datagram(b.identity.device, 'test', [42]);
        a.block(b.person, true);
        expect(await pending, isFalse);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(received, 0);
        a.block(b.person, false);
        expect(await na.datagram(b.identity.device, 'test', [42]), isTrue);
      } finally {
        await na.stop();
        await nb.stop();
        await a.close();
        await b.close();
      }
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  for (final byteLimit in [false, true]) {
    test(
      'cold datagram backlog bounds ${byteLimit ? 'bytes' : 'packets'}',
      () async {
        final a = Node(await LocalIdentity.create(), Store());
        final b = Node(await LocalIdentity.create(), Store());
        final na = PeerNetwork(a), nb = PeerNetwork(b);
        try {
          await na.start(local: true, automatic: false);
          await nb.start(local: true, automatic: false);
          await Future<void>.delayed(const Duration(seconds: 1));
          await na.addCard(nb.contactCard());
          await nb.addCard(na.contactCard());
          final received = Completer<void>();
          b.registry.handleDatagrams('test', (_, data) {
            if (data.length == 1 && data[0] == 42 && !received.isCompleted) {
              received.complete();
            }
          }, owner: 'test');
          final size = byteLimit ? 1100 : 1;
          final capacity = byteLimit
              ? PeerNetwork.maxPendingDatagramBytes ~/ size
              : PeerNetwork.maxPendingDatagrams;
          // All calls enter before the first dial can finish. The next call
          // must refuse immediately, rather than waiting behind that dial.
          final queued = [
            for (var i = 0; i < capacity; i++)
              na.datagram(b.identity.device, 'test', Uint8List(size)),
          ];
          expect(
            await na
                .datagram(b.identity.device, 'test', Uint8List(size))
                .timeout(const Duration(seconds: 1)),
            isFalse,
          );
          final sent = await Future.wait(queued);
          expect(sent, everyElement(isTrue));
          // Finishing the dial releases the reservation and normal forwarding
          // still works. UDP delivery of the burst itself is not guaranteed.
          expect(await na.datagram(b.identity.device, 'test', [42]), isTrue);
          await received.future.timeout(const Duration(seconds: 5));
          a.block(b.person, true);
          expect(await na.datagram(b.identity.device, 'test', [42]), isFalse);
        } finally {
          await na.stop();
          await nb.stop();
          await a.close();
          await b.close();
        }
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  }
}
