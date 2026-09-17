import 'model.dart';
import 'node.dart';

class EverydayItem {
  final SignedObject object;
  final Json data;
  EverydayItem(this.object, this.data);
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

  Future<List<EverydayItem>> records({String? space}) async {
    final result = <EverydayItem>[];
    final slice = TimeSlice();
    for (final o in node.store.objects(
      kinds: ['room', 'room_leave', 'inbox', 'room_item'],
      limit: Node.maxObjects,
      space: space,
    )) {
      if (!['room', 'room_leave', 'inbox', 'room_item'].contains(o.kind) ||
          o.isPublic)
        continue;
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
    if (room.startsWith('room2:') &&
        !room.startsWith('room2:${o.author}:'))
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

  Future<List<EverydayItem>> rooms({
    bool includeLeft = false,
    List<EverydayItem>? records,
  }) async {
    records ??= await this.records();
    final latest = <String, EverydayItem>{};
    for (final room in records.where(_roomValid)) {
      final old = latest[room.object.space];
      if (old == null || _supersedes(room, old) > 0)
        latest[room.object.space] = room;
    }
    return latest.values
        .where(
          (room) =>
              includeLeft ||
              (room.data['archived'] != true &&
                  effectiveMembers(room, records!).contains(node.person)),
        )
        .toList();
  }

  List<String> effectiveMembers(EverydayItem room, List<EverydayItem> records) {
    final members = (room.data['members'] as List).cast<String>().toSet();
    for (final leave in records.where(
      (r) =>
          r.object.kind == 'room_leave' &&
          r.object.space == room.object.space &&
          r.data['epoch'] == epoch(room),
    )) {
      members.remove(leave.object.author);
    }
    return members.toList()..sort();
  }

  Future<List<String>> members(EverydayItem room) async =>
      effectiveMembers(room, await records(space: room.object.space));

  Future<EverydayItem> current(
    EverydayItem room, [
    List<EverydayItem>? records,
  ]) async {
    records ??= await this.records(space: room.object.space);
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
        await node.addContact(cert);
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

  Future<EverydayItem> createRoom(
    String name,
    List<String> people, {
    String? noteId,
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
    };
    return EverydayItem(
      await node.publish('room', data, space: data['room'], audience: members),
      data,
    );
  }

  Future<EverydayItem> changeMembers(
    EverydayItem room,
    List<String> people, {
    required bool shareHistory,
    Future<void> Function(Json, List<String>)? beforePublish,
  }) async {
    room = await current(room);
    if (room.data['owner'] != node.person)
      throw StateError('Only the group owner can change membership.');
    final nextMembers = {node.person, ...people}.toList()..sort();
    if (nextMembers.length > 64)
      throw StateError('A group supports up to 64 members.');
    final history = await items(room);
    if (node.store.count + history.length + 2 > Node.maxObjects)
      throw StateError(
        'Not enough local capacity to update membership and retain history.',
      );
    // Legacy rooms migrate to a self-certifying namespace on their first edit.
    final id = room.data['generation'] == null
        ? 'room2:${node.person}:${randomId()}'
        : room.object.space;
    final data = <String, dynamic>{
      ...room.data,
      'room': id,
      'generation': (room.data['generation'] as int? ?? 0) + 1,
      'members': nextMembers,
      'epoch': randomId(),
      'certificates': _certificates(nextMembers),
    };
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
      );
    }
    await beforePublish?.call(data, nextMembers);
    final next = EverydayItem(
      await node.publish('room', data, space: id, audience: audience),
      data,
    );
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
        audience: room.object.audience,
      );
      return;
    }
    await node.publish(
      'room_leave',
      {'epoch': epoch(room)},
      space: room.object.space,
      audience: room.object.audience,
    );
  }

  Future<List<EverydayItem>> items([EverydayItem? room]) async {
    // One pass over local history serves both membership and item selection.
    final records = await this.records();
    if (room != null) room = await current(room, records);
    final selected = room;
    final result = records
        .where(
          (r) => room == null
              ? r.object.kind == 'inbox' &&
                    r.object.author == node.person &&
                    r.object.audience.length == 1 &&
                    r.object.audience.single == node.person
              : r.object.kind == 'room_item' &&
                    r.object.space == selected!.data['room'] &&
                    (selected.data['members'] as List).contains(
                      r.object.author,
                    ) &&
                    (selected.data['generation'] == null
                        ? r.object.audience.toSet().containsAll(
                                selected.object.audience,
                              ) &&
                              r.object.audience.length ==
                                  selected.object.audience.length
                        : r.data['epoch'] == epoch(selected) &&
                              r.object.audience.every(
                                (p) => (selected.data['members'] as List)
                                    .contains(p),
                              ) &&
                              (r.data['history'] != true ||
                                  r.object.author == selected.data['owner'])),
        )
        .toList();
    result.sort((a, b) {
      final order = (b.data['clock'] as int).compareTo(a.data['clock'] as int);
      return order == 0 ? b.object.id.compareTo(a.object.id) : order;
    });
    final seen = <String>{};
    return result.where((r) => seen.add(r.data['entry'])).toList();
  }

  Future<Json> data(Json content) async {
    var clock = 0;
    for (final r in await records()) {
      final n = r.data['clock'];
      if (n is int && n > clock) clock = n;
    }
    return {
      ...content,
      'entry': content['entry'] ?? randomId(),
      'clock': clock + 1,
    };
  }

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
