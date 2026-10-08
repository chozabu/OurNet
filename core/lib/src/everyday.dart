import 'dart:async';
import 'dart:math' as math;
import 'calendar.dart';
import 'model.dart';
import 'node.dart';
import 'notes.dart';
import 'room_forum.dart';

class EverydayItem {
  final SignedObject object;
  final Json data;

  /// For a room record: when its members last added each person they did
  /// (see [Everyday.invite]), and who of them the owner's record does not
  /// name yet. Both are already counted in `members`.
  final Map<String, int> invited;
  final Set<String> added;
  EverydayItem(
    this.object,
    this.data, {
    this.invited = const {},
    this.added = const {},
  });
}

/// Owner-signed membership epochs; independent list item operations
/// converge using a Lamport counter and deterministic object ID tie-break.
class Everyday {
  final Node node;
  Everyday(this.node);
  Future<void> shareHistory() async {
    for (final item in await items()) {
      await node.publish(
        'inbox',
        item.data,
        space: '_inbox',
        audience: [node.person],
      );
    }
  }

  /// Re-encrypts the groups this person owns to the devices admitted now.
  ///
  /// A private object is encrypted to the devices that existed when it was
  /// written, so a device enrolled later reads none of it. Without this a new
  /// device cannot see that a group exists at all: its room record stays
  /// unreadable, and later writes arrive in a space it has no membership for.
  ///
  /// The epoch is deliberately left alone. A membership change would strand
  /// whatever the other members wrote concurrently, and nothing about the
  /// membership has changed here — only which of this person's devices can
  /// read it. Only rooms this person owns are re-issued: a room record counts
  /// only from its owner, so a group someone else runs is theirs to re-issue.
  Future<int> shareRooms() async {
    var count = 0;
    for (final room in await rooms()) {
      // Legacy rooms take their epoch from the record's own ID, so a copy
      // would not describe the same epoch. They migrate on their next edit.
      if (room.data['owner'] != node.person ||
          room.data['note'] == true ||
          room.data['generation'] == null)
        continue;
      try {
        count += await reissue(room);
      } catch (_) {
        // A group with a member this device can no longer encrypt to must
        // not stop the rest of the pass; it is safe to run again later.
      }
    }
    return count;
  }

  /// Republishes [room]'s record, and its live entries when [entries] is set,
  /// unchanged except for being encrypted to the devices admitted now.
  Future<int> reissue(EverydayItem room, {bool entries = true}) async {
    final current = await this.current(room);
    if (current.data['owner'] != node.person)
      throw StateError('Only the group owner can re-issue this group.');
    var count = 1;
    final history = entries ? await _history(current) : const <EverydayItem>[];
    // The record first: a device that stops here has the group, and its
    // entries arrive with the next write or the next pass.
    await node.publish(
      'room',
      current.data,
      space: current.object.space,
      audience: _recordAudience(current),
    );
    for (final item in history) {
      // A deleted entry has nothing left to show, so the copy is the record
      // that said so; leaving it out simply leaves the entry absent.
      if (item.data['deleted'] == true) continue;
      // One below the record it copies, so a device that can read both keeps
      // showing the original: entries are deduplicated by the highest clock,
      // and a copy is only ever needed where the original cannot be read.
      final clock = item.data['clock'] as int;
      await node.publish(
        'room_item',
        {
          ...item.data,
          'clock': clock > 0 ? clock - 1 : 0,
          'epoch': epoch(current),
          'history': true,
          'originalAuthor': item.data['originalAuthor'] ?? item.object.author,
        },
        space: current.object.space,
        audience: await members(current),
      );
      count++;
    }
    if (entries) {
      for (final post in await RoomForum.read(node, current)) {
        await node.publish(
          'room_post',
          _postCopy(post),
          space: current.object.space,
          audience: await members(current),
        );
        count++;
      }
      final readers = await members(current);
      count += await Calendar.reshare(node, current, audience: (_) => readers);
    }
    return count;
  }

  /// A forum post as republished for people who could not read the original.
  /// It remembers what it copies, so replies still find their parent.
  Json _postCopy(ForumPost post) => {
    ...post.data,
    'history': true,
    'originalAuthor': post.author,
    'copyOf': post.root,
    'sent': post.sent,
  };

  /// Who a room record must be addressed to: everyone it names, and everyone
  /// the record it replaces was addressed to.
  List<String> _recordAudience(EverydayItem room) => {
    ...room.object.audience,
    ...(room.data['members'] as List).cast<String>(),
  }.toList();

  /// The record kinds group history is made of. Membership lives in the first
  /// three; the rest is what members wrote.
  static const membershipKinds = ['room', 'room_leave', 'room_invite'];
  static const itemKinds = ['inbox', 'room_item'];
  static const kinds = [...membershipKinds, ...itemKinds];

  static final _indexes = Expando<_EverydayIndex>();
  Future<_EverydayIndex> _index() async {
    final index = _indexes[node] ??= _EverydayIndex(node);
    await index.refresh();
    return index;
  }

  /// The visible records of [space], or of every space.
  ///
  /// Reading one space is what the views do, and costs that space alone.
  /// Passing no space walks all of local history and is left for tools and
  /// tests; nothing the app does on a refresh takes that path.
  Future<List<EverydayItem>> records({String? space}) async {
    final index = await _index();
    // Items can sit in a space the index has no membership for: the inbox,
    // which has no room, and a room whose record has not arrived yet.
    final spaces = space == null
        ? {...index.spaces.keys, ...node.store.spaces(itemKinds)}.toList()
        : [space];
    final result = <EverydayItem>[];
    for (final id in spaces) {
      result
        ..addAll(_visible(index.spaces[id]?.records ?? const []))
        ..addAll(await _items(id));
    }
    return result;
  }

