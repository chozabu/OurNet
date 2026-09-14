import 'package:test/test.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';

void main() {
  test(
    'a caller adding a contact does not grant admission at the receiver',
    () async {
      final a = Node(await LocalIdentity.create(), Store());
      final b = Node(await LocalIdentity.create(), Store());
      final na = PeerNetwork(a), nb = PeerNetwork(b);
      try {
        await na.start(local: true);
        await nb.start(local: true);
        await nb.addCard(na.contactCard());
        await a.publish('post', {'text': 'Admitted friends only'});
        await expectLater(
          nb.request(a.identity.device, {
            'type': 'pull',
            'inventory': b.inventory(),
          }),
          throwsA(anything),
        );
        expect(b.store.count, 0);
      } finally {
        await na.stop();
        await nb.stop();
        await a.close();
        await b.close();
      }
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'sync reports progress while running and completion afterwards',
    () async {
      final a = Node(await LocalIdentity.create(label: 'A'), Store());
      final b = Node(await LocalIdentity.create(label: 'B'), Store());
      final na = PeerNetwork(a), nb = PeerNetwork(b);
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
      await a.publish('post', {'text': 'progress'});
      final seen = <Map<String, int>>[];
      final activity = na.syncActivity.stream.listen(
        (_) => seen.add(na.syncing),
      );
      await na.sync(b.identity.device);
      await Future<void>.delayed(Duration.zero);
      await activity.cancel();
      final device = b.identity.device;
      expect(seen.first, {device: 0});
      expect(seen.any((s) => (s[device] ?? 0) > 0), isTrue);
      expect(seen.last, isEmpty);
      expect(na.syncing, isEmpty);
      expect(na.lastSync[device], isNotNull);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'two real iroh endpoints sync selected data',
    () async {
      final a = Node(await LocalIdentity.create(label: 'A'), Store());
      final b = Node(await LocalIdentity.create(label: 'B'), Store());
      final na = PeerNetwork(a), nb = PeerNetwork(b);
      addTearDown(() async {
        await na.stop();
        await nb.stop();
        await a.close();
        await b.close();
      });
      await na.start(local: true);
      await nb.start(local: true);
      await na.addCard(nb.contactCard());
      await nb.addCard(na.contactCard());
      final post = await a.publish('post', {'text': 'over actual QUIC'});
      await na.sync(b.identity.device);
      expect(b.store.get(post.id), isNotNull, reason: na.events.join('\n'));
      final message = await a.publish(
        'message',
        {'text': 'private actual QUIC'},
        audience: [b.person],
        space: '_messages',
      );
      await na.sync(b.identity.device);
      expect(
        (await b.content(b.store.get(message.id)!))!['text'],
        'private actual QUIC',
      );
      expect(
        a.store
            .evidence(message.id)
            .where((e) => e.data['domain'] == 'ournet/receipt/2'),
        isNotEmpty,
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
