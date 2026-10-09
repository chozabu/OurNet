import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';
import 'package:ournet/services/everyday_sync.dart';

class FlakyNetwork extends PeerNetwork {
  FlakyNetwork(super.node);
  bool fail = false;
  int blobRequests = 0;
  @override
  Future<Json> request(String device, Json request) {
    if (request['type'] == 'blob') {
      blobRequests++;
      if (fail) return Future.error(StateError('Test source unreachable'));
    }
    return super.request(device, request);
  }

  @override
  Future<(Json, Uint8List)> requestBytes(String device, Json request) {
    blobRequests++;
    if (fail) return Future.error(StateError('Test source unreachable'));
    return super.requestBytes(device, request);
  }
}

void main() {
  test(
    'inbox originals cache before delivery acknowledgement and export offline',
    () async {
      final owner = await LocalIdentity.create(),
          fresh = await LocalIdentity.create();
      final paired = await fresh.enrol(
        await owner.authorise(fresh.certificate),
      );
      final a = Node(owner, Store()), b = Node(paired, Store());
      final na = PeerNetwork(a), nb = PeerNetwork(b);
      final sync = EverydaySync(nb, () {});
      final dir = await Directory.systemTemp.createTemp('ournet-inbox-test-');
      try {
        await na.start(local: true);
        await nb.start(local: true);
        await na.addCard(nb.contactCard());
        await nb.addCard(na.contactCard());
        final source = File('${dir.path}/receipt.jpg');
        final bytes = List.generate(300000, (i) => i % 251);
        await source.writeAsBytes(bytes);
        final object = await Files(a, na).publish(
          source.path,
          audience: [a.person],
          everyday: await Everyday(a).data({'type': 'file'}),
        );
        await nb.sync(a.identity.device);
        expect(b.store.objects(kind: 'delivery'), isEmpty);
        final item = (await Everyday(b).items()).single;
        expect(Files(b, nb).cached(item.data), false);
        await sync.sync();
        expect(Files(b, nb).cached(item.data), true);
        expect(
          (await b.content(
            b.store.objects(kind: 'delivery').single,
          ))!['object'],
          object.id,
        );
        await na.sync(b.identity.device);
        expect(a.store.objects(kind: 'delivery'), hasLength(1));
        await na.stop();
        await nb.stop();
        final exported = File('${dir.path}/export.jpg');
        await Files(b, nb).save(item.object, exported.path);
        expect(await exported.readAsBytes(), bytes);
      } finally {
        sync.close();
        await na.stop();
        await nb.stop();
        await a.close();
        await b.close();
        for (final file in await dir.list().toList()) {
          await file.delete();
        }
        await dir.delete();
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'a file that cannot be fetched waits before retrying, until a device is heard from',
    () async {
      final owner = await LocalIdentity.create(),
          fresh = await LocalIdentity.create();
      final paired = await fresh.enrol(
        await owner.authorise(fresh.certificate),
      );
      final a = Node(owner, Store()), b = Node(paired, Store());
      final na = PeerNetwork(a), nb = FlakyNetwork(b);
      final sync = EverydaySync(nb, () {});
      final dir = await Directory.systemTemp.createTemp('ournet-retry-test-');
      try {
        await na.start(local: true, automatic: false);
        await nb.start(local: true, automatic: false);
        await na.addCard(nb.contactCard());
        await nb.addCard(na.contactCard());
        final source = File('${dir.path}/photo.jpg');
        await source.writeAsBytes(List.generate(1000, (i) => i % 251));
        await Files(a, na).publish(
          source.path,
          audience: [a.person],
          everyday: await Everyday(a).data({'type': 'file'}),
        );
        await nb.sync(a.identity.device);
        final item = (await Everyday(b).items()).single;
        nb.fail = true;
        await sync.sync();
        expect(sync.errors, isNotEmpty);
        final tried = nb.blobRequests;
        expect(tried, greaterThan(0));
        await sync.sync();
        expect(nb.blobRequests, tried, reason: 'retried without waiting');
        nb.fail = false;
        for (final seen in nb.peerSeenListeners.toList()) {
          seen(a.identity.device);
        }
        for (var i = 0; i < 50 && !Files(b, nb).cached(item.data); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(Files(b, nb).cached(item.data), true);
      } finally {
        sync.close();
        await na.stop();
        await nb.stop();
        await a.close();
        await b.close();
        await dir.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
