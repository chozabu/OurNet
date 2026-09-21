import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';

// Argon2id at its real cost takes seconds per call; these tests are about the
// logic, and the parameters travel with each copy.
const memory = 8 * 1024, iterations = 1;
const phrase = 'correct horse battery staple';

Future<LocalIdentity> sealed(LocalIdentity identity) =>
    identity.seal(phrase, memory: memory, iterations: iterations);

void main() {
  test(
    'a sealed root survives the vault and opens only with the phrase',
    () async {
      final original = await LocalIdentity.create(label: 'PC');
      final identity = await sealed(original);
      expect(identity.root, isNull);
      expect(identity.holdsRoot, isTrue);
      expect(identity.device, original.device);

      final secrets = await identity.exportSecrets();
      expect(secrets['root'], isNull);
      final restored = await LocalIdentity.restore(secrets);
      expect(restored.sealedRoot!.toJson(), identity.sealedRoot!.toJson());

      await expectLater(restored.unlockRoot(), throwsStateError);
      await expectLater(
        restored.unlockRoot('correct horse battery stapler'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('not right'),
          ),
        ),
      );
      final root = await restored.unlockRoot('  $phrase ');
      expect(
        (await root.extractPublicKey()).bytes,
        (await original.root!.extractPublicKey()).bytes,
      );
    },
  );

  test('short phrases are refused before anything is sealed', () async {
    final identity = await LocalIdentity.create();
    await expectLater(
      identity.seal('too short', memory: memory, iterations: iterations),
      throwsStateError,
    );
    await expectLater(
      // Padding does not count: the phrase is trimmed before use.
      identity.seal(
        '    too short     ',
        memory: memory,
        iterations: iterations,
      ),
      throwsStateError,
    );
  });

  test('a sealed device adds and revokes only once unlocked', () async {
    final owner = Node(await sealed(await LocalIdentity.create()), Store());
    final phone = await LocalIdentity.create(label: 'Phone');
    await expectLater(
      owner.identity.authorise(phone.certificate),
      throwsStateError,
    );

    final root = await owner.identity.unlockRoot(phrase);
    final approval = await owner.identity.authorise(
      phone.certificate,
      unlocked: root,
    );
    expect(approval.person, owner.person);
    expect(await approval.valid(), isTrue);

    await owner.addContact(approval);
    await expectLater(owner.revoke(approval.device), throwsStateError);
    await owner.revoke(approval.device, unlocked: root);
    expect(owner.revoked, contains(approval.device));
  });

  test('a device enrolled with a copy can add a device of its own', () async {
    final laptop = Node(await sealed(await LocalIdentity.create()), Store());
    final friend = Node(await LocalIdentity.create(), Store());
    await laptop.addContact(friend.identity.certificate);
    await friend.addContact(laptop.identity.certificate);

    final request = await LocalIdentity.create(label: 'Phone');
    final laptopRoot = await laptop.identity.unlockRoot(phrase);
    final phone = await request.enrol(
      await laptop.identity.authorise(
        request.certificate,
        unlocked: laptopRoot,
      ),
      sealedRoot: laptop.identity.sealedRoot,
    );
    expect(phone.root, isNull);
    expect(phone.holdsRoot, isTrue);

    // The laptop is gone; the phone adds a tablet with the same phrase.
    final tablet = await LocalIdentity.create(label: 'Tablet');
    final approval = await phone.authorise(
      tablet.certificate,
      unlocked: await phone.unlockRoot(phrase),
    );
    await friend.addContact(approval);
    expect(friend.contacts[approval.device]!.person, laptop.person);
  });

  test('a copy for another person, or a malformed copy, is refused', () async {
    final alice = await sealed(await LocalIdentity.create());
    final bob = await LocalIdentity.create();
    final request = await LocalIdentity.create();
    final approval = await bob.authorise(request.certificate);
    await expectLater(
      request.enrol(approval, sealedRoot: alice.sealedRoot),
      throwsStateError,
    );

    final good = alice.sealedRoot!.toJson();
    for (final change in <Map<String, Object?>>[
      {'memory': 4 * 1024 * 1024},
      {'iterations': 0},
      {'kdf': 'pbkdf2'},
      {
        'salt': b64([1, 2, 3]),
      },
      {'box': null},
    ]) {
      expect(
        () => SealedRoot.fromJson({...good, ...change}),
        throwsFormatException,
        reason: '$change',
      );
    }

    final secrets = await alice.exportSecrets();
    secrets['sealedRoot'] = (await sealed(bob)).sealedRoot!.toJson();
    await expectLater(LocalIdentity.restore(secrets), throwsStateError);
  });

  test('a node only takes an identity for the same device', () async {
    final identity = await LocalIdentity.create();
    final node = Node(identity, Store());
    final next = await sealed(identity);
    node.updateIdentity(next);
    expect(node.identity.sealedRoot, isNotNull);
    final other = await LocalIdentity.create();
    expect(() => node.updateIdentity(other), throwsStateError);
  });
}
