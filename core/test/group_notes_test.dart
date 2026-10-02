import 'package:test/test.dart';
import 'package:ournet_core/ournet_core.dart';

void main() {
  late Node a, b, c;
  late Notes alice, bob, cara;
  late EverydayItem group;
  setUp(() async {
    a = Node(await LocalIdentity.create(), Store());
    b = Node(await LocalIdentity.create(), Store());
    c = Node(await LocalIdentity.create(), Store());
    alice = Notes(a);
    bob = Notes(b);
    cara = Notes(c);
    for (final x in [a, b, c]) {
      for (final y in [a, b, c]) {
        if (x != y) await x.addContact(y.identity.certificate);
      }
    }
    group = await Everyday(a).createRoom('Trip', [b.person]);
    await syncPair(a, b);
  });
  tearDown(() async {
    for (final n in [a, b, c]) {
      await n.close();
    }
  });

  test(
    'a group note is shared by the group and kept out of personal notes',
    () async {
      final note = await alice.create(
        group: group.object.space,
        title: 'Packing',
        items: ['Tent', 'Stove'],
      );
      expect(note.isGroup, isTrue);
      expect(note.id, startsWith('${group.object.space}#'));
      expect(note.members, containsAll([a.person, b.person]));
      await alice.create(title: 'Mine');
      await syncPair(a, b);

      final theirs = (await bob.get(note.id))!;
      expect(theirs.title, 'Packing');
      expect(theirs.checks.map(theirs.itemText), ['Tent', 'Stove']);

      // Either member edits the same note.
      await bob.edit(
        note.id,
        theirs.epoch,
        'check:${theirs.checks.first}:done',
        true,
        theirs.parents('check:${theirs.checks.first}:done'),
      );
      await syncPair(a, b);
      final updated = (await alice.get(note.id))!;
      expect(updated.done(updated.checks.first), isTrue);
      expect(updated.hasConflicts, isFalse);

      // Only the group's notes are listed for the group, and only personal ones
      // among a person's own.
      final listed = await alice.list(group: group.object.space);
      expect(listed.map((n) => n.id), [note.id]);
      expect((await alice.list()).map((n) => n.title), ['Mine']);
      final summaries = await bob.summaries(group: group.object.space);
      expect(summaries.single.data['entry'], note.id);
      expect(summaries.single.data['title'], 'Packing');
    },
  );

  test(
    'outsiders cannot read it and the note cannot take its own members',
    () async {
      final note = await alice.create(
        group: group.object.space,
        text: 'Secret',
      );
      await syncPair(a, b);
      await syncPair(a, c);
      expect(await cara.get(note.id), isNull);
      expect(await cara.list(group: group.object.space), isEmpty);
      expect(c.store.objects(kind: 'note_op'), isEmpty);
      expect(
        () => alice.changeMembers(note.id, [c.person]),
        throwsA(isA<StateError>()),
      );
      expect(() => bob.leave(note.id), throwsA(isA<StateError>()));
    },
  );

  test(
    'a new member receives each note, and edits merge without a fork',
    () async {
      final note = await alice.create(
        group: group.object.space,
        title: 'Packing',
        text: 'Bring the tent',
      );
      await syncPair(a, b);
      final edited = (await bob.get(note.id))!;
      await bob.edit(
        note.id,
        edited.epoch,
        'text',
        'Bring the big tent',
        edited.parents('text'),
      );
      await syncPair(a, b);

      final joined = await Everyday(
        a,
      ).changeMembers(group, [b.person, c.person], shareHistory: true);
      await syncPair(a, b);
      await syncPair(a, c);
      final newcomer = (await cara.get(note.id))!;
      expect(newcomer.title, 'Packing');
      expect(newcomer.text, 'Bring the big tent');

      // Editing on top of the shared state reaches everyone as one version.
      await cara.edit(
        note.id,
        newcomer.epoch,
        'text',
        'Bring the big tent and a mallet',
        newcomer.parents('text'),
      );
      await syncPair(a, c);
      await syncPair(a, b);
      for (final reader in [alice, bob, cara]) {
        final seen = (await reader.get(note.id))!;
        expect(seen.text, 'Bring the big tent and a mallet');
        expect(seen.hasConflicts, isFalse);
        expect(seen.members, contains(c.person));
      }
      expect(joined.data['generation'], 1);
    },
  );

  test('history stays private when it is not shared', () async {
    final note = await alice.create(group: group.object.space, text: 'Before');
    await Everyday(
      a,
    ).changeMembers(group, [b.person, c.person], shareHistory: false);
    await syncPair(a, c);
    expect(await cara.get(note.id), isNull);
  });

  test(
    'a removed member loses the notes and their later edits are ignored',
    () async {
      final note = await alice.create(group: group.object.space, text: 'Plan');
      await syncPair(a, b);
      final theirs = (await bob.get(note.id))!;
      await Everyday(a).changeMembers(group, [], shareHistory: true);
      await syncPair(a, b);
      // Bob still holds the old group and writes to people he knew about.
      await b.publish(
        'note_op',
        {
          'reg': 1,
          'epoch': theirs.epoch,
          'field': 'text',
          'value': 'Bob still here',
          'parents': theirs.parents('text'),
          'clock': 99,
          'checkpoint': false,
        },
        space: note.id,
        audience: [a.person, b.person],
      );
      await syncPair(a, b);
      final seen = (await alice.get(note.id))!;
      expect(seen.text, 'Plan');
      expect(seen.members, [a.person]);
      expect(await bob.get(note.id), isNull);
    },
  );

  test(
    'a note can be removed, restored and copied into personal notes',
    () async {
      final note = await alice.create(
        group: group.object.space,
        title: 'Plan',
        text: 'Hike',
      );
      await alice.set(note, 'deleted', true);
      await syncPair(a, b);
      expect((await bob.get(note.id))!.deleted, isTrue);
      expect(
        (await bob.list(group: group.object.space)),
        isEmpty,
        reason: 'removed notes are not listed unless asked for',
      );
      final restored = (await alice.get(note.id))!;
      await alice.set(restored, 'deleted', false);
      final copy = await alice.copy(note.id);
      expect(copy.isGroup, isFalse);
      expect(copy.text, 'Hike');
    },
  );
}
