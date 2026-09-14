import 'dart:io';
import 'dart:typed_data';

import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';

Uint8List pixels(int width, int height, {int alpha = 255}) {
  final rgba = Uint8List(width * height * 4);
  for (var i = 0; i < rgba.length; i += 4) {
    rgba[i] = (i ~/ 4) % width * 255 ~/ width;
    rgba[i + 1] = (i ~/ 4) ~/ width * 255 ~/ height;
    rgba[i + 2] = 90;
    rgba[i + 3] = alpha;
  }
  return rgba;
}

void main() {
  for (final disk in [true, false]) {
    test('previews are compressed, encrypted at rest and authenticated '
        '(${disk ? 'disk' : 'memory'})', () async {
      final directory = await Directory.systemTemp.createTemp('ournet-prev-');
      final node = Node(
        await LocalIdentity.create(),
        Store(path: disk ? '${directory.path}/test.db' : null),
      );
      try {
        final key = Uint8List.fromList(List.generate(32, (i) => i));
        final rgba = pixels(320, 240);
        final encoded = await node.blobs.storePreview(
          'a/list',
          key,
          rgba,
          320,
          240,
        );
        expect(encoded.sublist(0, 2), [0xff, 0xd8], reason: 'JPEG');
        expect(encoded.length, lessThan(rgba.length ~/ 4));
        final stored = node.store.preview('a/list')!;
        expect(stored.length, encoded.length + 28);
        expect(
          String.fromCharCodes(
            stored,
          ).contains(String.fromCharCodes(encoded.sublist(0, 64))),
          isFalse,
        );
        expect(await node.blobs.readPreview('a/list', key), encoded);
        expect(await node.blobs.readPreview('missing', key), isNull);
        await expectLater(
          node.blobs.readPreview('a/list', Uint8List(32)),
          throwsStateError,
        );
        // Moving a ciphertext to another preview ID fails authentication.
        node.store.putPreview('b/list', stored);
        await expectLater(
          node.blobs.readPreview('b/list', key),
          throwsStateError,
        );
        final translucent = await node.blobs.storePreview(
          'c/list',
          null,
          pixels(8, 8, alpha: 128),
          8,
          8,
        );
        expect(translucent.sublist(1, 4), 'PNG'.codeUnits);
        expect(node.store.preview('c/list'), translucent);
        await expectLater(
          node.blobs.storePreview('d/list', key, Uint8List(10), 8, 8),
          throwsStateError,
        );
      } finally {
        await node.close();
        await directory.delete(recursive: true);
      }
    });
  }

  test('preview storage is bounded and evicts least recently used', () {
    final store = Store();
    addTearDown(store.close);
    final chunk = Uint8List(Store.maxPreviewSize);
    final count = Store.maxPreviewBytes ~/ Store.maxPreviewSize;
    for (var i = 0; i < count; i++) {
      store.putPreview('p$i', chunk);
      store.db.execute('UPDATE previews SET used=? WHERE id=?', [i, 'p$i']);
    }
    store.putPreview('newest', chunk);
    final total =
        store.db.select('SELECT SUM(size) AS n FROM previews').single['n']
            as int;
    expect(total, lessThanOrEqualTo(Store.maxPreviewBytes));
    expect(store.preview('p0'), isNull);
    expect(store.preview('newest'), isNotNull);
    expect(store.preview('p${count - 1}'), isNotNull);
    expect(
      () => store.putPreview('big', Uint8List(Store.maxPreviewSize + 1)),
      throwsStateError,
    );
  });

  test('batched chunk presence and cached object listing', () async {
    final node = Node(await LocalIdentity.create(), Store());
    addTearDown(node.close);
    final a = [1], b = [2];
    node.store.putBlob(blobHash(a), a);
    expect(node.store.hasBlobs([]), isTrue);
    expect(node.store.hasBlobs([blobHash(a), blobHash(a)]), isTrue);
    expect(node.store.hasBlobs([blobHash(a), blobHash(b)]), isFalse);
    node.store.putBlob(blobHash(b), b);
    expect(node.store.hasBlobs([blobHash(a), blobHash(b)]), isTrue);

    for (var i = 0; i < 5; i++) {
      await Everyday(node).write({'type': 'note', 'text': 'n$i'});
    }
    final first = node.store.objects(kinds: ['inbox']);
    final second = node.store.objects(kinds: ['inbox']);
    expect(second.map((o) => o.id), first.map((o) => o.id));
    expect(identical(first.first, second.first), isTrue);
    expect(node.store.objects(kinds: ['inbox'], limit: 2), hasLength(2));
    expect(identical(node.store.get(first.last.id), first.last), isTrue);

    // Content is decrypted once, frozen, and visibility is still enforced.
    final payload = await node.content(first.first);
    expect(identical(await node.content(first.first), payload), isTrue);
    expect(() => payload!['text'] = 'changed', throwsUnsupportedError);
    final items = await Everyday(node).items();
    expect(items.map((i) => i.data['text']), ['n4', 'n3', 'n2', 'n1', 'n0']);
    node.store.set('hidden/a', true);
    node.store.set('hidden/b', false);
    node.store.set('hiddenx', true);
    expect(node.store.trueSettings('hidden/'), {'a'});
    final evidence = await node.makeEvidence({
      'domain': 'ournet/handoff/2',
      'object': first.first.id,
      'to': 'device',
      'parents': [],
      'created': 1,
    });
    node.store.putEvidence(evidence);
    expect(node.store.evidenceIds(), {
      first.first.id: [evidence.id],
    });
    node.block(node.person, true);
    expect(await node.content(first.first), isNull);
  });
}