  /// Changes whenever a membership record is taken in or the projection is
  /// rebuilt: what [GroupAccess] checks before working out readers again.
  Future<int> membershipVersion() async => (await _index()).version;

  /// The visible membership records of [space]: its rooms and leaves, without
  /// the items. What a caller deriving membership or epochs needs, and all it
  /// should have to read.
  Future<List<EverydayItem>> membership(String space) async =>
      _visible((await _index()).spaces[space]?.records ?? const []);

  /// [Node.visible] depends on the clock (objects expire) and on who is
  /// blocked, so it is never baked into a projection: it is applied when a
  /// record is read, not when it was first indexed.
  List<EverydayItem> _visible(Iterable<EverydayItem> records) => [
    for (final r in records)
      if (node.visible(r.object)) r,
  ];

  /// What members wrote in one space. Read on demand rather than held: items
  /// are the bulk of history, and a view only ever shows one space's worth.
  ///
  /// All of that space, in pages: items are deduplicated by entry, so a limit
  /// would not shorten the list but lose whichever entries were last written
  /// about longest ago. Showing a very long group lazily is a separate piece
  /// of work; dropping part of it silently is not an acceptable stand-in.
  Future<List<EverydayItem>> _items(String space) async {
    final result = <EverydayItem>[];
    final slice = TimeSlice();
    for (final o in node.store.allOf(kinds: itemKinds, space: space)) {
      if (o.isPublic) continue;
      await slice.pause();
      final p = await node.content(o);
      if (p != null) result.add(EverydayItem(o, p));
    }
    return result;
  }

  String epoch(EverydayItem room) =>
      room.data['epoch'] as String? ?? room.object.id;

  bool _roomValid(EverydayItem r) {
    final p = r.data, o = r.object;
    if (o.kind != 'room' || o.space != p['room'] || o.author != p['owner'])
      return false;
    if (!o.audience.toSet().containsAll((p['members'] as List).cast<String>()))
      return false;
    // A self-certifying ID belongs to the person it names, whatever the
    // record's shape: otherwise anyone could publish a room over someone
    // else's note or group and claim to own it.
    final room = p['room'] as String;
    if (room.startsWith('room2:') && !room.startsWith('room2:${o.author}:'))
      return false;
    if (p['generation'] == null)
      return o.audience.length == (p['members'] as List).length;
    return p['generation'] is int && p['generation'] >= 0;
  }

  /// Which of two records for one room is current. A newer generation always
  /// wins; archiving settles rooms of the same generation. Never depends on
  /// the order records are read in, so every device agrees.
  static int _supersedes(EverydayItem a, EverydayItem b) {
    int archived(EverydayItem r) => r.data['archived'] == true ? 1 : 0;
    final generation = (a.data['generation'] as int? ?? 0).compareTo(
      b.data['generation'] as int? ?? 0,
    );
    if (generation != 0) return generation;
    final order = archived(a).compareTo(archived(b));
    return order != 0 ? order : a.object.id.compareTo(b.object.id);
  }

  /// Every room this person is in, latest record per space.
  ///
  /// Without [records] this reads the index, which holds membership alone, so
  /// it costs the rooms and leaves rather than all of history. Each space is
  /// settled on its own: a room's current record and who has left it are
  /// decided only by that space's records, so scoping changes no outcome.
  Future<List<EverydayItem>> rooms({
    bool includeLeft = false,
    List<EverydayItem>? records,
  }) async {
    if (records == null) {
      final index = await _index();
      return [
        for (final space in index.spaces.values)
          ..._latest(_visible(space.records), includeLeft: includeLeft),
      ];
    }
    return _latest(records, includeLeft: includeLeft);
  }

  List<EverydayItem> _latest(
    List<EverydayItem> records, {
    required bool includeLeft,
  }) {
    final latest = <String, EverydayItem>{};
    for (final room in records.where(_roomValid)) {
      final old = latest[room.object.space];
      if (old == null || _supersedes(room, old) > 0)
        latest[room.object.space] = room;
    }
    return latest.values
        .map((room) => _withInvites(room, records))
        .where(
          (room) =>
              includeLeft ||
              (room.data['archived'] != true &&
                  effectiveMembers(room, records).contains(node.person)),
        )
        .toList();
  }

