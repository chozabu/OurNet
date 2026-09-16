import 'dart:io';
import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'timestamp ties paginate without duplicates and rollback stays atomic',
    () async {
      final identity = await LocalIdentity.create();
      final store = Store();
      addTearDown(store.close);
      // Storage fixtures intentionally bypass protocol verification.
      SignedObject fixture(int nonce) => SignedObject(
        {
          'kind': 'message',
          'space': '_messages',
          'created': 42,
          'expires': 9999999999999,
          'audience': ['peer'],
          'nonce': nonce,
        },
        '',
        identity.certificate,
      );
      final expected = <String>{};
      for (var i = 0; i < 121; i++) {
        final object = fixture(i);
        store.put(object);
        store.put(object);
        expected.add(object.id);
      }
      final seen = <String>{};
      SignedObject? cursor;
      while (true) {
        final page = store.conversation(
          identity.person,
          'peer',
          before: cursor,
          limit: 17,
        );
        if (page.isEmpty) break;
        for (final object in page) {
          expect(seen.add(object.id), isTrue);
        }
        cursor = page.last;
      }
      expect(seen, expected);
      expect(store.conversationUnread('peer'), 121);
      expect(store.conversationUnread(identity.person), 0);
      expect(store.conversationUnread('peer', blocked: {identity.person}), 0);
      final readId = expected.first;
      store.set('read/$readId', true);
      store.set('read/$readId', true);
      expect(store.conversationUnread('peer'), 120);
      store.set('read/$readId', false);
      expect(store.conversationUnread('peer'), 121);
      expect(
        () => store.batch(() {
          store.put(fixture(999));
          throw StateError('rollback');
        }),
        throwsStateError,
      );
      expect(
        store.db.select('SELECT COUNT(*) n FROM message_peers').first['n'],
        242,
      );
      final expired = SignedObject(
        {...fixture(500).data, 'expires': 1},
        '',
        identity.certificate,
      );
      store.put(expired);
      expect(store.conversationUnread('peer'), 121);
      store.db.execute('DELETE FROM objects');
      expect(store.conversation(identity.person, 'peer'), isEmpty);
      expect(store.conversationUnread('peer'), 0);
    },
  );

  test(
    'conversation pages exceed shared limit and migrate without loss',
    () async {
      final dir = await Directory.systemTemp.createTemp('conversation-');
      final a = Node(
        await LocalIdentity.create(),
        Store(path: '${dir.path}/test.db'),
      );
      final b = await LocalIdentity.create();
      await a.addContact(b.certificate);
      final expected = <String>{};
      for (var i = 0; i < 1005; i++) {
        expected.add(
          (await a.publish(
            'message',
            {'text': '$i'},
            audience: [b.certificate.person],
          )).id,
        );
      }
      Set<String> read(Store store) {
        final ids = <String>{};
        SignedObject? cursor;
        while (true) {
          final page = store.conversation(
            a.person,
            b.certificate.person,
            before: cursor,
          );
          if (page.isEmpty) break;
          for (final object in page) {
            expect(ids.add(object.id), isTrue);
          }
          cursor = page.last;
        }
        return ids;
      }

      expect(read(a.store), expected);
      expect(a.store.conversation(a.person, 'unrelated'), isEmpty);
      a.store.db.execute(
        'DROP TRIGGER message_added; DROP TRIGGER message_removed; DROP TABLE message_peers;',
      );
      await a.close();
      final reopened = Store(path: '${dir.path}/test.db');
      expect(read(reopened), expected);
      expect(reopened.conversationUnread(b.person), 1005);
      reopened.close();
      await dir.delete(recursive: true);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
