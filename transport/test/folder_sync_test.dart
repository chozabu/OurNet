import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';

class EditingBackend extends DiskFolderBackend {
  EditingBackend(super.location);
  bool editAfterPut = false;
  bool editAfterMove = false;
  @override
  Future<FolderItem> write(
    String path,
    Stream<List<int>> data,
    String? expected,
  ) async {
    final written = await super.write(path, data, expected);
    if (editAfterPut) {
      editAfterPut = false;
      await File(
        '$location/$path',
      ).writeAsString('Edit after download committed');
    }
    return written;
  }

  @override
  Future<void> move(String source, String destination, String expected) async {
    await super.move(source, destination, expected);
    if (editAfterMove) {
      editAfterMove = false;
      await File(
        '$location/$destination/file.txt',
      ).writeAsString('Edit during directory rename');
    }
  }
}

void main() {
  late Directory temp, desktop, phone;
  late Node a, b;
  late FolderSync left, right;
  late String root;
  Future<void> exchange() async {
    await syncPair(a, b);
    // Exercise the real encrypted blobs without opening sockets. Endpoint
    // transfer and resumption are separately covered by transport drive tests.
    for (final source in [a, b]) {
      final target = identical(source, a) ? b : a;
      for (final row in source.store.db.select('SELECT id,bytes FROM blobs')) {
        target.store.db.execute('INSERT OR IGNORE INTO blobs VALUES (?,?)', [
          row['id'],
          row['bytes'],
        ]);
      }
    }
  }

  Future<void> settle() async {
    for (var i = 0; i < 3; i++) {
      await left.sync();
      await right.sync();
      await exchange();
    }
    await left.sync();
    await right.sync();
    expect(left.status[root], isNot(contains('Bad state')));
    expect(right.status[root], isNot(contains('Bad state')));
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ournet-folder-test-');
    desktop = await Directory('${temp.path}/desktop').create();
    phone = await Directory('${temp.path}/phone').create();
    final owner = await LocalIdentity.create();
    final fresh = await LocalIdentity.create();
    a = Node(owner, Store(path: '${temp.path}/a.db'));
    b = Node(
      await fresh.enrol(await owner.authorise(fresh.certificate)),
      Store(path: '${temp.path}/b.db'),
    );
    await a.addContact(b.identity.certificate);
    await b.addContact(owner.certificate);
    root = (await a.content(await Drive(a).folder('Pixel8Pro')))!['entry'];
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
    await left.connect(root, desktop.path);
    await exchange();
    await right.connect(root, phone.path);
  });
  tearDown(() async {
    await left.close();
    await right.close();
    await a.close();
    await b.close();
    await temp.delete(recursive: true);
  });
  test(
    'desktop deletion and offline phone addition converge, including nested folders',
    () async {
      await Directory('${desktop.path}/nested').create();
      await File('${desktop.path}/nested/old.txt').writeAsString('old');
      await settle();
      expect(await File('${phone.path}/nested/old.txt').readAsString(), 'old');
      await File('${desktop.path}/nested/old.txt').delete();
      await File(
        '${phone.path}/nested/new.txt',
      ).writeAsString('new from phone');
      // Both observe their local changes before either sees the other device.
      await left.sync();
      await right.sync();
      await exchange();
      await settle();
      expect(await File('${phone.path}/nested/old.txt').exists(), false);
      expect(
        await File('${desktop.path}/nested/new.txt').readAsString(),
        'new from phone',
      );
      final deleted = (await Drive(
        a,
      ).entries()).singleWhere((e) => e.current.data['name'] == 'old.txt');
      expect(deleted.current.deleted, true);
      expect(deleted.history.length, 2);
    },
  );
  test(
    'delete versus offline edit retains the edit and concurrent heads',
    () async {
      await File('${desktop.path}/same.txt').writeAsString('original');
      await settle();
      await File('${desktop.path}/same.txt').delete();
      await File('${phone.path}/same.txt').writeAsString('offline phone edit');
      await left.sync();
      await right.sync();
      await exchange();
      await settle();
      final entry = (await Drive(
        a,
      ).entries()).singleWhere((e) => e.current.data['name'] == 'same.txt');
      expect(entry.conflicted, true);
      expect(entry.heads.any((v) => v.deleted), true);
      expect(
        await File('${phone.path}/same.txt').readAsString(),
        'offline phone edit',
      );
      expect(left.status[root], contains('conflicts'));
      await Drive(a).revise(entry, {
        'deleted': false,
      }, source: entry.heads.singleWhere((v) => !v.deleted));
      await settle();
      expect(
        await File('${desktop.path}/same.txt').readAsString(),
        'offline phone edit',
      );
    },
  );
  test('new connection never overwrites an existing differing file', () async {
    await File('${desktop.path}/same.txt').writeAsString('desktop contents');
    await left.sync();
    await exchange();
    await File(
      '${phone.path}/same.txt',
    ).writeAsString('existing phone contents');
    await right.sync();
    await exchange();
    await settle();
    expect(
      await File('${phone.path}/same.txt').readAsString(),
      'existing phone contents',
    );
    expect(
      await File('${desktop.path}/same.txt').readAsString(),
      'desktop contents',
    );
    expect(
      (await Drive(a).entries())
          .singleWhere((e) => e.current.data['name'] == 'same.txt')
          .conflicted,
      true,
    );
  });
  test(
    'new connection adopts an identical existing file without a conflict',
    () async {
      await File('${desktop.path}/same.txt').writeAsString('same contents');
      await left.sync();
      await exchange();
      await File('${phone.path}/same.txt').writeAsString('same contents');
      final before = b.store.count;
      await right.sync();
      expect(b.store.count, before);
      expect(right.status[root], isNot(contains('conflicts')));
      await exchange();
      await settle();
      final entry = (await Drive(
        a,
      ).entries()).singleWhere((e) => e.current.data['name'] == 'same.txt');
      expect(entry.conflicted, false);
      expect(entry.history.length, 1);
      expect(left.status[root], isNot(contains('conflicts')));
      expect(right.status[root], isNot(contains('conflicts')));
      // The adopted baseline syncs later edits normally.
      await File('${phone.path}/same.txt').writeAsString('phone edit');
      await settle();
      expect(
        await File('${desktop.path}/same.txt').readAsString(),
        'phone edit',
      );
    },
  );
  test(
    'missing root cannot publish mass deletion; restarting retains baseline',
    () async {
      await File('${desktop.path}/kept.txt').writeAsString('keep');
      await settle();
      await left.close();
      final identity = a.identity;
      await a.close();
      a = Node(identity, Store(path: '${temp.path}/a.db'));
      left = FolderSync(
        Files(a, PeerNetwork(a)),
        DiskFolderBackend.new,
        automatic: false,
      );
      final before = a.store.count;
      await left.sync();
      expect(a.store.count, before);
      await desktop.rename('${temp.path}/unplugged');
      await left.sync();
      expect(left.status[root], contains('unavailable'));
      expect(a.store.count, before);
      expect(await File('${phone.path}/kept.txt').readAsString(), 'keep');
    },
  );
  test(
    'disconnect preserves both copies and stops local publication',
    () async {
      await File('${desktop.path}/keep.txt').writeAsString('keep');
      await settle();
      await left.disconnect(root);
      await File(
        '${desktop.path}/keep.txt',
      ).writeAsString('disconnected change');
      await settle();
      expect(await File('${phone.path}/keep.txt').readAsString(), 'keep');
    },
  );
  test('unsafe remote name cannot escape selected root', () async {
    await Drive(a).folder('CON', parent: root);
    await exchange();
    await right.sync();
    expect(right.status[root], contains('Unsupported'));
    expect(await Directory('${temp.path}/escape').exists(), false);
  });
  test('drive file rename and move propagate without losing content', () async {
    await Directory('${desktop.path}/one').create();
    await Directory('${desktop.path}/two').create();
    await File('${desktop.path}/one/file.txt').writeAsString('contents');
    await settle();
    var entries = await Drive(a).entries();
    final file = entries.singleWhere(
      (e) => e.current.data['name'] == 'file.txt',
    );
    final destination = entries.singleWhere(
      (e) => e.current.data['name'] == 'two',
    );
    await Drive(a).revise(file, {
      'name': 'renamed.txt',
      'folder': destination.current.entry,
    });
    await settle();
    for (final directory in [desktop, phone]) {
      expect(await File('${directory.path}/one/file.txt').exists(), false);
      expect(
        await File('${directory.path}/two/renamed.txt').readAsString(),
        'contents',
      );
    }
    entries = await Drive(a).entries();
    final moved = entries.singleWhere(
      (e) => e.current.entry == file.current.entry,
    );
    await Drive(a).revise(moved, {'folder': null});
    await settle();
    expect(await File('${phone.path}/two/renamed.txt').exists(), false);
    expect(
      (await Drive(a).entries())
          .singleWhere((e) => e.current.entry == file.current.entry)
          .current
          .deleted,
      false,
    );
  });
  test(
    'directory rename carries a concurrent local child edit and new child',
    () async {
      await Directory('${desktop.path}/before').create();
      await File('${desktop.path}/before/file.txt').writeAsString('original');
      await settle();
      final folder = (await Drive(
        a,
      ).entries()).singleWhere((e) => e.current.data['name'] == 'before');
      await Drive(a).revise(folder, {'name': 'after'});
      await File(
        '${phone.path}/before/file.txt',
      ).writeAsString('phone edit while folder renamed');
      await File('${phone.path}/before/new.txt').writeAsString('new child');
      await exchange();
      await settle();
      for (final directory in [desktop, phone]) {
        expect(await Directory('${directory.path}/before').exists(), false);
        expect(
          await File('${directory.path}/after/file.txt').readAsString(),
          'phone edit while folder renamed',
        );
        expect(
          await File('${directory.path}/after/new.txt').readAsString(),
          'new child',
        );
      }
    },
  );
  test('case-only drive rename is applied on Windows', () async {
    await File('${desktop.path}/case.txt').writeAsString('case');
    await settle();
    final entry = (await Drive(
      a,
    ).entries()).singleWhere((e) => e.current.data['name'] == 'case.txt');
    await Drive(a).revise(entry, {'name': 'CASE.txt'});
    await settle();
    expect(
      (await phone.list().toList()).map((e) => e.uri.pathSegments.last),
      contains('CASE.txt'),
    );
  });
  test(
    'edit after download commit is not mistaken for synchronized content',
    () async {
      await right.close();
      final fs = EditingBackend(phone.path)..editAfterPut = true;
      right = FolderSync(Files(b, PeerNetwork(b)), (_) => fs, automatic: false);
      await File('${desktop.path}/file.txt').writeAsString('remote original');
      await settle();
      expect(
        await File('${desktop.path}/file.txt').readAsString(),
        'Edit after download committed',
      );
      expect(
        await File('${phone.path}/file.txt').readAsString(),
        'Edit after download committed',
      );
    },
  );
  test(
    'edit during directory rename retains the previous content baseline',
    () async {
      await Directory('${desktop.path}/before').create();
      await File('${desktop.path}/before/file.txt').writeAsString('original');
      await settle();
      await right.close();
      final fs = EditingBackend(phone.path)..editAfterMove = true;
      right = FolderSync(Files(b, PeerNetwork(b)), (_) => fs, automatic: false);
      final entry = (await Drive(
        a,
      ).entries()).singleWhere((e) => e.current.data['name'] == 'before');
      await Drive(a).revise(entry, {'name': 'after'});
      await settle();
      expect(
        await File('${desktop.path}/after/file.txt').readAsString(),
        'Edit during directory rename',
      );
      expect(
        await File('${phone.path}/after/file.txt').readAsString(),
        'Edit during directory rename',
      );
    },
  );
  test(
    'directory deletion versus a new child preserves a visible folder conflict',
    () async {
      await Directory('${desktop.path}/photos').create();
      await File('${desktop.path}/photos/old.txt').writeAsString('old');
      await settle();
      await File('${desktop.path}/photos/old.txt').delete();
      await Directory('${desktop.path}/photos').delete();
      await File(
        '${phone.path}/photos/new.txt',
      ).writeAsString('new phone file');
      await left.sync();
      await right.sync(); // Both devices publish while disconnected.
      await exchange();
      await right.sync();
      await exchange();
      final folder = (await Drive(
        a,
      ).entries()).singleWhere((e) => e.current.data['name'] == 'photos');
      expect(folder.conflicted, true);
      expect(
        await File('${phone.path}/photos/new.txt').readAsString(),
        'new phone file',
      );
      await Drive(a).revise(folder, {'deleted': false});
      await settle();
      expect(
        await File('${desktop.path}/photos/new.txt').readAsString(),
        'new phone file',
      );
    },
  );
  test(
    'a folder deletion arriving before its children\'s does not resurrect it',
    () async {
      await Directory('${desktop.path}/photos/sub').create(recursive: true);
      await File('${desktop.path}/photos/old.txt').writeAsString('old');
      await File('${desktop.path}/photos/sub/deep.txt').writeAsString('deep');
      await settle();
      await Directory('${desktop.path}/photos').delete(recursive: true);
      await left.sync();
      // Records travel in pages, newest first, so a large deletion reaches
      // peers in parts. Deliver only the folder's own deletion.
      final tombstone = (await Drive(a).entries())
          .singleWhere((e) => e.current.data['name'] == 'photos')
          .current
          .object
          .id;
      final offered = await a.offer(
        b.identity.device,
        b.inventoryAfter(peerDevice: a.identity.device),
      );
      final only = offered.where((i) => jsonEncode(i).contains(tombstone));
      expect(only, hasLength(1));
      await b.receive(a.identity.device, only.toList());
      await right.sync();
      expect(right.status[root], isNot(contains('photos')));
      expect(await File('${phone.path}/photos/old.txt').exists(), true);
      await exchange();
      await settle();
      final folder = (await Drive(
        a,
      ).entries()).singleWhere((e) => e.current.data['name'] == 'photos');
      expect(folder.conflicted, false);
      expect(folder.current.deleted, true);
      expect(await Directory('${phone.path}/photos').exists(), false);
    },
  );
  test('folder checks slow down in the background', () async {
    expect(left.pollInterval, const Duration(seconds: 15));
    left.background = true;
    expect(left.pollInterval, const Duration(minutes: 5));
    left.background = false;
    expect(left.pollInterval, const Duration(seconds: 15));
  });
  test(
    'a new child follows a folder moved outside the connected subtree',
    () async {
      await Directory('${desktop.path}/photos').create();
      await File('${desktop.path}/photos/old.txt').writeAsString('old');
      await settle();
      final folder = (await Drive(
        a,
      ).entries()).singleWhere((e) => e.current.data['name'] == 'photos');
      await Drive(a).revise(folder, {'folder': null});
      await File(
        '${phone.path}/photos/new.txt',
      ).writeAsString('concurrent new child');
      await exchange();
      await settle();
      final child = (await Drive(
        a,
      ).entries()).singleWhere((e) => e.current.data['name'] == 'new.txt');
      expect(child.current.data['folder'], folder.current.entry);
      expect(child.current.deleted, false);
      final output = File('${temp.path}/new-child-export');
      await Files(a, PeerNetwork(a)).save(child.current.object, output.path);
      expect(await output.readAsString(), 'concurrent new child');
      expect(await Directory('${phone.path}/photos').exists(), false);
    },
  );
  test('a linked folder is reported and the rest still syncs', () async {
    final outside = await Directory('${temp.path}/outside').create();
    await File('${outside.path}/secret.txt').writeAsString('outside');
    await Link('${desktop.path}/linked').create(outside.path);
    await File('${desktop.path}/plain.txt').writeAsString('plain');
    await left.sync();
    expect(left.status[root], contains('Linked file or folder is not synced'));
    await exchange();
    await right.sync();
    expect(await File('${phone.path}/plain.txt').readAsString(), 'plain');
    expect(await Directory('${phone.path}/linked').exists(), false);
    expect(
      (await Drive(a).entries()).map((e) => e.current.data['name']),
      isNot(contains('secret.txt')),
    );
  });
  test('background passes redraw only when the status changes', () async {
    var updates = 0;
    final watcher = FolderSync(
      Files(a, PeerNetwork(a)),
      DiskFolderBackend.new,
      onUpdate: () => updates++,
    );
    addTearDown(watcher.close);
    await Future<void>.delayed(const Duration(seconds: 2));
    while (watcher.busy) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(updates, greaterThan(0)); // The first result is shown.
    final shown = updates;
    watcher.schedule();
    await Future<void>.delayed(const Duration(seconds: 2));
    while (watcher.busy) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(updates, shown);
    await left.disconnect(root);
    final idle = updates;
    watcher.schedule();
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(updates, idle); // Nothing connected: nothing to redraw.
  });
  test(
    'a tree-listed file syncs both ways, streamed without staging copies',
    () async {
      Files.newChunkBytes = 1024; // 700 chunks: a chunk tree.
      addTearDown(() => Files.newChunkBytes = Files.chunkSize);
      final bytes = List.generate(700 * 1024 + 3, (i) => (i * 13) & 255);
      await File('${desktop.path}/big.bin').writeAsBytes(bytes);
      final before = Directory.systemTemp
          .listSync()
          .where((e) => e.path.contains('ournet-folder-'))
          .length;
      await settle();
      expect(await File('${phone.path}/big.bin').readAsBytes(), bytes);
      final entry = (await Drive(
        a,
      ).entries()).singleWhere((e) => e.current.data['name'] == 'big.bin');
      expect(entry.current.data['chunkTree'], isNotEmpty);
      // An edit on the phone comes back the same way.
      final edited = [...bytes.reversed, 1, 2, 3];
      await File('${phone.path}/big.bin').writeAsBytes(edited);
      await settle();
      expect(await File('${desktop.path}/big.bin').readAsBytes(), edited);
      expect(
        Directory.systemTemp
            .listSync()
            .where((e) => e.path.contains('ournet-folder-'))
            .length,
        before,
      );
      for (final dir in [desktop, phone]) {
        expect(
          dir.listSync().map((e) => e.uri.pathSegments.last),
          ['big.bin'],
        );
      }
    },
  );
  test('backend compare-before-write preserves a newer local edit', () async {
    final file = File('${desktop.path}/race.txt');
    await file.writeAsString('before');
    final fs = DiskFolderBackend(desktop.path);
    final old = (await fs.stat('race.txt'))!.token;
    await file.writeAsString('edited while downloading');
    await expectLater(
      fs.write('race.txt', Stream.value(utf8.encode('remote')), old),
      throwsStateError,
    );
    expect(await file.readAsString(), 'edited while downloading');
    // Reading checks the token before and after.
    await expectLater(fs.read('race.txt', old).drain<void>(), throwsStateError);
    // No temporary file is left beside it either way.
    expect(
      desktop.listSync().map((e) => e.uri.pathSegments.last),
      ['race.txt'],
    );
  });
  group('first sync', () {
    late Directory fresh;
    Future<DriveEntry> entry(String name) async => (await Drive(
      a,
    ).entries()).singleWhere((e) => e.current.data['name'] == name);
    Future<String> text(DriveVersion v) async {
      final out = '${temp.path}/check-${randomId()}';
      await left.files.save(v.object, out);
      return File(out).readAsString();
    }

    String read(String path) => File('${fresh.path}/$path').readAsStringSync();
    bool exists(String path) =>
        FileSystemEntity.typeSync('${fresh.path}/$path') !=
        FileSystemEntityType.notFound;

    // The drive holds same, differ, stale (edited since "v1"), drive-only,
    // gone (deleted), folder dir/ and folder clash/. The phone's connection
    // is replaced by one to a fresh folder holding [files].
    Future<FirstSyncPlan> prepare(Map<String, String> files) async {
      await File('${desktop.path}/same.txt').writeAsString('same');
      await File('${desktop.path}/differ.txt').writeAsString('drive copy');
      await File('${desktop.path}/stale.txt').writeAsString('v1');
      await File('${desktop.path}/drive-only.txt').writeAsString('drive');
      await File('${desktop.path}/gone.txt').writeAsString('gone');
      await Directory('${desktop.path}/dir').create();
      await File('${desktop.path}/dir/in.txt').writeAsString('in');
      await Directory('${desktop.path}/clash').create();
      await File('${desktop.path}/clash/child.txt').writeAsString('child');
      await settle();
      await File('${desktop.path}/stale.txt').writeAsString('version two');
      await File('${desktop.path}/gone.txt').delete();
      await settle();
      await right.disconnect(root);
      fresh = await Directory('${temp.path}/fresh').create();
      for (final e in files.entries) {
        final file = File('${fresh.path}/${e.key}');
        await file.parent.create(recursive: true);
        await file.writeAsString(e.value);
      }
      return right.plan(root, fresh.path);
    }

    const existing = {
      'same.txt': 'same',
      'differ.txt': 'local copy, longer',
      'stale.txt': 'v1',
      'gone.txt': 'gone',
      'clash': 'a file here',
      'here.txt': 'local only',
      'dir/in.txt': 'in',
    };

    // Returns the status after the first pass.
    Future<String?> connect(
      FirstSyncPlan plan,
      FirstSyncChoice preset, {
      Map<String, FirstSyncChoice> overrides = const {},
      bool suggestions = false,
    }) async {
      await right.connect(
        root,
        fresh.path,
        decisions: plan.decisions(
          plan.resolve(preset, overrides, suggestions: suggestions),
        ),
      );
      await right.sync();
      final status = right.status[root];
      await exchange();
      await settle();
      return status;
    }

    test('plan sorts every path into its kind without writing', () async {
      final plan = await prepare(existing);
      final kinds = {for (final i in plan.items) i.path: i.kind};
      expect(kinds, {
        'clash': FirstSyncKind.clash,
        'dir': FirstSyncKind.identical,
        'differ.txt': FirstSyncKind.differs,
        'drive-only.txt': FirstSyncKind.onlyDrive,
        'gone.txt': FirstSyncKind.deletedElsewhere,
        'here.txt': FirstSyncKind.onlyHere,
        'same.txt': FirstSyncKind.identical,
        'stale.txt': FirstSyncKind.staleHere,
        'clash/child.txt': FirstSyncKind.onlyDrive,
        'dir/in.txt': FirstSyncKind.identical,
      });
      expect(plan.needsReview, true);
      final suggested = plan.resolve(
        FirstSyncChoice.both,
        const {},
        suggestions: true,
      );
      expect(suggested['stale.txt'], FirstSyncChoice.drive);
      expect(suggested['gone.txt'], FirstSyncChoice.drive);
      expect(suggested['differ.txt'], FirstSyncChoice.both);
      // A clash cannot be won by this folder; it keeps both.
      expect(
        plan.resolve(FirstSyncChoice.here, const {})['clash'],
        FirstSyncChoice.both,
      );
      expect(right.connections.containsKey(root), false);
      expect(exists('here.txt'), true);
    });

    test('no review when one side is empty or everything matches', () async {
      expect((await prepare(const {})).needsReview, false);
      await File('${fresh.path}/same.txt').writeAsString('same');
      await Directory('${fresh.path}/dir').create();
      await File('${fresh.path}/dir/in.txt').writeAsString('in');
      final partial = await right.plan(root, fresh.path);
      // The drive's other files are only there: someone should choose.
      expect(partial.needsReview, true);
      final emptyDrive = await Drive(a).folder('Empty');
      final empty = (await a.content(emptyDrive))!['entry'] as String;
      await exchange();
      expect((await right.plan(empty, fresh.path)).needsReview, false);
    });

    test('keep both merges as before, fast-forwarding a stale copy', () async {
      final plan = await prepare(existing);
      final before = (await entry('same.txt')).history.length;
      await connect(plan, FirstSyncChoice.both);
      expect((await entry('same.txt')).history.length, before);
      expect((await entry('differ.txt')).conflicted, true);
      expect(read('differ.txt'), 'local copy, longer');
      // Matching an earlier revision byte for byte is not a conflict.
      expect((await entry('stale.txt')).conflicted, false);
      expect(read('stale.txt'), 'version two');
      expect(read('drive-only.txt'), 'drive');
      expect(
        await File('${desktop.path}/here.txt').readAsString(),
        'local only',
      );
      expect(read('clash'), 'a file here');
      expect(right.connections[root]['firstSync'], isNull);
    });

    test('this folder wins: edits and deletions, no conflicts', () async {
      final plan = await prepare(existing);
      final status = await connect(plan, FirstSyncChoice.here);
      final differ = await entry('differ.txt');
      expect(differ.conflicted, false);
      expect(await text(differ.current), 'local copy, longer');
      expect(
        await File('${desktop.path}/differ.txt').readAsString(),
        'local copy, longer',
      );
      final only = await entry('drive-only.txt');
      expect(only.current.deleted, true);
      expect(await File('${desktop.path}/drive-only.txt').exists(), false);
      // Deleted from the drive, still restorable from its history.
      expect(await text(only.history.firstWhere((v) => !v.deleted)), 'drive');
      expect(exists('drive-only.txt'), false);
      expect(read('stale.txt'), 'v1');
      expect((await entry('stale.txt')).conflicted, false);
      // Only the clash, which this folder cannot win.
      expect(status, contains('1 conflicts'));
    });

    test('this folder wins deletes a drive-only folder whole', () async {
      final plan = await prepare(const {'here.txt': 'local only'});
      await connect(plan, FirstSyncChoice.here);
      expect((await entry('clash')).current.deleted, true);
      expect((await entry('child.txt')).current.deleted, true);
      expect(
        (await entry('clash')).current.data['removed'],
        contains((await entry('child.txt')).current.entry),
      );
      expect(await Directory('${desktop.path}/clash').exists(), false);
    });

    test(
      'drive wins: local copies kept in history or moved aside, never lost',
      () async {
        final plan = await prepare(existing);
        final status = await connect(plan, FirstSyncChoice.drive);
        final differ = await entry('differ.txt');
        expect(differ.conflicted, false);
        expect(read('differ.txt'), 'drive copy');
        expect(await text(differ.current), 'drive copy');
        final copies = [for (final v in differ.history) await text(v)];
        expect(copies, contains('local copy, longer'));
        final aside = '${fresh.path} (not synced)';
        expect(await File('$aside/here.txt').readAsString(), 'local only');
        expect(await File('$aside/gone.txt').readAsString(), 'gone');
        expect(await File('$aside/clash').readAsString(), 'a file here');
        expect(read('clash/child.txt'), 'child');
        expect(exists('here.txt'), false);
        expect(exists('gone.txt'), false);
        expect(await File('${desktop.path}/here.txt').exists(), false);
        expect((await entry('gone.txt')).current.deleted, true);
        expect(status, contains('3 not-synced items moved to $aside'));
        expect(status, isNot(contains('conflicts')));
      },
    );

    test('folder overrides apply to everything inside them', () async {
      final plan = await prepare(const {
        'keep/a.txt': 'a',
        'keep/deeper/b.txt': 'b',
        'drop/c.txt': 'c',
        'drop/d.txt': 'd',
        'same.txt': 'same',
      });
      final choices = plan.resolve(FirstSyncChoice.drive, const {
        'keep': FirstSyncChoice.both,
        'drop/d.txt': FirstSyncChoice.here,
      });
      expect(choices['keep/deeper/b.txt'], FirstSyncChoice.both);
      expect(choices['drop/c.txt'], FirstSyncChoice.drive);
      expect(choices['drop/d.txt'], FirstSyncChoice.here);
      await connect(
        plan,
        FirstSyncChoice.drive,
        overrides: const {
          'keep': FirstSyncChoice.both,
          'drop/d.txt': FirstSyncChoice.here,
        },
      );
      expect(
        await File('${desktop.path}/keep/deeper/b.txt').readAsString(),
        'b',
      );
      // drop/ stays for d.txt, so only c.txt moves aside.
      expect(
        await File('${fresh.path} (not synced)/drop/c.txt').readAsString(),
        'c',
      );
      expect(await File('${desktop.path}/drop/d.txt').readAsString(), 'd');
      expect(await File('${desktop.path}/drop/c.txt').exists(), false);
    });

    test('a choice is dropped when its file changes after planning', () async {
      final plan = await prepare(existing);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await File('${fresh.path}/here.txt').writeAsString('edited later');
      await File('${fresh.path}/differ.txt').writeAsString('edited too');
      await connect(plan, FirstSyncChoice.drive);
      expect(read('here.txt'), 'edited later');
      expect(
        await File('${desktop.path}/here.txt').readAsString(),
        'edited later',
      );
      expect(read('differ.txt'), 'edited too');
      expect((await entry('differ.txt')).conflicted, true);
      expect(right.connections[root]['firstSync'], isNull);
    });
  });
}
