import 'dart:async';
import 'dart:collection';
import 'everyday.dart';
import 'model.dart';
import 'node.dart';

class NoteDocument {
  final EverydayItem room;
  final List<String> members;
  final Map<String, List<EverydayItem>> heads;
  final List<EverydayItem> history;
  final List<EverydayItem> earlier;
  final bool available;
  NoteDocument(
    this.room,
    this.members,
    this.heads,
    this.history,
    this.earlier, {
    this.available = true,
  });
  String get id => room.object.space;
  String get epoch => room.data['epoch'];
  bool get deleted => value('deleted') == true;
  String get title =>
      (value('title') as String?) ??
      earlier
              .where((r) => r.data['field'] == 'title')
              .firstOrNull
              ?.data['value']
          as String? ??
      'Note';
  String get text => (value('text') as String?) ?? '';
  Object? value(String field) {
    final versions = heads[field] ?? [];
    // Removal wins concurrent restore; an explicit restore observes removals.
    if (field == 'deleted' || field.endsWith(':deleted')) {
      if (versions.any((r) => r.data['value'] == true)) return true;
    }
    return versions.firstOrNull?.data['value'];
  }

  List<String> parents(String field) =>
      (heads[field] ?? []).map((r) => r.object.id).toList();
  List<String> get checks =>
      (heads.keys
          .where((k) => k.startsWith('check:') && k.endsWith(':text'))
          .map((k) => k.split(':')[1])
          .where((id) => value('check:$id:deleted') != true)
          .toList()
        ..sort());
  bool get hasConflicts => heads.entries.any(
    (e) =>
        (e.key == 'text' || e.key == 'title' || e.key.endsWith(':text')) &&
        e.value.map((r) => r.data['value']).toSet().length > 1,
  );
}

/// One encrypted room per note, including personal notes. Membership epochs
/// reuse Everyday; note registers retain concurrent branches instead of LWW
/// discarding writing. No protocol or crypto is implemented in the UI/native host.
class Notes {
  final Node node;
  Notes(this.node);
  final _rooms = <String, EverydayItem>{};
  final _cache = LinkedHashMap<String, NoteDocument>();
  final _summaries = <String, EverydayItem>{};
  int _cursor = 0;
  Future<void>? _refreshing;
  Future<void> _tail = Future.value();
  int _queued = 0;
  String _policy = '';
  static const maxNotes = 200, maxChecks = 200;

  /// Serialize local mutation, including widget requests, and bound callers.
  Future<T> _serial<T>(Future<T> Function() action) {
    if (_queued >= 128)
      return Future.error(
        StateError('Too many pending note changes. Try again shortly.'),
      );
    _queued++;
    final result = _tail.then((_) => action());
    _tail = result.then<void>(
      (_) {
        _queued--;
      },
      onError: (Object _, StackTrace __) {
        _queued--;
      },
    );
    return result;
  }

  Future<void> refresh() =>
      _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  Future<void> _refresh() async {
    final policy =
        '${node.blocked.toList()..sort()}/${node.revoked.toList()..sort()}';
    if (policy != _policy) {
      _cache.clear();
      _summaries.clear();
      _policy = policy;
    }
    final slice = TimeSlice();
    while (true) {
      final page = node.store.insertedAfter(_cursor, [
        'room',
        'room_leave',
        'note_op',
      ]);
      if (page.isEmpty) break;
      for (final (cursor, object) in page) {
        _cache.remove(object.space);
        _summaries.remove(object.space);
        if (object.kind == 'room') {
          final data = await node.content(object);
          if (data != null && data['note'] == true) {
            final rooms = await Everyday(node).rooms(
              includeLeft: true,
              records: await Everyday(node).records(space: object.space),
            );
            if (rooms.isNotEmpty) _rooms[object.space] = rooms.single;
          }
        }
        _cursor = cursor;
        await slice.pause();
      }
    }
  }

  Future<List<NoteDocument>> list({bool includeDeleted = false}) async {
    await refresh();
    final result = <NoteDocument>[];
    for (final id in _rooms.keys.toList().reversed) {
      final note = await get(id);
      if (note != null && (includeDeleted || !note.deleted)) result.add(note);
      if (result.length >= maxNotes) break;
    }
    return result;
  }