  /// [room] with the people its members added since its owner wrote it.
  ///
  /// Membership is the owner's record plus the invites written within its
  /// epoch by people already members, in the order written; an invite from
  /// someone who is not (yet) a member counts once they are. Every device
  /// reading the same records works out the same members. Only the group's
  /// owner may add people unless the record says members may (`invite`).
  /// The owner folds invites into its next record (see [settleInvites]), so
  /// builds without invites see them then.
  EverydayItem _withInvites(EverydayItem room, List<EverydayItem> records) {
    if (room.data['note'] == true || room.data['generation'] == null) {
      return room;
    }
    final invites =
        records
            .where(
              (r) =>
                  r.object.kind == 'room_invite' &&
                  r.object.space == room.object.space &&
                  r.data['epoch'] == epoch(room),
            )
            .toList()
          ..sort((a, b) {
            final order = a.object.created.compareTo(b.object.created);
            return order != 0 ? order : a.object.id.compareTo(b.object.id);
          });
    if (invites.isEmpty) return room;
    final owner = room.data['owner'];
    final open = room.data['invite'] == 'members';
    final members = (room.data['members'] as List).cast<String>().toSet();
    final certificates = [...room.data['certificates'] as List? ?? const []];
    final invited = <String, int>{};
    final pending = [...invites];
    for (var changed = true; changed;) {
      changed = false;
      for (final invite in [...pending]) {
        final author = invite.object.author;
        if (!members.contains(author)) continue;
        pending.remove(invite);
        if (!open && author != owner) continue;
        final people = (invite.data['people'] as List).cast<String>();
        // Only people the invite reached, and the group's size limit holds.
        for (final person in people) {
          if (!invite.object.audience.contains(person)) continue;
          if (!members.contains(person)) {
            if (members.length >= 64) continue;
            members.add(person);
            changed = true;
          }
          invited[person] = math.max(
            invited[person] ?? 0,
            invite.object.created,
          );
        }
        for (final wire in invite.data['certificates'] as List) {
          if (wire is Map &&
              wire['data'] is Map &&
              people.contains(wire['data']['person'])) {
            certificates.add(wire);
          }
        }
      }
    }
    if (invited.isEmpty) return room;
    final recorded = (room.data['members'] as List).toSet();
    return EverydayItem(
      room.object,
      {
        ...room.data,
        'members': members.toList()..sort(),
        'certificates': certificates,
      },
      invited: invited,
      added: {
        for (final p in members)
          if (!recorded.contains(p)) p,
      },
    );
  }

  List<String> effectiveMembers(EverydayItem room, List<EverydayItem> records) {
    final members = (room.data['members'] as List).cast<String>().toSet();
    for (final leave in records.where(
      (r) =>
          r.object.kind == 'room_leave' &&
          r.object.space == room.object.space &&
          r.data['epoch'] == epoch(room),
    )) {
      // Someone invited back after leaving is a member again.
      final back = room.invited[leave.object.author];
      if (back != null && back > leave.object.created) continue;
      members.remove(leave.object.author);
    }
    return members.toList()..sort();
  }

  Future<List<String>> members(EverydayItem room) async =>
      effectiveMembers(room, await membership(room.object.space));

  /// The room record in force for [room]'s space, or a refusal.
  ///
  /// Only rooms and leaves decide this, so it reads membership alone: a write
  /// checks it first, and must not cost what the group has said. Callers that
  /// have already read a space pass their [records] instead.
  Future<EverydayItem> current(
    EverydayItem room, [
    List<EverydayItem>? records,
  ]) async {
    records ??= await membership(room.object.space);
    final latest = (await rooms(
      includeLeft: true,
      records: records,
    )).where((r) => r.object.space == room.object.space).firstOrNull;
    if (latest == null ||
        latest.data['archived'] == true ||
        !effectiveMembers(latest, records).contains(node.person))
      throw StateError('You are no longer a member of this group.');
    return latest;
  }

  Future<void> prepare(EverydayItem room) async {
    for (final wire in room.data['certificates'] as List? ?? []) {
      final cert = DeviceCertificate.fromJson(wire);
      if ((room.data['members'] as List).contains(cert.person) &&
          cert.person != node.person &&
          !node.contacts.containsKey(cert.device) &&
          !node.revoked.contains(cert.device))
        await node.addContact(cert, explicit: false);
    }
  }

  List<Json> _certificates(List<String> members) =>
      [node.identity.certificate, ...node.contacts.values]
          .where(
            (c) =>
                members.contains(c.person) && !node.revoked.contains(c.device),
          )
          .map((c) => c.toJson())
          .toList();

  /// Creates a group of this person and [people]. With [membersInvite] any
  /// member may add people (see [invite]); otherwise only its owner.
  Future<EverydayItem> createRoom(
    String name,
    List<String> people, {
    String? noteId,
    bool membersInvite = false,
  }) async {
    final members = {node.person, ...people}.toList()..sort();
    final data = <String, dynamic>{
      'room': 'room2:${node.person}:${noteId ?? randomId()}',
      if (noteId != null) 'note': true,
      'owner': node.person,
      'name': name.trim(),
      'members': members,
      'generation': 0,
      'epoch': randomId(),
      'certificates': _certificates(members),
      if (noteId == null) 'groupKey': newGroupKey(),
      if (noteId == null && membersInvite) 'invite': 'members',
    };
    return EverydayItem(
      await node.publish('room', data, space: data['room'], audience: members),
      data,
    );
  }

  /// Whether this person may add people to [room] themselves: its owner, or
  /// any member once the owner lets members add people.
  bool canInvite(EverydayItem room) =>
      room.data['owner'] == node.person ||
      (room.data['invite'] == 'members' && room.data['groupKey'] != null);

