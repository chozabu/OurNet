import 'dart:convert';
import 'dart:io';

import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';

/// Every profile saved by `tool/upgrade_fixture.dart` for an earlier release
/// must open with this build and show what that release wrote.
void main() {
  final fixtures =
      Directory(
          'test/fixtures/upgrade',
        ).listSync().whereType<Directory>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  test('there is at least one saved profile', () {
    expect(fixtures, isNotEmpty);
  });

  for (final fixture in fixtures) {
    final release = fixture.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
    test('a profile from $release opens with this build', () async {
      // Opening upgrades the database in place; keep the fixture untouched.
      final temp = Directory.systemTemp.createTempSync('ournet-upgrade');
      addTearDown(() => temp.deleteSync(recursive: true));
      final db = File(
        '${fixture.path}/profile.db',
      ).copySync('${temp.path}/profile.db');
      final identity = await LocalIdentity.restore(
        jsonDecode(File('${fixture.path}/identity.json').readAsStringSync()),
      );
      final node = Node(identity, Store(path: db.path));
      addTearDown(node.close);

      expect(node.contacts.values.map((c) => c.label), contains('Bob phone'));

      final notes = Notes(node);
      final byTitle = {for (final n in await notes.list()) n.title: n};
      expect(byTitle.keys, containsAll(['Plans', 'Shopping']));
      final plans = byTitle['Plans']!;
      expect(plans.text, 'Upgrades keep this');
      expect(notes.pinned(plans.id), isTrue);
      final shopping = byTitle['Shopping']!;
      expect(shopping.checks.map((c) => shopping.value('check:$c:text')), [
        'Eggs',
        'Tea',
      ]);
      final audio = plans.file(plans.files.single)!.data;
      expect(
        utf8.decode(
          (await node.blobs.readLocal(
            (audio['chunks'] as List).cast<String>(),
            unb64(audio['key']),
            expectedSize: audio['size'],
          ))!,
        ),
        'recorded audio',
      );

      final everyday = Everyday(node);
      final room = (await everyday.rooms()).singleWhere(
        (r) => r.data['name'] == 'Family',
      );
      expect(
        (await everyday.items(room)).map((i) => i.data['text']),
        containsAll(['Milk', 'Bread']),
      );

      final bob = node.contacts.values.firstWhere(
        (c) => c.person != node.person,
      );
      final messages = [
        for (final o in node.store.conversation(node.person, bob.person))
          (await node.content(o))?['text'],
      ];
      expect(messages, containsAll(['Hello Bob', 'Hello Alice']));

      final posts = [
        for (final o in node.store.allOf(kind: 'post', space: 'general'))
          (await node.content(o))?['text'],
      ];
      expect(posts, contains('Hello general'));

      expect(
        (await Drive(node).entries()).map((e) => e.current.data['name']),
        contains('Documents'),
      );

      // The upgraded profile still accepts new writes.
      await notes.create(title: 'After upgrade');
      expect(
        (await notes.list()).map((n) => n.title),
        contains('After upgrade'),
      );
    });
  }
}
