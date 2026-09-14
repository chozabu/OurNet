import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/services/thumbnails.dart';
import 'package:ournet/ui/inline_image.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';

class CountingBlobWorker extends BlobWorker {
  CountingBlobWorker(super.store);
  int chunkReads = 0;
  @override
  Future<Uint8List?> decode(String hash, List<int>? key, {List<int>? bytes}) {
    if (bytes == null) chunkReads++;
    return super.decode(hash, key, bytes: bytes);
  }
  @override
  Future<Uint8List?> readLocal(List<String> hashes, List<int>? key) {
    // Whole-file reads on a disk profile bypass decode; count their chunks.
    if (store.path != null) chunkReads += hashes.length;
    return super.readLocal(hashes, key);
  }
}

class CountingNode extends Node {
  CountingNode(super.identity, super.store);
  late final _blobs = CountingBlobWorker(store);
  @override
  CountingBlobWorker get blobs => _blobs;
}

void main() {
  testWidgets(
    'list photos reuse stored encrypted previews and decoded images',
    (tester) async {
      final node = CountingNode(await LocalIdentity.create(), Store());
      final files = Files(node, PeerNetwork(node));
      final thumbnails = Thumbnails.of(files);
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('ournet-thumb-'),
      ))!;
      final source = File('${dir.path}/garden.png');
      final object = (await tester.runAsync(() async {
        await source.writeAsBytes(
          await File('test/fixtures/preview.png').readAsBytes(),
        );
        return files.publish(source.path, audience: [node.person]);
      }))!;
      final payload = (await tester.runAsync(() => node.content(object)))!;

      Widget row() => MaterialApp(
        home: Scaffold(
          body: InlineImage(
            files: files,
            object: object,
            payload: payload,
            online: false,
          ),
        ),
      );
      Future<void> settle() async {
        for (
          var i = 0;
          i < 20 &&
              find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pump();
        }
      }

      RawImage raw() => tester.widget<RawImage>(find.byType(RawImage));

      await tester.pumpWidget(row());
      await settle();
      expect(raw().image, isNotNull);
      // The generated image is shown before its encrypted copy is stored.
      for (var i = 0; i < 40 && thumbnails.generated == 0; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      expect(thumbnails.generated, 1);
      final firstReads = node.blobs.chunkReads;
      expect(firstReads, greaterThan(0));
      final stored = node.store.preview('${object.id}/${Thumbnails.variant}')!;
      expect(raw().image!.width, lessThanOrEqualTo(Thumbnails.maxEdge));

      // Recreating the row (scrolling back) is served synchronously from the
      // image cache: no read, decryption, decode or preview lookup.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(row());
      expect(raw().image, isNotNull);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(node.blobs.chunkReads, firstReads);

      // After cache eviction the durable encrypted preview is used, never the
      // original.
      await tester.pumpWidget(const SizedBox());
      imageCache.clear();
      imageCache.clearLiveImages();
      await tester.pumpWidget(row());
      await settle();
      expect(raw().image, isNotNull);
      expect(node.blobs.chunkReads, firstReads);
      expect(thumbnails.generated, 1);
      expect(node.store.preview('${object.id}/${Thumbnails.variant}'), stored);

      // Previews stored by earlier builds under the larger variant are used
      // as they are, not regenerated from the original.
      await tester.runAsync(
        () => files.storePreview(
          object,
          Thumbnails.legacyVariant,
          Uint8List.fromList(List.filled(4 * 4 * 4, 200)),
          4,
          4,
        ),
      );
      node.store.db.execute('DELETE FROM previews WHERE id=?', [
        '${object.id}/${Thumbnails.variant}',
      ]);
      await tester.pumpWidget(const SizedBox());
      imageCache.clear();
      imageCache.clearLiveImages();
      await tester.pumpWidget(row());
      await settle();
      expect(raw().image, isNotNull);
      expect(node.blobs.chunkReads, firstReads);
      expect(thumbnails.generated, 1);

      // Without a preview or local original, the row explains what is needed.
      final remote = {
        ...payload,
        'chunks': ['0' * 64],
      };
      final other = (await tester.runAsync(
        () => files.publish(source.path, audience: [node.person]),
      ))!;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InlineImage(
              files: files,
              object: other,
              payload: remote,
              online: false,
            ),
          ),
        ),
      );
      await settle();
      await tester.pump();
      expect(find.text('Image available when connected'), findsOneWidget);
      expect(thumbnails.generated, 1);

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await node.close();
        await dir.delete(recursive: true);
      });
    },
  );
}
