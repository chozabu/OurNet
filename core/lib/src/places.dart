import 'dart:async';
import 'everyday.dart';
import 'model.dart';
import 'node.dart';

/// A deliberately shared point. Notes and list membership are never in links.
typedef PlaceLink = ({double lat, double lng, String name, String emoji});

/// A versioned saved map item. IDs are namespaced by their creator, so a
/// peer cannot claim another person's pin by publishing a higher clock.
class SavedMapEntry {
  final SignedObject object;
  final Json data;
  SavedMapEntry(this.object, this.data);
  String get id => data['id'] as String;
  String get space => object.space;
  String get kind => object.kind;
  String get owner => id.split(':').first;
  String get name => data['name'] as String? ?? '';
  String get emoji => data['emoji'] as String? ?? '⭐';
  String get note => data['note'] as String? ?? '';
  int get clock => data['clock'] as int;
  bool get deleted => data['deleted'] == true;
  double get lat => (data['lat'] as int) / 1e7;
  double get lng => (data['lng'] as int) / 1e7;
  String get key => '$space|$id';
}

/// Saved places are encrypted objects, separate from ephemeral live fixes.
/// A place is shared only within its scope. Memberships in lists are small
/// independent registers; private notes never leave the personal space.
class Places {
  final Node node;
  Places(this.node);
  static const personal = '_places';
  static const saved = 'saved';
  static const kinds = {'map_place', 'map_list', 'map_link', 'map_note'};
  static String link(PlaceLink place) => Uri(
    scheme: 'ournet',
    host: 'place',
    pathSegments: ['${place.lat}', '${place.lng}'],
    queryParameters: {'name': place.name, 'emoji': place.emoji},
  ).toString();
  static final linkPattern = RegExp(
    r'ournet://place/[^\s<>"\x27]+[^\s<>"\x27.,;:!?)\]}]',
  );
  static PlaceLink? parseLink(String text) {
    try {
      final uri = Uri.tryParse(text);
      if (uri == null ||
          uri.scheme != 'ournet' ||
          uri.host != 'place' ||
          uri.pathSegments.length != 2)
        return null;
      final lat = double.tryParse(uri.pathSegments[0]),
          lng = double.tryParse(uri.pathSegments[1]);
      final name = uri.queryParameters['name'] ?? 'Shared place';
      final emoji = uri.queryParameters['emoji'] ?? '⭐';
      if (lat == null ||
          lng == null ||
          !lat.isFinite ||
          !lng.isFinite ||
          lat.abs() > 90 ||
          lng.abs() > 180 ||
          name.length > 200 ||
          emoji.length > 32)
        return null;
      return (lat: lat, lng: lng, name: name, emoji: emoji);
    } on FormatException {
      return null;
    }
  }

  static final _indexes = Expando<_PlaceIndex>();
  _PlaceIndex get _index => _indexes[node] ??= _PlaceIndex(node);
  bool get loaded => _index.loaded;
  Future<bool> refresh() => _index.refresh();
  List<EverydayItem> get groups =>
      _index.rooms.values.where((r) => r.data['note'] != true).toList();
  String scopeName(String space) => space == personal
      ? 'Private'
      : _index.rooms[space]?.data['name'] as String? ?? 'Group';
  List<SavedMapEntry> get lists => _index.lists;
  List<SavedMapEntry> get all => _index.places;
  SavedMapEntry? place(String space, String id) =>
      _index.latest['map_place|$space|$id'];
  bool canEdit(SavedMapEntry entry) =>
      entry.owner == node.person ||
      _index.rooms[entry.space]?.data['owner'] == node.person;
  List<String> listsOf(SavedMapEntry entry) => [
    for (final link in _index.links[entry.key] ?? const <SavedMapEntry>[])
      link.data['list'] as String,
  ];
  List<SavedMapEntry> inList(String space, String list) =>
      _index.byList['$space|$list'] ?? const [];
  String privateNote(SavedMapEntry entry) =>
      _index.latest['map_note|$personal|${entry.key}']?.note ?? '';

