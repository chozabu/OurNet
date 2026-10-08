import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';
import 'package:test/test.dart';

class FlakyNetwork extends PeerNetwork {
  FlakyNetwork(super.node);
  bool fail = true;
  int requests = 0;
  @override
  Future<Json> request(String device, Json request) {
    requests++;
    if (fail) return Future.error(StateError('Test device unreachable'));
    return super.request(device, request);
  }
}

void main() {
  test('edits do not dial a device that keeps failing, and contact from it '
      'delivers at once', () async {
    final a = Node(await LocalIdentity.create(), Store());
    final b = Node(await LocalIdentity.create(), Store());
    final na = FlakyNetwork(a), nb = PeerNetwork(b);
    try {
      await na.start(local: true);
      await nb.start(local: true, automatic: false);
      await na.addCard(nb.contactCard());
      await nb.addCard(na.contactCard());
      final device = b.identity.device;
      for (var i = 0; i < 3; i++) {
        await na.sync(device);
      }
      expect(na.syncErrors[device], contains('unreachable'));
      // Let the contact's own change notification settle first.
      await Future<void>.delayed(const Duration(seconds: 1));
      final before = na.requests;
      final message = await a.publish(
        'message',
        {'text': 'Waits for the friend'},
        audience: [b.person],
      );
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(na.requests, before, reason: 'an edit dialled a failing device');
      na.fail = false;
      // The friend comes back and syncs: its message arrives in the reply,
      // and the sender retries straight away instead of after its backoff.
      await nb.sync(a.identity.device);
      expect(b.store.get(message.id), isNotNull);
      for (var i = 0; i < 50 && na.syncErrors.isNotEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(na.syncErrors, isEmpty);
      expect(na.lastSync[device], isNotNull);
    } finally {
      await na.stop();
      await nb.stop();
      await a.close();
      await b.close();
    }
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('sync times are kept across a restart', () async {
    final a = Node(await LocalIdentity.create(), Store());
    final b = Node(await LocalIdentity.create(), Store());
    final na = PeerNetwork(a), nb = PeerNetwork(b);
    try {
      await na.start(local: true, automatic: false);
      await nb.start(local: true, automatic: false);
      await na.addCard(nb.contactCard());
      await nb.addCard(na.contactCard());
      final device = b.identity.device;
      await na.sync(device);
      await na.sync(device);
      final last = na.lastSync[device]!;
      await na.stop();
      expect(
        PeerNetwork(a).lastSync[device]?.millisecondsSinceEpoch,
        last.millisecondsSinceEpoch,
      );
    } finally {
      await na.stop();
      await nb.stop();
      await a.close();
      await b.close();
    }
  });
}
