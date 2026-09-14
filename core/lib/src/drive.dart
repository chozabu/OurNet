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
  Future<List<DriveEntry>> entries() async {
    final groups = <String, List<DriveVersion>>{};
    final slice = TimeSlice();
    for (final o in node.store.objects(kind: 'drive', limit: Node.maxObjects)) {
      await slice.pause();
      if (o.author != node.person ||
          o.isPublic ||
          o.audience.length != 1 ||
          o.audience.single != node.person)
        continue;
      final p = await node.content(o);
      if (p != null) (groups[p['entry']] ??= []).add(DriveVersion(o, p));
    }
    return groups.values
        .map((versions) {
          final unique = <String, DriveVersion>{};
          for (final v in versions) {
            unique.putIfAbsent(v.data['revision'], () => v);
          }
          versions = unique.values.toList();
          final ids = versions.map((v) => v.data['revision']).toSet();
          final superseded = <String>{
            for (final v in versions)
              for (final parent in v.data['parents'])
                if (ids.contains(parent)) parent,
          };
          final heads =
              versions
                  .where((v) => !superseded.contains(v.data['revision']))
                  .toList()
                ..sort((a, b) {
                  final time = b.object.created.compareTo(a.object.created);
                  return time == 0 ? a.object.id.compareTo(b.object.id) : time;
                });
          return DriveEntry(versions, heads);
        })
        .where((e) => e.heads.isNotEmpty)
        .toList();
  }

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
  Future<int> shareHistory() async {
    final objects = node.store
        .objects(kind: 'drive', limit: Node.maxObjects)
        .reversed
        .toList();
    final seen = <String>{};
    var count = 0;
    for (final o in objects) {
      if (o.author != node.person || o.isPublic) continue;
      final p = await node.content(o);
      if (p == null || !seen.add(p['revision'])) continue;
      await node.publish('drive', p, space: '_drive', audience: [node.person]);
      count++;
    }
    return count;
  }
}
