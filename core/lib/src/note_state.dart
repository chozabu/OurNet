import 'everyday.dart';
import 'model.dart';
import 'node.dart';
import 'notes.dart' show orderBetween;

/// Personal note state: pins, archive, labels, reminders and manual order.
/// It is encrypted to this person's own devices and syncs between them, but
/// collaborators never see it. Values are registers keyed by field and target
/// (a note or label ID) that name the versions they replace; concurrent writes
/// from two of this person's devices resolve by Lamport clock and object ID.
class NoteState {
  final Node node;
  NoteState(this.node);
  final _heads = <String, List<EverydayItem>>{};
  final _consumed = <String, Set<String>>{};
  int _cursor = 0, _clock = 0;
  Future<void>? _refreshing;

  static const space = '_noteself';
  static const maxLabels = 64;
  static const repeats = ['none', 'daily', 'weekly', 'monthly', 'yearly'];

  Future<void> refresh() =>
      _refreshing ??= _refresh().whenComplete(() => _refreshing = null);

  Future<void> _refresh() async {
    final slice = TimeSlice();
    while (true) {
      final page = node.store.insertedAfter(_cursor, ['note_self']);
      if (page.isEmpty) break;
      for (final (cursor, object) in page) {
        _cursor = cursor;
        if (object.author == node.person &&
            object.audience.length == 1 &&
            object.space == space) {
          final data = await node.content(object);
          if (data != null) _add(EverydayItem(object, data));
        }
        await slice.pause();
      }
    }
    await _migrate();
  }

  /// Changes whenever a personal value changes, so views can skip rework.
  int get version => _version;
  int _version = 0;

  void _add(EverydayItem op) {
    final key = '${op.data['field']}/${op.data['target']}';
    final heads = _heads[key] ??= [];
    final consumed = _consumed[key] ??= {};
    if (heads.any((h) => h.object.id == op.object.id)) return;
    final clock = op.data['clock'] as int;
    if (clock > _clock) _clock = clock;
    consumed.addAll((op.data['parents'] as List).cast<String>());
    if (consumed.contains(op.object.id)) return;
    _version++;
    heads
      ..removeWhere((h) => consumed.contains(h.object.id))
      ..add(op)
      ..sort((a, b) {
        final order = (b.data['clock'] as int).compareTo(
          a.data['clock'] as int,
        );
        return order == 0 ? b.object.id.compareTo(a.object.id) : order;
      });
  }

  /// Pins were device-local settings before they synced between devices.
  Future<void> _migrate() async {
    if (node.store.setting('noteStateMigrated') == true) return;
    node.store.set('noteStateMigrated', true);
    final pins = node.store.trueSettings('notePin/');
    if (pins.isEmpty) return;
    await setAll([
      for (final id in pins)
        if (value('pin', id) == null) ('pin', id, true),
    ]);
  }

  Object? value(String field, String target) =>
      _heads['$field/$target']?.firstOrNull?.data['value'];

  /// Writes several personal values; each observes the current heads.
  Future<void> setAll(List<(String, String, Object)> values) async {
    if (values.isEmpty) return;
    final clock = ++_clock;
    for (final (field, target, value) in values) {
      final object = await node.publish(
        'note_self',
        {
          'field': field,
          'target': target,
          'value': value,
          'parents': [
            for (final h in _heads['$field/$target'] ?? const <EverydayItem>[])
              h.object.id,
          ],
          'clock': clock,
        },
        space: space,
        audience: [node.person],
      );
      final data = await node.content(object);
      if (data != null) _add(EverydayItem(object, data));
    }
  }

  Future<void> set(String field, String target, Object value) =>
      setAll([(field, target, value)]);

  bool pinned(String note) => value('pin', note) == true;
  bool archived(String note) => value('archive', note) == true;

  /// Whether this person emptied [removal] (a `deleted` operation ID) from
  /// Removed. Restoring and removing the note again shows it once more.
  bool purged(String note, String? removal) =>
      removal != null && value('purged', note) == removal;

  /// A grid position from builds before [rank], or null.
  String? order(String note) => value('order', note) as String?;

  /// The list position this person moved [note] to, or null when never
  /// moved: a key among [listKey]s.
  String? rank(String note) => value('rank', note) as String?;

  /// Where [note] sorts in the notes list; smaller keys are shown first.
  /// Notes never moved sort by [updated], newest first. A moved note keeps
  /// the key it was given between its neighbours, so notes edited later still
  /// rise above it. Positions from older builds (`order`) keep their order
  /// after all others.
  String listKey(String note, int updated) {
    if (rank(note) case final rank?) return rank;
    if (order(note) case final order?) return '2$order';
    return timeKey(updated, note);
  }

  static const _digits =
      '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';

