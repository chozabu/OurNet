import 'dart:io';
import 'dart:typed_data';

import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';
import 'package:test/test.dart';

/// Large files show their progress, can be stopped, and an import stopped
/// part of the way carries on from its last checkpoint, unless the file has
/// changed since. A 1 KiB chunk size makes small files large.
void main() {
  late Directory temp;
  late Node node;
  late Files files;
  setUp(() async {
    Files.newChunkBytes = 1024;
    Transfers.shownFrom = 0;
    temp = await Directory.systemTemp.createTemp('ournet-transfers-');
    node = Node(await LocalIdentity.create(), Store(path: '${temp.path}/p.db'));
    files = Files(node, PeerNetwork(node));
  });
  tearDown(() async {
    Files.newChunkBytes = Files.chunkSize;
    Transfers.shownFrom = 8 * 1024 * 1024;
    Files.largeTransfersAllowed = null;
    await node.close();
    await temp.delete(recursive: true);
  });

  Uint8List data(int seed) => Uint8List.fromList(
    List.generate(1000 * 1024 + 7, (i) => (i * seed + i ~/ 977) & 255),
  );

  /// Stops the first transfer once it is past [bytes].
  void stopAfter(int bytes) {
    late void Function() listener;
    listener = () {
      for (final t in files.transfers.active) {
        if (t.done > bytes) {
          files.transfers.removeListener(listener);
          t.cancel();
        }
      }
    };
    files.transfers.addListener(listener);
  }

  test('a stopped import carries on from its last checkpoint', () async {
    final source = File('${temp.path}/big.bin')..writeAsBytesSync(data(3));
    stopAfter(600 * 1024);
    await expectLater(
      files.store(source.path, encrypt: true),
      throwsA(isA<TransferCancelled>()),
    );
    expect(files.transfers.active, isEmpty);
    final starts = <int>[];
    final stored = await files.store(
      source.path,
      onProgress: (done, _) => starts.add(done),
    );
    // Carried on from the checkpoint at 512 chunks, not the start.
    expect(starts.first, 512 * 1024);
    final object = await node.publish('file', {
      ...stored,
      'text': '',
    }, space: 'files');
    final back = '${temp.path}/back.bin';
    await files.save(object, back);
    expect(await File(back).readAsBytes(), data(3));
    expect(node.store.settingsUnder('imports/'), isEmpty);
  });

  test('an import of a file changed since it stopped starts again', () async {
    final source = File('${temp.path}/big.bin')..writeAsBytesSync(data(3));
    stopAfter(600 * 1024);
    await expectLater(
      files.store(source.path),
      throwsA(isA<TransferCancelled>()),
    );
    // The same size, other bytes, a later modification time.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    source.writeAsBytesSync(data(5));
    final starts = <int>[];
    final stored = await files.store(
      source.path,
      onProgress: (done, _) => starts.add(done),
    );
    expect(starts.first, 0);
    final object = await node.publish('file', {
      ...stored,
      'text': '',
    }, space: 'files');
    final back = '${temp.path}/back.bin';
    await files.save(object, back);
    expect(await File(back).readAsBytes(), data(5));
  });

  test(
    'a stopped download keeps what it fetched and can finish later',
    () async {
      final source = File('${temp.path}/big.bin')..writeAsBytesSync(data(7));
      final object = await files.publish(source.path, audience: [node.person]);
      stopAfter(300 * 1024);
      await expectLater(
        files.save(object, '${temp.path}/out.bin'),
        throwsA(isA<TransferCancelled>()),
      );
      expect(File('${temp.path}/out.bin').existsSync(), isFalse);
      await files.save(object, '${temp.path}/out.bin');
      expect(await File('${temp.path}/out.bin').readAsBytes(), data(7));
    },
  );

  test('folder sync leaves large files waiting until they may move', () async {
    final folder = await Directory('${temp.path}/folder').create();
    final root = (await node.content(await Drive(node).folder('F')))!['entry'];
    final sync = FolderSync(files, DiskFolderBackend.new, automatic: false);
    addTearDown(sync.close);
    await sync.connect(root, folder.path);
    File('${folder.path}/big.bin').writeAsBytesSync(data(9));
    File('${folder.path}/small.txt').writeAsStringSync('small');
    var allowed = false;
    Files.largeTransfersAllowed = () async => allowed;
    await sync.sync();
    expect(sync.status[root], contains(waitingForPower));
    final names = {
      for (final e in await Drive(node).entries()) e.current.data['name'],
    };
    expect(names, contains('small.txt'));
    expect(names, isNot(contains('big.bin')));
    allowed = true;
    await sync.sync();
    expect(sync.status[root], contains('up to date'));
    expect(
      (await Drive(node).entries()).map((e) => e.current.data['name']),
      contains('big.bin'),
    );
  });
}