  Future<List<String>> _audience(String space) async {
    if (space == personal) return [node.person];
    final everyday = Everyday(node);
    final room = (await everyday.rooms())
        .where((r) => r.object.space == space && r.data['note'] != true)
        .firstOrNull;
    if (room == null)
      throw StateError('You are no longer a member of this group.');
    await everyday.prepare(room);
    return everyday.members(room);
  }

  Future<SavedMapEntry> _write(String kind, String space, Json data) async {
    final audience = await _audience(space);
    // Refresh before choosing a clock, including after offline edits arrive.
    await refresh();
    final payload = {...data, 'clock': ++_index.clock}..remove('history');
    final o = await node.publish(
      kind,
      payload,
      space: space,
      audience: audience,
    );
    await refresh();
    return SavedMapEntry(o, payload);
  }

  Future<SavedMapEntry> createList(String name, {String space = personal}) =>
      _write('map_list', space, {
        'id': '${node.person}:${randomId()}',
        'name': name.trim(),
      });

  Future<SavedMapEntry> save({
    required double lat,
    required double lng,
    required String name,
    String emoji = '⭐',
    String note = '',
    String space = personal,
    String list = saved,
    String? id,
  }) async {
    await refresh();
    _requireList(space, list);
    if (id != null && !id.startsWith('${node.person}:')) {
      throw ArgumentError('A new pin must use its creator’s ID.');
    }
    final entry = await _write('map_place', space, {
      'id': id ?? '${node.person}:${randomId()}',
      'name': name.trim(),
      'lat': (lat * 1e7).round(),
      'lng': (lng * 1e7).round(),
      'emoji': emoji.trim().isEmpty ? '⭐' : emoji.trim(),
      'note': note.trim(),
    });
    await setInList(entry, list, true);
    return entry;
  }

  void _requireList(String space, String list) {
    if (space == personal && list == saved) return;
    final entry = _index.latest['map_list|$space|$list'];
    if (entry == null || entry.deleted)
      throw StateError('This list is no longer available.');
  }

  Future<SavedMapEntry> edit(
    SavedMapEntry entry, {
    required String name,
    required String emoji,
    required String note,
  }) async {
    await refresh();
    if (_index.latest['${entry.kind}|${entry.space}|${entry.id}']?.deleted ==
        true) {
      throw StateError('This item has been deleted. Save a copy to keep it.');
    }
    if (!canEdit(entry))
      throw StateError(
        'Only the contributor or group owner can edit this place.',
      );
    return _write(entry.kind, entry.space, {
      ...entry.data,
      'name': name.trim(),
      'emoji': emoji.trim().isEmpty ? '⭐' : emoji.trim(),
      'note': note.trim(),
    });
  }

  Future<void> remove(SavedMapEntry entry) async {
    await refresh();
    if (!canEdit(entry))
      throw StateError(
        'Only the contributor or group owner can delete this item.',
      );
    await _write(entry.kind, entry.space, {...entry.data, 'deleted': true});
  }

  Future<void> setInList(
    SavedMapEntry entry,
    String list,
    bool included,
  ) async {
    await refresh();
    _requireList(entry.space, list);
    await _write('map_link', entry.space, {
      'id': '${entry.id}|$list',
      'place': entry.id,
      'list': list,
      'deleted': !included,
    });
  }

  Future<void> setPrivateNote(SavedMapEntry entry, String note) async {
    await _write('map_note', personal, {'id': entry.key, 'note': note.trim()});
  }

  /// Group history uses the existing owner-controlled history sharing flow.
  /// Include tombstones: omitting a deletion could resurrect an old pin.
  static Future<int> reshare(
    Node node,
    EverydayItem room, {
    String? into,
    GroupKey? seal,
    required List<String> Function(SavedMapEntry) audience,
  }) async {
    final places = Places(node);
    await places.refresh();
    var count = 0;
    for (final e in places._index.latest.values.toList()) {
      if (e.space != room.object.space || e.kind == 'map_note') continue;
      final readers = audience(e);
      if (readers.isEmpty) continue;
      await node.publish(
        e.kind,
        {...e.data, 'history': true},
        space: into ?? e.space,
        audience: readers,
        seal: seal,
      );
      count++;
    }
    return count;
  }
}

