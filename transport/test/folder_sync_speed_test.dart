import 'dart:io';
import 'dart:typed_data';

import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';
import 'package:test/test.dart';

/// End-to-end folder sync on real folders, timed: a new folder of thousands
/// of small files and some large ones, a second device joining with the same
/// files, a mixed folder that needs the first-sync review, and edits both
/// ways. Run with OURNET_FOLDER_SPEED=1; timings are printed.
void main() {
  final run = Platform.environment['OURNET_FOLDER_SPEED'] != null;
  late Directory temp;
  late Node a, b;
  late FolderSync left, right;
  late String root;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ournet-speed-');
    final owner = await LocalIdentity.create();
    final second = await LocalIdentity.create();
    a = Node(owner, Store(path: '${temp.path}/a.db'));
    b = Node(
      await second.enrol(await owner.authorise(second.certificate)),
      Store(path: '${temp.path}/b.db'),
    );
    await a.addContact(b.identity.certificate);
    await b.addContact(owner.certificate);
    root = (await a.content(await Drive(a).folder('Laptop')))!['entry'];
    left = FolderSync(
      Files(a, PeerNetwork(a)),
      DiskFolderBackend.new,
      automatic: false,
    );
    right = FolderSync(
      Files(b, PeerNetwork(b)),
      DiskFolderBackend.new,
      automatic: false,
    );
  });
  tearDown(() async {
    await left.close();
    await right.close();
    await a.close();
    await b.close();
    await temp.delete(recursive: true);
  });

  /// [small] 4 KiB files in folders of 100, and [large] files of 100 MiB.
  Future<void> fill(String path, {int small = 2000, int large = 3}) async {
    for (var i = 0; i < small; i++) {
      final dir = Directory('$path/d${i ~/ 100}');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      File('${dir.path}/f$i.txt').writeAsBytesSync(
        Uint8List.fromList(List.generate(4096, (j) => (i * 31 + j) & 255)),
      );
    }
    for (var i = 0; i < large; i++) {
      final out = File('$path/big$i.bin').openWrite();
      final block = Uint8List(1 << 20);
      for (var m = 0; m < 100; m++) {
        for (var j = 0; j < block.length; j += 4096) {
          block[j] = (m * 7 + i + j) & 255;
        }
        out.add(block);
      }
      await out.close();
    }
  }

  /// Records and, from the device holding them in its folder, chunks.
  Future<void> exchange({bool leaves = true}) async {
    await syncPair(a, b, rounds: 400);
    for (final (source, target, sync) in [(a, b, left), (b, a, right)]) {
      // What each stores (list chunks, kept copies), as fetches would.
      for (final table in ['blobs', 'blob_files']) {
        for (final row in source.store.db.select('SELECT id FROM $table')) {
          final id = row['id'] as String;
          if (target.store.hasBlob(id)) continue;
          target.store.putBlob(
            id,
            source.store.blob(id)!,
            asFile: table == 'blob_files',
          );
        }
      }
      if (!leaves) continue;
      for (final entry in await Drive(source).entries()) {
        for (final v in entry.heads) {
          final p = v.data;
          if (v.deleted || v.isFolder || p['chunks'] is! List) continue;
          final key = p['key'] == null ? null : unb64(p['key']);
          try {
            await for (final segment in chunkSegments(
              p,
              (h) async => (await source.blobs.decode(h, key))!,
            )) {
              for (final h in segment) {
                if (target.store.hasBlob(h)) continue;
                final bytes =
                    source.store.blob(h) ??
                    await sync.files.network.chunkSource?.call(v.object, h);
                if (bytes != null) {
                  target.store.putBlob(h, bytes, asFile: hasChunkTree(p));
                }
              }
            }
          } catch (_) {}
        }
      }
    }
  }

  Future<int> timed(Future<void> Function() step) async {
    final watch = Stopwatch()..start();
    await step();
    return watch.elapsedMilliseconds;
  }

  int dataRows(Node node) =>
      node.store.db.select('SELECT COUNT(*) AS n FROM blobs').first['n'] as int;

  test(
    'smoke: new folder, a device joining, edits both ways, large files',
    () async {
      final one = '${temp.path}/one', two = '${temp.path}/two';
      await fill(one);
      await left.connect(root, one);
      final first = await timed(left.sync);
      print('(a) new folder, 2000 x 4 KiB + 3 x 100 MiB: $first ms');
      expect(left.status[root], contains('up to date'));
      expect(dataRows(a), 0); // Nothing kept twice.
      final again = await timed(left.sync);
      print('    unchanged second pass: $again ms');

      // (b) The second device has the same files and fetches no file data:
      // only the large file's few list chunks, which this copies over.
      await exchange(leaves: false);
      await fill(two);
      final plan = await right.plan(root, two);
      expect(plan.needsReview, isFalse);
      await right.connect(root, two);
      final join = await timed(right.sync);
      print('(b) joining with the same files: $join ms');
      expect(right.status[root], contains('up to date'));
      expect(right.status[root], isNot(contains('conflicts')));
      expect(
        b.store.db.select('SELECT COUNT(*) AS n FROM blob_files').first['n'],
        lessThan(10),
      );

      // (d) An edit on each side reaches the other.
      File('$one/d3/f300.txt').writeAsStringSync('edited on a');
      File('$two/d7/f700.txt').writeAsStringSync('edited on b');
      final edits = await timed(() async {
        await left.sync();
        await right.sync();
        await exchange();
        await left.sync();
        await right.sync();
      });
      print('(d) an edit each way: $edits ms');
      expect(File('$two/d3/f300.txt').readAsStringSync(), 'edited on a');
      expect(File('$one/d7/f700.txt').readAsStringSync(), 'edited on b');
    },
    skip: run ? false : 'Set OURNET_FOLDER_SPEED',
    timeout: const Timeout(Duration(minutes: 30)),
  );

  test(
    'smoke: a mixed folder shows the review, and a large file arrives',
    () async {
      final one = '${temp.path}/one', two = '${temp.path}/two';
      await fill(one, small: 200, large: 1);
      await left.connect(root, one);
      await left.sync();
      await syncPair(a, b, rounds: 400);
      await fill(two, small: 100, large: 0);
      File('$two/d0/f5.txt').writeAsStringSync('different');
      File('$two/only-here.txt').writeAsStringSync('new');
      final plan = await right.plan(root, two);
      expect(plan.needsReview, isTrue);
      final kinds = {for (final i in plan.items) i.path: i.kind};
      expect(kinds['d0/f5.txt'], FirstSyncKind.differs);
      expect(kinds['only-here.txt'], FirstSyncKind.onlyHere);
      expect(kinds['big0.bin'], FirstSyncKind.onlyDrive);
      await right.connect(
        root,
        two,
        decisions: plan.decisions(plan.resolve(FirstSyncChoice.both, {})),
      );
      final mixed = await timed(() async {
        await right.sync();
        await exchange();
        await right.sync();
        await left.sync();
      });
      print(
        '(c) mixed folder after the review, with a 100 MiB file: $mixed ms',
      );
      expect(
        File('$two/big0.bin').lengthSync(),
        File('$one/big0.bin').lengthSync(),
      );
      expect(
        await sameBytes(
          File('$two/big0.bin').openRead(),
          File('$one/big0.bin').openRead(),
        ),
        isTrue,
      );
      expect(File('$one/only-here.txt').readAsStringSync(), 'new');
      expect(right.status[root], contains('1 conflicts'));
    },
    skip: run ? false : 'Set OURNET_FOLDER_SPEED',
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
