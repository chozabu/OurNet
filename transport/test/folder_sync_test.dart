import 'dart:io';
import 'package:test/test.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';

class EditingBackend extends DiskFolderBackend {
  EditingBackend(super.location);
  bool editAfterPut = false;
  bool editAfterMove = false;
  @override
  Future<FolderItem> put(String path, String source, String? expected) async {
    final written = await super.put(path, source, expected);
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
  test('backend compare-before-write preserves a newer local edit', () async {
    final file = File('${desktop.path}/race.txt');
    await file.writeAsString('before');
    final fs = DiskFolderBackend(desktop.path);
    final old = (await fs.stat('race.txt'))!.token;
    await file.writeAsString('edited while downloading');
    final stage = File('${temp.path}/stage');
    await stage.writeAsString('remote');
    await expectLater(fs.put('race.txt', stage.path, old), throwsStateError);
    expect(await file.readAsString(), 'edited while downloading');
  });
}