  /// Adds [people], whom this member knows, to [room]: an invite every
  /// member's device counts, carrying their devices and the group's key, so
  /// they can open what the group has said so far. No one else needs to be
  /// online: members pass the group's objects on to them.
  Future<List<SignedObject>> invite(
    EverydayItem room,
    List<String> people,
  ) async {
    room = await current(room);
    if (!canInvite(room)) {
      throw StateError('Only the owner can add people to this group.');
    }
    final key = room.data['groupKey'];
    if (key is! Json) {
      throw StateError('This group is from an earlier version.');
    }
    final members = await this.members(room);
    final adding = {
      for (final p in people)
        if (p != node.person && !members.contains(p)) p,
    }.toList()..sort();
    if (adding.isEmpty) throw StateError('They are already members.');
    if (members.length + adding.length > 64) {
      throw StateError('A group supports up to 64 members.');
    }
    await prepare(room);
    for (final person in adding) {
      if (!node.contacts.values.any(
        (c) => c.person == person && !node.revoked.contains(c.device),
      )) {
        throw StateError('Add a current device for everyone you add first.');
      }
    }
    final sent = <SignedObject>[];
    for (var i = 0; i < adding.length; i += 16) {
      final batch = adding.sublist(i, math.min(i + 16, adding.length));
      sent.add(
        await node.publish(
          'room_invite',
          {
            'epoch': epoch(room),
            'people': batch,
            'certificates': _certificates(batch),
            'groupKey': key,
          },
          space: room.object.space,
          audience: {...members, ...batch}.toList(),
        ),
      );
    }
    return sent;
  }

  /// Folds the people members added into the records of the groups this
  /// person owns, so builds without invites count them too. Returns how many
  /// records were written. Safe to run on every change: a group with nothing
  /// to fold costs a read of its membership.
  Future<int> settleInvites() async {
    var count = 0;
    for (final room in await rooms()) {
      if (room.data['owner'] != node.person || room.added.isEmpty) continue;
      await prepare(room);
      final data = {
        ...room.data,
        'generation': (room.data['generation'] as int) + 1,
      };
      try {
        await node.publish(
          'room',
          data,
          space: room.object.space,
          audience: _recordAudience(room),
        );
        count++;
      } catch (_) {
        // A member whose devices this device has not met yet: their devices
        // come with the next sync, and this runs again then.
      }
    }
    return count;
  }

  /// Lets any member of [room] add people, as its owner. One way: a group
  /// told it is shared is not taken back by one person.
  ///
  /// Everything the group holds is re-shared under a new key, so whoever is
  /// added later can open what came before, as with any membership change.
  Future<EverydayItem> letMembersInvite(EverydayItem room) async {
    room = await current(room);
    if (room.data['owner'] != node.person) {
      throw StateError('Only the group owner can change who adds people.');
    }
    if (room.data['invite'] == 'members' && room.data['groupKey'] != null) {
      return room;
    }
    final members = await this.members(room);
    return changeMembers(
      room,
      members.where((p) => p != node.person).toList(),
      shareHistory: true,
      membersInvite: true,
    );
  }

  /// Asks [room]'s owner to add [people], friends of this member. Only
  /// the owner signs membership, so this is a private `room_add` for the
  /// owner, which carries those people's devices: the owner may not know
  /// them. Builds without it ignore it.
  Future<SignedObject> askToAdd(EverydayItem room, List<String> people) async {
    room = await current(room);
    final owner = room.data['owner'] as String;
    if (owner == node.person) {
      throw StateError('You own this group: add them directly.');
    }
    final members = await this.members(room);
    final adding = {
      for (final p in people)
        if (p != node.person && !members.contains(p)) p,
    }.toList()..sort();
    if (adding.isEmpty) throw StateError('They are already members.');
    await prepare(room);
    return node.publish(
      'room_add',
      {
        'epoch': epoch(room),
        'people': adding,
        'certificates': _certificates(adding),
      },
      space: room.object.space,
      audience: [owner],
    );
  }

  /// Members' requests to add people, for the owner to approve: the people
  /// not yet members, newest request first.
  Future<List<({SignedObject object, List<String> people, List certificates})>>
  addRequests(EverydayItem room) async {
    if (room.data['owner'] != node.person) return const [];
    final members = await this.members(room);
    final result =
        <({SignedObject object, List<String> people, List certificates})>[];
    for (final o in node.store.objects(
      kind: 'room_add',
      space: room.object.space,
      limit: 200,
    )) {
      if (o.author == node.person ||
          o.isPublic ||
          !node.visible(o) ||
          !members.contains(o.author) ||
          node.store.setting('roomAdd/${o.id}') == true) {
        continue;
      }
      final p = await node.content(o);
      if (p == null) continue;
      final people = [
        for (final person in (p['people'] as List).cast<String>())
          if (!members.contains(person) && !node.blocked.contains(person))
            person,
      ];
      if (people.isEmpty) continue;
      result.add((
        object: o,
        people: people,
        certificates: p['certificates'] as List,
      ));
    }
    return result;
  }

  /// Admits the devices a member's request carries for [people], as a
  /// group's members are admitted: not as friends.
  Future<void> admitRequested(List certificates, List<String> people) async {
    for (final wire in certificates) {
      try {
        final cert = DeviceCertificate.fromJson(wire as Json);
        if (people.contains(cert.person) &&
            cert.person != node.person &&
            !node.contacts.containsKey(cert.device) &&
            !node.revoked.contains(cert.device)) {
          await node.addContact(cert, explicit: false);
        }
      } catch (_) {}
    }
  }

  /// Settles a request to add people, approved or not, on this device.
  void closeAddRequest(SignedObject request) {
    node.store.set('roomAdd/${request.id}', true);
    node.notify();
  }

