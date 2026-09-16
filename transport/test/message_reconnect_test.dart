import 'dart:async';
import 'dart:io';

import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';
import 'package:test/test.dart';

/// Saves at the exact point an otherwise idle exchange is finishing.
class LateMessageNetwork extends PeerNetwork {
  LateMessageNetwork(super.node);
  Future<void> Function()? onIdlePush;

  @override
  Future<Json> request(String device, Json request) async {
    final reply = await super.request(device, request);
    if (request['type'] == 'push' && reply['changed'] == 0) {
      final action = onIdlePush;
      onIdlePush = null;
      await action?.call();
    }
    return reply;
  }
}

void main() {
  test(
    'continuous local changes do not starve automatic delivery',
    () async {
      final a = Node(await LocalIdentity.create(), Store());
      final b = Node(await LocalIdentity.create(), Store());
      final na = PeerNetwork(a), nb = PeerNetwork(b);
      Timer? changes;
      addTearDown(() async {
        changes?.cancel();
        await na.stop();
        await nb.stop();
        await a.close();
        await b.close();
      });
      await na.start(local: true);
      await nb.start(local: true, automatic: false);
      await na.addCard(nb.contactCard());
      await nb.addCard(na.contactCard());
      await na.syncAll();
      // Let contact-change notifications settle before publishing the message.
      await Future<void>.delayed(const Duration(seconds: 1));
      final message = await a.publish(
        'message',
        {'text': 'while editing'},
        space: '_messages',
        audience: [b.person],
      );
      changes = Timer.periodic(const Duration(milliseconds: 50), (_) {
        a.changes.add(null);
      });
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (b.store.get(message.id) == null &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(
        b.store.get(message.id),
        isNotNull,
        reason: 'Delivery must not require local changes to stop',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'message saved during final exchange is delivered without manual retry',
    () async {
      final a = Node(await LocalIdentity.create(), Store());
      final b = Node(await LocalIdentity.create(), Store());
      final na = LateMessageNetwork(a), nb = PeerNetwork(b);
      addTearDown(() async {
        await na.stop();
        await nb.stop();
        await a.close();
        await b.close();
      });
      await na.start(local: true, automatic: false);
      await nb.start(local: true, automatic: false);
      await na.addCard(nb.contactCard());
      await nb.addCard(na.contactCard());
      late SignedObject message;
      na.onIdlePush = () async {
        message = await a.publish(
          'message',
          {'text': 'late send'},
          space: '_messages',
          audience: [b.person],
        );
        // Same trigger as the debounced change listener, while sync is busy.
        unawaited(na.sync(b.identity.device));
      };
      await na.sync(b.identity.device);
      expect((await b.content(b.store.get(message.id)!))!['text'], 'late send');
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'offline message survives sender restart and sends on network start',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ournet-message-',
      );
      final identity = await LocalIdentity.create();
      var a = Node(identity, Store(path: '${directory.path}/sender.db'));
      final b = Node(await LocalIdentity.create(), Store());
      var na = PeerNetwork(a);
      final nb = PeerNetwork(b);
      addTearDown(() async {
        await na.stop();
        await nb.stop();
        await a.close();
        await b.close();
        await directory.delete(recursive: true);
      });
      await nb.start(local: true, automatic: false);
      await na.addCard(nb.contactCard());
      await nb.addCard(na.contactCard());
      final message = await a.publish(
        'message',
        {'text': 'saved offline'},
        space: '_messages',
        audience: [b.person],
      );
      await na.stop();
      await a.close();
      a = Node(identity, Store(path: '${directory.path}/sender.db'));
      na = PeerNetwork(a);
      await na.start(local: true);
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (b.store.get(message.id) == null &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(b.store.get(message.id), isNotNull, reason: na.events.join('\n'));
      expect(
        (await b.content(b.store.get(message.id)!))!['text'],
        'saved offline',
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
