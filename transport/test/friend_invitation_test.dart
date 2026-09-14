import 'dart:convert';
import 'package:test/test.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';

void main() {
  test(
    'friend invitation requires approval and preserves independent identities',
    () async {
      final a = Node(await LocalIdentity.create(label: 'Alice'), Store());
      final b = Node(await LocalIdentity.create(label: 'Bob'), Store());
      final na = PeerNetwork(a), nb = PeerNetwork(b);
      addTearDown(() async {
        await na.stop();
        await nb.stop();
        await a.close();
        await b.close();
      });
      await na.start(local: true, automatic: false);
      await nb.start(local: true, automatic: false);
      final original = b.person;
      await Everyday(a).write({'type': 'note', 'text': 'Private note'});
      var approved = false;
      final session = FriendSession(na, (cert, code) async {
        expect(cert.person, b.person);
        return approved;
      });
      await expectLater(
        session.approve(b.identity.device, {
          'token': 'wrong',
          'card': jsonDecode(nb.contactCard()),
        }),
        throwsStateError,
      );
      await expectLater(
        FriendSession.join(nb, session.invitation),
        throwsStateError,
      );
      expect(a.contacts, isEmpty);
      expect(b.contacts, isEmpty);
      approved = true;
      await FriendSession.join(nb, session.invitation);
      expect(a.contacts[b.identity.device]!.person, original);
      expect(b.person, original);
      expect(b.person, isNot(a.person));
      expect(b.identity.root, isNotNull);
      expect(session.available, isFalse);
      await nb.sync(a.identity.device);
      expect(await Everyday(b).items(), isEmpty);
      final message = await a.publish(
        'message',
        {'text': 'Hi Bob'},
        space: '_messages',
        audience: [b.person],
      );
      await nb.sync(a.identity.device);
      expect(
        await b.content(b.store.get(message.id)!),
        containsPair('text', 'Hi Bob'),
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
  test('expired friend invitations fail before network access', () {
    expect(
      () => FriendSession.parse(
        canonical({'friend': 1, 'token': 'x' * 44, 'expires': 0}),
      ),
      throwsStateError,
    );
  });
}