  /// Publishes [room]'s membership as [people] and this owner, in a new
  /// epoch. A group gets a new key: with [shareHistory] what it holds is
  /// re-shared under it, to everyone, so it opens for whoever is added later.
  /// [membersInvite] lets members add people from then on.
  Future<EverydayItem> changeMembers(
    EverydayItem room,
    List<String> people, {
    required bool shareHistory,
    bool membersInvite = false,
    Future<void> Function(Json, List<String>)? beforePublish,
  }) async {
    room = await current(room);
    if (room.data['owner'] != node.person)
      throw StateError('Only the group owner can change membership.');
    // People members added come with their devices in their invites.
    await prepare(room);
    final nextMembers = {node.person, ...people}.toList()..sort();
    if (nextMembers.length > 64)
      throw StateError('A group supports up to 64 members.');
    final history = await _history(room);
    // Legacy rooms migrate to a self-certifying namespace on their first edit.
    final id = room.data['generation'] == null
        ? 'room2:${node.person}:${randomId()}'
        : room.object.space;
    final group = room.data['note'] != true;
    final data = <String, dynamic>{
      ...room.data,
      'room': id,
      'generation': (room.data['generation'] as int? ?? 0) + 1,
      'members': nextMembers,
      'epoch': randomId(),
      'certificates': _certificates(nextMembers),
      if (group) 'groupKey': newGroupKey(),
      if (group && membersInvite) 'invite': 'members',
    };
    // Copies are written before the record that holds the new key, so they
    // name it themselves. A group whose history is shared re-shares all of
    // it: the old key opens nothing for people added from now on.
    final seal = group ? groupKeyFrom(data['groupKey'] as Json) : null;
    final reseal = group && shareHistory;
    final audience =
        {...(room.data['members'] as List).cast<String>(), ...nextMembers}
            .where(
              (p) =>
                  p == node.person ||
                  node.contacts.values.any(
                    (c) => c.person == p && !node.revoked.contains(c.device),
                  ),
            )
            .toList();
    if (audience.length > 64)
      throw StateError(
        'Remove members first, then invite replacements to stay within the 64-person update limit.',
      );
    if (_certificates(audience).length > 128)
      throw StateError(
        'This membership update exceeds the 128-device encryption limit.',
      );
    // Check encryption recipients before committing the membership update.
    for (final member in nextMembers) {
      if (member != node.person &&
          !node.contacts.values.any(
            (c) => c.person == member && !node.revoked.contains(c.device),
          ))
        throw StateError('Add a current device for every group member first.');
    }
    for (final item in history) {
      if (item.data['deleted'] == true) continue;
      final historyAudience = shareHistory
          ? nextMembers
          : nextMembers.where(item.object.audience.contains).toList();
      await node.publish(
        'room_item',
        {
          ...item.data,
          'epoch': data['epoch'],
          'history': true,
          'originalAuthor': item.data['originalAuthor'] ?? item.object.author,
        },
        space: id,
        audience: historyAudience,
        seal: shareHistory ? seal : null,
      );
    }
    // The group forum has no epochs: members who had a post keep it. Where the
    // room moved to a new space (legacy groups) everyone needs a copy, and
    // otherwise only the people joining do, and only if history is shared.
    final before = (room.data['members'] as List).cast<String>();
    final joining = nextMembers.where((p) => !before.contains(p)).toList();
    for (final post in await RoomForum.read(node, room)) {
      final List<String> readers;
      if (reseal) {
        readers = nextMembers;
      } else if (id == room.object.space) {
        if (!shareHistory || joining.isEmpty) continue;
        readers = [node.person, ...joining];
      } else {
        readers = shareHistory
            ? nextMembers
            : nextMembers.where(post.object.audience.contains).toList();
      }
      await node.publish(
        'room_post',
        _postCopy(post),
        space: id,
        audience: readers,
        seal: reseal ? seal : null,
      );
    }
    // The calendar works the same way: events are not epoch-bound, so only
    // people joining need copies, and people leaving take their events with
    // them unless the owner passes those on as its own.
    final leaving = before.where((p) => !nextMembers.contains(p)).toSet();
    await Calendar.reshare(
      node,
      room,
      into: id,
      seal: reseal ? seal : null,
      audience: (e) {
        if (reseal) return nextMembers;
        if (id != room.object.space) {
          return shareHistory
              ? nextMembers
              : nextMembers.where(e.object.audience.contains).toList();
        }
        return [
          if (shareHistory) ...joining,
          if (leaving.contains(e.author)) ...nextMembers,
        ];
      },
    );
    await beforePublish?.call(data, nextMembers);
    final next = EverydayItem(
      await node.publish('room', data, space: id, audience: audience),
      data,
    );
    // Notes kept in the group's space are encrypted to the people who were
    // members when they were written. People joining are sent each note's
    // current state, and the owner's other members see no change.
    if (shareHistory &&
        (reseal || joining.isNotEmpty) &&
        id == room.object.space) {
      await Notes(node).shareGroup(next, audience: nextMembers);
    }
    if (id != room.object.space) {
      await node.publish(
        'room',
        {...room.data, 'archived': true},
        space: room.object.space,
        audience: room.object.audience,
      );
    }
    return next;
  }

  Future<void> leave(EverydayItem room) async {
    room = await current(room);
    // Someone added by a member may not have met every member's devices.
    await prepare(room);
    if (room.data['owner'] == node.person) {
      await node.publish(
        'room',
        {
          ...room.data,
          'archived': true,
          if (room.data['generation'] != null)
            'generation': (room.data['generation'] as int) + 1,
        },
        space: room.object.space,
        audience: _recordAudience(room),
      );
      return;
    }
    await node.publish(
      'room_leave',
      {'epoch': epoch(room)},
      space: room.object.space,
      audience: _recordAudience(room),
    );
  }

