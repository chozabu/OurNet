import 'dart:convert';
import 'dart:io';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';

Future<void> main(List<String> args) async {
  final dir = await Directory.systemTemp.createTemp('ournet-benchmark-');
  final a = Node(await LocalIdentity.create(), Store(path: '${dir.path}/a.db'));
  final b = Node(await LocalIdentity.create(), Store(path: '${dir.path}/b.db'));
  final na = PeerNetwork(a), nb = PeerNetwork(b);
  final results = <String, dynamic>{
    'utc': DateTime.now().toUtc().toIso8601String(),
    'platform': Platform.operatingSystem,
    'dart': Platform.version,
    'messages': 100,
    'fileBytes': 1024 * 1024,
  };
  Future<void> measure(String name, Future<void> Function() action) async {
    final watch = Stopwatch()..start();
    await action();
    results[name] = watch.elapsedMicroseconds / 1000;
  }

  try {
    await na.start(local: true, automatic: false);
    await nb.start(local: true, automatic: false);
    await na.addCard(nb.contactCard());
    await nb.addCard(na.contactCard());
    await measure('publish100EncryptedMs', () async {
      for (var i = 0; i < 100; i++) {
        await a.publish(
          'message',
          {'text': 'Benchmark message $i'},
          audience: [b.person],
          space: '_messages',
        );
      }
    });
    await measure('quicSync100Ms', () => na.sync(b.identity.device));
    if (b.store.objects(kind: 'message').length != 100)
      throw StateError('Incomplete benchmark sync');
    final file = File('${dir.path}/payload.bin');
    await file.writeAsBytes(List.generate(1024 * 1024, (i) => i % 251));
    late SignedObject object;
    await measure('encryptAndStore1MiBMs', () async {
      object = await Files(a, na).publish(file.path, audience: [b.person]);
    });
    await na.sync(b.identity.device);
    await measure(
      'quicDownloadDecrypt1MiBMs',
      () => Files(b, nb).cache(b.store.get(object.id)!),
    );
    results['rssMiB'] = ProcessInfo.currentRss / (1024 * 1024);
    results['inventoryBytes'] = bytes(
      a.inventory(peerDevice: b.identity.device),
    ).length;
    results['transferMiBPerSecond'] =
        1000 / (results['quicDownloadDecrypt1MiBMs'] as num);
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(results));
    if (args.isNotEmpty) {
      final output = File(args.first);
      await output.parent.create(recursive: true);
      await output.writeAsString(
        const JsonEncoder.withIndent('  ').convert(results),
      );
    }
  } finally {
    await na.stop();
    await nb.stop();
    await a.close();
    await b.close();
    for (final name in [
      'a.db',
      'a.db-wal',
      'a.db-shm',
      'b.db',
      'b.db-wal',
      'b.db-shm',
      'payload.bin',
    ]) {
      final f = File('${dir.path}/$name');
      if (await f.exists()) await f.delete();
    }
    await dir.delete();
  }
}