  /// '1', eight digits that fall as [time] rises, and three from [id] that
  /// separate equal times and never end in '0'.
  static String timeKey(int time, String id) {
    const width = 8;
    var span = 1;
    for (var i = 0; i < width; i++) {
      span *= _digits.length;
    }
    var rest = span - 1 - time.clamp(0, span - 1);
    final key = List.filled(width, '0');
    for (var i = width - 1; i >= 0; i--) {
      key[i] = _digits[rest % _digits.length];
      rest ~/= _digits.length;
    }
    var hash = 0x811c9dc5;
    for (final unit in id.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    final tag = [
      _digits[hash % 62],
      _digits[(hash ~/ 62) % 62],
      _digits[1 + (hash ~/ 3844) % 61],
    ];
    return '1${key.join()}${tag.join()}';
  }

  /// Moves [note] to just before [target] in [section], the notes in their
  /// shown order with their [listKey]s. Usually one key is written; when the
  /// gap is too narrow for a short key, a few neighbours are respaced.
  Future<void> move(
    List<({String id, String key})> section,
    String note,
    String target, {
    int? now,
  }) async {
    final rest = [
      for (final s in section)
        if (s.id != note) s,
    ];
    final at = rest.indexWhere((s) => s.id == target);
    if (at < 0) return;
    final ids = [for (final s in rest) s.id]..insert(at, note);
    final keys = <String?>[for (final s in rest) s.key]..insert(at, null);
    // Above the first note, stay below notes written from now on.
    final top = timeKey((now ?? DateTime.now().millisecondsSinceEpoch) + 1, '');
    var (a, b) = (at, at + 1);
    while (true) {
      final high = b < keys.length ? keys[b]! : null;
      final low = a > 0 ? keys[a - 1]! : null;
      final fresh = spread(
        low ?? (high == null || top.compareTo(high) < 0 ? top : null),
        // The end of a section stays before older builds' positions.
        high ?? (low == null || low.compareTo('2') < 0 ? '2' : null),
        b - a,
      );
      if (fresh != null) {
        await setAll([
          for (var i = a; i < b; i++)
            if (keys[i] != fresh[i - a]) ('rank', ids[i], fresh[i - a]),
        ]);
        return;
      }
      if (a == 0 && b == keys.length) {
        throw StateError('This note cannot be moved there.');
      }
      final width = b - a;
      (a, b) = ((a - width).clamp(0, a), (b + width).clamp(b, keys.length));
    }
  }

  /// [count] ascending keys between [low] and [high] (null is unbounded), or
  /// null when one would be longer than a stored key allows.
  static List<String>? spread(String? low, String? high, int count) {
    if (count == 0) return [];
    final mid = orderBetween(low, high);
    if (mid.length > 64) return null;
    final left = (count - 1) ~/ 2;
    final before = spread(low, mid, left);
    final after = spread(mid, high, count - 1 - left);
    if (before == null || after == null) return null;
    return [...before, mid, ...after];
  }

  /// Live label IDs on [note].
  List<String> labelsOf(String note) {
    final live = labels;
    return [
      for (final l in (value('labels', note) as List? ?? const []))
        if (live.containsKey(l)) l as String,
    ];
  }

  /// `{at: millisecondsSinceEpoch, repeat: none|daily|weekly|monthly|yearly}`,
  /// or null when no reminder is set.
  Json? reminder(String note) {
    final v = value('reminder', note);
    return v is Map && v.isNotEmpty ? v.cast<String, dynamic>() : null;
  }

  Future<void> setReminder(
    String note,
    DateTime? at, {
    String repeat = 'none',
  }) {
    if (!repeats.contains(repeat)) throw ArgumentError.value(repeat, 'repeat');
    return set(
      'reminder',
      note,
      at == null
          ? const {}
          : {'at': at.millisecondsSinceEpoch, 'repeat': repeat},
    );
  }

  /// Archiving also unpins, like Keep; unarchiving leaves pins alone.
  Future<void> archive(Iterable<String> notes, bool value) => setAll([
    for (final note in notes) ...[
      ('archive', note, value),
      if (value && pinned(note)) ('pin', note, false),
    ],
  ]);

  /// Live labels by ID, sorted by name.
  Map<String, String> get labels {
    final result = <String, String>{};
    for (final key in _heads.keys) {
      if (!key.startsWith('labelName/')) continue;
      final id = key.substring('labelName/'.length);
      if (value('labelDeleted', id) == true) continue;
      result[id] = value('labelName', id) as String;
    }
    return Map.fromEntries(
      result.entries.toList()..sort(
        (a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase()),
      ),
    );
  }

  /// Targets with a personal value for [field], e.g. every reminder.
  Iterable<String> targets(String field) => _heads.keys
      .where((k) => k.startsWith('$field/'))
      .map((k) => k.substring(field.length + 1));

  /// Returns the existing label with the same name, ignoring case.
  Future<String> createLabel(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.length > 50) {
      throw StateError('Use a label name up to 50 characters.');
    }
    final existing = labels.entries
        .where((e) => e.value.toLowerCase() == trimmed.toLowerCase())
        .firstOrNull;
    if (existing != null) return existing.key;
    if (labels.length >= maxLabels) {
      throw StateError('Up to $maxLabels labels are supported.');
    }
    final id = randomId()
        .replaceAll(RegExp('[^A-Za-z0-9]'), '')
        .substring(0, 16);
    await set('labelName', id, trimmed);
    return id;
  }

  Future<void> renameLabel(String id, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.length > 50) {
      throw StateError('Use a label name up to 50 characters.');
    }
    if (labels.entries.any(
      (e) => e.key != id && e.value.toLowerCase() == trimmed.toLowerCase(),
    )) {
      throw StateError('A label with that name already exists.');
    }
    await set('labelName', id, trimmed);
  }

  Future<void> deleteLabel(String id) => set('labelDeleted', id, true);

  /// Adds or removes [label] on each of [notes].
  Future<void> label(Iterable<String> notes, String label, bool value) =>
      setAll([
        for (final note in notes)
          if (labelsOf(note).contains(label) != value)
            (
              'labels',
              note,
              value
                  ? [...labelsOf(note), label]
                  : (labelsOf(note)..remove(label)),
            ),
      ]);
}
