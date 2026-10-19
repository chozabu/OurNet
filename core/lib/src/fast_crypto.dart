import 'dart:typed_data';

import 'package:crypto/crypto.dart' as digest;
import 'package:cryptography/cryptography.dart';
import 'package:ournet_native/ournet_native.dart';

/// Crypto OurNet runs often, through the native library where it is built
/// (see `package:ournet_native`) and the Dart implementations otherwise. Both
/// give identical bytes; anything the native code does not confirm (a
/// signature, a box that does not open) is decided by the Dart code, so
/// results never depend on which ran.

/// ChaCha20-Poly1305 with 12-byte nonces and 16-byte tags.
final class ChachaAead {
  const ChachaAead();
  static final _dart = Chacha20.poly1305Aead();

  Future<SecretKey> newSecretKey() => _dart.newSecretKey();

  Future<SecretBox> encrypt(
    List<int> clearText, {
    required SecretKey secretKey,
    List<int>? nonce,
    List<int> aad = const [],
  }) async {
    final n = nonce ?? _dart.newNonce();
    final sealed = NativeCrypto.chachaSeal(
      await secretKey.extractBytes(),
      n,
      clearText,
      aad: aad,
    );
    if (sealed == null) {
      return _dart.encrypt(clearText, secretKey: secretKey, nonce: n, aad: aad);
    }
    final length = sealed.length - 16;
    return SecretBox(
      Uint8List.sublistView(sealed, 0, length),
      nonce: n,
      mac: Mac(Uint8List.sublistView(sealed, length)),
    );
  }

  Future<List<int>> decrypt(
    SecretBox secretBox, {
    required SecretKey secretKey,
    List<int> aad = const [],
  }) async =>
      NativeCrypto.chachaOpen(
        await secretKey.extractBytes(),
        secretBox.nonce,
        secretBox.cipherText,
        secretBox.mac.bytes,
        aad: aad,
      ) ??
      // Not opened natively: the Dart code decides, raising its usual error.
      await _dart.decrypt(secretBox, secretKey: secretKey, aad: aad);
}

const aead = ChachaAead();

final _ed25519 = Ed25519();
final _x25519 = X25519();

Future<Signature> ed25519Sign(List<int> message, SimpleKeyPair key) async {
  final signature = NativeCrypto.ed25519Sign(
    await key.extractPrivateKeyBytes(),
    message,
  );
  if (signature == null) return _ed25519.sign(message, keyPair: key);
  return Signature(signature, publicKey: await key.extractPublicKey());
}

Future<bool> ed25519Verify(
  List<int> message,
  List<int> signature,
  List<int> publicKey,
) async =>
    NativeCrypto.ed25519Verifies(publicKey, message, signature) ||
    await _ed25519.verify(
      message,
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
      ),
    );

final _basePoint = Uint8List(32)..[0] = 9;

/// A new X25519 key pair, with the public key worked out natively.
Future<SimpleKeyPair> newAgreementKeyPair() async {
  final secret = SecretKeyData.random(length: 32).bytes;
  final public = NativeCrypto.x25519(secret, _basePoint);
  if (public == null) return _x25519.newKeyPairFromSeed(secret);
  return SimpleKeyPairData(
    secret,
    publicKey: SimplePublicKey(public, type: KeyPairType.x25519),
    type: KeyPairType.x25519,
  );
}

Future<SecretKey> x25519Agree(SimpleKeyPair keyPair, List<int> remote) async {
  final shared = NativeCrypto.x25519(
    await keyPair.extractPrivateKeyBytes(),
    remote,
  );
  if (shared != null) return SecretKeyData(shared);
  return _x25519.sharedSecretKey(
    keyPair: keyPair,
    remotePublicKey: SimplePublicKey(remote, type: KeyPairType.x25519),
  );
}

/// Argon2id with one lane and a 32-byte result, as sealed roots and backups
/// use. Slow by design; callers run it in an isolate of its own.
Future<List<int>> argon2id(
  List<int> password,
  List<int> salt, {
  required int memory,
  required int iterations,
}) async =>
    NativeCrypto.argon2id(
      password,
      salt,
      memoryKiB: memory,
      iterations: iterations,
    ) ??
    await (await Argon2id(
      parallelism: 1,
      memory: memory,
      iterations: iterations,
      hashLength: 32,
    ).deriveKey(secretKey: SecretKey(password), nonce: salt)).extractBytes();

const _hexDigits = '0123456789abcdef';

/// SHA-256 of [data].
Uint8List sha256Bytes(List<int> data) =>
    NativeCrypto.sha256(data) ??
    Uint8List.fromList(digest.sha256.convert(data).bytes);

/// HMAC-SHA-256 (RFC 2104) of [parts], in order, under [key].
Uint8List hmacSha256(List<int> key, List<List<int>> parts) {
  const block = 64;
  final k = Uint8List(block)
    ..setAll(0, key.length > block ? sha256Bytes(key) : key);
  final inner = BytesBuilder(copy: false)
    ..add([for (final b in k) b ^ 0x36]);
  for (final part in parts) {
    inner.add(part);
  }
  return sha256Bytes([
    for (final b in k) b ^ 0x5c,
    ...sha256Bytes(inner.takeBytes()),
  ]);
}

/// Lowercase hex SHA-256, as `package:crypto`'s `toString()` gives it.
String sha256Hex(List<int> data) {
  final hash = NativeCrypto.sha256(data);
  if (hash == null) return digest.sha256.convert(data).toString();
  final out = StringBuffer();
  for (final b in hash) {
    out
      ..writeCharCode(_hexDigits.codeUnitAt(b >> 4))
      ..writeCharCode(_hexDigits.codeUnitAt(b & 15));
  }
  return out.toString();
}
