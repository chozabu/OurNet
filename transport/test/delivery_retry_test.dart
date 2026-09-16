import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';
import 'package:test/test.dart';

class IntermittentNetwork extends PeerNetwork {
  IntermittentNetwork(super.node);
  bool fail = true;
  @override
  Future<Json> request(String device, Json request) {
    if (fail) return Future.error(StateError('Test connection interrupted'));
    return super.request(device, request);
  }
}

void main() {
  test('failed exchange remains visible until a successful retry', () async {
    final a = Node(await LocalIdentity.create(), Store());
    final b = Node(await LocalIdentity.create(), Store());
    final na = IntermittentNetwork(a), nb = PeerNetwork(b);
    try {
      await na.start(local: true, automatic: false);
      await nb.start(local: true, automatic: false);
      await na.addCard(nb.contactCard());
      await nb.addCard(na.contactCard());
      final message = await a.publish(
        'message',
        {'text': 'Retain on failure'},
        audience: [b.person],
      );
      await na.sync(b.identity.device);
      expect(na.syncErrors[b.identity.device], contains('interrupted'));
      expect(na.lastSync[b.identity.device], isNull);
      expect(a.store.get(message.id), isNotNull);
      na.fail = false;
      await na.sync(b.identity.device);
      expect(na.syncErrors, isEmpty);
      expect(na.lastSync[b.identity.device], isNotNull);
      expect(b.store.get(message.id), isNotNull);
    } finally {
      await na.stop();
      await nb.stop();
      await a.close();
      await b.close();
    }
  });
}