  /// Small list projection: unchanged notes do not reread operation history.
  /// Text shown in a list is bounded; the editor loads the full document.
  Future<List<EverydayItem>> summaries({bool includeDeleted = false}) async {
    await refresh();
    final result = <EverydayItem>[];
    for (final id in _rooms.keys.toList().reversed) {
      var summary = _summaries[id];
      if (summary == null) {
        final note = await get(id, includeUnavailable: true);
        if (note == null) continue;
        final text = note.text.isEmpty && note.checks.isNotEmpty
            ? note.checks
                  .take(5)
                  .map(
                    (c) =>
                        '${note.value('check:$c:done') == true ? '☑' : '☐'} ${note.value('check:$c:text')}',
                  )
                  .join('\n')
            : note.text;
        summary = EverydayItem(note.room.object, {
          'entry': id,
          'type': 'shared_note',
          'title': note.title.substring(0, note.title.length.clamp(0, 100)),
          'text': text.substring(0, text.length.clamp(0, 512)),
          'checklist': note.checks.isNotEmpty,
          'epoch': note.epoch,
          'checks': [
            for (final id in note.checks.take(3))
              {
                'id': id,
                'text': (note.value('check:$id:text') as String).substring(
                  0,
                  (note.value('check:$id:text') as String).length.clamp(0, 160),
                ),
                'done': note.value('check:$id:done') == true,
                'parents': note.parents('check:$id:done'),
              },
          ],
          'deleted': note.deleted || !note.available,
          'available': note.available,
          'members': note.members.length,
          'conflicts': note.hasConflicts,
        });
        _summaries[id] = summary;
      }
      if (includeDeleted || summary.data['deleted'] != true)
        result.add(summary);
      if (result.length >= maxNotes) break;
    }
    return result;
  }

  Future<NoteDocument?> get(
    String id, {
    bool includeUnavailable = false,
  }) async {
    await refresh();
    final cached = _cache.remove(id);
    if (cached != null && cached.history.every((r) => node.visible(r.object))) {
      _cache[id] = cached;
      return cached.available || includeUnavailable ? cached : null;
    }
    final records = await Everyday(node).records(space: id);
    final rooms = await Everyday(
      node,
    ).rooms(includeLeft: true, records: records);
    final room = rooms.firstOrNull;
    if (room == null || room.data['note'] != true) return null;
    final members = Everyday(node).effectiveMembers(room, records);
    final available =
        members.contains(node.person) && room.data['archived'] != true;
    if (!available && !includeUnavailable) return null;
    final ops = <EverydayItem>[], earlier = <EverydayItem>[];
    final slice = TimeSlice();
    for (final object in node.store.objects(
      kind: 'note_op',
      space: id,
      limit: Node.maxObjects,
    )) {
      final data = await node.content(object);
      if (data == null || object.isPublic) continue;
      final epochRooms = records.where(
        (r) =>
            r.object.kind == 'room' &&
            r.data['epoch'] == data['epoch'] &&
            r.object.author == room.data['owner'] &&
            r.data['room'] == id &&
            r.data['owner'] == room.data['owner'],
      );
      final membership = epochRooms.firstOrNull;
      if (membership == null ||
          !(membership.data['members'] as List).contains(object.author) ||
          !object.audience.every(
            (p) => (membership.data['members'] as List).contains(p),
          ) ||
          (data['checkpoint'] == true && object.author != room.data['owner']))
        continue;
      final leaves = records.where(
        (r) =>
            r.object.kind == 'room_leave' &&
            r.data['epoch'] == data['epoch'] &&
            r.object.author == object.author,
      );
      final accepted = leaves.every(
        (r) => (r.data['noteAccepted'] as List? ?? []).contains(object.id),
      );
      final item = EverydayItem(object, data);
      if (data['epoch'] == room.data['epoch'] && accepted) {
        ops.add(item);
      } else {
        earlier.add(item);
      }
      await slice.pause();
    }
    final fields = <String, List<EverydayItem>>{};
    for (final op in ops) {
      (fields[op.data['field']] ??= []).add(op);
    }
    for (final entry in fields.entries) {
      final byId = {for (final op in entry.value) op.object.id: op};
      final consumed = <String>{};
      for (final op in entry.value) {
        for (final parent in op.data['parents'] as List) {
          final prior = byId[parent];
          if (prior != null && prior.data['clock'] < op.data['clock'])
            consumed.add(parent);
        }
      }
      entry.value.removeWhere((op) => consumed.contains(op.object.id));
      entry.value.sort((a, b) {
        final order = (b.data['clock'] as int).compareTo(
          a.data['clock'] as int,
        );
        return order == 0 ? b.object.id.compareTo(a.object.id) : order;
      });
    }
    final note = NoteDocument(
      room,
      members,
      fields,
      ops,
      earlier,
      available: available,
    );
    // Bound retained decrypted history by both count and value size.
    final size = [
      ...ops,
      ...earlier,
    ].fold<int>(0, (n, r) => n + r.data.toString().length * 2);
    if (size < 512 * 1024) _cache[id] = note;
    while (_cache.length > 16) {
      _cache.remove(_cache.keys.first);
    }
    return note;
  }

