import 'dart:async';

import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';
import 'package:test/test.dart';

void main() {
  test(
    'a sync session reuses one connection for its pages',
    () async {
      final window = Node.inventoryWindow;
      Node.inventoryWindow = 2;
      final a = Node(await LocalIdentity.create(), Store());
      final b = Node(await LocalIdentity.create(), Store());
      final na = PeerNetwork(a), nb = PeerNetwork(b);
      try {
        await na.start(local: true, automatic: false);
        await nb.start(local: true, automatic: false);
        await na.addCard(nb.contactCard());
        await nb.addCard(na.contactCard());
        final sent = [
          for (var i = 0; i < 12; i++)
            await a.publish(
              'message',
              {'text': 'Page $i'},
              audience: [b.person],
            ),
        ];
        // A session's requests, and a session straight after it, share one
        // connection.
        await na.sync(b.identity.device);
        expect(na.dialed, 1);
        await na.sync(b.identity.device);
        for (final o in sent) {
          expect(b.store.get(o.id), isNotNull);
        }
        expect(na.dialed, 1);
      // Closed shortly after the last request; the next session redials.
        await Future<void>.delayed(
          PeerNetwork.pooledIdle + const Duration(seconds: 1),
        );
        await na.sync(b.identity.device);
        expect(na.dialed, 2);
      } finally {
        Node.inventoryWindow = window;
        await na.stop();
        await nb.stop();
        await a.close();
        await b.close();
      }
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'idle pooled connections make room for other devices',
    () async {
      final server = Node(await LocalIdentity.create(), Store());
      final ns = PeerNetwork(server);
      final clients = [
        for (var i = 0; i < PeerNetwork.maxInbound + 2; i++)
          Node(await LocalIdentity.create(), Store()),
      ];
      final networks = [for (final c in clients) PeerNetwork(c)];
      try {
        await ns.start(local: true, automatic: false);
        for (final n in networks) {
          await n.start(local: true, automatic: false);
          await n.addCard(ns.contactCard());
          await ns.addCard(n.contactCard());
        }
        final device = server.identity.device;
        // Twice each, so the second goes on a pooled connection that then
        // stays open on the server, filling its inbound slots.
        for (final n in networks) {
          await n.sync(device);
          await n.sync(device);
          expect(n.syncErrors, isEmpty);
        }
        // A device whose pooled connection was closed to make room sends its
        // next request on a new one.
        await networks.first.sync(device);
        expect(networks.first.syncErrors, isEmpty);
      } finally {
        for (final n in networks) {
          await n.stop();
        }
        await ns.stop();
        for (final c in clients) {
          await c.close();
        }
        await server.close();
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'a server with every slot in use says busy, and is tried again soon',
    () async {
      final server = Node(await LocalIdentity.create(), Store());
      final ns = PeerNetwork(server);
      final clients = [
        for (var i = 0; i <= PeerNetwork.maxInbound; i++)
          Node(await LocalIdentity.create(), Store()),
      ];
      final networks = [for (final c in clients) PeerNetwork(c)];
      final gate = Completer<void>();
      ns.signal = (_, _) async {
        await gate.future;
        return {};
      };
      try {
        await ns.start(local: true, automatic: false);
        for (final n in networks) {
          await n.start(local: true, automatic: false);
          await n.addCard(ns.contactCard());
          await ns.addCard(n.contactCard());
        }
        final device = server.identity.device;
        // Requests the server holds on to, one per slot.
        final held = [
          for (final n in networks.skip(1))
            n.request(device, {'type': 'signal', 'payload': {}}),
        ];
        await Future<void>.delayed(const Duration(seconds: 1));
        final late = networks.first;
        await late.sync(device);
        expect(late.syncErrors, isEmpty);
        expect(late.lastSync[device], isNull);
        expect(late.events.first, contains('busy'));
        gate.complete();
        await Future.wait(held);
        for (var i = 0; i < 100 && late.lastSync[device] == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(late.lastSync[device], isNotNull);
      } finally {
        if (!gate.isCompleted) gate.complete();
        for (final n in networks) {
          await n.stop();
        }
        await ns.stop();
        for (final c in clients) {
          await c.close();
        }
        await server.close();
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
