import 'package:flutter_test/flutter_test.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet/services/network.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Flutter adapter syncs selected data over real iroh endpoints',
    () async {
      final a = Node(await LocalIdentity.create(label: 'A'), Store());
      final b = Node(await LocalIdentity.create(label: 'B'), Store());
      final na = Network(a), nb = Network(b);
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
