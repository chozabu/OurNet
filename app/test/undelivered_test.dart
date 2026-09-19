import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/services/undelivered.dart';
import 'package:ournet_core/ournet_core.dart';

void main() {
  test('a sent message is undelivered until its receipt comes back', () async {
    final a = Node(await LocalIdentity.create(), Store());
    final b = Node(await LocalIdentity.create(), Store());
    addTearDown(() async {
      await a.close();
      await b.close();
    });
    await a.addContact(b.identity.certificate);
    await b.addContact(a.identity.certificate);
    final undelivered = Undelivered(a)..start();
    addTearDown(undelivered.close);
    expect(undelivered.any, isFalse);

    await a.publish(
      'message',
      {'text': 'Hello'},
      space: '_messages',
      audience: [b.person],
    );
    await pumpEventQueue();
    expect(undelivered.any, isTrue);

    // b's receipt reaches a in the same exchange.
    await syncPair(a, b);
    expect(undelivered.any, isFalse);

    // Messages from others, and public posts, are not waited for.
    await b.publish(
      'message',
      {'text': 'Hi'},
      space: '_messages',
      audience: [a.person],
    );
    await a.publish('post', {'text': 'Public'});
    await syncPair(a, b);
    await pumpEventQueue();
    expect(undelivered.any, isFalse);
  });
}
