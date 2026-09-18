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

  /// The record kinds group history is made of. Membership lives in the first
  /// two; the rest is what members wrote.
  static const membershipKinds = ['room', 'room_leave'];
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
        .where(
          (room) =>
              includeLeft ||
              (room.data['archived'] != true &&
                  effectiveMembers(room, records).contains(node.person)),
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
    // One pass over the space serves both membership and item selection. A
    // room's items live in its own space, and the inbox in `_inbox`, so this
    // is everything the selection below can match.
    final records = await this.records(space: room?.object.space ?? '_inbox');
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

  /// The counter is maintained as records are indexed, so a write no longer
  /// walks history to find out what to number itself.
  Future<Json> data(Json content) async => {
    ...content,
    'entry': content['entry'] ?? randomId(),
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
    }
    // Where the store had reached when this pass started. Looking for a kind
    // walks the rows in between whether or not any of them are of that kind,
    // so a cursor that stops at the last record it wanted rewalks everything
    // written after it on the next pass. A profile of notes holds no group
    // items at all, which is the worst case: every pass would scan all of it.
    final target = node.store.insertionCursor;
    final slice = TimeSlice();
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
