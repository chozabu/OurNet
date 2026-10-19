import 'dart:io';
import 'dart:typed_data';

import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';
import 'package:test/test.dart';

/// Writes [length] bytes of a position-dependent pattern without holding
/// them in memory.
Future<void> writePattern(File file, int length) async {
  final output = file.openWrite();
  final block = Uint8List(1024 * 1024);
  for (var at = 0; at < length; at += block.length) {
    final n = length - at < block.length ? length - at : block.length;
    for (var i = 0; i < n; i++) {
      block[i] = ((at + i) * 7 + (at + i) ~/ 65521) & 255;
    }
    output.add(Uint8List.sublistView(block, 0, n));
    if (at % (64 * block.length) == 0) await output.flush();
  }
  await output.close();
}

/// Whether two files hold the same bytes, compared a block at a time.
Future<bool> sameFiles(File a, File b) => sameBytes(a.openRead(), b.openRead());

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ournet-large-');
  });
  tearDown(() => directory.delete(recursive: true));

  Json driveFields() => {
    'entry': randomId(),
    'revision': randomId(),
    'parents': const [],
    'folder': null,
    'type': 'file',
    'deleted': false,
  };

  test('a file over 64 MiB stores as a chunk tree and reads back', () async {
    final node = Node(
      await LocalIdentity.create(),
      Store(path: '${directory.path}/profile.db'),
    );
    addTearDown(node.close);
    final files = Files(node, PeerNetwork(node));
    final source = File('${directory.path}/big.bin');
    await writePattern(source, 70 * 1024 * 1024 + 123);
    final object = await files.publish(
      source.path,
      drive: driveFields(),
      audience: [node.person],
    );
    final payload = (await node.content(object))!;
    expect(payload['size'], 70 * 1024 * 1024 + 123);
    expect(payload['chunks'], isEmpty);
    expect(payload['chunkDepth'], 1);
    expect(files.cached(payload), isTrue);
    // Its chunks are files beside the database, not rows in it. (The
    // pattern repeats, and equal chunks of one file are one chunk.)
    expect(
      node.store.db.select('SELECT COUNT(*) AS n FROM blob_files').first['n'],
      greaterThan(10),
    );
    expect(
      node.store.db.select('SELECT COUNT(*) AS n FROM blobs').first['n'],
      0,
    );
    expect(Directory(node.store.chunkDirectory!).existsSync(), isTrue);
    final back = File('${directory.path}/back.bin');
    await files.save(object, back.path);
    expect(await sameFiles(source, back), isTrue);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test(
    'a file the storage limit cannot hold is refused before storing',
    () async {
      final node = Node(await LocalIdentity.create(), Store());
      addTearDown(node.close);
      final files = Files(node, PeerNetwork(node));
      final source = File('${directory.path}/f.bin');
      await writePattern(source, 3 * 1024 * 1024);
      node.store.set('storageLimit', node.store.storedBytes + 1024 * 1024);
      final before = node.store.storedBytes;
      await expectLater(
        files.publish(source.path, audience: [node.person]),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('f.bin needs'), contains('storage limit')),
          ),
        ),
      );
      expect(node.store.storedBytes, before);
      // A destination whose free space cannot be told is not checked.
      files.checkRoom(
        1024,
        stored: false,
        destination: '${directory.path}/no/such/folder',
      );
    },
  );

  test('free space is checked where a store and a copy live', () async {
    final node = Node(
      await LocalIdentity.create(),
      Store(path: '${directory.path}/p.db'),
    );
    addTearDown(node.close);
    final files = Files(node, PeerNetwork(node));
    final free = NativeDisk.freeBytes(directory.path);
    if (free == null) return markTestSkipped('No native library here');
    node.store.set('storageLimit', 1 << 60);
    final tooBig = free + (1 << 30);
    expect(
      () => files.checkRoom(tooBig, name: 'huge.bin'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('this device has'),
        ),
      ),
    );
    expect(
      () => files.checkRoom(
        tooBig,
        name: 'huge.bin',
        stored: false,
        destination: directory.path,
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('free where it is saved'),
        ),
      ),
    );
    files.checkRoom(1024 * 1024, destination: directory.path);
  });

  // Several GB through the real path: set OURNET_LARGE_FILE_GB (e.g. 3) to
  // run it where the disk has room for the source, the store and the copy.
  final gigabytes = int.tryParse(
    Platform.environment['OURNET_LARGE_FILE_GB'] ?? '',
  );
  test(
    'a multi-gigabyte file stores and reads back',
    () async {
      final length = gigabytes! * 1024 * 1024 * 1024 + 4097;
      final node = Node(
        await LocalIdentity.create(),
        Store(path: '${directory.path}/profile.db'),
      );
      addTearDown(node.close);
      node.store.set('storageLimit', 1 << 50);
      final files = Files(node, PeerNetwork(node));
      final source = File('${directory.path}/huge.bin');
      await writePattern(source, length);
      final object = await files.publish(
        source.path,
        drive: driveFields(),
        audience: [node.person],
      );
      final payload = (await node.content(object))!;
      expect(payload['size'], length);
      expect(payload['chunkTree'], isNotEmpty);
      final back = File('${directory.path}/back.bin');
      await files.save(object, back.path);
      expect(await back.length(), length);
      expect(await sameFiles(source, back), isTrue);
    },
    skip: gigabytes == null ? 'Set OURNET_LARGE_FILE_GB to run' : false,
    timeout: const Timeout(Duration(hours: 2)),
  );
}
