import 'dart:async';
import 'dart:io';
import 'package:ournet_core/ournet_core.dart';
import 'files.dart';

/// A provider token changes when a local file changes. Directory tokens must
/// stay stable when their children change. All paths are relative and portable.
class FolderItem {
  final bool directory;
  final String token;
  final int size;
  // Ignores metadata changes caused solely by a rename (e.g. Unix ctime).
  final String? contentStamp;
  const FolderItem(
    this.directory,
    this.token, [
    this.size = 0,
    this.contentStamp,
  ]);

  /// The token a scan reports for a symlink or junction, which is never
  /// followed or synced.
  static const link = 'link';
}

abstract class FolderBackend {
  String get location;
  Stream<void> get changes => const Stream.empty();
  Future<Map<String, FolderItem>> scan();
  Future<FolderItem?> stat(String path);
  Future<void> readTo(String path, String destination, String expected);
  Future<FolderItem> put(String path, String source, String? expected);
  Future<void> mkdir(String path);
  Future<void> move(String source, String destination, String expected);
  Future<void> remove(String path, String expected);
}

bool safeFolderPath(String path) =>
    path.isNotEmpty &&
    path
        .split('/')
        .every(
          (p) =>
              p.isNotEmpty &&
              p != '.' &&
              p != '..' &&
              !p.toLowerCase().startsWith('.ournet-') &&
              !RegExp(r'[\\\x00-\x1f<>:"|?*]').hasMatch(p) &&
              !p.endsWith('.') &&
              !p.endsWith(' ') &&
              !RegExp(
                r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\.|$)',
                caseSensitive: false,
              ).hasMatch(p),
        );

