import 'dart:io';

import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('ournet-chunks'));
  tearDown(() => temp.deleteSync(recursive: true));

  test('chunks kept as files are indexed, counted, read and removed', () {
    final store = Store(path: '${temp.path}/p.db');
    addTearDown(store.close);
    final inDatabase = [1, 2, 3], asFile = List.generate(5000, (i) => i & 255);
    final a = blobHash(inDatabase), b = blobHash(asFile);
    final before = store.storedBytes;
    store.putBlob(a, inDatabase);
    store.putBlob(b, asFile, asFile: true);
    expect(store.storedBytes, before + 3 + 5000);
    final file = File(Store.chunkFile(store.chunkDirectory!, b));
    expect(file.readAsBytesSync(), asFile);
    expect(store.db.select('SELECT id FROM blobs').map((r) => r['id']), [a]);
    expect(store.blob(a), inDatabase);
    expect(store.blob(b), asFile);
    expect(store.hasBlob(b), isTrue);
    expect(
      store.heldBlobs([
        a,
        b,
        blobHash([9]),
      ]),
      {a, b},
    );
    expect(store.hasBlobs([a, b]), isTrue);
    expect(store.removeBlob(b), isTrue);
    expect(file.existsSync(), isFalse);
    expect(store.hasBlob(b), isFalse);
    expect(store.storedBytes, before + 3);
    expect(store.removeBlob(a), isTrue);
    expect(store.removeBlob(a), isFalse);
    expect(store.storedBytes, before);
  });

  test('chunk files count towards the storage limit', () {
    final store = Store(path: '${temp.path}/p.db');
    addTearDown(store.close);
    store.set('storageLimit', store.storedBytes + 100);
    final big = List.generate(200, (i) => i);
    expect(
      () => store.putBlob(blobHash(big), big, asFile: true),
      throwsStateError,
    );
    expect(Directory(store.chunkDirectory!).existsSync(), isFalse);
  });

  test('a file removed from outside, or a missing folder, is not claimed', () {
    var store = Store(path: '${temp.path}/p.db');
    final one = [1], two = [2];
    store.putBlob(blobHash(one), one, asFile: true);
    store.putBlob(blobHash(two), two, asFile: true);
    File(Store.chunkFile(store.chunkDirectory!, blobHash(one))).deleteSync();
    expect(store.blob(blobHash(one)), isNull);
    expect(store.hasBlob(blobHash(one)), isFalse);
    store.close();
    Directory('${temp.path}/p.db.chunks').deleteSync(recursive: true);
    store = Store(path: '${temp.path}/p.db');
    addTearDown(store.close);
    expect(store.hasBlob(blobHash(two)), isFalse);
    expect(store.storedBytes, lessThan(1000000));
  });

  test('a store in memory keeps every chunk in its database', () {
    final store = Store();
    addTearDown(store.close);
    final bytes = [7, 7, 7];
    store.putBlob(blobHash(bytes), bytes, asFile: true);
    expect(store.chunkDirectory, isNull);
    expect(store.blob(blobHash(bytes)), bytes);
  });
}
