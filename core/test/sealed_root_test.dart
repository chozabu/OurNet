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

  test('any phrase seals, and an empty one opens without asking', () async {
    final original = await LocalIdentity.create();
    final short = await original.seal(
      'abc',
      memory: memory,
      iterations: iterations,
    );
    expect(short.hasPhrase, isTrue);
    await expectLater(short.unlockRoot(), throwsStateError);
    await short.unlockRoot('abc');

    // Padding does not count: the phrase is trimmed before use.
    final open = await original.seal('   ');
    expect(open.root, isNull);
    expect(open.hasPhrase, isFalse);
    // Sealed at the lowest cost whatever was asked: nothing needs guessing.
    expect(open.sealedRoot!.toJson()['memory'], 8 * 1024);
    expect(open.sealedRoot!.toJson()['iterations'], 1);
    final restored = await LocalIdentity.restore(await open.exportSecrets());
    expect(restored.hasPhrase, isFalse);
    final root = await restored.unlockRoot();
    expect(
      (await root.extractPublicKey()).bytes,
      (await original.root!.extractPublicKey()).bytes,
    );
    // Builds before phrase-less copies open them with an empty phrase.
    await open.sealedRoot!.open('');
  });

  test('the phrase can be changed, or removed, with the root', () async {
    final original = await LocalIdentity.create();
    final first = await sealed(original);
    final root = await first.unlockRoot(phrase);
    final changed = await first.seal(
      'new words entirely',
      unlocked: root,
      memory: memory,
      iterations: iterations,
    );
    expect(changed.device, original.device);
    await expectLater(changed.unlockRoot(phrase), throwsStateError);
    await changed.unlockRoot('new words entirely');
    final removed = await changed.seal(
      '',
      unlocked: await changed.unlockRoot('new words entirely'),
    );
    expect(removed.hasPhrase, isFalse);

    final other = await LocalIdentity.create();
    await expectLater(
      first.seal('x', unlocked: other.root, memory: memory),
      throwsStateError,
    );
    final foreign = (await sealed(other)).sealedRoot!;
    expect(() => first.adopt(foreign), throwsStateError);
    expect(first.adopt(removed.sealedRoot!).hasPhrase, isFalse);
  });

  test(
    'a new phrase reaches other devices, which keep theirs until confirmed',
    () async {
      var time = 1000;
      final laptop = Node(
        await sealed(await LocalIdentity.create(label: 'Laptop')),
        Store(),
        clock: () => time++,
      );
      final request = await LocalIdentity.create(label: 'Phone');
      final phone = Node(
        await request.enrol(
          await laptop.identity.authorise(
            request.certificate,
            unlocked: await laptop.identity.unlockRoot(phrase),
          ),
          sealedRoot: laptop.identity.sealedRoot,
        ),
        Store(),
        clock: () => time++,
      );
      await laptop.addContact(phone.identity.certificate);
      await phone.addContact(laptop.identity.certificate);
      expect(await phone.pendingRootChange(), isNull);

      // Taking a copy is announced, and is not a change to confirm.
      await phone.announceRootCopy();
      await syncPair(phone, laptop);
      expect(await laptop.pendingRootChange(), isNull);
      expect(
        (await laptop.rootCopies())[phone.identity.device]!.copy.same(
          laptop.identity.sealedRoot,
        ),
        isTrue,
      );

      final changed = await laptop.identity.seal(
        'a different phrase',
        unlocked: await laptop.identity.unlockRoot(phrase),
        memory: memory,
        iterations: iterations,
      );
      laptop.updateIdentity(changed);
      await laptop.announceRootCopy(changed: true);
      await syncPair(laptop, phone);

      final pending = await phone.pendingRootChange();
      expect(pending, isNotNull);
      expect(pending!.device.device, laptop.identity.device);
      // Nothing changes here until the new phrase opens it.
      await phone.identity.unlockRoot(phrase);
      await expectLater(pending.copy.open(phrase), throwsStateError);
      await pending.copy.open('a different phrase');
      await phone.adoptRootChange(pending);
      expect(phone.identity.sealedRoot!.same(changed.sealedRoot), isTrue);
      await phone.identity.unlockRoot('a different phrase');
      expect(await phone.pendingRootChange(), isNull);

      // The laptop learns the phone took it.
      await syncPair(phone, laptop);
      expect(
        (await laptop.rootCopies())[phone.identity.device]!.copy.same(
          laptop.identity.sealedRoot,
        ),
        isTrue,
      );
      expect(await laptop.pendingRootChange(), isNull);

      // A declined change stays declined, until a newer one.
      final again = await laptop.identity.seal(
        'third time',
        unlocked: await laptop.identity.unlockRoot('a different phrase'),
        memory: memory,
        iterations: iterations,
      );
      laptop.updateIdentity(again);
      await laptop.announceRootCopy(changed: true);
      await syncPair(laptop, phone);
      phone.declineRootChange((await phone.pendingRootChange())!);
      expect(await phone.pendingRootChange(), isNull);
      await phone.identity.unlockRoot('a different phrase');
    },
  );

  test('a copy announced by a friend is never offered', () async {
    final laptop = Node(await sealed(await LocalIdentity.create()), Store());
    final friend = Node(await sealed(await LocalIdentity.create()), Store());
    await laptop.addContact(friend.identity.certificate);
    await friend.addContact(laptop.identity.certificate);
    await friend.announceRootCopy(changed: true);
    await syncPair(friend, laptop);
    expect(await laptop.rootCopies(), isEmpty);
    expect(await laptop.pendingRootChange(), isNull);
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
