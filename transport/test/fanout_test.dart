import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';
import 'package:test/test.dart';

/// Counts the sync sessions started with each device.
class CountingNetwork extends PeerNetwork {
  CountingNetwork(super.node);
  final sessions = <String, int>{};
  @override
  Future<void> sync(String device) {
    sessions[device] = (sessions[device] ?? 0) + 1;
    return super.sync(device);
  }
}

void main() {
  test('a change syncs only with the devices it concerns', () async {
    final a = Node(await LocalIdentity.create(), Store());
    final b = Node(await LocalIdentity.create(), Store());
    final c = Node(await LocalIdentity.create(), Store());
    final na = CountingNetwork(a), nb = PeerNetwork(b), nc = PeerNetwork(c);
    addTearDown(() async {
      for (final n in [na, nb, nc]) {
        await n.stop();
      }
      for (final n in [a, b, c]) {
        await n.close();
      }
    });
    await nb.start(local: true, automatic: false);
    await nc.start(local: true, automatic: false);
    await na.start(local: true);
    await na.addCard(nb.contactCard());
    await nb.addCard(na.contactCard());
    await na.addCard(nc.contactCard());
    await nc.addCard(na.contactCard());
    // Agree with both, so each has a mark, and let notifications settle.
    for (var i = 0; i < 2; i++) {
      await na.sync(b.identity.device);
      await na.sync(c.identity.device);
    }
    await Future<void>.delayed(const Duration(seconds: 1));
    na.sessions.clear();

    final message = await a.publish(
      'message',
      {'text': 'for b alone'},
      space: '_messages',
      audience: [b.person],
    );
    for (var i = 0; i < 50 && b.store.get(message.id) == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(b.store.get(message.id), isNotNull);
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(na.sessions[b.identity.device], greaterThan(0));
    expect(na.sessions[c.identity.device], isNull);

    // A public post may concern anyone.
    na.sessions.clear();
    await a.publish('post', {'text': 'for everyone'});
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(na.sessions[c.identity.device], greaterThan(0));
  }, timeout: const Timeout(Duration(seconds: 60)));
}
