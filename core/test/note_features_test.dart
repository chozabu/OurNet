import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:ournet_core/ournet_core.dart';

Stream<List<int>> bytesOf(List<int> data) => Stream.value(data);

Future<List<int>> read(Node node, EverydayItem op) async {
  final key = unb64(op.data['key']);
  final out = <int>[];
  for (final hash in (op.data['chunks'] as List).cast<String>()) {
    out.addAll((await node.blobs.decode(hash, key))!);
  }
  return out;
}

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

  test('registers from newer builds are kept, replicated and ignored', () {
    final op = {'epoch': 'x', 'clock': 1, 'parents': []};
    bool valid(String field, Object? value, [Json extra = const {}]) =>
        validContent('note_op', {
          ...op,
          ...extra,
          'field': field,
          'value': value,
        });
    expect(valid('sticker', {'name': 'star'}), true);
    expect(valid('check:x:priority', 2), true);
    expect(valid('check:x:indent', 1), true);
    expect(valid('check:x:indent', 2), false);
    expect(valid('Bad field', true), false);
    expect(valid('future', 'x' * 16385), false);
    expect(valid('future', {'big': 'x' * 9000}), false);
    expect(valid('background', 'dots'), true);
    expect(valid('created', 1700000000000), true);
    expect(valid('created', -1), false);
    // An attachment register must carry its chunks.
    expect(valid('file:f:meta', {'kind': 'audio'}), false);
    expect(
      valid(
        'file:f:meta',
        {'kind': 'audio'},
        {
          'chunks': ['a' * 64],
          'size': 1,
          'name': 'Recording.m4a',
        },
      ),
      true,
    );
    expect(valid('file:f:transcript', 'Hello'), true);
  });

  test('unknown registers leave the document readable', () async {
    final note = await alice.create(text: 'Hello');
    await alice.edit(note.id, note.epoch, 'sticker', {'name': 'star'}, []);
    final read = (await alice.get(note.id))!;
    expect(read.text, 'Hello');
    expect(read.value('sticker'), {'name': 'star'});
    expect(read.hasConflicts, false);
  });

  test(
    'attachments keep encrypted chunks across collaborators and copies',
    () async {
      final audio = Uint8List.fromList(
        List.generate(Notes.chunkSize * 2 + 17, (i) => i % 251),
      );
      final note = await alice.create();
      final file = await alice.attach(
        note.id,
        note.epoch,
        Stream.fromIterable([audio.sublist(0, 1000), audio.sublist(1000)]),
        name: 'Recording.m4a',
        meta: {'kind': 'audio', 'mime': 'audio/mp4', 'duration': 4200},
      );
      var current = (await alice.get(note.id))!;
      expect(current.files, [file]);
      expect(current.fileMeta(file)['duration'], 4200);
      expect(current.label, 'Voice note');
      expect((current.file(file)!.data['chunks'] as List).length, 3);
      await alice.edit(
        note.id,
        note.epoch,
        'file:$file:transcript',
        'Buy oat milk',
        [],
      );
      await alice.changeMembers(note.id, [b.person]);
      await syncPair(a, b);
      // Chunks travel separately (the blob request); copy them for the test.
      current = (await alice.get(note.id))!;
      for (final hash in (current.file(file)!.data['chunks'] as List)) {
        b.store.putBlob(hash, a.store.blob(hash)!);
      }
      final received = (await bob.get(note.id))!;
      expect(received.files, [file]);
      expect(received.transcript(file), 'Buy oat milk');
      expect(received.label, 'Buy oat milk');
      expect(await read(b, received.file(file)!), audio);
      final summary = (await bob.summaries()).single.data;
      expect(summary['transcript'], 'Buy oat milk');
      expect((summary['files'] as List).single['kind'], 'audio');

      final copy = await bob.copy(note.id);
      expect(copy.id, isNot(note.id));
      expect(copy.members, [b.person]);
      expect(copy.files.length, 1);
      expect(copy.transcript(copy.files.single), 'Buy oat milk');
      expect(await read(b, copy.file(copy.files.single)!), audio);

      await bob.edit(
        note.id,
        received.epoch,
        'file:$file:deleted',
        true,
        received.parents('file:$file:deleted'),
      );
      expect((await bob.get(note.id))!.files, isEmpty);
    },
  );

  test('copies keep checked state, nesting, colour and labels', () async {
    final note = await alice.create(
      title: 'Trip',
      items: ['Pack', 'Socks', 'Book'],
      color: 'mint',
    );
    final [pack, socks, _] = note.checks;
    await alice.apply(note.id, note.epoch, [
      (field: 'check:$socks:indent', value: 1, parents: const []),
      (field: 'check:$pack:done', value: true, parents: const []),
    ]);
    final label = await alice.state.createLabel('Travel');
    await alice.state.label([note.id], label, true);
    final copy = await alice.copy(note.id);
    expect(copy.rawTitle, 'Trip');
    expect(copy.color, 'mint');
    expect(copy.checks.map(copy.itemText), ['Pack', 'Socks', 'Book']);
    expect(copy.checks.map(copy.done), [true, false, false]);
    expect(copy.checks.map(copy.indent), [0, 1, 0]);
    expect(alice.state.labelsOf(copy.id), [label]);
  });

  test('personal state syncs between own devices only', () async {
    final fresh = await LocalIdentity.create();
    final laptop = Node(
      await fresh.enrol(await a.identity.authorise(fresh.certificate)),
      Store(),
    );
    addTearDown(laptop.close);
    await a.addContact(laptop.identity.certificate);
    await laptop.addContact(a.identity.certificate);
    await laptop.addContact(b.identity.certificate);
    await b.addContact(laptop.identity.certificate);
    final mine = Notes(laptop);

    final note = await alice.create(text: 'Shared');
    await alice.changeMembers(note.id, [b.person]);
    final label = await alice.state.createLabel('Home');
    await alice.pin(note.id, true);
    await alice.state.label([note.id], label, true);
    await alice.state.setReminder(
      note.id,
      DateTime.utc(2026, 9, 20, 8),
      repeat: 'weekly',
    );
    await syncPair(a, laptop);
    await syncPair(a, b);
    await mine.refresh();
    await bob.refresh();
    expect(mine.pinned(note.id), true);
    expect(mine.state.labels, {label: 'Home'});
    expect(mine.state.labelsOf(note.id), [label]);
    expect(mine.state.reminder(note.id)!['repeat'], 'weekly');
    expect(bob.pinned(note.id), false);
    expect(bob.state.labels, isEmpty);
    expect(bob.state.reminder(note.id), isNull);

    // Archiving unpins; concurrent device writes converge.
    await mine.state.archive([note.id], true);
    await alice.state.renameLabel(label, 'House');
    await syncPair(a, laptop);
    await alice.refresh();
    await mine.refresh();
    for (final notes in [alice, mine]) {
      expect(notes.state.archived(note.id), true);
      expect(notes.pinned(note.id), false);
      expect(notes.state.labels, {label: 'House'});
    }
    await alice.state.deleteLabel(label);
    expect(alice.state.labelsOf(note.id), isEmpty);
    await alice.state.setReminder(note.id, null);
    expect(alice.state.reminder(note.id), isNull);
    expect(await alice.state.createLabel(' house '), isNot(label));
  });

  test('emptying Removed applies to one removal, not later ones', () async {
    final note = await alice.create(text: 'Old list');
    await alice.edit(note.id, note.epoch, 'deleted', true, []);
    var summary = (await alice.summaries(includeDeleted: true)).single.data;
    final removal = summary['removal'] as String;
    expect(summary['removedAt'], isA<int>());
    await alice.state.set('purged', note.id, removal);
    expect(alice.state.purged(note.id, removal), true);
    var current = (await alice.get(note.id, includeUnavailable: true))!;
    await alice.edit(
      note.id,
      note.epoch,
      'deleted',
      false,
      current.parents('deleted'),
    );
    current = (await alice.get(note.id))!;
    await alice.edit(
      note.id,
      note.epoch,
      'deleted',
      true,
      current.parents('deleted'),
    );
    summary = (await alice.summaries(includeDeleted: true)).single.data;
    expect(alice.state.purged(note.id, summary['removal']), false);
  });

  test('device-local pins migrate to synced personal state', () async {
    final note = await alice.create(text: 'Pinned before');
    // A profile from an earlier build: a local pin and no migration yet.
    a.store.set('notePin/${note.id}', true);
    a.store.set('noteStateMigrated', false);
    final fresh = Notes(a);
    await fresh.refresh();
    expect(fresh.pinned(note.id), true);
    expect(a.store.objects(kind: 'note_self').length, 1);
    await Notes(a).refresh();
    expect(a.store.objects(kind: 'note_self').length, 1);
  });

  test('personal state rejects malformed values', () {
    bool valid(String field, Object? value) => validContent('note_self', {
      'field': field,
      'target': 'room2:x:y',
      'value': value,
      'clock': 1,
      'parents': [],
    });
    expect(valid('pin', true), true);
    expect(valid('pin', 'yes'), false);
    expect(valid('reminder', {}), true);
    expect(valid('reminder', {'at': 5, 'repeat': 'weekly'}), true);
    expect(valid('reminder', {'at': 5, 'repeat': 'hourly'}), false);
    expect(valid('labels', ['a', 'b']), true);
    expect(valid('labels', List.filled(65, 'a')), false);
    expect(valid('labelName', ' '), false);
    expect(valid('order', 'V'), true);
    expect(valid('purged', 'removal-op'), true);
    expect(valid('purged', true), false);
    expect(valid('someday', {'x': 1}), true);
    expect(cara.pinned('nothing'), false);
  });
}
