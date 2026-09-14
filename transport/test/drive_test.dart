import 'dart:io';
import 'package:test/test.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';

void main() {
  test(
    'private drive auto-caches across real own-device endpoints and exports offline',
    () async {
      final owner = await LocalIdentity.create(),
          fresh = await LocalIdentity.create();
      final paired = await fresh.enrol(
        await owner.authorise(fresh.certificate),
      );
      final a = Node(owner, Store()), b = Node(paired, Store());
      final na = PeerNetwork(a), nb = PeerNetwork(b);
      final mirror = DriveSync(nb);
      final directory = await Directory.systemTemp.createTemp('ournet-drive-');
      try {
        await na.start(local: true);
        await nb.start(local: true);
        await na.addCard(nb.contactCard());
        await nb.addCard(na.contactCard());
        final file = File('${directory.path}/source.txt');
        await file.writeAsString('A file held only by my devices');
        final o = await Files(a, na).publish(
          file.path,
          audience: [a.person],
          drive: {
            'entry': randomId(),
            'revision': randomId(),
            'folder': null,
            'type': 'file',
            'deleted': false,
            'parents': [],
          },
        );
        await nb.sync(a.identity.device);
        final entry = (await Drive(b).entries()).single;
        expect(entry.current.object.id, o.id);
        expect(Files(b, nb).cached(entry.current.data), false);
        mirror.setEnabled(true);
        await mirror.sync();
        expect(mirror.error, isNull);
        expect(Files(b, nb).cached(entry.current.data), true);
        await na.stop();
        await nb.stop();
        final output = File('${directory.path}/export.txt');
        await Files(b, nb).save(entry.current.object, output.path);
        expect(await output.readAsString(), await file.readAsString());
      } finally {
        await na.stop();
        await nb.stop();
        await mirror.close();
        await a.close();
        await b.close();
        for (final name in [
          'source.txt',
          'export.txt',
          'export.txt.ournet-part',
        ]) {
          final file = File('${directory.path}/$name');
          if (await file.exists()) await file.delete();
        }
        await directory.delete();
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
