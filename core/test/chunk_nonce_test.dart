import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_core/src/fast_crypto.dart';
import 'package:test/test.dart';

void main() {
  test('HMAC-SHA-256 matches the reference implementation', () async {
    for (final keyLength in [0, 16, 32, 64, 65, 200]) {
      final key = List.generate(keyLength, (i) => i * 7 & 255);
      for (final message in [
        <int>[],
        utf8.encode('abc'),
        List.generate(128 * 1024, (i) => i & 255),
      ]) {
        final expected = await Hmac.sha256().calculateMac(
          message,
          secretKey: SecretKey(key),
        );
        expect(
          hmacSha256(key, [message.take(5).toList(), message.skip(5).toList()]),
          expected.bytes,
          reason: 'key $keyLength, message ${message.length}',
        );
      }
    }
  });

  test('a chunk seals the same way twice, so it can be made again', () async {
    final key = SecretKey(List.generate(32, (i) => i));
    final plain = Uint8List.fromList(List.generate(5000, (i) => i * 3 & 255));
    final a = await sealBlob(plain, key, versioned: true);
    final b = await sealBlob(plain, key, versioned: true);
    expect(blobHash(a), blobHash(b));
    expect(await openBlob(a, key), plain);
    // Under another key the same plaintext seals differently.
    final other = await sealBlob(
      plain,
      SecretKey(List.filled(32, 9)),
      versioned: true,
    );
    expect(blobHash(other), isNot(blobHash(a)));
  });

  test('an edited chunk never reuses a nonce with different content', () async {
    final keyBytes = List.generate(32, (i) => 255 - i);
    final key = SecretKey(keyBytes);
    final original = Uint8List.fromList(List.generate(4096, (i) => i & 255));
    final nonces = <String, String>{}; // nonce -> plaintext
    void see(Uint8List plain) {
      final nonce = base64.encode(chunkNonce(keyBytes, plain));
      final text = base64.encode(plain);
      expect(nonces[nonce] ?? text, text, reason: 'nonce reused');
      nonces[nonce] = text;
    }

    see(original);
    // Every one-byte edit at every position, as an in-place edit of the
    // same chunk of the same file would make it.
    for (var at = 0; at < original.length; at += 37) {
      final edited = Uint8List.fromList(original)..[at] ^= 1;
      see(edited);
      final sealed = await sealBlob(edited, key, versioned: true);
      expect(sealed.sublist(1, 13), chunkNonce(keyBytes, edited));
    }
    // Truncated and extended edits too.
    see(Uint8List.sublistView(original, 0, 4095));
    see(Uint8List.fromList([...original, 0]));
    expect(nonces.length, 1 + (4096 + 36) ~/ 37 + 2);
  });

  test('a store follows where chunk plaintext lives in folders', () {
    final store = Store();
    addTearDown(store.close);
    final h1 = blobHash([1]), h2 = blobHash([2]), h3 = blobHash([3]);
    store.recordChunkSources('root', 'dir/a.bin', 't1', [
      (h1, 0, 10),
      (h2, 10, 5),
    ]);
    store.recordChunkSources('root', 'b.bin', 't2', [(h3, 0, 3)]);
    expect(store.chunkSource(h2), (
      root: 'root',
      path: 'dir/a.bin',
      offset: 10,
      length: 5,
      token: 't1',
    ));
    store.moveChunkSources('root', 'dir', 'moved');
    expect(store.chunkSource(h1)!.path, 'moved/a.bin');
    expect(
      store.chunkSourcesOf('root', 'moved/a.bin'),
      unorderedEquals([h1, h2]),
    );
    store.forgetChunkSources('root', 'moved');
    expect(store.chunkSource(h1), isNull);
    expect(store.chunkSource(h3), isNotNull);
    store.forgetFolderSources('root');
    expect(store.chunkSource(h3), isNull);
  });
}
