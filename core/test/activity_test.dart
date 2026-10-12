import 'package:test/test.dart';
import 'package:ournet_core/ournet_core.dart';

Future<Node> friendOf(Node a, {int Function()? clock}) async {
  final other = Node(await LocalIdentity.create(), Store(), clock: clock);
  await a.addContact(other.identity.certificate);
  await other.addContact(a.identity.certificate);
  addTearDown(other.close);
  return other;
}

List<String> rows(Activity feed) => [
  for (final e in feed.entries) '${e.section.name} ${e.space} ${e.count}',
];

void main() {
  late Node a, b;
  setUp(() async {
    a = Node(await LocalIdentity.create(), Store());
    addTearDown(a.close);
    b = await friendOf(a);
  });

  test('merges what arrived about one thing on one day into a row', () async {
    await b.publish('post', {'text': 'One', 'title': 'Sourdough'});
    await b.publish('post', {'text': 'Two'});
    await syncPair(a, b);
    final feed = Activity(a);
    expect(await feed.refresh(), isTrue);
    final posts = feed.entries
        .where((e) => e.section == ActivitySection.posts)
        .single;
    expect(posts.space, 'general');
    expect(posts.count, 2);
    expect(posts.public, isTrue);
    expect(posts.people, [b.person]);
    expect(posts.items.map((i) => i.data!['text']), containsAll(['One', 'Two']));
    // The friend added in setUp is news too.
    expect(
      feed.entries.where((e) => e.section == ActivitySection.people).single.space,
      b.person,
    );
  });

  test('what this device did is left out; other devices of mine are not',
      () async {
    await a.publish('post', {'text': 'Mine, from here'});
    final feed = Activity(a);
    await feed.refresh();
    expect(
      feed.entries.where((e) => e.section == ActivitySection.posts),
      isEmpty,
    );
  });

  test('refresh takes in only what arrived since, and new rows count',
      () async {
    final feed = Activity(a);
    await feed.refresh();
    feed.markSeen();
    expect(feed.unseen(), 0);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await b.publish('post', {'text': 'Later', 'title': 'News'});
    await syncPair(a, b);
    expect(await feed.refresh(), isTrue);
    expect(feed.entries.first.section, ActivitySection.posts);
    expect(feed.isNew(feed.entries.first), isTrue);
    expect(feed.unseen(), 1);
    feed.markSeen();
    expect(feed.unseen(), 0);
    // Nothing new: nothing changes.
    expect(await feed.refresh(), isFalse);
  });

  test('group notes, chat and forum posts belong to their group', () async {
    final room = await Everyday(a).createRoom('Trip', [b.person]);
    await syncPair(a, b);
    final space = room.object.space;
    final theirs = (await Everyday(b).rooms()).single;
    final bobNotes = Notes(b);
    final note = await bobNotes.create(
      group: space,
      title: 'Packing',
      items: ['Tent'],
    );
    final doc = (await bobNotes.get(note.id))!;
    await bobNotes.edit(
      note.id,
      doc.epoch,
      'check:${doc.checks.first}:done',
      true,
      doc.parents('check:${doc.checks.first}:done'),
    );
    await Everyday(b).write({'type': 'note', 'text': 'Hi all'}, room: theirs);
    await b.publish(
      'room_post',
      {'text': 'Where to?', 'title': 'Route'},
      space: space,
      audience: await Everyday(b).members(theirs),
    );
    await syncPair(a, b);

    final feed = Activity(a, notes: Notes(a));
    await feed.refresh();
    final inGroup = feed.entries
        .where((e) => e.inScope(ScopeKind.group, group: space))
        .toList();
    expect(
      inGroup.map((e) => e.section).toSet(),
      {ActivitySection.notes, ActivitySection.chat, ActivitySection.posts},
    );
    final noteRow = inGroup.firstWhere(
      (e) => e.section == ActivitySection.notes,
    );
    expect(noteRow.space, note.id);
    expect(noteRow.count, greaterThan(1));
    expect(noteRow.note?.data['title'], 'Packing');
    // Not personal, not public.
    expect(
      feed.entries.where(
        (e) => e.inScope(ScopeKind.personal) && e.group != null,
      ),
      isEmpty,
    );
    expect(
      feed.entries.where((e) => e.inScope(ScopeKind.public)).map((e) => e.space),
      isNot(contains(space)),
    );
  });

  test('history that arrives late is placed when it was written', () async {
    final old = DateTime.now()
        .subtract(const Duration(days: 20))
        .millisecondsSinceEpoch;
    final past = await friendOf(a, clock: () => old);
    await past.publish('post', {'text': 'Long ago'}, space: 'archive');
    a.subscribe('archive', true);
    past.subscribe('archive', true);
    await syncPair(a, past);
    final arrival = a.store
        .arrivals(limit: 10)
        .firstWhere((r) => r.$2.space == 'archive');
    expect(arrival.$1, old);
  });

  test('reads back further a page at a time', () async {
    for (var i = 0; i < 5; i++) {
      await b.publish('post', {'text': 'post $i'}, space: 'f$i');
      a.subscribe('f$i', true);
      b.subscribe('f$i', true);
    }
    await syncPair(a, b);
    final feed = Activity(a);
    await feed.refresh();
    expect(feed.entries.where((e) => e.section == ActivitySection.posts),
        hasLength(5));
    expect(feed.exhausted, isTrue);
    expect(await feed.more(), isFalse);
    expect(rows(feed), contains('posts f4 1'));
  });
}
