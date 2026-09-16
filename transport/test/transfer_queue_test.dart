import 'dart:async';
import 'dart:io';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';
import 'package:test/test.dart';

class GatedBlobs extends PeerNetwork {
  final Node source;
  GatedBlobs(super.node, this.source);
  final gate = Completer<void>();
  int active = 0, maximum = 0;
  @override
  Future<Json> request(String device, Json request) async {
    active++;
    if (active > maximum) maximum = active;
    try {
      await gate.future;
      return {'bytes': b64(source.store.blob(request['hash'])!)};
    } finally {
      active--;
    }
  }
}

void main() {
  test(
    'original transfers coalesce and bound concurrency and pending work',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'ournet-transfer-queue-',
      );
      final a = Node(await LocalIdentity.create(), Store());
      final b = Node(await LocalIdentity.create(), Store());
      final network = GatedBlobs(b, a);
      try {
        await a.addContact(b.identity.certificate);
        await b.addContact(a.identity.certificate);
        final source = File('${dir.path}/small.bin');
        await source.writeAsBytes([1, 2, 3]);
        final objects = <SignedObject>[];
        for (var i = 0; i < 17; i++) {
          objects.add(
            await Files(
              a,
              PeerNetwork(a),
            ).publish(source.path, audience: [b.person]),
          );
        }
        await syncPair(a, b);
        final files = Files(b, network);
        final jobs = [
          for (final object in objects.take(16))
            files.cache(b.store.get(object.id)!),
        ];
        expect(
          identical(files.cache(b.store.get(objects.first.id)!), jobs.first),
          isTrue,
        );
        await expectLater(
          files.cache(b.store.get(objects.last.id)!),
          throwsStateError,
        );
        for (var i = 0; i < 100 && network.active < 2; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(network.active, 2);
        network.gate.complete();
        await Future.wait(jobs);
        await files.cache(b.store.get(objects.last.id)!);
        expect(network.maximum, 2);
      } finally {
        if (!network.gate.isCompleted) network.gate.complete();
        await a.close();
        await b.close();
        await dir.delete(recursive: true);
      }
    },
  );
}