  /// Whether [r] is an item of [selected], the room record in force: written
  /// by a member, to the right audience and, once rooms have epochs, within
  /// the current one. History shared with a new member counts only from the
  /// owner.
  bool _belongs(EverydayItem selected, EverydayItem r) =>
      r.object.kind == 'room_item' &&
      r.object.space == selected.data['room'] &&
      (selected.data['members'] as List).contains(r.object.author) &&
      (selected.data['generation'] == null
          ? r.object.audience.toSet().containsAll(selected.object.audience) &&
                r.object.audience.length == selected.object.audience.length
          : r.data['epoch'] == epoch(selected) &&
                r.object.audience.every(
                  (p) => (selected.data['members'] as List).contains(p),
                ) &&
                (r.data['history'] != true ||
                    r.object.author == selected.data['owner']));

  /// When an item was first written. Editing replaces the object, so newer
  /// items carry the original time in `sent`; older ones fall back to the
  /// object's own.
  static int sentOf(EverydayItem i) =>
      i.data['sent'] as int? ?? i.object.created;

  /// What reactions to a group entry are filed under.
  static String reactionTarget(EverydayItem i) => 'entry:${i.data['entry']}';

  Future<List<EverydayItem>> items([EverydayItem? room]) async {
    // One pass over the space serves both membership and item selection. A
    // room's items live in its own space, and the inbox in `_inbox`, so this
    // is everything the selection below can match.
    final records = await this.records(space: room?.object.space ?? '_inbox');
    if (room != null) room = await current(room, records);
    return _live(records, room);
  }

  /// The latest version of each entry in [records] that belongs to
  /// [selected], or to the inbox when it is null. Highest clock first.
  List<EverydayItem> _live(List<EverydayItem> records, EverydayItem? selected) {
    final result = records
        .where(
          (r) => selected == null
              ? r.object.kind == 'inbox' &&
                    r.object.author == node.person &&
                    r.object.audience.length == 1 &&
                    r.object.audience.single == node.person
              : _belongs(selected, r),
        )
        .toList();
    result.sort((a, b) {
      final order = (b.data['clock'] as int).compareTo(a.data['clock'] as int);
      return order == 0 ? b.object.id.compareTo(a.object.id) : order;
    });
    final seen = <String>{};
    return result.where((r) => seen.add(r.data['entry'])).toList();
  }

  /// [room]'s live entries as copies should carry them: each with `sent`,
  /// oldest first, so that copies written in this order are also stored in
  /// it and [RoomFeed] pages them newest first.
  ///
  /// Entries from before `sent` existed take the earliest time any version
  /// of them held here says, so a copy keeps the original's place rather
  /// than taking the time it was made. Only versions by the entry's author,
  /// or copies by the owner, count: anyone else could claim an early time.
  Future<List<EverydayItem>> _history(EverydayItem room) async {
    final records = await this.records(space: room.object.space);
    room = await current(room, records);
    final owner = room.data['owner'];
    final first = <String, int>{};
    for (final r in records) {
      final entry = r.data['entry'];
      if (r.object.kind != 'room_item' || entry is! String) continue;
      final author = r.data['originalAuthor'] ?? r.object.author;
      if (r.object.author != author && r.object.author != owner) continue;
      final key = '$author/$entry';
      final sent = sentOf(r);
      if (sent < (first[key] ?? sent + 1)) first[key] = sent;
    }
    return [
      for (final item in _live(records, room))
        if (item.data['sent'] is int)
          item
        else
          EverydayItem(item.object, {
            ...item.data,
            'sent':
                first['${item.data['originalAuthor'] ?? item.object.author}/'
                    '${item.data['entry']}'] ??
                sentOf(item),
          }),
    ]..sort((a, b) => sentOf(a).compareTo(sentOf(b)));
  }

  /// The counter is maintained as records are indexed, so a write no longer
  /// walks history to find out what to number itself.
  ///
  /// A new entry (one without an `entry` yet) is stamped with when it was
  /// written. A new version keeps its entry's `sent`, which its caller passes
  /// on (see [sentOf]), so editing never moves it.
  Future<Json> data(Json content) async => {
    ...content,
    'entry': content['entry'] ?? randomId(),
    if (content['entry'] == null) 'sent': content['sent'] ?? node.now(),
    'clock': (await _index()).clock + 1,
  };

  Future<void> write(Json content, {EverydayItem? room}) async {
    if (room != null) {
      room = await current(room);
      await prepare(room);
    }
    await node.publish(
      room == null ? 'inbox' : 'room_item',
      await data({
        ...content,
        if (room != null) 'epoch': epoch(room),
        if (room != null) 'history': false,
      }),
      space: room?.data['room'] ?? '_inbox',
      audience: room == null ? [node.person] : await members(room),
    );
  }
}

