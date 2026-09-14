import 'package:test/test.dart';
import 'package:ournet_core/ournet_core.dart';

void main() {
  late Node a, b, c;
  late Notes alice, bob, cara;
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
  });
  tearDown(() async {
    for (final n in [a, b, c]) {
      await n.close();
    }
  });
  Future<NoteDocument> shared() async {
    final note = await alice.create(text: 'Original writing');
    await alice.changeMembers(note.id, [b.person]);
    await syncPair(a, b);
    return (await alice.get(note.id))!;
  }

  test(
    'one stable note, independent fields, recoverable concurrent writing',
    () async {
      final note = await shared();
      await alice.edit(note.id, note.epoch, 'check:milk:text', 'Milk', []);
      await alice.edit(note.id, note.epoch, 'check:bread:text', 'Bread', []);
      await syncPair(a, b);
      final other = (await bob.get(note.id))!;
      await alice.edit(
        note.id,
        note.epoch,
        'text',
        'Alice offline',
        note.parents('text'),
      );
      await bob.edit(
        note.id,
        note.epoch,
        'text',
        'Bob offline',
        other.parents('text'),
      );
      await alice.edit(note.id, note.epoch, 'check:milk:done', true, []);
      await bob.edit(note.id, note.epoch, 'check:bread:done', true, []);
      await bob.edit(
        note.id,
        note.epoch,
        'check:milk:text',
        'Oat milk',
        other.parents('check:milk:text'),
      );
      await syncPair(a, b);
      final result = (await alice.get(note.id))!;
      expect(result.value('check:milk:done'), true);
      expect(result.value('check:bread:done'), true);
      expect(result.value('check:milk:text'), 'Oat milk');
      expect(result.heads['text']!.map((r) => r.data['value']).toSet(), {
        'Alice offline',
        'Bob offline',
      });
      expect(result.hasConflicts, true);
      expect((await bob.get(note.id))!.text, result.text);
      await alice.edit(
        note.id,
        note.epoch,
        'text',
        'Combined writing',
        result.parents('text'),
      );
      await syncPair(a, b);
      expect((await bob.get(note.id))!.hasConflicts, false);
      expect(
        (await bob.get(
          note.id,
        ))!.history.where((r) => r.data['value'] == 'Bob offline'),
        isNotEmpty,
      );
      expect((await bob.summaries()).single.data['entry'], note.id);
    },
  );

  test(
    'removal wins concurrent edit and explicit restore recovers writing',
    () async {
      final note = await shared();
      await alice.edit(note.id, note.epoch, 'deleted', true, []);
      await bob.edit(
        note.id,
        note.epoch,
        'text',
        'Still writing offline',
        note.parents('text'),
      );
      await syncPair(a, b);
      final removed = (await bob.get(note.id))!;
      expect(removed.deleted, true);
      expect(await bob.summaries(), isEmpty);
      expect(removed.text, 'Still writing offline');
      await expectLater(
        bob.edit(note.id, note.epoch, 'text', 'No implicit restore', []),
        throwsStateError,
      );
      await bob.edit(
        note.id,
        note.epoch,
        'deleted',
        false,
        removed.parents('deleted'),
      );
      await syncPair(a, b);
      expect((await alice.get(note.id))!.deleted, false);
      expect((await alice.get(note.id))!.text, 'Still writing offline');
    },
  );

  test(
    'new collaborator gets current content and conflicts, not past history',
    () async {
      final note = await shared();
      await alice.edit(
        note.id,
        note.epoch,
        'text',
        'Current Alice',
        note.parents('text'),
      );
      await bob.edit(
        note.id,
        note.epoch,
        'text',
        'Current Bob',
        note.parents('text'),
      );
      await syncPair(a, b);
      await alice.changeMembers(note.id, [b.person, c.person]);
      await syncPair(a, c);
      final received = (await cara.get(note.id))!;
      expect(received.hasConflicts, true);
      expect(received.heads['text']!.map((r) => r.data['value']).toSet(), {
        'Current Alice',
        'Current Bob',
      });
      expect(received.earlier, isEmpty);
      expect(
        received.history.any((r) => r.data['value'] == 'Original writing'),
        false,
      );
      expect(received.id, note.id);
    },
  );

  test(
    'removed member offline work is retained but cannot alter new epoch',
    () async {
      final note = await shared();
      await alice.changeMembers(note.id, []);
      await bob.edit(
        note.id,
        note.epoch,
        'text',
        'Offline after removal',
        note.parents('text'),
      );
      await syncPair(a, b);
      expect(await bob.get(note.id), isNull);
      final current = (await alice.get(note.id))!;
      expect(current.text, 'Original writing');
      expect(
        current.earlier.any((r) => r.data['value'] == 'Offline after removal'),
        true,
      );
      await expectLater(
        alice.edit(
          note.id,
          note.epoch,
          'text',
          'Old draft',
          [],
          request: 'stale-widget',
        ),
        throwsStateError,
      );
      await expectLater(
        bob.edit(note.id, note.epoch, 'text', 'Online after removal', []),
        throwsStateError,
      );
      await alice.edit(
        current.id,
        current.epoch,
        'text',
        'New private content',
        current.parents('text'),
      );
      await syncPair(a, b);
      expect(
        (await Everyday(
          b,
        ).records()).any((r) => r.data['text'] == 'New private content'),
        false,
      );
      for (final op in b.store.objects(kind: 'note_op')) {
        expect((await b.content(op))?['value'], isNot('New private content'));
      }
    },
  );

  test('outsiders cannot forge content, checkpoint or membership', () async {
    final note = await shared();
    await c.publish(
      'note_op',
      {
        'epoch': note.epoch,
        'field': 'text',
        'value': 'Forged',
        'clock': 999,
        'parents': [],
      },
      space: note.id,
      audience: [a.person],
    );
    await c.publish(
      'room',
      {
        ...note.room.data,
        'members': [a.person, c.person],
        'generation': 100,
      },
      space: note.id,
      audience: [a.person],
    );
    await b.publish(
      'note_op',
      {
        'epoch': note.epoch,
        'field': 'text',
        'value': 'Forged checkpoint',
        'clock': 1000,
        'parents': note.parents('text'),
        'checkpoint': true,
      },
      space: note.id,
      audience: [a.person],
    );
    await syncPair(a, c);
    await syncPair(a, b);
    expect((await alice.get(note.id))!.text, 'Original writing');
    await expectLater(bob.changeMembers(note.id, [c.person]), throwsStateError);
    expect(await cara.get(note.id), isNull);
  });

  test(
    'leave retains accepted writing and excludes later offline device edits',
    () async {
      final note = await shared();
      await bob.edit(
        note.id,
        note.epoch,
        'text',
        'Before leaving',
        note.parents('text'),
      );
      await bob.leave(note.id);
      await syncPair(a, b);
      expect(await bob.get(note.id), isNull);
      expect((await alice.get(note.id))!.text, 'Before leaving');
      await b.publish(
        'note_op',
        {
          'epoch': note.epoch,
          'field': 'text',
          'value': 'After leaving',
          'clock': 999,
          'parents': [],
        },
        space: note.id,
        audience: [a.person],
      );
      await syncPair(a, b);
      expect((await alice.get(note.id))!.text, 'Before leaving');
      expect(
        (await alice.get(
          note.id,
        ))!.earlier.any((r) => r.data['value'] == 'After leaving'),
        true,
      );
    },
  );

  test(
    'widget request replay after restart is idempotent and pins stay local',
    () async {
      final note = await shared();
      await alice.edit(note.id, note.epoch, 'check:milk:text', 'Milk', []);
      await alice.edit(
        note.id,
        note.epoch,
        'check:milk:done',
        true,
        [],
        request: 'tap-1',
      );
      final count = a.store.count;
      await Notes(a).edit(
        note.id,
        note.epoch,
        'check:milk:done',
        true,
        [],
        request: 'tap-1',
      );
      expect(a.store.count, count);
      alice.pin(note.id, true);
      await syncPair(a, b);
      expect(alice.pinned(note.id), true);
      expect(bob.pinned(note.id), false);
      expect((await bob.get(note.id))!.value('check:milk:done'), true);
    },
  );

  test('invalid note registers are rejected', () {
    final op = {
      'epoch': 'x',
      'field': 'text',
      'value': 'Hi',
      'clock': 1,
      'parents': [],
    };
    expect(validContent('note_op', op), true);
    expect(validContent('note_op', {...op, 'field': 'check:x:done'}), false);
    expect(
      validContent('note_op', {...op, 'parents': List.filled(129, 'x')}),
      false,
    );
    expect(validContent('note_op', {...op, 'value': 'x' * 16385}), false);
  });
}
