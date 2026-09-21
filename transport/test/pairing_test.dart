import 'dart:convert';
import 'package:test/test.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';

void main() {
  test(
    'pairing requires approval, pins identity, exchanges contacts and is single use',
    () async {
      final owner = Node(await LocalIdentity.create(label: 'PC'), Store());
      final phone = Node(await LocalIdentity.create(label: 'Phone'), Store());
      final a = PeerNetwork(owner), b = PeerNetwork(phone);
      addTearDown(() async {
        await a.stop();
        await b.stop();
        await owner.close();
        await phone.close();
      });
      await a.start(local: true, automatic: false);
      await b.start(local: true, automatic: false);
      var allow = false;
      var confirmations = 0;
      late String sessionToken;
      final session = PairingSession(a, (cert, code) async {
        confirmations++;
        expect(cert.device, phone.identity.device);
        expect(
          code,
          PairingSession.code(sessionToken, phone.identity.certificate),
        );
        return allow;
      });
      final invitation = session.invitation;
      sessionToken = (jsonDecode(invitation) as Map)['token'];
      await expectLater(
        session.approve(phone.identity.device, {
          'token': 'wrong',
          'card': jsonDecode(b.contactCard()),
        }),
        throwsStateError,
      );
      await expectLater(
        session.approve(owner.identity.device, {
          'token': sessionToken,
          'card': jsonDecode(b.contactCard()),
        }),
        throwsStateError,
      );
      expect(confirmations, 0);
      await b.addCard(a.contactCard());
      await expectLater(
        b.request(owner.identity.device, {
          'type': 'pull',
          'inventory': phone.inventory(),
        }),
        throwsA(anything),
      );
      expect(owner.contacts, isEmpty);
      await expectLater(PairingSession.join(b, invitation), throwsStateError);
      expect(owner.contacts, isEmpty);
      expect(session.available, isTrue);
      allow = true;
      final paired = await PairingSession.join(b, invitation);
      expect(paired.person, owner.person);
      expect(paired.root, isNull);
      expect(paired.device, phone.identity.device);
      expect(owner.contacts[paired.device]!.person, owner.person);
      expect(phone.contacts[owner.identity.device], isNotNull);
      expect(
        phone.store.setting('address/${owner.identity.device}'),
        isNotNull,
      );
      expect(session.available, isFalse);
      await expectLater(PairingSession.join(b, invitation), throwsA(anything));
      expect(confirmations, 2);
      await b.stop();
      final joined = Node(paired, phone.store);
      final joinedNetwork = PeerNetwork(joined);
      try {
        await joinedNetwork.start(local: true, automatic: false);
        final post = await owner.publish('post', {'text': 'After pairing'});
        await joinedNetwork.sync(owner.identity.device);
        expect(joined.store.get(post.id), isNotNull);
      } finally {
        await joinedNetwork.stop();
      }
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'a paired device gets the sealed root and can pair another device itself',
    () async {
      const phrase = 'correct horse battery staple';
      final laptop = Node(
        await (await LocalIdentity.create(
          label: 'Laptop',
        )).seal(phrase, memory: 8 * 1024, iterations: 1),
        Store(),
      );
      final phone = Node(await LocalIdentity.create(label: 'Phone'), Store());
      final tablet = Node(await LocalIdentity.create(label: 'Tablet'), Store());
      final watch = Node(await LocalIdentity.create(label: 'Watch'), Store());
      final networks = [
        for (final node in [laptop, phone, tablet, watch]) PeerNetwork(node),
      ];
      addTearDown(() async {
        for (final network in networks) {
          await network.stop();
        }
      });
      for (final network in networks) {
        await network.start(local: true, automatic: false);
      }
      final [a, b, c, d] = networks;

      expect(
        () => PairingSession(a, (_, _) async => true),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('recovery phrase'),
          ),
        ),
      );
      final fromLaptop = PairingSession(
        a,
        (_, _) async => true,
        root: await laptop.identity.unlockRoot(phrase),
      );
      final onPhone = await PairingSession.join(b, fromLaptop.invitation);
      expect(onPhone.root, isNull);
      expect(
        onPhone.sealedRoot!.toJson(),
        laptop.identity.sealedRoot!.toJson(),
      );

      // The phone, now enrolled, opens Add device without the laptop.
      await b.stop();
      await a.stop();
      final enrolled = Node(onPhone, phone.store);
      final e = PeerNetwork(enrolled);
      networks.add(e);
      await e.start(local: true, automatic: false);
      expect(() => PairingSession(e, (_, _) async => true), throwsStateError);
      final fromPhone = PairingSession(
        e,
        (_, _) async => true,
        root: await onPhone.unlockRoot(phrase),
      );
      final onTablet = await PairingSession.join(c, fromPhone.invitation);
      expect(onTablet.person, laptop.person);
      expect(await onTablet.certificate.valid(), isTrue);
      expect(onTablet.sealedRoot, isNotNull);
      expect(enrolled.contacts[onTablet.device]!.person, laptop.person);

      // A device paired with the box unticked gets no copy.
      final withoutCopy = PairingSession(
        e,
        (_, _) async => true,
        root: await onPhone.unlockRoot(phrase),
      )..shareRoot = false;
      final onWatch = await PairingSession.join(d, withoutCopy.invitation);
      expect(onWatch.person, laptop.person);
      expect(onWatch.holdsRoot, isFalse);
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test('expired invitations are rejected before connecting', () {
    expect(
      () => PairingSession.parse(
        canonical({
          'pairing': 1,
          'token': 'x' * 44,
          'expires': DateTime.now().millisecondsSinceEpoch - 1,
        }),
      ),
      throwsStateError,
    );
  });
}
