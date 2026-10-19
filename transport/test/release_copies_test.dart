import 'dart:io';
import 'dart:typed_data';

import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';
import 'package:test/test.dart';

/// With "keep copies of large files" off, a synced folder's large files are
/// not stored twice: their chunks are made again from the folder, checked
/// against their hash, when another device (or this one) asks.
void main() {
  late Directory temp;
  late Node desktop, phone;
  late PeerNetwork nd, np;
  late FolderSync sync;
  late String root;

  setUp(() async {
    Files.newChunkBytes = 1024; // 700 KiB is a 700-chunk tree.
    temp = await Directory.systemTemp.createTemp('ournet-release-');
    final owner = await LocalIdentity.create();
    final second = await LocalIdentity.create();
    desktop = Node(owner, Store(path: '${temp.path}/desktop.db'));
    phone = Node(
      await second.enrol(await owner.authorise(second.certificate)),
      Store(path: '${temp.path}/phone.db'),
    );
    await desktop.addContact(phone.identity.certificate);
    await phone.addContact(owner.certificate);
    nd = PeerNetwork(desktop);
    np = PeerNetwork(phone);
    for (final n in [nd, np]) {
      await n.start(local: true, automatic: false);
    }
    await nd.addCard(np.contactCard());
    await np.addCard(nd.contactCard());
    root = (await desktop.content(
      await Drive(desktop).folder('Videos'),
    ))!['entry'];
    sync = FolderSync(
      Files(desktop, nd),
      DiskFolderBackend.new,
      automatic: false,
    );
    await Directory('${temp.path}/folder').create();
    await sync.connect(root, '${temp.path}/folder');
  });

  tearDown(() async {
    Files.newChunkBytes = Files.chunkSize;
    await sync.close();
    await nd.stop();
    await np.stop();
    await desktop.close();
    await phone.close();
    await temp.delete(recursive: true);
  });

  Uint8List bytes(int seed) => Uint8List.fromList(
    List.generate(700 * 1024 + 9, (i) => (i * seed + i ~/ 1013) & 255),
  );

  Future<SignedObject> publish(Uint8List data) async {
    await File('${temp.path}/folder/film.bin').writeAsBytes(data);
    await sync.sync();
    expect(sync.status[root], contains('up to date'));
    return (await Drive(desktop).entries())
        .singleWhere((e) => e.current.data['name'] == 'film.bin')
        .current
        .object;
  }

  int dataChunks(Node node) =>
      node.store.db.select('SELECT COUNT(*) AS n FROM blob_files').first['n']
          as int;

  test('a synced folder keeps no copy: served from the folder, read back '
      'here, and refused once the file changes', () async {
    final data = bytes(5);
    final object = await publish(data);
    final payload = (await desktop.content(object))!;
    // Only the list chunks are stored; the folder holds the rest.
    expect(dataChunks(desktop), lessThan(40));
    expect(
      desktop.store.db.select('SELECT COUNT(*) AS n FROM blobs').first['n'],
      0,
    );
    expect(sync.files.cached(payload), isTrue);

    // This device reads it from the folder, keeping nothing more.
    final local = '${temp.path}/local.bin';
    await sync.files.save(object, local);
    expect(await File(local).readAsBytes(), data);
    expect(dataChunks(desktop), lessThan(40));

    // Another device gets every chunk made again on request.
    await nd.sync(phone.identity.device);
    final mine = phone.store.get(object.id)!;
    final target = '${temp.path}/phone.bin';
    await Files(phone, np).save(mine, target);
    expect(await File(target).readAsBytes(), data);

    // Changed in the folder: the old chunks cannot be made from it.
    final source = desktop.store.chunkSourcesOf(root, 'film.bin');
    expect(source, isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await File('${temp.path}/folder/film.bin').writeAsBytes(bytes(7));
    expect(await nd.chunkSource!(object, source.first), isNull);
    expect(desktop.store.chunkSource(source.first), isNull);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test(
    'a device drops its copy only once another shows it holds the file',
    () async {
      final object = await publish(bytes(11));
      await nd.sync(phone.identity.device);
      final mine = phone.store.get(object.id)!;
      final files = Files(phone, np);
      await files.save(mine, '${temp.path}/p.bin');
      final payload = (await phone.content(mine))!;
      expect(files.cached(payload), isTrue);
      expect(await files.releaseHeldElsewhere(mine), greaterThan(700));
      expect(files.cached(payload), isFalse);

      // With nobody to show it, the phone keeps its copy of another.
      await File('${temp.path}/folder/other.bin').writeAsBytes(bytes(13));
      await sync.sync();
      await nd.sync(phone.identity.device);
      final other = (await Drive(phone).entries())
          .singleWhere((e) => e.current.data['name'] == 'other.bin')
          .current
          .object;
      await files.save(other, '${temp.path}/o.bin');
      await nd.stop();
      expect(await files.releaseHeldElsewhere(other), 0);
      expect(files.cached((await phone.content(other))!), isTrue);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
