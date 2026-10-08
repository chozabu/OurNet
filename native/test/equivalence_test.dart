import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as digest;
import 'package:cryptography/cryptography.dart';
import 'package:ournet_native/ournet_native.dart';
import 'package:test/test.dart';

/// The native functions must give exactly what the Dart code they replace
/// gives, or no answer at all.
void main() {
  final random = Random(42);
  Uint8List bytes(int n) =>
      Uint8List.fromList(List.generate(n, (_) => random.nextInt(256)));

  test('the library is built for this platform', () {
    expect(NativeCrypto.enabled, isTrue);
  });

  test('Ed25519 signatures match and verify alike', () async {
    final ed = Ed25519();
    for (var i = 0; i < 64; i++) {
      final seed = bytes(32), message = bytes(random.nextInt(600));
      final pair = await ed.newKeyPairFromSeed(seed);
      final public = (await pair.extractPublicKey()).bytes;
      final dart = await ed.sign(message, keyPair: pair);
      expect(NativeCrypto.ed25519Sign(seed, message), dart.bytes);
      expect(NativeCrypto.ed25519Verifies(public, message, dart.bytes), isTrue);
      // Any change is rejected by both.
      final bad = Uint8List.fromList(dart.bytes)..[random.nextInt(64)] ^= 1;
      expect(NativeCrypto.ed25519Verifies(public, message, bad), isFalse);
      expect(
        await ed.verify(
          message,
          signature: Signature(
            bad,
            publicKey: SimplePublicKey(public, type: KeyPairType.ed25519),
          ),
        ),
        isFalse,
      );
    }
    expect(NativeCrypto.ed25519Verifies(bytes(31), bytes(5), bytes(64)), false);
    expect(
      NativeCrypto.ed25519Verifies(Uint8List(32), bytes(5), Uint8List(64)),
      false,
    );
  });

  test('X25519 agreements match', () async {
    final x = X25519();
    for (var i = 0; i < 64; i++) {
      final a = await x.newKeyPairFromSeed(bytes(32));
      final b = await (await x.newKeyPair()).extractPublicKey();
      final dart = await (await x.sharedSecretKey(
        keyPair: a,
        remotePublicKey: b,
      )).extractBytes();
      expect(
        NativeCrypto.x25519(await a.extractPrivateKeyBytes(), b.bytes),
        dart,
      );
    }
    // A low-order key is left to Dart.
    expect(NativeCrypto.x25519(bytes(32), Uint8List(32)), isNull);
  });

  test('ChaCha20-Poly1305 boxes match and open alike', () async {
    final c = Chacha20.poly1305Aead();
    for (final n in [0, 1, 15, 16, 17, 63, 64, 65, 1000, 128 * 1024]) {
      final key = bytes(32), nonce = bytes(12), plain = bytes(n);
      final aad = bytes(random.nextInt(40));
      final dart = await c.encrypt(
        plain,
        secretKey: SecretKey(key),
        nonce: nonce,
        aad: aad,
      );
      final sealed = NativeCrypto.chachaSeal(key, nonce, plain, aad: aad)!;
      expect(sealed.sublist(0, n), dart.cipherText);
      expect(sealed.sublist(n), dart.mac.bytes);
      expect(
        NativeCrypto.chachaOpen(
          key,
          nonce,
          dart.cipherText,
          dart.mac.bytes,
          aad: aad,
        ),
        plain,
      );
      final tag = Uint8List.fromList(dart.mac.bytes)..[0] ^= 1;
      expect(
        NativeCrypto.chachaOpen(key, nonce, dart.cipherText, tag, aad: aad),
        isNull,
      );
      expect(
        NativeCrypto.chachaOpen(
          key,
          nonce,
          dart.cipherText,
          dart.mac.bytes,
          aad: [...aad, 0],
        ),
        isNull,
      );
    }
  });

  test('SHA-256 matches', () {
    for (final n in [0, 1, 55, 56, 63, 64, 65, 1000, 128 * 1024 + 7]) {
      final data = bytes(n);
      expect(NativeCrypto.sha256(data), digest.sha256.convert(data).bytes);
    }
  });

  test('Argon2id matches', () async {
    for (final (memory, iterations) in [(8, 1), (64, 2), (1024, 3)]) {
      final salt = bytes(16);
      const password = 'correct horse battery staple ✓';
      final dart = await (await Argon2id(
        parallelism: 1,
        memory: memory,
        iterations: iterations,
        hashLength: 32,
      ).deriveKeyFromPassword(password: password, nonce: salt)).extractBytes();
      expect(
        NativeCrypto.argon2id(
          utf8.encode(password),
          salt,
          memoryKiB: memory,
          iterations: iterations,
        ),
        dart,
      );
    }
  });

  test('JPEG previews encode', () {
    const width = 64, height = 48;
    final pixels = Uint8List(width * height * 4);
    for (var i = 0; i < pixels.length; i++) {
      pixels[i] = i % 4 == 3 ? 255 : (i * 37) % 256;
    }
    final jpeg = NativeImage.jpeg(pixels, width, height, quality: 82)!;
    expect(jpeg.sublist(0, 3), [0xff, 0xd8, 0xff]);
    expect(jpeg.sublist(jpeg.length - 2), [0xff, 0xd9]);
    expect(NativeImage.jpeg(pixels, width, height + 1, quality: 82), isNull);
  });
}
