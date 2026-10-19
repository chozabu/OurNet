import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';

// Argon2id at its real cost takes seconds per call; the cost travels with
// each backup, so these use the smallest the reader accepts.
const memory = 8 * 1024, iterations = 1;
const passphrase = 'correct horse battery staple';

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('ournet-backup'));
  tearDown(() => temp.deleteSync(recursive: true));

  Future<Node> profile() async {
    final node = Node(
      await LocalIdentity.create(label: 'PC'),
      Store(path: '${temp.path}/live.db'),
    );
    addTearDown(node.close);
    return node;
  }

  test('a backup restores the notes and keys of the profile', () async {
    final node = await profile();
    final note = await Notes(node).create(title: 'Plans', text: 'Keep this');
    final zip = '${temp.path}/backup.zip';
    final info = await Backup.create(
      node,
      zip,
      passphrase,
      memory: memory,
      iterations: iterations,
    );
    expect(info.person, node.person);
    expect(info.objects, node.store.count);
    expect(File(zip).existsSync(), isTrue);
    expect(File('$zip.partial').existsSync(), isFalse);
    expect(File('$zip.snapshot').existsSync(), isFalse);

    expect((await Backup.inspect(zip)).person, node.person);

    final staged = await Backup.stage(
      zip,
      '  $passphrase ',
      '${temp.path}/restored.db',
    );
    final restored = Node(
      await LocalIdentity.restore(staged.secrets),
      Store(path: staged.database),
    );
    addTearDown(restored.close);
    expect(restored.person, node.person);
    expect(restored.identity.device, node.identity.device);
    expect(restored.store.count, node.store.count);
    final found = (await Notes(restored).list()).single;
    expect(found.id, note.id);
    expect(found.title, 'Plans');
    expect(found.text, 'Keep this');
  });

  test('a backup carries the chunks a profile keeps as files', () async {
    final node = await profile();
    final kept = [1, 2, 3], lost = [4, 5, 6];
    node.store.putBlob(blobHash(kept), kept, asFile: true);
    node.store.putBlob(blobHash(lost), lost, asFile: true);
    final zip = '${temp.path}/backup.zip';
    // One chunk file goes missing before the backup: it is not claimed.
    File(
      Store.chunkFile(node.store.chunkDirectory!, blobHash(lost)),
    ).deleteSync();
    await Backup.create(
      node,
      zip,
      passphrase,
      memory: memory,
      iterations: iterations,
    );
    final staged = await Backup.stage(
      zip,
      passphrase,
      '${temp.path}/restored.db',
    );
    final store = Store(path: staged.database);
    addTearDown(store.close);
    expect(store.blob(blobHash(kept)), kept);
    expect(store.hasBlob(blobHash(lost)), isFalse);
    expect(
      File(Store.chunkFile(store.chunkDirectory!, blobHash(kept))).existsSync(),
      isTrue,
    );
    store.close();
    await staged.discard();
    expect(Directory('${staged.database}.chunks').existsSync(), isFalse);
  });

  test('the wrong passphrase opens nothing and leaves nothing behind', () async {
    final node = await profile();
    final zip = '${temp.path}/backup.zip';
    await Backup.create(
      node,
      zip,
      passphrase,
      memory: memory,
      iterations: iterations,
    );
    await expectLater(
      Backup.stage(zip, 'a different passphrase', '${temp.path}/out.db'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('not right'),
        ),
      ),
    );
    expect(File('${temp.path}/out.db').existsSync(), isFalse);
  });

  test('a backup sealed with an unknown cipher asks for a newer version', () async {
    final node = await profile();
    final zip = '${temp.path}/backup.zip';
    await Backup.create(
      node,
      zip,
      passphrase,
      memory: memory,
      iterations: iterations,
    );
    final archive = ZipDecoder().decodeBytes(File(zip).readAsBytesSync());
    final rewritten = Archive();
    for (final file in archive.files) {
      if (file.name != 'identity.json') {
        rewritten.addFile(file);
        continue;
      }
      final sealed = jsonDecode(utf8.decode(file.content as List<int>)) as Map;
      expect(sealed['aead'], aeadAlgorithm);
      sealed['aead'] = 'aes-256-gcm';
      rewritten.addFile(
        ArchiveFile.bytes('identity.json', utf8.encode(jsonEncode(sealed))),
      );
    }
    File(zip).writeAsBytesSync(ZipEncoder().encode(rewritten));
    await expectLater(
      Backup.stage(zip, passphrase, '${temp.path}/out.db'),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', contains('newer')),
      ),
    );
  });

  test('any passphrase seals a backup, however short', () async {
    final node = await profile();
    await Backup.create(
      node,
      '${temp.path}/b.zip',
      'short',
      memory: memory,
      iterations: iterations,
    );
    final staged = await Backup.stage(
      '${temp.path}/b.zip',
      'short',
      '${temp.path}/out.db',
    );
    await staged.discard();
  });

  test('files that are not backups are refused', () async {
    File('${temp.path}/x.zip').writeAsStringSync('not a zip');
    await expectLater(
      Backup.stage('${temp.path}/x.zip', passphrase, '${temp.path}/o.db'),
      throwsA(isA<FormatException>()),
    );
  });

  test('a backup can be made while the profile keeps changing', () async {
    final node = await profile();
    final notes = Notes(node);
    await notes.create(title: 'One', text: '1');
    final made = Backup.create(
      node,
      '${temp.path}/b.zip',
      passphrase,
      memory: memory,
      iterations: iterations,
    );
    await notes.create(title: 'Two', text: '2');
    await made;
    final staged = await Backup.stage(
      '${temp.path}/b.zip',
      passphrase,
      '${temp.path}/o.db',
    );
    final restored = Node(
      await LocalIdentity.restore(staged.secrets),
      Store(path: staged.database),
    );
    addTearDown(restored.close);
    expect((await Notes(restored).list()).map((n) => n.title), contains('One'));
  });
}
