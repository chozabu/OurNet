import 'package:test/test.dart';
import 'package:ournet_core/ournet_core.dart';

void main() {
  test(
    'membership epochs retain history selectively and reject stale writes',
    () async {
      final a = Node(await LocalIdentity.create(), Store());
      final b = Node(await LocalIdentity.create(), Store());
      final c = Node(await LocalIdentity.create(), Store());
      addTearDown(() async {
        await a.close();
        await b.close();
        await c.close();
      });
      for (final n in [a, b, c]) {
        for (final other in [a, b, c]) {
          if (n != other) await n.addContact(other.identity.certificate);
        }
      }
      final ea = Everyday(a), eb = Everyday(b), ec = Everyday(c);
      final original = await ea.createRoom('Family', [b.person]);
      await ea.write({
        'type': 'note',
        'text': 'Before invitation',
      }, room: original);
      await syncPair(a, b);
      final expanded = await ea.changeMembers(original, [
        b.person,
        c.person,
      ], shareHistory: false);
      await syncPair(a, b);
      await syncPair(a, c);
      expect((await ec.rooms()).length, 1);
      expect(await ec.items((await ec.rooms()).single), isEmpty);
      expect(
        (await eb.items((await eb.rooms()).single)).single.data['text'],
        'Before invitation',
      );
      await ec.write({
        'type': 'note',
        'text': 'Hello everyone',
      }, room: (await ec.rooms()).single);
      await syncPair(a, c);
      expect(
        (await ea.items(expanded)).map((i) => i.data['text']),
        contains('Hello everyone'),
      );
      await expectLater(
        ec.changeMembers((await ec.rooms()).single, [], shareHistory: true),
        throwsStateError,
      );
      final reduced = await ea.changeMembers(expanded, [
        c.person,
      ], shareHistory: false);
      await syncPair(a, b);
      await syncPair(a, c);
      expect(await eb.rooms(), isEmpty);
      expect(
        (await ec.items(
          (await ec.rooms()).single,
        )).where((i) => i.data['text'] == 'Before invitation'),
        isEmpty,
      );
      await expectLater(
        eb.write({'type': 'note', 'text': 'Stale'}, room: original),
        throwsStateError,
      );
      await ea.write({'type': 'note', 'text': 'After removal'}, room: reduced);
      await syncPair(a, b);
      expect(
        (await eb.records()).where((i) => i.data['text'] == 'After removal'),
        isEmpty,
      );
      await ec.leave((await ec.rooms()).single);
      await syncPair(a, c);
      expect(await ea.members(reduced), [a.person]);
      await ea.write({
        'type': 'note',
        'text': 'After departure',
      }, room: reduced);
      await syncPair(a, c);
      expect(
        (await ec.records()).where((i) => i.data['text'] == 'After departure'),
        isEmpty,
      );
      await ea.leave(reduced);
      expect(await ea.rooms(), isEmpty);
    },
  );

  test(
    'explicit history sharing includes original content and forged owner updates fail',
    () async {
      final a = Node(await LocalIdentity.create(), Store());
      final b = Node(await LocalIdentity.create(), Store());
      addTearDown(() async {
        await a.close();
        await b.close();
      });
      await a.addContact(b.identity.certificate);
      await b.addContact(a.identity.certificate);
      final room = await Everyday(a).createRoom('Project', []);
      await Everyday(a).write({
        'type': 'check',
        'text': 'Milk',
        'done': false,
        'list': 'Shopping',
      }, room: room);
      final expanded = await Everyday(
        a,
      ).changeMembers(room, [b.person], shareHistory: true);
      await syncPair(a, b);
      final other = (await Everyday(b).rooms()).single;
      final item = (await Everyday(b).items(other)).single;
      expect(item.data['text'], 'Milk');
      await Everyday(b).write({...item.data, 'done': true}, room: other);
      await syncPair(a, b);
      expect((await Everyday(a).items(expanded)).single.data['done'], true);
      await b.publish(
        'room',
        {...other.data, 'owner': b.person, 'generation': 999},
        space: other.object.space,
        audience: [a.person],
      );
      await syncPair(a, b);
      expect((await Everyday(a).rooms()).single.data['owner'], a.person);
    },
  );
}
