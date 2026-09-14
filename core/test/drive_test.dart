import 'package:test/test.dart';
import 'package:ournet_core/ournet_core.dart';

void main() {
  test(
    'own devices retain concurrent revisions, resolve, delete and restore',
    () async {
      final owner = await LocalIdentity.create();
      final fresh = await LocalIdentity.create();
      final paired = await fresh.enrol(
        await owner.authorise(fresh.certificate),
      );
      final a = Node(owner, Store()),
          b = Node(paired, Store()),
          friend = Node(await LocalIdentity.create(), Store());
      addTearDown(() async {
        await a.close();
        await b.close();
        await friend.close();
      });
      await a.addContact(paired.certificate);
      await b.addContact(owner.certificate);
      await a.addContact(friend.identity.certificate);
      await friend.addContact(owner.certificate);
      await Drive(a).folder('Private');
      await syncPair(a, b);
      expect((await Drive(b).entries()).single.current.data['name'], 'Private');
      await syncPair(a, friend);
      expect(friend.store.count, 0);
      final ea = (await Drive(a).entries()).single,
          eb = (await Drive(b).entries()).single;
      await Drive(a).revise(ea, {'name': 'Laptop edit'});
      await Drive(b).revise(eb, {'name': 'Phone edit'});
      await syncPair(a, b);
      final conflict = (await Drive(a).entries()).single;
      expect(conflict.heads, hasLength(2));
      await Drive(a).revise(conflict, {'name': 'Resolved'});
      await syncPair(a, b);
      final resolved = (await Drive(b).entries()).single;
      expect(resolved.heads, hasLength(1));
      expect(resolved.history, hasLength(4));
      await Drive(b).revise(resolved, {'deleted': true});
      await syncPair(a, b);
      final deleted = (await Drive(a).entries()).single;
      expect(deleted.current.deleted, true);
      await Drive(
        a,
      ).revise(deleted, {'deleted': false}, source: resolved.current);
      await syncPair(a, b);
      expect((await Drive(b).entries()).single.current.deleted, false);
    },
  );

  test(
    'history re-encryption reaches a late device without introducing conflicts',
    () async {
      final a = Node(await LocalIdentity.create(), Store());
      final fresh = await LocalIdentity.create();
      final paired = await fresh.enrol(
        await a.identity.authorise(fresh.certificate),
      );
      final b = Node(paired, Store());
      addTearDown(() async {
        await a.close();
        await b.close();
      });
      await Drive(a).folder('Before enrolment');
      await Drive(
        a,
      ).revise((await Drive(a).entries()).single, {'name': 'Second revision'});
      await a.addContact(paired.certificate);
      await b.addContact(a.identity.certificate);
      await syncPair(a, b);
      expect(await Drive(b).entries(), isEmpty);
      expect(await Drive(a).shareHistory(), 2);
      await syncPair(a, b);
      final entry = (await Drive(b).entries()).single;
      expect(entry.history, hasLength(2));
      expect(entry.heads, hasLength(1));
      expect(entry.current.data['name'], 'Second revision');
      expect((await Drive(a).entries()).single.heads, hasLength(1));
    },
  );
}