/// No symlinks/junctions are followed, including in the selected root.
class DiskFolderBackend extends FolderBackend {
  @override
  final String location;
  DiskFolderBackend(this.location);
  @override
  Stream<void> get changes =>
      Directory(location).watch(recursive: true).map((_) {});
  Future<String> _path(String path) async {
    if (path.isNotEmpty && !safeFolderPath(path))
      throw StateError('Unsupported filename: $path');
    var current = Directory(location).absolute.path;
    // Check every ancestor as well as descendants: an existing parent junction
    // must not redirect an operation outside the selected tree.
    var ancestor = Directory(current);
    while (true) {
      if (await FileSystemEntity.type(ancestor.path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw StateError('Linked folders are not supported');
      }
      if (ancestor.parent.path == ancestor.path) break;
      ancestor = ancestor.parent;
    }
    if (!await Directory(current).exists())
      throw StateError('Folder unavailable: $location');
    for (final part in path.isEmpty ? <String>[] : path.split('/')) {
      current = '$current${Platform.pathSeparator}$part';
      if (await FileSystemEntity.type(current, followLinks: false) ==
          FileSystemEntityType.link) {
        throw StateError('Linked files are not supported: $path');
      }
    }
    return current;
  }

  @override
  Future<FolderItem?> stat(String path) async =>
      _item(await FileStat.stat(await _path(path)), path);

  FolderItem? _item(FileStat stat, String path) {
    if (stat.type == FileSystemEntityType.notFound) return null;
    if (stat.type == FileSystemEntityType.directory)
      return const FolderItem(true, 'directory');
    if (stat.type != FileSystemEntityType.file)
      throw StateError('Unsupported file: $path');
    return FolderItem(
      false,
      '${stat.modified.microsecondsSinceEpoch}/${stat.changed.microsecondsSinceEpoch}/${stat.size}',
      stat.size,
      '${stat.modified.microsecondsSinceEpoch}/${stat.size}',
    );
  }

  Future<void> _check(String path, String? expected) async {
    if ((await stat(path))?.token != expected)
      throw StateError(
        'File changed during sync: $path; retrying preserves your edit',
      );
  }

  @override
  Future<Map<String, FolderItem>> scan() async {
    final result = <String, FolderItem>{};
    // The root and its ancestors are checked once. Below it, the listing
    // itself reports links without following them, so entries need no
    // per-path ancestor walk.
    Future<void> visit(String relative, String directory) async {
      if (relative.split('/').length > 64)
        throw StateError('Folder nesting exceeds 64 levels');
      await for (final entity in Directory(
        directory,
      ).list(followLinks: false)) {
        final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (name.toLowerCase().startsWith('.ournet-')) continue;
        final path = relative.isEmpty ? name : '$relative/$name';
        final item = entity is Link
            ? const FolderItem(false, FolderItem.link)
            : _item(await FileStat.stat(entity.path), path);
        if (item == null)
          throw StateError('Folder changed while scanning; retry');
        result[path] = item;
        if (result.length > 10000)
          throw StateError('Folder limit is 10,000 entries');
        if (item.directory) await visit(path, entity.path);
      }
    }

    await visit('', await _path(''));
    return result;
  }

  @override
  Future<void> readTo(String path, String destination, String expected) async {
    await _check(path, expected);
    final output = File(destination).openWrite();
    var total = 0;
    try {
      await for (final bytes in File(await _path(path)).openRead()) {
        total += bytes.length;
        if (total > Files.maxSize)
          throw StateError('$path exceeds the 64 MiB file limit');
        output.add(bytes);
        await output.flush();
      }
    } finally {
      await output.close();
    }
    await _check(path, expected);
  }

  @override
  Future<FolderItem> put(String path, String source, String? expected) async {
    final target = await _path(path);
    final temp = File('${File(target).parent.path}/.ournet-${randomId()}.part');
    try {
      await File(source).copy(temp.path);
      await _check(path, expected);
      await temp.rename(target);
      return (await stat(path))!;
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  @override
  Future<void> mkdir(String path) async {
    final target = await _path(path);
    if (await FileSystemEntity.type(target) != FileSystemEntityType.notFound) {
      if (!await Directory(target).exists())
        throw StateError('File blocks folder: $path');
      return;
    }
    await Directory(target).create();
  }

  @override
  Future<void> move(String source, String destination, String expected) async {
    final from = await _path(source), to = await _path(destination);
    await _check(source, expected);
    final targetType = await FileSystemEntity.type(to, followLinks: false);
    if (targetType != FileSystemEntityType.notFound &&
        !await FileSystemEntity.identical(from, to)) {
      throw StateError('Rename destination already exists: $destination');
    }
    final directory = await Directory(from).exists();
    Future<void> rename(String a, String b) async {
      if (directory) {
        await Directory(a).rename(b);
      } else {
        await File(a).rename(b);
      }
    }

    // A temporary sibling also handles case-only renames on Windows.
    final temp = '${File(from).parent.path}/.ournet-${randomId()}.move';
    await rename(from, temp);
    try {
      await rename(temp, to);
    } catch (_) {
      await rename(temp, from);
      rethrow;
    }
  }

  @override
  Future<void> remove(String path, String expected) async {
    await _check(path, expected);
    final target = await _path(path);
    if (await Directory(target).exists()) {
      await Directory(
        target,
      ).delete(); // Never recursively remove unknown files.
    } else {
      await File(target).delete();
    }
  }
}

/// Durable baseline per device, never shared as part of the logical drive.
/// One operation at a time bounds plaintext staging and attachment-worker load.
class FolderSync {
  final Files files;
  final FolderBackend Function(String) backend;
  final void Function()? onUpdate;
  final bool _automatic;
  Node get node => files.node;
  final Map<String, String> status = {};
  StreamSubscription<void>? _changes;
  Timer? _timer, _debounce;
  Future<void>? _active;
  bool _closed = false;
  bool _again = false;
  final _watchers = <String, StreamSubscription<void>>{};
  bool get busy => _active != null;
  FolderSync(this.files, this.backend, {this.onUpdate, bool automatic = true})
    : _automatic = automatic {
    if (automatic) {
      _changes = node.onChangesTo(const {'drive'}, schedule);
      _poll();
      schedule();
    }
  }

  bool _background = false;

  /// How often connections are checked for changes no notification reported.
  /// In the background the check slows down to save battery: an Android
  /// folder is rescanned whole each time. Drive changes still sync at once.
  Duration get pollInterval =>
      _background ? const Duration(minutes: 5) : const Duration(seconds: 15);

  /// Whether the app is in the background.
  set background(bool value) {
    if (value == _background) return;
    _background = value;
    if (_timer != null && !_closed) _poll();
    if (!value) schedule();
  }

  void _poll() {
    _timer?.cancel();
    _timer = Timer.periodic(pollInterval, (_) => schedule());
  }

  Map<String, dynamic> get connections => Map<String, dynamic>.from(
    node.store.setting('folder-sync/connections') as Map? ?? {},
  );
  Future<void> connect(String root, String location) async {
    final configs = connections;
    if (configs.containsKey(root))
      throw StateError(
        'Disconnect this folder before choosing another location',
      );
    // A tree cannot have two competing writers, including nested connections.
    String normalize(String location) {
      String decoded;
      try {
        decoded = Uri.decodeFull(location);
      } on ArgumentError {
        decoded = location; // A plain path may hold a literal '%'.
      }
      return decoded
          .replaceAll('\\', '/')
          .toLowerCase()
          .replaceAll(RegExp(r'/+$'), '');
    }

    final normalized = normalize(location);
    for (final config in configs.values) {
      final other = normalize(config['location'] as String);
      if (normalized == other ||
          normalized.startsWith('$other/') ||
          other.startsWith('$normalized/')) {
        throw StateError('This location overlaps another connected folder');
      }
    }
    await backend(
      location,
    ).scan(); // Permission/root failure cannot look empty.
    configs[root] = {'location': location};
    node.store.set('folder-sync/connections', configs);
    schedule();
    onUpdate?.call();
  }

  Future<void> disconnect(String root) async {
    await _active;
    final configs = connections..remove(root);
    node.store.set('folder-sync/connections', configs);
    node.store.removeSettingsUnder('folder-sync/item/$root/');
    await _watchers.remove(root)?.cancel();
    status.remove(root);
    _shown = Map.of(status);
    onUpdate?.call();
  }

  void schedule() {
    if (_closed || !_automatic) return;
    if (_active != null) {
      _again = true;
      return;
    }
    _debounce ??= Timer(const Duration(seconds: 1), () {
      _debounce = null;
      unawaited(_sync(quiet: true));
    });
  }

  /// Checks every connection now, showing that it is checking.
  Future<void> sync() => _sync(quiet: false);

  // Background passes redraw only when what they show changes: the app
  // rebuilds on every update, and most passes find nothing to do.
  Future<void> _sync({required bool quiet}) async {
    if (_closed) return;
    if (_active != null) return _active;
    if (connections.isEmpty) return;
    _active = _run(quiet);
    try {
      await _active;
    } finally {
      _active = null;
      _show();
      if (_again) {
        _again = false;
        schedule();
      }
    }
  }

  Map<String, String> _shown = const {};
  void _show() {
    if (_shown.length == status.length &&
        status.entries.every((e) => _shown[e.key] == e.value))
      return;
    _shown = Map.of(status);
    onUpdate?.call();
  }

  Future<void> _run(bool quiet) async {
    for (final root in connections.keys) {
      if (_closed) return;
      try {
        if (!quiet || status[root] == null) {
          status[root] = 'Checking local changes…';
          _show();
        }
        await _syncRoot(root);
      } catch (e) {
        status[root] = '$e';
      }
    }
  }

  Json _metadata(Json data) => {...data}
    ..remove('chunks')
    ..remove('key')
    ..remove('size');

  Future<void> _syncRoot(String root) async {
    final config = connections[root];
    if (config == null) return;
    final fs = backend(config['location']);
    if (_automatic && !_watchers.containsKey(root)) {
      try {
        _watchers[root] = fs.changes.listen(
          (_) => schedule(),
          onError: (Object _) {
            // Events are only hints; the periodic scan checks availability.
            schedule();
          },
        );
      } catch (_) {
        /* Platforms without recursive watchers use reconciliation. */
      }
    }
    final state = node.store.settingsUnder('folder-sync/item/$root/');
    var local = await fs.scan();
    final entries = await Drive(node).entries();
    final byId = {for (final e in entries) e.current.entry: e};
    final rootEntry = byId[root];
    if (rootEntry == null ||
        rootEntry.conflicted ||
        rootEntry.current.deleted) {
      throw StateError(
        'Connected drive folder is unavailable or conflicted; local files preserved',
      );
    }
    final remote = <String, DriveEntry>{};
    final errors = <String>[];
    void report(String message) {
      if (errors.length < 8) errors.add(message);
    }

    String? pathFor(DriveEntry e, Set<String> seen) {
      if (e.current.entry == root) return '';
      if (!seen.add(e.current.entry)) throw StateError('Folder cycle');
      final parent = byId[e.current.data['folder']];
      if (parent == null) return null;
      final prefix = pathFor(parent, seen);
      if (prefix == null) return null;
      final name = e.current.data['name'] as String;
      // A name this device cannot write leaves that one entry in the drive,
      // rather than stopping the whole folder from syncing.
      if (!safeFolderPath(name) || name.contains('/')) {
        report('Unsupported drive filename: $name');
        return null;
      }
      return prefix.isEmpty ? name : '$prefix/$name';
    }

    final folded = <String>{};
    for (final entry in entries) {
      final path = pathFor(entry, {});
      if (path == null || path.isEmpty) continue;
      // Retained tombstones can share a path with a later new entry.
      if (entry.current.deleted && !state.containsKey(entry.current.entry))
        continue;
      if (!folded.add(path.toLowerCase())) {
        report('Name collision: $path; resolve in drive history');
        continue;
      }
      remote[path] = entry;
    }
    final synced = {for (final v in state.values) v['path'] as String};
    final unsupported = local.keys
        .where((p) => !safeFolderPath(p) || local[p]!.token == FolderItem.link)
        .toSet();
    for (final path in unsupported) {
      final problem = local[path]!.token == FolderItem.link
          ? 'Linked file or folder is not synced'
          : 'Unsupported local filename';
      // A name that was never synced is left out of this pass. One that was
      // would look deleted here, so it still needs a person to resolve it.
      if (synced.contains(path)) throw StateError('$problem: $path');
      report('$problem: $path');
    }
    if (unsupported.isNotEmpty)
      local = {
        for (final e in local.entries)
          if (!unsupported.contains(e.key)) e.key: e.value,
      };
    final localFolded = <String>{};
    if (local.keys.any((p) => !localFolded.add(p.toLowerCase())))
      throw StateError('Local names differ only by case');
    var conflicts = 0;
    final stage = await Directory.systemTemp.createTemp('ournet-folder-');
    void persist(String id) {
      node.store.set('folder-sync/item/$root/$id', state[id]);
    }

    void record(
      String id,
      String path,
      String revision,
      bool directory,
      FolderItem current,
    ) {
      state[id] = {
        'path': path,
        'revision': revision,
        'token': current.token,
        'directory': directory,
      };
      persist(id);
    }

    final drive = Drive(node);
    // Publishes [data] after [parents]: the local file at [path] for files,
    // a metadata-only revision for folders and deletions. Returns its revision.
    Future<String> revise(
      Json data,
      List<String> parents,
      String path,
      FolderItem? item,
    ) async {
      // A folder's list of entries deleted with it belongs to that deletion.
      data = {...data};
      if (data['deleted'] != true || data['removed'] is! List)
        data.remove('removed');
      final SignedObject object;
      if (item == null || item.directory) {
        object = await drive.write(data, parents: parents);
      } else {
        if (item.size > Files.maxSize)
          throw StateError('$path exceeds the 64 MiB file limit');
        final input = '${stage.path}/input';
        await fs.readTo(path, input, item.token);
        object = await files.publish(
          input,
          audience: [node.person],
          name: data['name'],
          drive: {
            ..._metadata(data),
            'revision': randomId(),
            'parents': parents,
          },
        );
      }
      return (await node.content(object))!['revision'];
    }

    // Whether the local file at [path] holds exactly the bytes of the drive
    // file [v]. Sizes are compared first; equal sizes compare the contents.
    // Reading checks [item]'s token before and after, so an edit made during
    // the comparison fails this pass rather than being adopted unseen.
    Future<bool> sameFile(String path, FolderItem item, DriveVersion v) async {
      if (v.data['size'] != item.size) return false;
      final mine = '${stage.path}/local', theirs = '${stage.path}/remote';
      await files.save(v.object, theirs);
      await fs.readTo(path, mine, item.token);
      final a = await File(mine).open(), b = await File(theirs).open();
      try {
        while (true) {
          final x = await a.read(Files.chunkSize);
          final y = await b.read(Files.chunkSize);
          if (x.length != y.length) return false;
          if (x.isEmpty) return true;
          for (var i = 0; i < x.length; i++) {
            if (x[i] != y[i]) return false;
          }
        }
      } finally {
        await a.close();
        await b.close();
      }
    }

    try {
      // Apply drive moves parent-first. Moving a directory carries unknown
      // local children too; their edits retain their original baseline tokens.
      final relocated =
          remote.entries
              .where(
                (e) =>
                    state[e.value.current.entry] != null &&
                    state[e.value.current.entry]['path'] != e.key,
              )
              .toList()
            ..sort(
              (a, b) =>
                  a.key.split('/').length.compareTo(b.key.split('/').length),
            );
      for (final moved in relocated) {
        final entry = moved.value, base = state[moved.value.current.entry];
        if (entry.conflicted || base['path'] == moved.key) continue;
        final oldPath = base['path'] as String;
        final old = local[oldPath];
        if (old?.token != base['token'] || old == null) continue;
        try {
          await fs.move(oldPath, moved.key, old.token);
          final after = await fs.scan();
          for (final id in state.keys.toList()) {
            final item = state[id];
            final path = item['path'] as String;
            if (path != oldPath &&
                !(old.directory && path.startsWith('$oldPath/')))
              continue;
            final next = '${moved.key}${path.substring(oldPath.length)}';
            final unchanged = local[path]?.token == item['token'];
            state[id] = {
              ...item,
              'path': next,
              if (unchanged &&
                  path == oldPath &&
                  after[next] != null &&
                  (old.directory ||
                      (old.contentStamp ?? old.token) ==
                          (after[next]!.contentStamp ?? after[next]!.token)))
                'token': after[next]!.token,
            };
            persist(id);
          }
          local = after;
        } catch (e) {
          report('$oldPath → ${moved.key}: $e');
        }
      }
      final mappedPaths = {
        for (final value in state.values) value['path'] as String,
      };
      // A folder deletion concurrent with an added/edited descendant is a
      // folder conflict, not permission to hide or remove the descendant.
      final baselineByPath = {
        for (final item in state.values) item['path'] as String: item,
      };
      // A folder deleted elsewhere lists the entries deleted with it
      // ('removed'). Records travel in pages, newest first, so the folder's
      // deletion can arrive before its children's: an unchanged child it
      // lists is on its way out, not a concurrent addition.
      int byDepth(String a, String b) {
        final d = a.split('/').length.compareTo(b.split('/').length);
        return d == 0 ? a.compareTo(b) : d;
      }

      final departing = <String>{};
      for (final path in local.keys.toList()..sort(byDepth)) {
        final entry = remote[path], base = baselineByPath[path];
        if (!path.contains('/') ||
            entry == null ||
            base == null ||
            entry.conflicted ||
            entry.current.deleted ||
            base['token'] != local[path]!.token ||
            base['revision'] != entry.current.data['revision'])
          continue;
        final parentPath = path.substring(0, path.lastIndexOf('/'));
        final parent = remote[parentPath];
        if (departing.contains(parentPath) ||
            (parent != null &&
                !parent.conflicted &&
                parent.current.deleted &&
                (parent.current.data['removed'] as List?)?.contains(
                      entry.current.entry,
                    ) ==
                    true))
          departing.add(path);
      }
      final waiting = {
        for (final path in departing) path.substring(0, path.lastIndexOf('/')),
      };
      final dirtyParents = <String>{};
      for (final item in local.entries) {
        if (departing.contains(item.key)) continue;
        final liveRemoteChild =
            remote[item.key]?.heads.any((v) => !v.deleted) ?? false;
        if (baselineByPath[item.key]?['token'] == item.value.token &&
            !liveRemoteChild)
          continue;
        var parent = item.key;
        while (parent.contains('/')) {
          parent = parent.substring(0, parent.lastIndexOf('/'));
          dirtyParents.add(parent);
        }
      }
      for (final path in dirtyParents) {
        final entry = remote[path];
        if (entry == null ||
            entry.conflicted ||
            !entry.current.deleted ||
            !entry.current.isFolder ||
            local[path]?.directory != true)
          continue;
        final base = state[entry.current.entry];
        if (base == null) continue;
        final object = await drive.write(
          {...entry.current.data, 'deleted': false},
          parents: [base['revision'] as String],
        );
        final version = DriveVersion(object, (await node.content(object))!);
        state[version.entry] = {
          ...base,
          'revision': version.data['revision'],
          'token': local[path]!.token,
        };
        persist(version.entry);
        remote[path] = DriveEntry(entry.history, [version, ...entry.heads]);
      }
      // Local additions are processed parent-first, including empty directories.
      final paths = {...local.keys, ...remote.keys}.toList()..sort(byDepth);
      // Entries deleted here this pass, by parent path, so a folder deleted
      // with them can list them.
      final removedUnder = <String, List<String>>{};
      for (final e in remote.entries) {
        final base = state[e.value.current.entry];
        if (!e.key.contains('/') ||
            local.containsKey(e.key) ||
            base == null ||
            base['path'] != e.key ||
            base['token'] == null)
          continue;
        (removedUnder[e.key.substring(0, e.key.lastIndexOf('/'))] ??= []).add(
          e.value.current.entry,
        );
      }
      final folderIds = <String, String>{
        '': root,
        // A concurrent new child follows its parent's stable identity even
        // when that parent has moved outside this device's connected subtree.
        for (final item in state.entries)
          if (item.value['directory'] == true &&
              byId[item.key]?.current.isFolder == true &&
              byId[item.key]?.current.deleted == false)
            item.value['path'] as String: item.key,
      };
      for (final path in paths) {
        if (_closed) return;
        try {
          final existing = remote[path];
          if (existing?.current.isFolder == true)
            folderIds[path] = existing!.current.entry;
          final item = local[path];
          if (existing == null && item != null) {
            // A remote rename/move must not cause an old mapped path to be
            // imported as a new unrelated entry.
            if (mappedPaths.contains(path)) {
              conflicts++;
              continue;
            }
            final parentPath = path.contains('/')
                ? path.substring(0, path.lastIndexOf('/'))
                : '';
            final parent = folderIds[parentPath];
            if (parent == null) {
              conflicts++;
              continue;
            }
            final data = <String, dynamic>{
              'entry': randomId(),
              'folder': parent,
              'name': path.split('/').last,
              'type': item.directory ? 'folder' : 'file',
              'deleted': false,
            };
            // Preserve the snapshot token, not a newer edit made during import.
            record(
              data['entry'],
              path,
              await revise(data, const [], path, item),
              item.directory,
              item,
            );
            if (item.directory) folderIds[path] = data['entry'];
            continue;
          }
          if (existing == null) continue;
          final v = existing.current;
          final base = state[v.entry];
          if (base != null && base['path'] != path) {
            // A local edit/deletion concurrent with a move gets its own branch,
            // based on the revision/path actually present on this device.
            final oldPath = base['path'] as String;
            final old = local[oldPath];
            if (old?.token != base['token']) {
              final ancestor = existing.history
                  .where((h) => h.data['revision'] == base['revision'])
                  .firstOrNull;
              if (ancestor == null)
                throw StateError('Local revision is unavailable');
              state[v.entry] = {
                ...base,
                'revision': await revise(
                  {...ancestor.data, 'deleted': old == null},
                  [base['revision'] as String],
                  oldPath,
                  old,
                ),
                'token': old?.token,
              };
              persist(v.entry);
            }
            conflicts++;
            continue;
          }
          final changed = base != null && item?.token != base['token'];
          if (changed) {
            if (item != null && item.directory != v.isFolder) {
              conflicts++;
              continue;
            }
            final baseRevision = base['revision'] as String;
            final removed = removedUnder[path];
            state[v.entry] = {
              'path': path,
              'revision': await revise(
                {
                  ...v.data,
                  'deleted': item == null,
                  // Bounded: a longer list only costs the early arrival case.
                  if (item == null &&
                      v.isFolder &&
                      removed != null &&
                      removed.length <= 1000)
                    'removed': removed,
                },
                [baseRevision],
                path,
                item,
              ),
              'token': item?.token,
              'directory': v.isFolder,
            };
            persist(v.entry);
            if (existing.conflicted || v.data['revision'] != baseRevision)
              conflicts++;
            continue;
          }
          if (existing.conflicted) {
            conflicts++;
            continue;
          }
          if (base?['revision'] == v.data['revision']) continue;
          if (base == null && item != null && !(item.directory && v.isFolder)) {
            // Initial nonempty destination: retain its contents as a concurrent
            // revision. No timestamp winner and no first-sync overwrite.
            if (item.directory != v.isFolder) {
              conflicts++;
              continue;
            }
            // An identical file adopts the drive's revision instead: no
            // rival head and no upload.
            if (!v.deleted && await sameFile(path, item, v)) {
              record(v.entry, path, v.data['revision'], false, item);
              continue;
            }
            record(
              v.entry,
              path,
              await revise({...v.data, 'deleted': false}, const [], path, item),
              false,
              item,
            );
            conflicts++;
            continue;
          }
          if (v.deleted) continue; // Delete leaves last, after children.
          status[root] = 'Syncing $path';
          _show();
          FolderItem written;
          if (v.isFolder) {
            await fs.mkdir(path);
            written = const FolderItem(true, 'directory');
          } else {
            final output = '${stage.path}/output';
            await files.save(v.object, output);
            written = await fs.put(path, output, item?.token);
          }
          record(v.entry, path, v.data['revision'], v.isFolder, written);
        } catch (e) {
          report('$path: $e');
        }
      }
      for (final path in paths.reversed) {
        try {
          final entry = remote[path];
          if (entry == null || entry.conflicted || !entry.current.deleted)
            continue;
          final v = entry.current, base = state[v.entry];
          if (base == null ||
              base['revision'] == v.data['revision'] ||
              base['path'] != path)
            continue;
          final item = local[path];
          if (item?.token != base['token']) continue;
          // Its children's deletions have not arrived yet.
          if (waiting.contains(path)) continue;
          if (item != null) await fs.remove(path, item.token);
          state[v.entry] = {
            'path': path,
            'revision': v.data['revision'],
            'token': null,
            'directory': v.isFolder,
          };
          persist(v.entry);
        } catch (e) {
          report('$path: $e');
        }
      }
      final remoteIds = {for (final e in remote.values) e.current.entry};
      final departed =
          state.keys
              .where((id) => !remoteIds.contains(id) && byId.containsKey(id))
              .toList()
            ..sort(
              (a, b) => (state[b]['path'] as String).length.compareTo(
                (state[a]['path'] as String).length,
              ),
            );
      for (final id in departed) {
        final entry = byId[id]!;
        if (entry.conflicted) {
          conflicts++;
          continue;
        }
        final base = state[id], path = state[id]['path'] as String;
        final item = local[path];
        if (item?.token != base['token']) {
          // Do not discard edits when a file was moved out of this subtree.
          // The user can resolve the location/content conflict in drive history.
          final ancestor = entry.history
              .where((h) => h.data['revision'] == base['revision'])
              .firstOrNull;
          if (ancestor == null) {
            conflicts++;
            continue;
          }
          try {
            state[id] = {
              ...base,
              'revision': await revise(
                {...ancestor.data, 'deleted': item == null},
                [base['revision'] as String],
                path,
                item,
              ),
              'token': item?.token,
            };
            persist(id);
            conflicts++;
          } catch (e) {
            report('$path: $e');
          }
          continue;
        }
        try {
          if (item != null) await fs.remove(path, item.token);
          state[id] = {...base, 'token': null};
          persist(id);
        } catch (e) {
          report('$path: $e');
        }
      }
      status[root] = errors.isNotEmpty
          ? errors.join('\n')
          : conflicts == 0
          ? 'Local folder up to date · peer delivery depends on connection'
          : '$conflicts conflicts · local files preserved; resolve in drive history';
    } finally {
      // Only this newly created staging directory is ever recursively removed.
      await stage.delete(recursive: true);
    }
  }

  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    _debounce?.cancel();
    await _changes?.cancel();
    await _active;
    for (final watcher in _watchers.values) {
      await watcher.cancel();
    }
    _watchers.clear();
  }
}
