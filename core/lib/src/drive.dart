import 'dart:collection';
import 'model.dart';
import 'node.dart';

class DriveVersion {
  final SignedObject object;
  final Json data;
  DriveVersion(this.object, this.data);
  String get entry => data['entry'];
  bool get deleted => data['deleted'];
  bool get isFolder => data['type'] == 'folder';
}

class DriveEntry {
  final List<DriveVersion> history;
  final List<DriveVersion> heads;
  DriveEntry(this.history, this.heads);
  DriveVersion get current => heads.first;
  bool get conflicted => heads.length > 1;
}

/// Private per-person revision graph. Parent IDs, not wall clocks, determine
/// supersession. Concurrent heads remain available until explicitly merged.
class Drive {
  final Node node;
  Drive(this.node);
  static final _indexes = Expando<_DriveIndex>();
  Future<List<DriveEntry>> entries() =>
      (_indexes[node] ??= _DriveIndex(node)).read();

  Future<SignedObject> write(Json data, {List<String> parents = const []}) =>
      node.publish(
        'drive',
        {...data, 'revision': randomId(), 'parents': parents},
        space: '_drive',
        audience: [node.person],
      );

  Future<SignedObject> folder(String name, {String? parent}) => write({
    'entry': randomId(),
    'name': name,
    'folder': parent,
    'type': 'folder',
    'deleted': false,
  });

  Future<SignedObject> revise(
    DriveEntry entry,
    Json changes, {
    DriveVersion? source,
  }) => write({
    ...(source ?? entry.current).data,
    ...changes,
  }, parents: entry.heads.map((v) => v.data['revision'] as String).toList());

  /// Republish every readable revision with its original ancestry for newly
  /// enrolled devices. Equivalent copies are deduplicated in entries().
  /// Republishing is deliberately a pass over everything, so it reads in
  /// insertion-cursor pages rather than materialising the whole of it.
  Future<int> shareHistory() async {
    final seen = <String>{};
    var count = 0, cursor = 0;
    final slice = TimeSlice();
    while (true) {
      final page = node.store.objectsAfter('drive', cursor);
      if (page.isEmpty) break;
      for (final (sequence, o) in page) {
        cursor = sequence;
        await slice.pause();
        if (o.author != node.person || o.isPublic) continue;
        final p = await node.content(o);
        if (p == null || !seen.add(p['revision'])) continue;
        await node.publish(
          'drive',
          p,
          space: '_drive',
          audience: [node.person],
        );
        count++;
      }
    }
    return count;
  }
}

/// Decrypted state is memory-only. Restart rebuilds once; subsequent reads
/// consume only newly arrived records, including reshared older revisions.
class _DriveIndex {
  final Node node;
  int cursor = 0;
  final groups = <String, _DriveGroup>{};
  Future<List<DriveEntry>>? active;
  _DriveIndex(this.node);
  Future<List<DriveEntry>> read() =>
      active ??= _read().whenComplete(() => active = null);
  Future<List<DriveEntry>> _read() async {
    final slice = TimeSlice();
    while (true) {
      final page = node.store.objectsAfter('drive', cursor);
      if (page.isEmpty) break;
      for (final (sequence, o) in page) {
        await slice.pause();
        if (o.author == node.person &&
            !o.isPublic &&
            o.audience.length == 1 &&
            o.audience.single == node.person) {
          final payload = await node.content(o);
          if (payload != null) {
            (groups[payload['entry']] ??= _DriveGroup()).add(
              DriveVersion(o, payload),
            );
          }
        }
        cursor = sequence;
      }
    }
    return [
      for (final group in groups.values)
        if (group.heads.isNotEmpty) group.view,
    ];
  }
}

class _DriveGroup {
  final revisions = <String>{};
  final superseded = <String>{};
  final history = <DriveVersion>[];
  final heads = <String, DriveVersion>{};
  DriveEntry? cached;
  void add(DriveVersion version) {
    final id = version.data['revision'] as String;
    if (!revisions.add(id)) return;
    history.add(version);
    for (final parent in (version.data['parents'] as List).cast<String>()) {
      superseded.add(parent);
      heads.remove(parent);
    }
    if (!superseded.contains(id)) heads[id] = version;
    cached = null;
  }

  DriveEntry get view => cached ??= DriveEntry(
    UnmodifiableListView(history),
    heads.values.toList()..sort((a, b) {
      final time = b.object.created.compareTo(a.object.created);
      return time == 0 ? a.object.id.compareTo(b.object.id) : time;
    }),
  );
}
