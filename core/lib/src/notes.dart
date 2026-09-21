import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';
import 'everyday.dart';
import 'note_state.dart';
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

  /// The written title, empty when none was given (lists fall back to 'Note').
  String get rawTitle => (value('title') as String?) ?? '';
  String get text => (value('text') as String?) ?? '';

  /// A short name for pickers: the title, else the first written line.
  String get label {
    final lines = [
      rawTitle,
      text,
      ...checks.map(itemText),
      ...files.map(transcript),
    ].expand((v) => v.split('\n')).map((v) => v.trim());
    final first = lines.where((v) => v.isNotEmpty).firstOrNull ?? '';
    return first.isEmpty
        ? (checks.isNotEmpty
              ? 'List'
              : files.any((f) => fileMeta(f)['kind'] == 'audio')
              ? 'Voice note'
              : 'Note')
        : first.substring(0, first.length.clamp(0, 100));
  }

  /// A shared colour name from [noteColors]; null or 'default' is uncoloured.
  String? get color => value('color') as String?;

  /// A shared background pattern name; null or 'none' has no pattern.
  String? get background => value('background') as String?;

  /// 'markup' when the body uses lightweight formatting (see `NoteMarkup`).
  String get format => (value('format') as String?) ?? 'plain';

  /// Original creation time, which an import may set; otherwise the note's.
  int get created => (value('created') as int?) ?? room.object.created;

  /// Nesting level of a checklist item: 0, or 1 under the previous item.
  int indent(String id) => (value('check:$id:indent') as int?) ?? 0;

  /// Live attachments (audio, images, drawings) in display order.
  late final List<String> files = _live('file', 'meta');

  /// The signed operation holding an attachment's encrypted chunks.
  EverydayItem? file(String id) => heads['file:$id:meta']?.firstOrNull;

  /// `kind` (audio, image, drawing), `mime`, and kind-specific details such as
  /// `duration` in milliseconds or `width`/`height` in pixels.
  Json fileMeta(String id) =>
      (value('file:$id:meta') as Map?)?.cast<String, dynamic>() ?? const {};

  /// A drawing's editable strokes, stored as a separate encrypted file.
  EverydayItem? strokes(String id) => heads['file:$id:strokes']?.firstOrNull;
  String transcript(String id) =>
      (value('file:$id:transcript') as String?) ?? '';

  /// Newest accepted edit time, for most-recently-edited ordering. An import
  /// writes the original edit time (`edited`) last; its own earlier writes
  /// are not edits, later ones are.
  int get updated {
    final mark = heads['edited']?.firstOrNull;
    final since = mark?.object.created;
    var latest = mark?.data['value'] as int? ?? room.object.created;
    for (final r in history) {
      final at = r.object.created;
      if (at > latest && (since == null || at > since)) latest = at;
    }
    return latest;
  }

  String itemText(String id) => (value('check:$id:text') as String?) ?? '';
  bool done(String id) => value('check:$id:done') == true;
  String? order(String id) => value('check:$id:order') as String?;
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

  /// Live items in display order: an explicit order key, then (for items
  /// written before ordering existed) first-write clock and item ID.
  late final List<String> checks = _live('check', 'text');

  /// Live `<kind>:<id>:<field>` registers, ordered by `<kind>:<id>:order`,
  /// then first-write clock and ID.
  List<String> _live(String kind, String field) {
    bool matches(String k) => k.startsWith('$kind:') && k.endsWith(':$field');
    final first = <String, int>{};
    for (final op in history) {
      final key = op.data['field'] as String;
      if (!matches(key)) continue;
      final id = key.split(':')[1];
      final clock = op.data['clock'] as int;
      if (clock < (first[id] ?? clock + 1)) first[id] = clock;
    }
    String orderOf(String id) => value('$kind:$id:order') as String? ?? '';
    return heads.keys
        .where(matches)
        .map((k) => k.split(':')[1])
        .where((id) => value('$kind:$id:deleted') != true)
        .toList()
      ..sort((a, b) {
        final byOrder = orderOf(a).compareTo(orderOf(b));
        if (byOrder != 0) return byOrder;
        final byClock = (first[a] ?? 0).compareTo(first[b] ?? 0);
        return byClock != 0 ? byClock : a.compareTo(b);
      });
  }

  bool get hasConflicts => heads.entries.any(
    (e) =>
        (e.key == 'text' ||
            e.key == 'title' ||
            e.key.endsWith(':text') ||
            e.key.endsWith(':transcript')) &&
        e.value.map((r) => r.data['value']).toSet().length > 1,
  );
}

