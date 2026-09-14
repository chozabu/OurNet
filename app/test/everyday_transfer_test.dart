import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';
import 'package:ournet/services/everyday_sync.dart';

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
}
