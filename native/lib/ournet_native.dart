/// Native (Rust) versions of the crypto OurNet otherwise does in pure Dart.
///
/// Every function here either gives the result the Dart implementation
/// would, or says it has none (`null`, or `false` for a signature check),
/// in which case the caller runs the Dart code. So the library being absent,
/// for a platform the build hook could not target, changes speed only.
@DefaultAsset('package:ournet_native/ournet_native.dart')
library;

import 'dart:ffi';
import 'dart:typed_data';

@Native<Uint32 Function()>(symbol: 'ournet_native_version', isLeaf: true)
external int _version();

@Native<Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Size, Pointer<Uint8>)>(
  symbol: 'ournet_ed25519_verify',
  isLeaf: true,
)
external int _verify(
  Pointer<Uint8> public,
  Pointer<Uint8> message,
  int length,
  Pointer<Uint8> signature,
);

@Native<Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Size, Pointer<Uint8>)>(
  symbol: 'ournet_ed25519_sign',
  isLeaf: true,
)
external int _sign(
  Pointer<Uint8> seed,
  Pointer<Uint8> message,
  int length,
  Pointer<Uint8> out,
);

@Native<Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>)>(
  symbol: 'ournet_x25519',
  isLeaf: true,
)
external int _x25519(
  Pointer<Uint8> secret,
  Pointer<Uint8> public,
  Pointer<Uint8> out,
);

@Native<
  Int32 Function(
    Pointer<Uint8>,
    Pointer<Uint8>,
    Pointer<Uint8>,
    Size,
    Pointer<Uint8>,
    Size,
    Pointer<Uint8>,
  )
>(symbol: 'ournet_chacha_seal', isLeaf: true)
external int _seal(
  Pointer<Uint8> key,
  Pointer<Uint8> nonce,
  Pointer<Uint8> aad,
  int aadLength,
  Pointer<Uint8> plain,
  int length,
  Pointer<Uint8> out,
);

@Native<
  Int32 Function(
    Pointer<Uint8>,
    Pointer<Uint8>,
    Pointer<Uint8>,
    Size,
    Pointer<Uint8>,
    Size,
    Pointer<Uint8>,
    Pointer<Uint8>,
  )
>(symbol: 'ournet_chacha_open', isLeaf: true)
external int _open(
  Pointer<Uint8> key,
  Pointer<Uint8> nonce,
  Pointer<Uint8> aad,
  int aadLength,
  Pointer<Uint8> cipherText,
  int length,
  Pointer<Uint8> tag,
  Pointer<Uint8> out,
);

@Native<Int32 Function(Pointer<Uint8>, Size, Pointer<Uint8>)>(
  symbol: 'ournet_sha256',
  isLeaf: true,
)
external int _sha256(Pointer<Uint8> data, int length, Pointer<Uint8> out);

@Native<
  Int32 Function(
    Pointer<Uint8>,
    Size,
    Pointer<Uint8>,
    Size,
    Uint32,
    Uint32,
    Pointer<Uint8>,
    Size,
  )
>(symbol: 'ournet_argon2id', isLeaf: true)
external int _argon2id(
  Pointer<Uint8> password,
  int passwordLength,
  Pointer<Uint8> salt,
  int saltLength,
  int memoryKiB,
  int iterations,
  Pointer<Uint8> out,
  int outLength,
);

@Native<Int32 Function(Pointer<Uint8>, Uint32, Uint32, Uint8, Pointer<Uint64>)>(
  symbol: 'ournet_jpeg',
  isLeaf: true,
)
external int _jpeg(
  Pointer<Uint8> rgba,
  int width,
  int height,
  int quality,
  Pointer<Uint64> out,
);

@Native<Void Function(Pointer<Uint8>, Size)>(
  symbol: 'ournet_free',
  isLeaf: true,
)
external void _free(Pointer<Uint8> data, int length);

Uint8List _bytes(List<int> value) =>
    value is Uint8List ? value : Uint8List.fromList(value);

abstract final class NativeCrypto {
  /// Whether the library loaded in this isolate. Tests may switch it off to
  /// compare against the Dart code.
  static bool enabled = _load();

  static bool _load() {
    try {
      return _version() >= 2;
    } catch (_) {
      return false;
    }
  }