/// Shared note colours, in picker order. Unknown names display uncoloured.
const noteColors = [
  'default',
  'coral',
  'peach',
  'sand',
  'mint',
  'sage',
  'fog',
  'storm',
  'dusk',
  'blossom',
  'clay',
  'chalk',
];

const _orderDigits =
    '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';

/// A key sorting strictly between [before] and [after] (null is unbounded).
/// Keys never end in '0', so a later key can always be placed before them.
/// Equal or inverted bounds (concurrent placements) sort after [before].
String orderBetween(String? before, String? after) {
  final low = before ?? '';
  String? high = after;
  if (high != null && high.compareTo(low) <= 0) high = null;
  final result = StringBuffer();
  for (var i = 0; ; i++) {
    // Both bounds exhausted: [after] is [before] followed by '0's, so no key
    // sorts strictly between them. Place this one after, as inverted bounds do.
    if (high != null && i >= high.length && i >= low.length) high = null;
    final lo = i < low.length ? _orderDigits.indexOf(low[i]) : 0;
    final hi = high == null
        ? _orderDigits.length
        : i < high.length
        ? _orderDigits.indexOf(high[i])
        : 0;
    if (hi - lo > 1) {
      result.write(_orderDigits[(lo + hi) ~/ 2]);
      return result.toString();
    }
    result.write(_orderDigits[lo]);
    if (hi - lo == 1) high = null;
  }
}

/// [count] short, evenly spaced keys for renumbering a whole list.
List<String> orderSequence(int count) {
  final base = _orderDigits.length;
  final span = base * base;
  return [
    for (var i = 1; i <= count; i++)
      () {
        var n = i * span ~/ (count + 1);
        if (n % base == 0) n++;
        return '${_orderDigits[n ~/ base]}${_orderDigits[n % base]}';
      }(),
  ];
}

/// One register write in a batch.
typedef NoteChange = ({String field, Object value, List<String> parents});

/// One encrypted room per note, including personal notes. Membership epochs
/// reuse Everyday; note registers retain concurrent branches instead of LWW
/// discarding writing. No protocol or crypto is implemented in the UI/native host.
class Notes {
  final Node node;
  Notes(this.node);

  /// Pins, archive, labels, reminders and manual order: personal, synced
  /// between this person's own devices, never visible to collaborators.
  late final state = NoteState(node);
  late final _everyday = Everyday(node);
  final _rooms = <String, EverydayItem>{};
  final _cache = LinkedHashMap<String, NoteDocument>();
  final _summaries = <String, EverydayItem>{};
  int _cursor = 0;
  Future<void>? _refreshing;
  Future<void> _tail = Future.value();
  int _queued = 0;
  String _policy = '';
  static const maxChecks = 200;