/// Membership records, projected once each and kept per node.
///
/// Records are immutable and reached by insertion cursors, so a refresh reads
/// only what has arrived since the last one and a routine change never
/// rewalks history. Two things are tracked, and they are separated because
/// they cost very differently:
///
/// * Rooms and leaves, which membership is derived from. There are few of
///   them, so they are projected in memory and rebuilt on each start.
/// * The Lamport counter, whose maximum is only found inside item payloads.
///   Items are the bulk of history, so decrypting all of them to learn one
///   number is done once per device and the result is stored, not repeated
///   on every start. Nothing is retained from the items themselves.
class _EverydayIndex {
  final Node node;
  final spaces = <String, _EverydaySpace>{};
  int cursor = 0;
  int version = 0;
  late int clock = node.store.setting(_clockKey) as int? ?? 0;
  late int _clockCursor = node.store.setting(_cursorKey) as int? ?? 0;
  late String _policy = node.store.setting(_policyKey) as String? ?? '';
  Future<void>? _running;
  int _settled = -1;
  _EverydayIndex(this.node);

  static const _clockKey = 'everyday/clock';
  static const _cursorKey = 'everyday/clockCursor';
  static const _policyKey = 'everyday/clockPolicy';

  /// Brings the projection up to the end of the store.
  ///
  /// Every read goes through here, several times per rebuilt view, so the
  /// common case — nothing stored since the last pass — must cost nothing and
  /// must not even be asynchronous: queueing work on each read leaves a view
  /// rescheduling itself for as long as reads keep arriving.
  ///
  /// When there is something new, one pass runs and other callers join it,
  /// as the notes and drive projections do. Queueing a pass per caller
  /// instead would let a rebuilding view enqueue them faster than they drain,
  /// and a write would then wait behind every one of them.
  ///
  /// Joining means a caller can observe a pass that began just before their
  /// own write. That is what a Lamport counter tolerates — a repeated value
  /// breaks the tie by object ID, and every write notifies, which refreshes
  /// again — and it is the only thing that keeps reads cheap.
  Future<void> refresh() {
    // Blocking someone stores nothing, so the cursor alone would not notice
    // it; the projection still has to be rebuilt without it.
    if (_blocked() == _policy && node.store.insertionCursor == _settled) {
      return Future.value();
    }
    return _running ??= _run().whenComplete(() => _running = null);
  }

  String _blocked() => '${node.blocked.toList()..sort()}';

  /// Rechecks the gate: by the time a pass starts, the one it joined behind
  /// may already have read everything there was.
  Future<void> _run() async {
    final target = node.store.insertionCursor;
    if (_blocked() == _policy && target == _settled) return;
    await _refresh();
    _settled = target;
  }

  Future<void> _refresh() async {
    // Expiry only ever takes visibility away, so it is applied when records
    // are read. Blocking gives it back, and no cursor walks backwards, so a
    // change of who is blocked reprojects instead. The policy is stored with
    // the counter's cursor, so a change made while this device was closed
    // reprojects too. The counter itself is never lowered by one: a Lamport
    // clock only rises.
    final policy = _blocked();
    if (policy != _policy) {
      _policy = policy;
      cursor = 0;
      spaces.clear();
      _clockCursor = 0;
      version++;
    }
    // Where the store had reached when this pass started. Looking for a kind
    // walks the rows in between whether or not any of them are of that kind,
    // so a cursor that stops at the last record it wanted rewalks everything
    // written after it on the next pass. A profile of notes holds no group
    // items at all, which is the worst case: every pass would scan all of it.
    final target = node.store.insertionCursor;
    final slice = TimeSlice();
    // Records written to a group before this person joined open with its
    // key, which an invite or another record brings.
    await node.groups.learn();
    while (true) {
      final page = node.store.insertedAfter(cursor, Everyday.membershipKinds);
      if (page.isEmpty) break;
      for (final (sequence, object) in page) {
        cursor = sequence;
        await slice.pause();
        if (object.isPublic) continue;
        final data = await node.content(object);
        if (data == null) continue;
        (spaces[object.space] ??= _EverydaySpace()).records.add(
          EverydayItem(object, data),
        );
        version++;
      }
    }
    if (cursor < target) cursor = target;
    await _advanceClock(slice, target);
  }

  /// Reads item payloads that have arrived since this device last looked, for
  /// their counter alone. The cursor is stored, so the walk is not repeated
  /// on the next start; a profile written before this existed pays for one
  /// pass, where every call used to pay for one.
  Future<void> _advanceClock(TimeSlice slice, int target) async {
    while (true) {
      final page = node.store.insertedAfter(_clockCursor, Everyday.itemKinds);
      if (page.isEmpty) break;
      for (final (sequence, object) in page) {
        _clockCursor = sequence;
        await slice.pause();
        if (object.isPublic) continue;
        final counter = (await node.content(object))?['clock'];
        if (counter is int && counter > clock) clock = counter;
      }
    }
    if (_clockCursor < target) _clockCursor = target;
    // Unchanged settings do not write rows, so this costs nothing when a
    // refresh found nothing new.
    node.store
      ..set(_clockKey, clock)
      ..set(_cursorKey, _clockCursor)
      ..set(_policyKey, _policy);
  }
}

class _EverydaySpace {
  final records = <EverydayItem>[];
}

/// A window onto one group's chat that grows from the newest message back,
/// and takes in new arrivals from an insertion cursor.
///
/// [Everyday.items] reads and decrypts a whole space, which is the right
/// answer for a pass that must see everything (re-sharing history) but not
/// for showing a chat: opening it would cost the length of the conversation.
/// This reads pages of the newest objects until it has enough entries, keeps
/// only the latest version of each, and later pages back on request. The cost
/// of opening, and of every refresh, follows what is shown or new.
class RoomFeed {
  final Node node;
  final String space;
  EverydayItem _room;
  final _entries = <String, EverydayItem>{};
  (int, String)? _after;
  bool _exhausted = false;
  int _cursor;
  int _floor = 0;
  String _blocked;
  List<EverydayItem>? _sorted;
  Future<void>? _loading;
  final _deferred = <String, EverydayItem>{};

