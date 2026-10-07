import 'everyday.dart';
import 'model.dart';
import 'node.dart';

/// Group keys this device holds, and who each group's current key opens to.
///
/// A private object is encrypted to the devices its author knew of, so on its
/// own it never reaches anyone who joined later. A group's room record holds
/// a key, and what is written to the whole group is also sealed with it (see
/// [encryptFor]). Someone added to the group is handed the key, so they can
/// open what came before, and members pass those objects on to them as they
/// pass on anything else: a member offers a group's objects to the people the
/// group's membership names, not only to the ones each object was addressed
/// to. Authors, signatures and times stay as they were.
///
/// Keys are learned from the room records and invites this device can open.
/// Learning one from an invite that later proves to be from nobody in the
/// group gains nothing: it opens only what was sealed with it.
class GroupAccess {
  final Node node;
  GroupAccess(this.node);

  final _keys = <String, GroupKey>{};

  /// For each key, the people whose devices may be sent what it seals: the
  /// audiences of the records it came in, and the group's readers.
  final _keyPeople = <String, Set<String>>{};

  /// Each group's current key and who it is for, by room space.
  final _current = <String, ({GroupKey key, Set<String> readers})>{};

  /// Room records and invites not yet opened: a key from one may open
  /// another, and the record that holds a key can arrive after what it opens.
  final _pending = <SignedObject>[];
  int _cursor = 0;
  String _policy = '';
  int _settled = -1;
  int _version = -1;
  Future<void>? _learning, _refreshing;

  static const _kinds = ['room', 'room_invite'];

  /// The room a space belongs to: a group note lives in `<room>#<key>`.
  static String roomOf(String space) {
    final at = space.indexOf('#');
    return at > 0 ? space.substring(0, at) : space;
  }

  GroupKey? key(String id) => _keys[id];

  /// Whether this device holds the group key [o] is sealed with.
  bool opens(SignedObject o) {
    if (o.isPublic || _keys.isEmpty) return false;
    final payload = o.data['payload'];
    if (payload is! Json) return false;
    final id = groupSealOf(payload);
    return id != null && _keys.containsKey(id);
  }

  /// The current key of the group [space] belongs to.
  GroupKey? current(String space) => _current[roomOf(space)]?.key;

  /// Whether [person] is one of the readers of the group [space] belongs to.
  bool reaches(String space, String person) =>
      _current[roomOf(space)]?.readers.contains(person) ?? false;

  /// The key ids a peer of [person]'s may be offered objects under: the
  /// groups this device knows them to be in. An inventory carries them, so
  /// objects are only offered to a device that can open them, and the groups
  /// someone is in are never told to anyone outside them.
  List<String> keysFor(String person) => [
    for (final MapEntry(:key, :value) in _keyPeople.entries)
      if (value.contains(person)) key,
  ]..sort();

  /// The current key of the group [space] belongs to, when [recipients]
  /// covers all of its readers: what is written to the whole group opens with
  /// the group's key, and nothing narrower does.
  GroupKey? sealFor(String space, Set<String> recipients) {
    final current = _current[roomOf(space)];
    if (current == null || !recipients.containsAll(current.readers)) {
      return null;
    }
    return current.key;
  }

  /// Takes in the keys of room records and invites stored since the last
  /// look. Cheap when nothing new has arrived.
  Future<void> learn() =>
      _learning ??= _learn().whenComplete(() => _learning = null);

  Future<void> _learn() async {
    final policy = '${node.blocked.toList()..sort()}';
    if (policy != _policy) {
      // Unblocking someone makes their records readable again.
      _policy = policy;
      _cursor = 0;
      _pending.clear();
    }
    // Where the store had reached: looking for a kind walks every row in
    // between, so stopping at the last record wanted would walk everything
    // written after it again on the next pass.
    final target = node.store.insertionCursor;
    while (true) {
      final page = node.store.insertedAfter(_cursor, _kinds);
      if (page.isEmpty) break;
      for (final (sequence, object) in page) {
        _cursor = sequence;
        if (!object.isPublic) _pending.add(object);
      }
    }
    if (_cursor < target) _cursor = target;
    if (_pending.isEmpty) return;
    for (var changed = true; changed;) {
      changed = false;
      for (final object in [..._pending]) {
        final payload = object.data['payload'];
        if (payload is! Json) {
          _pending.remove(object);
          continue;
        }
        if (!wrappedFor(payload, node.identity.device) &&
            !opens(object) &&
            !await node.holdsKeyFor(object)) {
          continue;
        }
        _pending.remove(object);
        final data = await node.content(object);
        final wire = data?['groupKey'];
        if (wire is! Json || !validGroupKey(wire)) continue;
        final key = groupKeyFrom(wire);
        (_keyPeople[key.id] ??= {}).addAll(object.audience);
        if (_keys.containsKey(key.id)) continue;
        _keys[key.id] = key;
        changed = true;
      }
    }
  }

  /// Brings keys and each group's readers up to date with what is stored.
  /// Sync calls this before offering or taking objects.
  Future<void> refresh() {
    if (node.store.insertionCursor == _settled &&
        '${node.blocked.toList()..sort()}' == _policy) {
      return Future.value();
    }
    return _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  }

  Future<void> _refresh() async {
    final target = node.store.insertionCursor;
    await learn();
    final everyday = Everyday(node);
    // Most of what arrives is not about membership: readers stay as they are.
    // Expiry, which can end a membership record, waits for the next change.
    final version = await everyday.membershipVersion();
    if (version == _version) {
      _settled = target;
      return;
    }
    final next = <String, ({GroupKey key, Set<String> readers})>{};
    for (final room in await everyday.rooms()) {
      final wire = room.data['groupKey'];
      if (room.data['note'] == true || wire is! Json || !validGroupKey(wire)) {
        continue;
      }
      final key = groupKeyFrom(wire);
      _keys[key.id] ??= key;
      final readers = (await everyday.members(room)).toSet();
      (_keyPeople[key.id] ??= {}).addAll(readers);
      next[room.object.space] = (key: key, readers: readers);
    }
    _current
      ..clear()
      ..addAll(next);
    _settled = target;
    _version = version;
  }
}
