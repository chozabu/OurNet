import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';
import 'package:test/test.dart';

void main() {
  test(
    'a linked device learns friends from its owner and converses directly',
    () async {
      final laptop = Node(await LocalIdentity.create(), Store());
      final phone = Node(
        await LocalIdentity.create(root: laptop.identity.root, label: 'Phone'),
        Store(),
      );
      final friend = Node(await LocalIdentity.create(), Store());
      final nl = PeerNetwork(laptop),
          np = PeerNetwork(phone),
          nf = PeerNetwork(friend);
      try {
        await nl.start(local: true, automatic: false);
        await np.start(local: true, automatic: false);
        await nf.start(local: true, automatic: false);
        // The phone and the friend only know the laptop.
        await nl.addCard(np.contactCard());
        await np.addCard(nl.contactCard());
        await nl.addCard(nf.contactCard());
        await nf.addCard(nl.contactCard());
        await nl.sync(friend.identity.device);
        await nl.sync(phone.identity.device);
        expect(phone.contacts, contains(friend.identity.device));
        expect(friend.contacts, contains(phone.identity.device));

        final message = await phone.publish(
          'message',
          {'text': 'from the phone'},
          audience: [friend.person],
        );
        await np.sync(friend.identity.device);
        expect(np.syncErrors, isEmpty);
        expect(
          (await friend.content(friend.store.get(message.id)!))!['text'],
          'from the phone',
        );
        final reply = await friend.publish(
          'message',
          {'text': 'to both devices'},
          audience: [laptop.person],
        );
        await nf.sync(phone.identity.device);
        expect(
          (await phone.content(phone.store.get(reply.id)!))!['text'],
          'to both devices',
        );
      } finally {
        await nl.stop();
        await np.stop();
        await nf.stop();
        await laptop.close();
        await phone.close();
        await friend.close();
      }
    },
  );
}