  Future<NoteDocument> create({
    String title = 'Note',
    String text = '',
    bool checklist = false,
    String? stableId,
  }) => _serial(() async {
    if (text.length > 16384 || title.length > 100)
      throw StateError(
        'Use a title up to 100 characters and text up to 16,384 characters.',
      );
    await refresh();
    if (_rooms.length >= maxNotes)
      throw StateError('Up to $maxNotes notes can be shown.');
    final key = stableId ?? randomId();
    final id = 'room2:${node.person}:$key';
    final existing = await get(id);
    if (existing != null) return existing;
    final room = await Everyday(node).createRoom(
      title.trim().isEmpty
          ? 'Note'
          : title.trim().substring(0, title.trim().length.clamp(0, 100)),
      [],
      noteId: key,
    );
    await _publish(room, 'title', title, [], 1);
    await _publish(room, 'text', text, [], 2);
    if (checklist)
      await _publish(room, 'check:${randomId()}:text', 'New item', [], 3);
    return (await get(id))!;
  });

  Future<void> _publish(
    EverydayItem room,
    String field,
    Object value,
    List<String> parents,
    int clock, {
    String? request,
    bool checkpoint = false,
    List<String>? audience,
  }) async {
    await node.publish(
      'note_op',
      {
        'epoch': room.data['epoch'],
        'field': field,
        'value': value,
        'parents': parents,
        'clock': clock,
        'checkpoint': checkpoint,
        if (request != null) 'request': request,
      },
      space: room.object.space,
      audience: audience ?? await Everyday(node).members(room),
    );
  }

  /// Pass the editor's observed parents, never the newly received heads: saving
  /// an old draft must produce a recoverable branch, not overwrite unseen text.
  Future<void> edit(
    String id,
    String epoch,
    String field,
    Object value,
    List<String> parents, {
    String? request,
  }) => _serial(() async {
    final note = await get(id, includeUnavailable: true);
    if (note == null)
      throw StateError(
        'This note is unavailable. Your draft is kept on this device.',
      );
    if (request != null &&
        [...note.history, ...note.earlier].any(
          (r) =>
              r.data['request'] == request &&
              r.object.author == node.person &&
              r.object.certificate.device == node.identity.device &&
              r.data['field'] == field &&
              r.data['value'] == value,
        ))
      return;
    if (!note.available)
      throw StateError(
        'This note is unavailable. Your draft is kept on this device.',
      );
    if (note.epoch != epoch)
      throw StateError(
        'Collaborators changed. Reopen the note before saving; your draft is kept.',
      );
    if (note.deleted && field != 'deleted')
      throw StateError(
        'This note was removed. Restore it before applying your draft.',
      );
    if (field.startsWith('check:') &&
        !field.endsWith(':deleted') &&
        note.value('check:${field.split(':')[1]}:deleted') == true) {
      throw StateError(
        'This checklist item was removed. Restore it in Recovery before editing.',
      );
    }
    if (field.startsWith('check:') &&
        !note.heads.containsKey(field) &&
        field.endsWith(':text') &&
        note.checks.length >= maxChecks)
      throw StateError('A checklist supports $maxChecks items.');
    await Everyday(node).prepare(note.room);
    var clock = 0;
    for (final r in note.history) {
      if (r.data['clock'] > clock) clock = r.data['clock'];
    }
    await _publish(
      note.room,
      field,
      value,
      parents,
      clock + 1,
      request: request,
    );
  });

  Future<void> changeMembers(
    String id,
    List<String> people,
  ) => _serial(() async {
    final note = await get(id);
    if (note == null) throw StateError('This note is unavailable.');
    if (note.room.data['owner'] != node.person)
      throw StateError('Only the owner can change collaborators.');
    final heads = note.heads.values.expand((v) => v).toList();
    if (node.store.count + heads.length + 2 > Node.maxObjects)
      throw StateError('Not enough local storage to update collaborators.');
    await Everyday(node).changeMembers(
      note.room,
      people,
      shareHistory: false,
      beforePublish: (data, members) async {
        final next = EverydayItem(note.room.object, data);
        // Stable namespace; publish all live competing branches before committing
        // the epoch. A failed preparation leaves harmless, unreachable objects.
        for (final head in heads) {
          await _publish(
            next,
            head.data['field'],
            head.data['value'],
            [],
            head.data['clock'],
            checkpoint: true,
            audience: members,
          );
        }
      },
    );
  });

  Future<void> leave(String id) => _serial(() async {
    final note = await get(id);
    if (note == null) return;
    if (note.room.data['owner'] == node.person)
      throw StateError(
        'The owner can remove the note or manage collaborators.',
      );
    await node.publish(
      'room_leave',
      {
        'epoch': note.epoch,
        'noteAccepted': note.history
            .where((r) => r.object.author == node.person)
            .map((r) => r.object.id)
            .toList(),
      },
      space: id,
      audience: note.members,
    );
  });

  void pin(String id, bool value) {
    node.store.set('notePin/$id', value);
    node.notify();
  }

  bool pinned(String id) => node.store.setting('notePin/$id') == true;
}