class _PlaceIndex {
  final Node node;
  _PlaceIndex(this.node);
  final latest = <String, SavedMapEntry>{};
  Map<String, EverydayItem> rooms = {};
  final _unreadable = <String, SignedObject>{};
  int _cursor = 0, clock = 0;
  String _access = '';
  bool loaded = false;
  Future<bool>? _running;
  List<SavedMapEntry> lists = [], places = [];
  Map<String, List<SavedMapEntry>> links = {}, byList = {};

  Future<bool> refresh() =>
      _running ??= _refresh().whenComplete(() => _running = null);

  Future<bool> _refresh() async {
    final target = node.store.insertionCursor;
    final nextRooms = (await Everyday(
      node,
    ).rooms()).where((r) => r.data['note'] != true).toList();
    final signature =
        '${nextRooms.map((r) => '${r.object.id}:${r.data['members']}').toList()..sort()}|'
        '${node.blocked.toList()..sort()}|${node.revoked.toList()..sort()}';
    var changed = false;
    if (signature != _access) {
      _access = signature;
      rooms = {for (final r in nextRooms) r.object.space: r};
      // Access changes are exceptional. Reproject saved-map kinds only,
      // restoring an earlier valid version when a contributor is removed.
      _cursor = 0;
      latest.clear();
      _unreadable.clear();
      changed = true;
    }
    final slice = TimeSlice();
    var keys = false;
    while (true) {
      final page = node.store.insertedAfter(_cursor, [...Places.kinds, 'keys']);
      if (page.isEmpty) break;
      for (final (cursor, object) in page) {
        _cursor = cursor;
        await slice.pause();
        if (object.kind == 'keys') {
          keys = true;
          continue;
        }
        if (await _take(object)) changed = true;
      }
    }
    if (keys) {
      for (final o in _unreadable.values.toList()) {
        await slice.pause();
        if (await _take(o)) changed = true;
      }
    }
    if (_cursor < target) _cursor = target;
    loaded = true;
    if (changed) _build();
    return changed;
  }

  Future<bool> _take(SignedObject o) async {
    if (o.isPublic ||
        node.blocked.contains(o.author) ||
        node.revoked.contains(o.certificate.device))
      return false;
    if (o.space == Places.personal) {
      if (o.author != node.person ||
          o.audience.length != 1 ||
          o.audience.single != node.person)
        return false;
    } else {
      final room = rooms[o.space];
      if (room == null || o.kind == 'map_note') return false;
      final members = (room.data['members'] as List).cast<String>();
      if (!members.contains(o.author)) return false;
    }
    final p = await node.content(o);
    if (p == null) {
      _unreadable[o.id] = o;
      return false;
    }
    _unreadable.remove(o.id);
    final entry = SavedMapEntry(o, p);
    final owner = rooms[o.space]?.data['owner'];
    if (p['history'] == true && o.author != owner) return false;
    if (o.kind == 'map_place' || o.kind == 'map_list') {
      if (!entry.id.contains(':') ||
          (entry.owner != o.author && o.author != owner))
        return false;
    }
    final key = '${o.kind}|${o.space}|${entry.id}';
    final old = latest[key];
    if (entry.clock > clock) clock = entry.clock;
    if (old != null &&
        (old.clock > entry.clock ||
            old.clock == entry.clock && old.object.id.compareTo(o.id) >= 0))
      return false;
    latest[key] = entry;
    return true;
  }

  void _build() {
    lists = [];
    places = [];
    links = {};
    byList = {};
    for (final e in latest.values) {
      if (e.deleted) continue;
      if (e.kind == 'map_list') lists.add(e);
      if (e.kind == 'map_place') places.add(e);
      if (e.kind == 'map_link') {
        (links['${e.space}|${e.data['place']}'] ??= []).add(e);
      }
    }
    for (final p in places) {
      for (final link in links[p.key] ?? const <SavedMapEntry>[]) {
        (byList['${p.space}|${link.data['list']}'] ??= []).add(p);
      }
    }
    int compare(SavedMapEntry a, SavedMapEntry b) =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase());
    lists.sort(compare);
    places.sort(compare);
    for (final list in byList.values) {
      list.sort(compare);
    }
  }
}