  RoomFeed(this.node, EverydayItem room)
    : space = room.object.space,
      _room = room,
      _cursor = node.store.insertionCursor,
      _blocked = '${node.blocked.toList()..sort()}';

  /// The room record this window was last checked against.
  EverydayItem get room => _room;

  /// Whether older messages remain beyond what has been read.
  bool get hasOlder => !_exhausted;

  /// Latest version of each loaded entry, newest first. Deleted entries are
  /// included so callers can show that they were removed.
  List<EverydayItem> get items => _sorted ??= () {
    final list = _entries.values.toList();
    list.sort((a, b) {
      final order = Everyday.sentOf(b).compareTo(Everyday.sentOf(a));
      if (order != 0) return order;
      final clock = (b.data['clock'] as int).compareTo(a.data['clock'] as int);
      return clock != 0 ? clock : b.object.id.compareTo(a.object.id);
    });
    return list;
  }();

  /// The loaded entry with this entry ID, if any.
  EverydayItem? entry(String id) => _entries[id];

  /// Reads back until about [want] more entries are loaded or history ends.
  /// Returns how many were added. Concurrent calls queue behind each other.
  Future<int> loadOlder({int want = 40}) async {
    while (_loading != null) {
      await _loading;
    }
    final done = Completer<void>();
    _loading = done.future;
    try {
      return await _loadOlder(want);
    } finally {
      _loading = null;
      done.complete();
    }
  }

  Future<int> _loadOlder(int want) async {
    if (_exhausted) return 0;
    final everyday = Everyday(node);
    _room = await everyday.current(_room);
    var added = 0;
    final slice = TimeSlice();
    while (added < want && !_exhausted) {
      final page = node.store.objects(
        kind: 'room_item',
        space: space,
        after: _after,
        limit: 64,
      );
      if (page.isEmpty) {
        _exhausted = true;
        break;
      }
      _after = (page.last.created, page.last.id);
      for (final o in page) {
        await slice.pause();
        if (await _take(everyday, o) == _Merge.added) added++;
      }
    }
    if (_entries.isNotEmpty) {
      _floor = _entries.values.map(Everyday.sentOf).reduce(math.min);
    }
    return added;
  }

  /// Takes in what arrived since the last call. True when anything shown may
  /// have changed, including a membership change that restarts the window.
  Future<bool> refresh() async {
    final target = node.store.insertionCursor;
    final blocked = '${node.blocked.toList()..sort()}';
    final everyday = Everyday(node);
    final next = await everyday.current(_room);
    if (everyday.epoch(next) != everyday.epoch(_room) ||
        next.data['generation'] != _room.data['generation'] ||
        blocked != _blocked) {
      _room = next;
      _blocked = blocked;
      _entries.clear();
      _deferred.clear();
      _after = null;
      _exhausted = false;
      _sorted = null;
      _cursor = target;
      await loadOlder();
      return true;
    }
    _room = next;
    if (target == _cursor) return false;
    var changed = false;
    var cursor = _cursor;
    final slice = TimeSlice();
    while (true) {
      final page = node.store.insertedAfter(cursor, ['room_item']);
      if (page.isEmpty) break;
      for (final (sequence, o) in page) {
        cursor = sequence;
        if (o.space != space) continue;
        await slice.pause();
        if (await _take(everyday, o, fresh: true) != _Merge.none) {
          changed = true;
        }
      }
    }
    _cursor = math.max(cursor, target);
    return changed;
  }

  Future<_Merge> _take(
    Everyday everyday,
    SignedObject o, {
    bool fresh = false,
  }) async {
    if (o.isPublic || !node.visible(o)) return _Merge.none;
    final p = await node.content(o);
    if (p == null) return _Merge.none;
    var item = EverydayItem(o, p);
    if (!everyday._belongs(_room, item)) return _Merge.none;
    final id = p['entry'];
    if (id is! String) return _Merge.none;
    final old = _entries[id];
    // An edit to something older than the window would leave a gap of
    // unloaded messages if shown now. It is held until paging reaches the
    // entry, because that walk goes by when objects were written and the edit
    // sits ahead of it.
    if (fresh && old == null && !_exhausted && Everyday.sentOf(item) < _floor) {
      final held = _deferred[id];
      if (held == null || _newer(item, held)) _deferred[id] = item;
      return _Merge.none;
    }
    if (!fresh) {
      final held = _deferred[id];
      if (held != null && _newer(held, item)) item = held;
    }
    if (old != null && !_newer(item, old)) return _Merge.none;
    _deferred.remove(id);
    _entries[id] = item;
    _sorted = null;
    return old == null ? _Merge.added : _Merge.replaced;
  }

  /// Which version of an entry wins: the higher clock, then the higher ID.
  static bool _newer(EverydayItem a, EverydayItem b) {
    final order = (a.data['clock'] as int).compareTo(b.data['clock'] as int);
    return order > 0 || (order == 0 && a.object.id.compareTo(b.object.id) > 0);
  }
}

enum _Merge { none, replaced, added }