  /// [value] cut to at most [length] characters.
  static String bounded(String value, int length) =>
      value.substring(0, value.length.clamp(0, length));

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
    await state.refresh();
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
            final rooms = await _everyday.rooms(
              includeLeft: true,
              records: await _everyday.membership(object.space),
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
    }
    return result;
  }

  /// Small list projection: unchanged notes do not reread operation history.
  /// Text shown in a list is bounded; the editor loads the full document.
  /// Notes not yet projected are read with pauses, so a first load of many
  /// notes does not hold up the UI.
  Future<List<EverydayItem>> summaries({bool includeDeleted = false}) async {
    await refresh();
    final result = <EverydayItem>[];
    final slice = TimeSlice();
    for (final id in _rooms.keys.toList().reversed) {
      var summary = _summaries[id];
      if (summary == null) {
        await slice.pause();
        final note = await get(id, includeUnavailable: true);
        if (note == null) continue;
        final text = note.text.isEmpty && note.checks.isNotEmpty
            ? note.checks
                  .take(12)
                  .map((c) => '${note.done(c) ? '☑' : '☐'} ${note.itemText(c)}')
                  .join('\n')
            : note.text;
        final unchecked = note.checks.where((c) => !note.done(c)).toList();
        final transcripts = note.files
            .map(note.transcript)
            .where((t) => t.isNotEmpty)
            .join('\n');
        summary = EverydayItem(note.room.object, {
          'entry': id,
          'type': 'shared_note',
          'title': bounded(note.rawTitle, 100),
          'label': note.label,
          'text': bounded(text, 512),
          'body': bounded(note.text, 512),
          'checklist': note.checks.isNotEmpty,
          'epoch': note.epoch,
          'color': note.color ?? 'default',
          'updated': note.updated,
          'owner': note.room.data['owner'],
          'people': note.members.take(8).toList(),
          // Unchecked items first, in list order, as a bounded card preview.
          'checks': [
            for (final id in unchecked.take(8))
              {
                'id': id,
                'text': bounded(note.itemText(id), 160),
                'done': false,
                'indent': note.indent(id),
                'parents': note.parents('check:$id:done'),
              },
          ],
          'moreUnchecked': (unchecked.length - 8).clamp(0, maxChecks),
          'checkedCount': note.checks.length - unchecked.length,
          'deleted': note.deleted || !note.available,
          'removed': note.deleted,
          if (note.deleted)
            ...() {
              final removal = note.heads['deleted']!.firstWhere(
                (r) => r.data['value'] == true,
              );
              return {
                'removal': removal.object.id,
                'removedAt': removal.object.created,
              };
            }(),
          'deletedParents': note.parents('deleted'),
          'available': note.available,
          'members': note.members.length,
          'conflicts': note.hasConflicts,
          'background': note.background ?? 'none',
          'format': note.format,
          'created': note.created,
          'transcript': bounded(transcripts, 512),
          // Attachment references only; cards read stored previews by object.
          'files': [
            for (final f in note.files.take(6))
              {
                // Chunk references and key, as a file payload for previews.
                ..._fileFields(note.file(f)!.data),
                'id': f,
                'object': note.file(f)!.object.id,
                'kind': note.fileMeta(f)['kind'],
                'duration': note.fileMeta(f)['duration'],
              },
          ],
          'fileCount': note.files.length,
        });
        _summaries[id] = summary;
      }
      if (includeDeleted || summary.data['deleted'] != true)
        result.add(summary);
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
    final records = await _everyday.membership(id);
    final rooms = await _everyday.rooms(includeLeft: true, records: records);
    final room = rooms.firstOrNull;
    if (room == null || room.data['note'] != true) return null;
    final members = _everyday.effectiveMembers(room, records);
    final available =
        members.contains(node.person) && room.data['archived'] != true;
    if (!available && !includeUnavailable) return null;
    final ops = <EverydayItem>[], earlier = <EverydayItem>[];
    final slice = TimeSlice();
    // Every operation on this note, read in pages. A document is folded from
    // all of them, so a limit here would silently drop whatever was written
    // once and never revised: the title, an early checklist item. It is
    // bounded by the note, not by the profile.
    for (final object in node.store.allOf(kind: 'note_op', space: id)) {
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

  /// Creates a note. [checklist] adds one empty item when [items] is empty.
  /// A repeated [stableId] returns the existing note rather than a duplicate.
  Future<NoteDocument> create({
    String title = '',
    String text = '',
    bool checklist = false,
    List<String> items = const [],
    String? color,
    String? stableId,
    String? background,
    String? format,
    int? created,
  }) => _serial(() async {
    if (text.length > 16384 ||
        title.length > 100 ||
        items.length > maxChecks ||
        items.any((i) => i.length > 16384))
      throw StateError(
        'Use a title up to 100 characters and text up to 16,384 characters.',
      );
    final key = stableId ?? randomId();
    final id = 'room2:${node.person}:$key';
    final existing = await get(id);
    if (existing != null) return existing;
    final room = await _everyday.createRoom(
      title.trim().isEmpty
          ? 'Note'
          : title.trim().substring(0, title.trim().length.clamp(0, 100)),
      [],
      noteId: key,
    );
    // An absent register reads as empty, so writing one costs an object for
    // nothing. Imports of many short notes feel this most.
    if (title.isNotEmpty) await _publish(room, 'title', title, [], 1);
    if (text.isNotEmpty) await _publish(room, 'text', text, [], 1);
    if (color != null && color != 'default')
      await _publish(room, 'color', color, [], 1);
    if (background != null && background != 'none')
      await _publish(room, 'background', background, [], 1);
    if (format != null && format != 'plain')
      await _publish(room, 'format', format, [], 1);
    if (created != null) await _publish(room, 'created', created, [], 1);
    final written = items.isEmpty && checklist ? [''] : items;
    final keys = orderSequence(written.length);
    for (var i = 0; i < written.length; i++) {
      final item = randomId();
      await _publish(room, 'check:$item:text', written[i], [], 1);
      await _publish(room, 'check:$item:order', keys[i], [], 1);
    }
    return (await get(id))!;
  });

  Future<SignedObject> _publish(
    EverydayItem room,
    String field,
    Object value,
    List<String> parents,
    int clock, {
    String? request,
    bool checkpoint = false,
    List<String>? audience,
    Json extra = const {},
  }) async {
    return node.publish(
      'note_op',
      {
        ...extra,
        'epoch': room.data['epoch'],
        'field': field,
        'value': value,
        'parents': parents,
        'clock': clock,
        'checkpoint': checkpoint,
        if (request != null) 'request': request,
      },
      space: room.object.space,
      audience: audience ?? await _everyday.members(room),
    );
  }

  /// Pass the editor's observed parents, never the newly received heads: saving
  /// an old draft must produce a recoverable branch, not overwrite unseen text.
  /// Returns the published operation ID (or null for an already applied
  /// [request]), so an editor can observe its own write as the next parent.
  Future<String?> edit(
    String id,
    String epoch,
    String field,
    Object value,
    List<String> parents, {
    String? request,
  }) async => (await apply(id, epoch, [
    (field: field, value: value, parents: parents),
  ], request: request)).single;

  /// Replaces every current version of [field] in [note]. For choices such
  /// as removal or colour; typed text passes its observed parents to [edit].
  Future<String?> set(NoteDocument note, String field, Object value) =>
      edit(note.id, note.epoch, field, value, note.parents(field));

  /// Validates every change against one document state, then publishes them
  /// in order. Earlier changes remain published if a later publication fails.
  Future<List<String?>> apply(
    String id,
    String epoch,
    List<NoteChange> changes, {
    String? request,
  }) => _serial(() async {
    final note = await get(id, includeUnavailable: true);
    if (note == null)
      throw StateError(
        'This note is unavailable. Your draft is kept on this device.',
      );
    bool applied(NoteChange change) =>
        request != null &&
        [...note.history, ...note.earlier].any(
          (r) =>
              r.data['request'] == request &&
              r.object.author == node.person &&
              r.object.certificate.device == node.identity.device &&
              r.data['field'] == change.field &&
              // Compared by value: maps and lists are never identical.
              canonical(r.data['value']) == canonical(change.value),
        );
    if (changes.every(applied)) return [for (final _ in changes) null];
    if (!note.available)
      throw StateError(
        'This note is unavailable. Your draft is kept on this device.',
      );
    if (note.epoch != epoch)
      throw StateError(
        'Collaborators changed. Reopen the note before saving; your draft is kept.',
      );
    var added = 0;
    for (final change in changes) {
      final field = change.field;
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
          note.checks.length + ++added > maxChecks)
        throw StateError('A checklist supports $maxChecks items.');
    }
    await _everyday.prepare(note.room);
    final clock = _clock(note);
    return [
      for (final change in changes)
        applied(change)
            ? null
            : (await _publish(
                note.room,
                change.field,
                change.value,
                change.parents,
                clock + 1,
                request: request,
              )).id,
    ];
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
    await _everyday.changeMembers(
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
            extra: _fileFields(head.data),
          );
        }
      },
    );
  });

  /// Re-encrypts this person's own notes, and their personal note state, to
  /// the devices admitted now.
  ///
  /// Note operations are encrypted to the devices that existed when they were
  /// written, so a device enrolled later reads none of them — not even the
  /// room record, without which the note does not appear at all and later
  /// edits arrive in a space it knows nothing about. Each live register is
  /// rewritten as a checkpoint that consumes exactly the version it copies,
  /// so branches are preserved rather than silently resolved, and the note's
  /// edit time is restored afterwards so a new device does not reorder the
  /// list. Notes owned by a collaborator are theirs to re-issue.
  Future<int> shareNotes() async {
    await refresh();
    var count = 0;
    for (final id in _rooms.keys.toList()) {
      final note = await get(id);
      if (note == null || note.room.data['owner'] != node.person) continue;
      try {
        count += await _reissue(note);
      } catch (_) {
        // A note this device can no longer encrypt to every collaborator
        // must not stop the pass; running it again later is safe.
      }
    }
    return count + await state.reshare();
  }

  Future<int> _reissue(NoteDocument note) => _serial(() async {
    final edited = note.updated;
    // Both records describe the same room, so which one a device that holds
    // both settles on is decided by object ID. A note that never recorded
    // its own creation time reads it off that record, so write it down
    // before the copy exists rather than let the date move.
    if (note.value('created') == null) {
      await _publish(note.room, 'created', note.created, const [], 1,
          checkpoint: true);
    }
    var count = await _everyday.reissue(note.room, entries: false) + 1;
    for (final MapEntry(key: field, value: heads) in note.heads.entries) {
      if (field == 'edited') continue;
      // Each branch copies itself and names only its own version as the
      // parent it replaces, so concurrent versions stay concurrent.
      for (final head in heads) {
        await _publish(
          note.room,
          field,
          head.data['value'] as Object,
          [head.object.id],
          (head.data['clock'] as int) + 1,
          checkpoint: true,
          extra: _fileFields(head.data),
        );
        count++;
      }
    }
    // Last, so the copies above are not read as edits: see [updated].
    await _publish(
      note.room,
      'edited',
      edited,
      note.parents('edited'),
      _clock(note) + 2,
      checkpoint: true,
    );
    return count + 1;
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

  Future<void> pin(String id, bool value) => state.set('pin', id, value);
  bool pinned(String id) => state.pinned(id);

  static const chunkSize = 128 * 1024;
  static const maxFileSize = 64 * 1024 * 1024;
  static const maxFiles = 32;

  /// Encrypts [source] into content-addressed chunks and publishes it as an
  /// attachment register (`file:<id>:meta`, or `file:<id>:strokes` with
  /// [field]). Replacing an existing attachment passes its [parents].
  /// Returns the attachment ID.
  Future<String> attach(
    String id,
    String epoch,
    Stream<List<int>> source, {
    required String name,
    required Json meta,
    String? fileId,
    String field = 'meta',
    List<String> parents = const [],
  }) async {
    // Refuse before storing chunks: blobs of a refused attachment stay behind.
    final before = await _writable(id, epoch);
    if (fileId == null &&
        field == 'meta' &&
        before.files.length >= maxFiles) {
      throw StateError('A note holds up to $maxFiles attachments.');
    }
    final key = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    final chunks = <String>[];
    var pending = BytesBuilder(copy: false);
    var size = 0;
    await for (final part in source) {
      size += part.length;
      if (size > maxFileSize) {
        throw StateError('Attachments are up to 64 MiB.');
      }
      pending.add(part);
      while (pending.length >= chunkSize) {
        final all = pending.takeBytes();
        chunks.add(
          await node.blobs.encode(
            Uint8List.sublistView(all, 0, chunkSize),
            key,
          ),
        );
        pending = BytesBuilder(copy: false)
          ..add(Uint8List.sublistView(all, chunkSize));
      }
    }
    if (pending.length > 0) {
      chunks.add(await node.blobs.encode(pending.takeBytes(), key));
    }
    final file = fileId ?? randomId();
    var safeName = name.replaceAll(RegExp(r'[/\\\x00-\x1f]'), '_');
    safeName = safeName.substring(0, safeName.length.clamp(0, 255));
    await _serial(() async {
      final note = await _writable(id, epoch);
      final isNew = !note.heads.containsKey('file:$file:meta');
      if (isNew && field == 'meta' && note.files.length >= maxFiles) {
        throw StateError('A note holds up to $maxFiles attachments.');
      }
      final clock = _clock(note) + 1;
      await _publish(
        note.room,
        'file:$file:$field',
        meta,
        parents,
        clock,
        extra: {
          'chunks': chunks,
          'name': safeName.trim().isEmpty ? 'Attachment' : safeName,
          'size': size,
          'key': b64(key),
        },
      );
      if (isNew && field == 'meta') {
        final last = note.files.isEmpty
            ? null
            : note.value('file:${note.files.last}:order') as String?;
        await _publish(
          note.room,
          'file:$file:order',
          orderBetween(last, null),
          [],
          clock,
        );
      }
    });
    return file;
  }

  static final _imageName = RegExp(
    r'\.(png|jpe?g|webp|gif|bmp)$',
    caseSensitive: false,
  );

  static String imageMime(String name) =>
      switch (name.split('.').last.toLowerCase()) {
        'png' => 'image/png',
        'webp' => 'image/webp',
        'gif' => 'image/gif',
        'bmp' => 'image/bmp',
        _ => 'image/jpeg',
      };

  /// Attaches a photo; names without an image extension are saved as JPEG.
  Future<String> attachImage(
    NoteDocument note,
    Stream<List<int>> source,
    String name,
  ) {
    final saved = _imageName.hasMatch(name) ? name : '$name.jpg';
    return attach(
      note.id,
      note.epoch,
      source,
      name: saved,
      meta: {'kind': 'image', 'mime': imageMime(saved)},
    );
  }

  /// Attaches a recording of [duration] milliseconds.
  Future<String> attachAudio(
    NoteDocument note,
    Stream<List<int>> source, {
    required String name,
    required String mime,
    required int duration,
  }) => attach(
    note.id,
    note.epoch,
    source,
    name: name,
    meta: {'kind': 'audio', 'mime': mime, 'duration': duration},
  );

  /// Attaches a drawing's image and editable strokes, replacing [existing].
  Future<String> attachDrawing(
    NoteDocument note, {
    required List<int> png,
    required List<int> strokes,
    required int width,
    required int height,
    String? existing,
  }) async {
    List<String> parents(String field) =>
        existing == null ? const [] : note.parents('file:$existing:$field');
    final file = await attach(
      note.id,
      note.epoch,
      Stream.value(png),
      name: 'Drawing.png',
      fileId: existing,
      parents: parents('meta'),
      meta: {
        'kind': 'drawing',
        'mime': 'image/png',
        'width': width,
        'height': height,
      },
    );
    await attach(
      note.id,
      note.epoch,
      Stream.value(strokes),
      name: 'Drawing.json',
      fileId: file,
      field: 'strokes',
      parents: parents('strokes'),
      meta: {'version': 1},
    );
    return file;
  }

  /// An independent copy with this person's labels. Attachments reuse their
  /// encrypted chunks. Collaborators and personal pins are not copied.
  Future<NoteDocument> copy(String id) async {
    final source = await get(id, includeUnavailable: true);
    if (source == null) throw StateError('This note is unavailable.');
    final copied = await create(
      // Titles written by older builds or other people can exceed the limit
      // a new note accepts.
      title: bounded(source.rawTitle, 100),
      text: source.text,
      items: [for (final c in source.checks) source.itemText(c)],
      color: source.color,
      background: source.background,
      format: source.format,
    );
    final changes = <NoteChange>[
      for (final (i, c) in copied.checks.indexed) ...[
        if (source.done(source.checks[i]))
          (field: 'check:$c:done', value: true, parents: const <String>[]),
        if (source.indent(source.checks[i]) > 0)
          (
            field: 'check:$c:indent',
            value: source.indent(source.checks[i]),
            parents: const <String>[],
          ),
      ],
    ];
    if (changes.isNotEmpty) await apply(copied.id, copied.epoch, changes);
    if (source.files.isNotEmpty) {
      await _serial(() async {
        final note = await _writable(copied.id, copied.epoch);
        final clock = _clock(note) + 1;
        for (final f in source.files) {
          final file = randomId();
          for (final field in ['meta', 'strokes', 'transcript', 'order']) {
            final head = source.heads['file:$f:$field']?.firstOrNull;
            if (head == null) continue;
            await _publish(
              note.room,
              'file:$file:$field',
              head.data['value'],
              [],
              clock,
              extra: _fileFields(head.data),
            );
          }
        }
      });
    }
    final labels = state.labelsOf(id);
    if (labels.isNotEmpty) await state.set('labels', copied.id, labels);
    return (await get(copied.id))!;
  }

  Future<NoteDocument> _writable(String id, String epoch) async {
    final note = await get(id);
    if (note == null || !note.available) {
      throw StateError('This note is unavailable.');
    }
    if (note.epoch != epoch) {
      throw StateError('Collaborators changed. Reopen the note and try again.');
    }
    if (note.deleted) {
      throw StateError('This note was removed. Restore it first.');
    }
    await _everyday.prepare(note.room);
    return note;
  }

  int _clock(NoteDocument note) => note.history.fold(
    0,
    (max, r) => (r.data['clock'] as int) > max ? r.data['clock'] as int : max,
  );

  static Json _fileFields(Json data) => {
    for (final key in ['chunks', 'name', 'size', 'key'])
      if (data[key] != null) key: data[key],
  };
}