  /// True only for a valid Ed25519 signature under strict rules; false means
  /// "not confirmed here", and the caller asks the Dart code.
  static bool ed25519Verifies(
    List<int> public,
    List<int> message,
    List<int> signature,
  ) {
    if (!enabled || public.length != 32 || signature.length != 64) {
      return false;
    }
    final m = _bytes(message);
    return _verify(
          _bytes(public).address,
          m.address,
          m.length,
          _bytes(signature).address,
        ) ==
        1;
  }

  /// The RFC 8032 signature of [message] by the key with this 32-byte seed.
  static Uint8List? ed25519Sign(List<int> seed, List<int> message) {
    if (!enabled || seed.length != 32) return null;
    final m = _bytes(message), out = Uint8List(64);
    return _sign(_bytes(seed).address, m.address, m.length, out.address) == 1
        ? out
        : null;
  }

  /// X25519 shared secret; null for a low-order peer key, left to Dart.
  static Uint8List? x25519(List<int> secret, List<int> public) {
    if (!enabled || secret.length != 32 || public.length != 32) return null;
    final out = Uint8List(32);
    return _x25519(
              _bytes(secret).address,
              _bytes(public).address,
              out.address,
            ) ==
            1
        ? out
        : null;
  }

  /// ChaCha20-Poly1305: the ciphertext followed by the 16-byte tag.
  static Uint8List? chachaSeal(
    List<int> key,
    List<int> nonce,
    List<int> plain, {
    List<int> aad = const [],
  }) {
    if (!enabled || key.length != 32 || nonce.length != 12) return null;
    final p = _bytes(plain), a = _bytes(aad), out = Uint8List(p.length + 16);
    return _seal(
              _bytes(key).address,
              _bytes(nonce).address,
              a.address,
              a.length,
              p.address,
              p.length,
              out.address,
            ) ==
            1
        ? out
        : null;
  }

  /// The plaintext, or null when the box does not open here.
  static Uint8List? chachaOpen(
    List<int> key,
    List<int> nonce,
    List<int> cipherText,
    List<int> tag, {
    List<int> aad = const [],
  }) {
    if (!enabled ||
        key.length != 32 ||
        nonce.length != 12 ||
        tag.length != 16) {
      return null;
    }
    final c = _bytes(cipherText), a = _bytes(aad), out = Uint8List(c.length);
    return _open(
              _bytes(key).address,
              _bytes(nonce).address,
              a.address,
              a.length,
              c.address,
              c.length,
              _bytes(tag).address,
              out.address,
            ) ==
            1
        ? out
        : null;
  }

  static Uint8List? sha256(List<int> data) {
    if (!enabled) return null;
    final d = _bytes(data), out = Uint8List(32);
    return _sha256(d.address, d.length, out.address) == 1 ? out : null;
  }

  /// Argon2id (version 0x13, one lane) of [password] with [salt].
  static Uint8List? argon2id(
    List<int> password,
    List<int> salt, {
    required int memoryKiB,
    required int iterations,
    int length = 32,
  }) {
    if (!enabled) return null;
    final p = _bytes(password), s = _bytes(salt), out = Uint8List(length);
    return _argon2id(
              p.address,
              p.length,
              s.address,
              s.length,
              memoryKiB,
              iterations,
              out.address,
              length,
            ) ==
            1
        ? out
        : null;
  }
}

/// Image encoding for local previews and avatars. Unlike [NativeCrypto], its
/// output need not match the Dart encoder's byte for byte: any valid JPEG of
/// the pixels will do.
abstract final class NativeImage {
  /// A baseline JPEG of [width] x [height] RGBA [pixels], transparent parts
  /// laid over white; null when the library is not available.
  static Uint8List? jpeg(
    Uint8List pixels,
    int width,
    int height, {
    required int quality,
  }) {
    if (!NativeCrypto.enabled || pixels.length != width * height * 4) {
      return null;
    }
    final out = Uint64List(2);
    if (_jpeg(pixels.address, width, height, quality, out.address) != 1) {
      return null;
    }
    final data = Pointer<Uint8>.fromAddress(out[0]);
    try {
      return Uint8List.fromList(data.asTypedList(out[1]));
    } finally {
      _free(data, out[1]);
    }
  }
}
