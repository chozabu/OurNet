import 'dart:async';
import 'dart:io';

import 'package:iroh_quic/iroh_quic.dart' as iroh;
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';
import 'package:test/test.dart';

/// A peer that goes silent part-way through its handshake (out of signal, or
/// restarting just as it was dialled) must not hold off other devices.
void main() {
  test(
    'a handshake left hanging does not block other inbound connections',
    () async {
      final a = Node(await LocalIdentity.create(), Store());
      final c = Node(await LocalIdentity.create(), Store());
      final na = PeerNetwork(a), nc = PeerNetwork(c);
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
      final address = iroh.EndpointAddr.decode(
        unb64(c.store.setting('address/${a.identity.device}') as String),
      );
      final direct = address.ipAddrs.firstWhere((s) => !s.startsWith('['));
      final colon = direct.lastIndexOf(':');
      final host = InternetAddress(direct.substring(0, colon));
      final port = int.parse(direct.substring(colon + 1));

      // Lets the stranger's first packet through to A and nothing after it,
      // so A's side of that handshake waits for a client that has gone.
      final relay = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
      );
      addTearDown(relay.close);
      var passed = 0;
      relay.listen((event) {
        final datagram = event == RawSocketEvent.read ? relay.receive() : null;
        if (datagram == null || datagram.port == port) return;
        if (passed++ == 0) relay.send(datagram.data, host, port);
      });
      final stranger = await iroh.Endpoint.bind(
        relayMode: iroh.RelayMode.disabled,
      );
      addTearDown(stranger.close);
      unawaited(
        stranger
            .connect(
              iroh.EndpointAddr(
                address.id,
                ipAddrs: ['127.0.0.1:${relay.port}'],
              ),
              'ournet/2'.codeUnits,
            )
            .then((connection) => connection.close(), onError: (Object _) {}),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (passed == 0 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(passed, greaterThan(0));
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final took = Stopwatch()..start();
      await nc.sync(a.identity.device);
      expect(nc.syncErrors[a.identity.device], isNull);
      expect(took.elapsed, lessThan(const Duration(seconds: 5)));
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
