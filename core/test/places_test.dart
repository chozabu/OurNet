import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';

class CountingNode extends Node {
  int reads = 0;
  CountingNode(super.identity, super.store);
  @override
  Future<Json?> content(SignedObject object) {
    if (Places.kinds.contains(object.kind)) reads++;
    return super.content(object);
  }
}

Future<CountingNode> person() async {
  final node = CountingNode(await LocalIdentity.create(), Store());
  addTearDown(node.close);
  return node;
}

Future<void> connect(Node a, Node b) async {
  await a.addContact(b.identity.certificate);
  await b.addContact(a.identity.certificate);
}

void main() {
  test(
    'a contributor can edit a pin received as owner-shared history',
    () async {
      final owner = await person(), author = await person();
      await connect(owner, author);
      final room = await Everyday(owner).createRoom('Trip', [author.person]);
      await syncPair(owner, author);
      final po = Places(owner), pa = Places(author);
      final list = await po.createList('Stops', space: room.object.space);
      await syncPair(owner, author);
      await pa.refresh();
      final pin = await pa.save(
        lat: 1,
        lng: 2,
        name: 'Camp',
        space: list.space,
        list: list.id,
      );
      await syncPair(owner, author);
      await owner.publish(
        'map_place',
        {...pin.data, 'clock': pin.clock + 1, 'history': true},
        space: pin.space,
        audience: [owner.person, author.person],
      );
      await syncPair(owner, author);
      await pa.refresh();
      expect(pa.all.single.data['history'], isTrue);
      await pa.edit(
        pa.all.single,
        name: 'New camp',
        emoji: '⛺',
        note: 'Updated',
      );
      await syncPair(owner, author);
      await po.refresh();
      expect(po.all.single.name, 'New camp');
      await po.remove(po.all.single);
      await expectLater(
        po.edit(
          po.place(pin.space, pin.id)!,
          name: 'Stale edit',
          emoji: '⭐',
          note: '',
        ),
        throwsStateError,
      );
    },
  );
  test('place links carry a point, never private record contents', () {
    final point = (
      lat: -33.86,
      lng: 151.2,
      name: 'A swim & picnic',
      emoji: '🏊🏽‍♀️',
    );
    final link = Places.link(point);
    expect(Places.parseLink(link), point);
    expect(Places.linkPattern.firstMatch('Meet at $link.')?.group(0), link);
    expect(Places.parseLink('ournet://place/NaN/2'), isNull);
    expect(Places.parseLink('ournet://place/91/2'), isNull);
    expect(Places.parseLink('https://place/1/2'), isNull);
    expect(Places.parseLink('ournet://place/1/2?name=%FF'), isNull);
  });
  test(
    'private saves, independent memberships, notes and list deletion',
    () async {
      final a = await person();
      final b = await person();
      await connect(a, b);
      final p = Places(a);
      final list = await p.createList('Swimming');
      final pin = await p.save(
        lat: 51.5,
        lng: -.12,
        name: 'River',
        note: 'Quiet',
        emoji: '🏊🏽‍♀️',
      );
      await p.setInList(pin, list.id, true);
      expect(p.inList(Places.personal, Places.saved).single.id, pin.id);
      expect(p.inList(Places.personal, list.id).single.id, pin.id);
      await p.setPrivateNote(pin, 'My reminder');
      expect(p.privateNote(pin), 'My reminder');
      await p.remove(list);
      expect(p.lists, isEmpty);
      expect(p.all.single.note, 'Quiet');
      await p.setInList(pin, Places.saved, false);
      expect(p.all.single.id, pin.id);
      await syncPair(a, b);
      final theirs = Places(b);
      await theirs.refresh();
      expect(theirs.all, isEmpty);
      expect(b.store.objects(kind: 'map_note'), isEmpty);
      await p.remove(pin);
      expect(p.all, isEmpty);
    },
  );

  test(
    'group places sync but private notes do not; peers cannot forge edits',
    () async {
      final a = await person();
      final b = await person();
      final c = await person();
      await connect(a, b);
      await connect(a, c);
      await connect(b, c);
      final room = await Everyday(a).createRoom('Trip', [b.person, c.person]);
      await syncPair(a, b);
      await syncPair(a, c);
      final pa = Places(a), pb = Places(b), pc = Places(c);
      final list = await pa.createList('Stops', space: room.object.space);
      final pin = await pa.save(
        lat: 1,
        lng: 2,
        name: 'Camp',
        space: list.space,
        list: list.id,
        note: 'Meet here',
      );
      await pa.setPrivateNote(pin, 'Private door code');
      await syncPair(a, b);
      await pb.refresh();
      expect(pb.all.single.name, 'Camp');
      expect(pb.privateNote(pb.all.single), isEmpty);
      expect(pb.canEdit(pb.all.single), isFalse);
      await expectLater(
        pb.edit(pb.all.single, name: 'Forged', emoji: '⭐', note: ''),
        throwsStateError,
      );
      await b.publish(
        'map_place',
        {...pin.data, 'clock': 999, 'name': 'Forged'},
        space: list.space,
        audience: [a.person, b.person, c.person],
      );
      await syncPair(a, b);
      await pa.refresh();
      expect(pa.all.single.name, 'Camp');
      // Every member can organise existing pins, without editing their details.
      await pb.setInList(pb.all.single, list.id, false);
      await syncPair(a, b);
      await pa.refresh();
      expect(pa.inList(list.space, list.id), isEmpty);
      await syncPair(a, c);
      await pc.refresh();
      expect(pc.all.single.name, 'Camp');
      expect(pc.privateNote(pc.all.single), isEmpty);
    },
  );

  test(
    'concurrent edits converge and deletion survives later synchronisation',
    () async {
      final a = await person(), b = await person();
      await connect(a, b);
      final room = await Everyday(a).createRoom('Trip', [b.person]);
      await syncPair(a, b);
      final pa = Places(a), pb = Places(b);
      final list = await pa.createList('Stops', space: room.object.space);
      await syncPair(a, b);
      await pb.refresh();
      final pin = await pb.save(
        lat: 1,
        lng: 2,
        name: 'Camp',
        space: list.space,
        list: list.id,
      );
      await syncPair(a, b);
      await pa.refresh();
      await pa.edit(pa.all.single, name: 'Owner edit', emoji: '⛺', note: 'A');
      await pb.edit(pin, name: 'Contributor edit', emoji: '🌲', note: 'B');
      await syncPair(a, b);
      await pa.refresh();
      await pb.refresh();
      expect(pa.all.single.object.id, pb.all.single.object.id);
      await pa.remove(pa.all.single);
      await syncPair(a, b);
      await pb.refresh();
      expect(pb.all, isEmpty);
    },
  );

  test(
    'membership changes preserve saved places, list links and tombstones',
    () async {
      final a = await person(), b = await person(), c = await person();
      await connect(a, b);
      await connect(a, c);
      var room = await Everyday(a).createRoom('Trip', [b.person]);
      await syncPair(a, b);
      final pa = Places(a), pb = Places(b), pc = Places(c);
      final list = await pa.createList('Stops', space: room.object.space);
      await syncPair(a, b);
      await pb.refresh();
      final pin = await pb.save(
        lat: 1,
        lng: 2,
        name: 'Camp',
        space: list.space,
        list: list.id,
      );
      await syncPair(a, b);
      room = await Everyday(
        a,
      ).changeMembers(room, [b.person, c.person], shareHistory: true);
      await syncPair(a, c);
      await pc.refresh();
      expect(pc.inList(list.space, list.id).single.name, 'Camp');
      await pa.refresh();
      await pa.remove(pa.place(pin.space, pin.id)!);
      room = await Everyday(
        a,
      ).changeMembers(room, [c.person], shareHistory: true);
      await syncPair(a, c);
      await pc.refresh();
      expect(pc.all, isEmpty);
      expect(pc.lists.single.name, 'Stops');
      await expectLater(
        pb.createList('Old group', space: room.object.space),
        completes,
      );
      // The removed device has not heard yet. Once it does, writes are refused.
      await syncPair(a, b);
      await pb.refresh();
      expect(pb.groups, isEmpty);
      await expectLater(
        pb.createList('No access', space: room.object.space),
        throwsStateError,
      );
    },
  );

  test(
    'refresh reads new map records only, regardless of stored history',
    () async {
      final a = await person();
      final p = Places(a);
      var pin = await p.save(lat: 1, lng: 2, name: 'Place');
      for (var i = 0; i < 80; i++) {
        pin = await p.edit(pin, name: 'Place $i', emoji: '⭐', note: '');
      }
      a.reads = 0;
      await p.refresh();
      await p.refresh();
      expect(a.reads, 0);
      await a.publish('message', {'text': 'Unrelated'}, audience: [a.person]);
      await p.refresh();
      expect(a.reads, 0);
      await Everyday(a).createRoom('Shared note', [], noteId: 'note');
      await p.refresh();
      expect(
        a.reads,
        0,
        reason: 'A shared note is not a map membership change.',
      );
      await a.publish(
        'map_place',
        {...pin.data, 'clock': pin.clock + 1, 'name': 'Newest'},
        space: Places.personal,
        audience: [a.person],
      );
      await p.refresh();
      expect(a.reads, 1);
      expect(p.all.single.name, 'Newest');
    },
  );

  test('map validators reject invalid coordinates and oversized fields', () {
    final registry = Registry();
    final base = <String, dynamic>{
      'id': 'person:pin',
      'clock': 1,
      'lat': 0,
      'lng': 0,
      'name': 'Place',
      'emoji': '⭐',
      'note': '',
    };
    expect(registry.accepts('map_place', base), isTrue);
    expect(registry.accepts('map_place', {...base, 'lat': 900000001}), isFalse);
    expect(registry.accepts('map_place', {...base, 'lng': 1.5}), isFalse);
    expect(registry.accepts('map_place', {...base, 'name': ''}), isFalse);
    expect(
      registry.accepts('map_place', {...base, 'note': 'x' * 4001}),
      isFalse,
    );
    expect(
      registry.accepts('map_link', {
        'id': 'wrong',
        'clock': 1,
        'place': 'p',
        'list': 'l',
      }),
      isFalse,
    );
  });
}
