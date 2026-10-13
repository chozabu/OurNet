import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';

void main() {
  test('storage report splits stored objects by kind and author', () async {
    final store = Store();
    void add(String id, String kind, String author, int created) =>
        store.db.execute('INSERT INTO objects VALUES (?,?,?,?,?,?)', [
          id,
          kind,
          'space',
          author,
          created,
          '{"pad":"${'x' * 20}"}',
        ]);
    add('a', 'message', 'me', 1760000000000);
    add('b', 'message', 'you', 1760000000000);
    add('c', 'post', 'you', 1750000000000);

    final report = await StorageReport.build(store, person: 'me');
    expect(report.objectCount, 3);
    expect(report.kinds.first.id, 'message');
    expect(report.kinds.first.count, 2);
    expect(report.ownCount, 1);
    expect(report.authors.map((a) => a.id), containsAll(['me', 'you']));
    expect(
      report.objectBytes,
      report.kinds.fold<int>(0, (s, k) => s + k.bytes),
    );
    expect(report.months, isNotEmpty);
    expect(report.oldest!.isBefore(report.newest!), isTrue);
  });
}
