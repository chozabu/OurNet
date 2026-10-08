import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_core/src/fast_crypto.dart';
import 'package:ournet_native/ournet_native.dart';
import 'package:test/test.dart';

/// Builds with the native library and builds without it (pure Dart) must
/// read and verify each other's data byte for byte.
void main() {
  tearDown(() => NativeCrypto.enabled = true);

  Future<T> dart<T>(Future<T> Function() run) async {
    NativeCrypto.enabled = false;
    try {
      return await run();
    } finally {
      NativeCrypto.enabled = true;
    }
  }

  test('native crypto is in use on this platform', () {
    expect(NativeCrypto.enabled, isTrue);
  });

  test('signatures are identical and verify either way', () async {
    final identity = await LocalIdentity.create();
    final value = {'domain': 'test', 'n': 1, 'text': 'héllo'};
    final native = await sign(value, identity.deviceKey);
    final pure = await dart(() => sign(value, identity.deviceKey));
    expect(native, pure);
    final key = identity.certificate.device;
    expect(await verify(value, native, key), isTrue);
    expect(await dart(() => verify(value, native, key)), isTrue);
    expect(await verify({...value, 'n': 2}, native, key), isFalse);
    expect(await dart(() => verify({...value, 'n': 2}, native, key)), isFalse);
  });

  test('encrypted payloads open across implementations', () async {
    final a = await LocalIdentity.create(), b = await LocalIdentity.create();
    final plain = {'text': 'for both', 'list': List.generate(50, (i) => i)};
    final native = await encryptFor(plain, [a.certificate, b.certificate]);
    final pure = await dart(
      () => encryptFor(plain, [a.certificate, b.certificate]),
    );
    expect(await dart(() => decryptFor(native, b)), plain);
    expect(await decryptFor(pure, b), plain);
    expect(await decryptFor(native, a), plain);
  });

  test('new agreement keys match what Dart derives from them', () async {
    for (var i = 0; i < 16; i++) {
      final pair = await newAgreementKeyPair();
      final again = await X25519().newKeyPairFromSeed(
        await pair.extractPrivateKeyBytes(),
      );
      expect(
        (await pair.extractPublicKey()).bytes,
        (await again.extractPublicKey()).bytes,
      );
    }
  });

  test('blobs and hashes match', () async {
    final key = await aead.newSecretKey();
    final plain = List.generate(128 * 1024, (i) => i * 7 % 256);
    final sealed = await sealBlob(plain, key, versioned: true);
    expect(await dart(() => openBlob(sealed, key)), plain);
    final pure = await dart(() => sealBlob(plain, key, versioned: true));
    expect(await openBlob(pure, key), plain);
    expect(blobHash(plain), await dart(() async => blobHash(plain)));
    expect(
      canonicalHash('{"a":1}'),
      await dart(() async => canonicalHash('{"a":1}')),
    );
    // A box that does not open still raises the same error.
    final tampered = [...sealed]..[sealed.length - 1] ^= 1;
    expect(
      () => openBlob(tampered, key),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
  });

  test('Argon2id matches the Dart derivation sealed roots used', () async {
    final salt = List.generate(16, (i) => i);
    const phrase = 'a recovery phrase of some length';
    final native = await argon2id(
      utf8.encode(phrase),
      salt,
      memory: 256,
      iterations: 2,
    );
    final pure = await (await Argon2id(
      parallelism: 1,
      memory: 256,
      iterations: 2,
      hashLength: 32,
    ).deriveKeyFromPassword(password: phrase, nonce: salt)).extractBytes();
    expect(native, pure);
    expect(
      await dart(
        () => argon2id(utf8.encode(phrase), salt, memory: 256, iterations: 2),
      ),
      pure,
    );
  });
}
