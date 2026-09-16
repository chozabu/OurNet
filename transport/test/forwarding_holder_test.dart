import 'dart:io';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';
import 'package:test/test.dart';

void main() {
  test(
    'chosen helper retains ciphertext across restart and delivers with sender offline',
    () async {
      final dir = await Directory.systemTemp.createTemp('ournet-holder-');
      final a = Node(await LocalIdentity.create(), Store());
      final b = Node(await LocalIdentity.create(), Store());
      final helperIdentity = await LocalIdentity.create();
      var holder = Node(helperIdentity, Store(path: '${dir.path}/holder.db'));
      final na = PeerNetwork(a), nb = PeerNetwork(b);
      var nh = PeerNetwork(holder);
      try {
        await a.addContact(b.identity.certificate);
        await b.addContact(a.identity.certificate);
        await na.start(local: true, automatic: false);
        await nh.start(local: true, automatic: false);
        await na.addCard(nh.contactCard());
        await nh.addCard(na.contactCard());
        final message = await a.publish(
          'message',
          {'text': 'Delivered later'},
          audience: [b.person],
          via: [holder.person],
        );
        await na.sync(holder.identity.device);
        expect(holder.store.get(message.id), isNotNull);
        expect(await holder.content(holder.store.get(message.id)!), isNull);
        expect(
          a.store
              .evidence(message.id)
              .any(
                (e) =>
                    e.data['domain'] == 'ournet/receipt/2' &&
                    e.certificate.person == holder.person,
              ),
          isTrue,
        );
        await na.stop();
        await nh.stop();
        await holder.close();
        holder = Node(helperIdentity, Store(path: '${dir.path}/holder.db'));
        nh = PeerNetwork(holder);
        await nh.start(local: true, automatic: false);
        await nb.start(local: true, automatic: false);
        await nb.addCard(nh.contactCard());
        await nh.addCard(nb.contactCard());
        await nb.sync(holder.identity.device);
        expect(
          (await b.content(b.store.get(message.id)!))!['text'],
          'Delivered later',
        );
        expect(na.running, isFalse);
      } finally {
        await na.stop();
        await nb.stop();
        await nh.stop();
        await a.close();
        await b.close();
        await holder.close();
        await dir.delete(recursive: true);
      }
    },
  );
}
