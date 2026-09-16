import 'dart:io';
import 'dart:typed_data';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';
import 'package:test/test.dart';

class InterruptingNetwork extends PeerNetwork {
  InterruptingNetwork(super.node);
  final requested = <String>[];
  int? allowChunks;
  @override
  Future<Json> request(String device, Json request) {
    if (request['type'] == 'blob') {
      requested.add(request['hash'] as String);
      if (allowChunks != null && requested.length > allowChunks!) {
        return Future.error(StateError('Connection lost'));
      }
    }
    return super.request(device, request);
  }
}

void main() {
  test(
    'interrupted encrypted attachment resumes missing chunks after restart',
    () async {
      final dir = await Directory.systemTemp.createTemp('ournet-resume-');
      final a = Node(
        await LocalIdentity.create(),
        Store(path: '${dir.path}/a.db'),
      );
      final recipient = await LocalIdentity.create();
      var b = Node(recipient, Store(path: '${dir.path}/b.db'));
      final na = PeerNetwork(a);
      var nb = InterruptingNetwork(b);
      try {
        await na.start(local: true, automatic: false);
        await nb.start(local: true, automatic: false);
        await na.addCard(nb.contactCard());
        await nb.addCard(na.contactCard());
        final bytes = Uint8List.fromList(
          List.generate(Files.chunkSize * 3 + 17, (i) => i % 251),
        );
        final source = File('${dir.path}/source.bin');
        await source.writeAsBytes(bytes);
        final object = await Files(
          a,
          na,
        ).publish(source.path, audience: [b.person]);
        await nb.sync(a.identity.device);
        final payload = (await b.content(b.store.get(object.id)!))!;
        final chunks = (payload['chunks'] as List).cast<String>();
        final target = File('${dir.path}/saved.bin');
        nb.allowChunks = 1;
        await expectLater(
          Files(b, nb).save(b.store.get(object.id)!, target.path),
          throwsStateError,
        );
        expect(b.store.hasBlobs([chunks.first]), isTrue);
        expect(b.store.hasBlobs(chunks), isFalse);
        expect(await target.exists(), isFalse);
        expect(
          (await dir.list().toList()).where(
            (f) => f.path.endsWith('.ournet-part'),
          ),
          isEmpty,
        );
        await nb.stop();
        await b.close();
        b = Node(recipient, Store(path: '${dir.path}/b.db'));
        nb = InterruptingNetwork(b);
        await nb.start(local: true, automatic: false);
        final progress = <int>[];
        await Files(b, nb).save(
          b.store.get(object.id)!,
          target.path,
          onProgress: (done, total) {
            expect(total, bytes.length);
            progress.add(done);
          },
        );
        expect(nb.requested, chunks.skip(1).toList());
        expect(progress.first, 0);
        expect(progress.last, bytes.length);
        expect(await target.readAsBytes(), bytes);
        expect(b.store.hasBlobs(chunks), isTrue);
      } finally {
        await nb.stop();
        await na.stop();
        await b.close();
        await a.close();
        await dir.delete(recursive: true);
      }
    },
  );
}
