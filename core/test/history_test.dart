import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';

/// Views read what they show, not all of local history, and storage is
/// bounded by bytes a peer can drive rather than by a count of objects.
void main() {
  test('group views read one space, not every space', () async {
    final node = Node(await LocalIdentity.create(), Store());
    addTearDown(node.close);
    final everyday = Everyday(node);
    final rooms = [
      for (var g = 0; g < 4; g++) await everyday.createRoom('Group $g', []),
    ];
    for (final (index, room) in rooms.indexed) {
      for (var i = 0; i < 3; i++) {
        await everyday.write({
          'type': 'note',
          'text': 'Item $index/$i',
        }, room: room);
      }
    }
    await everyday.write({'type': 'note', 'text': 'Inbox'});
    // Reading one room yields that room's items alone, and the inbox is not
    // reachable through a room (nor a room through the inbox).
    for (final (index, room) in rooms.indexed) {
      final items = await everyday.items(room);
      expect(items.map((i) => i.data['text']), [
        'Item $index/2',
        'Item $index/1',
        'Item $index/0',
      ]);
      final records = await everyday.records(space: room.object.space);
      expect(
        records.every((r) => r.object.space == room.object.space),
        isTrue,
        reason: 'a space read must not reach into other spaces',
      );
    }
    expect((await everyday.items()).map((i) => i.data['text']), ['Inbox']);
    expect((await everyday.rooms()).length, 4);
    // An unscoped read still reaches every space, including the inbox, which
    // has no room record to find it by.
    final all = await everyday.records();
    expect(all.where((r) => r.data['text'] == 'Inbox'), hasLength(1));
    expect(all.map((r) => r.object.space).toSet(), {
      '_inbox',
      for (final r in rooms) r.object.space,
    });
  });

  test('membership is settled without reading what a group said', () async {
    final node = Node(await LocalIdentity.create(), Store());
    addTearDown(node.close);
    final everyday = Everyday(node);
    final room = await everyday.createRoom('Busy', []);
    for (var i = 0; i < 40; i++) {
      await everyday.write({'type': 'note', 'text': 'Item $i'}, room: room);
    }
    // What a write settles is membership, and membership records are the
    // rooms and leaves alone. This is the structural reason its cost does
    // not follow how much the group has said; if items appeared here, every
    // write would read them again.
    final records = await everyday.membership(room.object.space);
    expect(records, isNotEmpty);
    expect(
      records.map((r) => r.object.kind).toSet(),
      {'room'},
      reason: 'membership must not reach the items',
    );
    expect(
      (await everyday.current(room)).object.id,
      room.object.id,
      reason: 'and it settles the room from those records alone',
    );
    expect(await everyday.members(room), [node.person]);
    expect(await everyday.items(room), hasLength(40));
  });

  test('the indexed projection agrees with an unscoped read', () async {
    final a = Node(await LocalIdentity.create(), Store());
    final b = Node(await LocalIdentity.create(), Store());
    addTearDown(() async {
      await a.close();
      await b.close();
    });
    await a.addContact(b.identity.certificate);
    await b.addContact(a.identity.certificate);
    final room = await Everyday(a).createRoom('Trip', [b.person]);
    await syncPair(a, b);
    await Everyday(a).write({'type': 'note', 'text': 'One'}, room: room);
    final mine = (await Everyday(b).rooms()).single;
    await Everyday(b).write({'type': 'note', 'text': 'Two'}, room: mine);
    await syncPair(a, b);
    // Membership derived from the index matches membership derived from
    // every record this device holds, including after a departure.
    Future<void> agrees(Node node, EverydayItem room) async {
      final everyday = Everyday(node);
      final all = await everyday.records();
      expect(
        everyday.effectiveMembers(room, all),
        await everyday.members(room),
      );
      expect(
        (await everyday.rooms()).map((r) => r.object.space).toSet(),
        (await everyday.rooms(records: all)).map((r) => r.object.space).toSet(),
      );
    }

    await agrees(a, room);
    await agrees(b, mine);
    await Everyday(b).leave(mine);
    await syncPair(a, b);
    expect(await Everyday(a).members(room), [a.person]);
    await agrees(a, room);
    expect(await Everyday(b).rooms(), isEmpty);
  });

  test('blocking hides records and unblocking brings them back', () async {
    final a = Node(await LocalIdentity.create(), Store());
    final b = Node(await LocalIdentity.create(), Store());
    addTearDown(() async {
      await a.close();
      await b.close();
    });
    await a.addContact(b.identity.certificate);
    await b.addContact(a.identity.certificate);
    final room = await Everyday(a).createRoom('Shared', [b.person]);
    await syncPair(a, b);
    await Everyday(b).write({
      'type': 'note',
      'text': 'From b',
    }, room: (await Everyday(b).rooms()).single);
    await syncPair(a, b);
    Future<List<String>> texts() async => [
      for (final i in await Everyday(a).items(room)) i.data['text'] as String,
    ];
    expect(await texts(), ['From b']);
    // A projection must not outlive the policy it was made under.
    a.block(b.person, true);
    expect(await texts(), isEmpty);
    expect(
      (await Everyday(a).records(
        space: room.object.space,
      )).where((r) => r.object.author == b.person),
      isEmpty,
      reason: 'the blocked author is gone, this device\'s own room is not',
    );
    a.block(b.person, false);
    expect(await texts(), ['From b']);
  });

  test('expiry removes a record without any change to the store', () async {
    var clock = 1000;
    final node = Node(
      await LocalIdentity.create(),
      Store(),
      clock: () => clock,
    );
    addTearDown(node.close);
    final everyday = Everyday(node);
    final room = await everyday.createRoom('Timed', []);
    await node.publish(
      'room_item',
      await everyday.data({
        'type': 'note',
        'text': 'Passing',
        'epoch': everyday.epoch(room),
        'history': false,
      }),
      space: room.data['room'],
      audience: [node.person],
      expires: 2000,
    );
    expect((await everyday.items(room)).length, 1);
    final count = node.store.count;
    clock = 3000;
    // Nothing was written or deleted: visibility is decided when read.
    expect(await everyday.items(room), isEmpty);
    expect(node.store.count, count);
  });

  test('the Lamport counter survives a restart without rereading', () async {
    final identity = await LocalIdentity.create();
    final store = Store();
    final first = Node(identity, store);
    final everyday = Everyday(first);
    final room = await everyday.createRoom('Counting', []);
    for (var i = 0; i < 5; i++) {
      await everyday.write({'type': 'note', 'text': 'Item $i'}, room: room);
    }
    final reached = (await everyday.data({'type': 'note'}))['clock'] as int;
    expect(reached, greaterThan(5));
    // A second node over the same store starts from what was recorded rather
    // than rereading every item, and never numbers a new write below one
    // already stored.
    final second = Node(identity, store);
    addTearDown(() async {
      await second.close();
      await first.close();
    });
    expect((await Everyday(second).data({'type': 'note'}))['clock'], reached);
    expect(store.setting('everyday/clock'), reached - 1);
  });

  test('a block applied while closed reprojects on the next start', () async {
    final a = Node(await LocalIdentity.create(), Store());
    final b = Node(await LocalIdentity.create(), Store());
    addTearDown(() async {
      await a.close();
      await b.close();
    });
    await a.addContact(b.identity.certificate);
    await b.addContact(a.identity.certificate);
    final room = await Everyday(a).createRoom('Shared', [b.person]);
    await syncPair(a, b);
    await Everyday(b).write({
      'type': 'note',
      'text': 'From b',
    }, room: (await Everyday(b).rooms()).single);
    await syncPair(a, b);
    expect(await Everyday(a).items(room), hasLength(1));
    final policy = a.store.setting('everyday/clockPolicy');
    // Blocking without this device looking, then starting again: the stored
    // cursor must not carry over, or records that became readable would sit
    // behind it forever.
    a.block(b.person, true);
    final reopened = Node(a.identity, a.store);
    addTearDown(reopened.close);
    expect(await Everyday(reopened).items(room), isEmpty);
    expect(reopened.store.setting('everyday/clockPolicy'), isNot(policy));
  });

  test('a cursor moves past what it scanned, not the last match', () async {
    final node = Node(await LocalIdentity.create(), Store());
    addTearDown(node.close);
    final notes = Notes(node);
    for (var i = 0; i < 5; i++) {
      await notes.create(title: 'Note $i');
    }
    // This profile holds no group items at all. Looking for them walks every
    // row on the way, so a cursor left at the last match would still be zero
    // and every later pass would walk the whole store again — which turns an
    // incremental projection back into a quadratic one.
    await Everyday(node).rooms();
    expect(node.store.insertionCursor, greaterThan(0));
    expect(
      node.store.setting('everyday/clockCursor'),
      node.store.insertionCursor,
    );
  });

  test('object bytes are accounted across writes and deletes', () async {
    final node = Node(await LocalIdentity.create(), Store());
    addTearDown(node.close);
    final store = node.store;
    expect(store.objectBytes, 0);
    final object = await node.publish('post', {'text': 'counted'});
    expect(store.objectBytes, object.wire.length);
    // Storing the same object again changes nothing.
    store.put(object);
    expect(store.objectBytes, object.wire.length);
    final other = await node.publish('post', {'text': 'also counted'});
    expect(store.objectBytes, object.wire.length + other.wire.length);
    store.db.execute('DELETE FROM objects WHERE id=?', [other.id]);
    expect(store.objectBytes, object.wire.length);
  });

  test('a peer cannot store past the received budget', () async {
    final a = Node(await LocalIdentity.create(), Store());
    final b = Node(await LocalIdentity.create(), Store());
    addTearDown(() async {
      await a.close();
      await b.close();
    });
    await a.addContact(b.identity.certificate);
    await b.addContact(a.identity.certificate);
    await a.publish('message', {'text': 'first'}, audience: [b.person]);
    await syncPair(a, b);
    expect(b.store.count, 1);
    // Own writes are never refused by the budget; a peer's are.
    b.store.set('receivedBudget', 1);
    await b.publish('post', {'text': 'mine'});
    await a.publish('message', {'text': 'second'}, audience: [b.person]);
    await expectLater(syncPair(a, b), throwsStateError);
    expect(b.store.count, 2, reason: 'the peer object was refused');
    b.store.set('receivedBudget', Node.maxReceivedBytes);
    await syncPair(a, b);
    expect(b.store.count, 3);
  });

  test('evidence digests stay correct past the cached bound', () async {
    final node = Node(await LocalIdentity.create(), Store());
    addTearDown(node.close);
    final store = node.store;
    final objects = [
      for (var i = 0; i < 40; i++) await node.publish('post', {'text': '$i'}),
    ];
    final digests = <String, String>{};
    for (final o in objects) {
      store.putEvidence(
        await node.makeEvidence({
          'domain': 'ournet/handoff/2',
          'object': o.id,
          'to': 'device-${o.id}',
          'parents': <String>[],
          'created': 1,
        }),
      );
      digests[o.id] = store.evidenceDigest(o.id);
    }
    // Reading them again, in a different order, gives the same answers
    // whether or not each one is still cached.
    for (final o in objects.reversed) {
      expect(store.evidenceDigest(o.id), digests[o.id]);
      expect(store.evidence(o.id), hasLength(1));
      expect(store.hasEvidence(o.id, store.evidence(o.id).single.id), isTrue);
    }
    expect(digests.values.toSet(), hasLength(objects.length));
  });
}
