import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';

void main() {
  test('listeners hear only changes that may concern their kinds', () async {
    final a = await LocalIdentity.create(), b = await LocalIdentity.create();
    final node = Node(a, Store());
    addTearDown(node.close);
    await node.addContact(b.certificate);
    var heard = 0;
    final subscription = node.onChangesTo(const {'message'}, () => heard++);
    addTearDown(subscription.cancel);
    Future<void> settle() => Future<void>.delayed(Duration.zero);

    await node.publish('post', {'text': 'Elsewhere'}, space: 'forum');
    await settle();
    expect(heard, 0, reason: 'a post does not concern messages');

    await node.publish('message', {'text': 'Hi'}, audience: [b.person]);
    await settle();
    expect(heard, 1);

    // Not a stored object (a setting, a contact): always heard.
    node.notify();
    await settle();
    expect(heard, 2);

    // Who may read or see what changed: always heard.
    await node.publish('revoke', {
      'device': b.certificate.device,
    }, space: '_devices');
    await settle();
    expect(heard, greaterThanOrEqualTo(3));
  });
}
