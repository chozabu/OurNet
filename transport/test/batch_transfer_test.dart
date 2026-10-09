import 'dart:io';
import 'dart:typed_data';

import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';
import 'package:test/test.dart';

/// Records which device each chunk request went to, and how many chunks.
class Counting extends PeerNetwork {
  Counting(super.node);
  final asked = <(String, int)>[];
  @override
  Future<(Json, Uint8List)> requestBytes(String device, Json request) {
    asked.add((device, (request['hashes'] as List).length));
    return super.requestBytes(device, request);
  }
}

void main() {
  test(
    'a file arrives in batches spread over the devices holding it',
    () async {
      final directory = await Directory.systemTemp.createTemp('ournet-batch-');
      final author = Node(await LocalIdentity.create(), Store());
      final holder = Node(await LocalIdentity.create(), Store());
      final reader = Node(await LocalIdentity.create(), Store());
      final na = PeerNetwork(author), nh = PeerNetwork(holder);
      final nr = Counting(reader);
      addTearDown(() async {
        for (final n in [na, nh, nr]) {
          await n.stop();
        }
        for (final n in [author, holder, reader]) {
          await n.close();
        }
        await directory.delete(recursive: true);
      });
      for (final n in [na, nh, nr]) {
        await n.start(local: true, automatic: false);
      }
      for (final (x, y) in [(na, nh), (na, nr), (nh, nr)]) {
        await x.addCard(y.contactCard());
        await y.addCard(x.contactCard());
      }
      final data = Uint8List.fromList(
        List.generate(Files.chunkSize * 40 + 5, (i) => (i * 7) % 251),
      );
      final source = File('${directory.path}/source.bin')
        ..writeAsBytesSync(data);
      final object = await Files(
        author,
        na,
      ).publish(source.path, audience: [holder.person, reader.person]);
      await na.sync(holder.identity.device);
      await na.sync(reader.identity.device);
      await Files(holder, nh).cache(holder.store.get(object.id)!);
      // Each learns what the other can do.
      await nr.sync(holder.identity.device);

      final target = '${directory.path}/received.bin';
      await Files(reader, nr).save(reader.store.get(object.id)!, target);
      expect(await File(target).readAsBytes(), data);
      // 41 chunks in three batches, not 41 requests, from both holders.
      expect(nr.asked, hasLength(3));
      expect(nr.asked.map((a) => a.$2), [16, 16, 9]);
      expect(nr.asked.map((a) => a.$1).toSet(), {
        author.identity.device,
        holder.identity.device,
      });
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('chunks one holder lacks come from another', () async {
    final directory = await Directory.systemTemp.createTemp('ournet-batch-');
    final author = Node(await LocalIdentity.create(), Store());
    final holder = Node(await LocalIdentity.create(), Store());
    final reader = Node(await LocalIdentity.create(), Store());
    final na = PeerNetwork(author), nh = PeerNetwork(holder);
    final nr = Counting(reader);
    addTearDown(() async {
      for (final n in [na, nh, nr]) {
        await n.stop();
      }
      for (final n in [author, holder, reader]) {
        await n.close();
      }
      await directory.delete(recursive: true);
    });
    for (final n in [na, nh, nr]) {
      await n.start(local: true, automatic: false);
    }
    for (final (x, y) in [(na, nh), (na, nr), (nh, nr)]) {
      await x.addCard(y.contactCard());
      await y.addCard(x.contactCard());
    }
    final data = Uint8List.fromList(
      List.generate(Files.chunkSize * 20, (i) => (i * 3) % 251),
    );
    final source = File('${directory.path}/source.bin')
      ..writeAsBytesSync(data);
    final object = await Files(
      author,
      na,
    ).publish(source.path, audience: [holder.person, reader.person]);
    await na.sync(holder.identity.device);
    await na.sync(reader.identity.device);
    // The holder has the record, and no chunks: asked first by recency, it
    // answers with none, and the author supplies them.
    await nh.sync(reader.identity.device);
    final target = '${directory.path}/received.bin';
    await Files(reader, nr).save(reader.store.get(object.id)!, target);
    expect(await File(target).readAsBytes(), data);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
