import 'dart:async';
import 'dart:math';
import 'dart:io';
import 'dart:typed_data';
import 'package:ournet_core/ournet_core.dart';
import 'files.dart';
import 'first_sync.dart';

/// A provider token changes when a local file changes. Directory tokens must
/// stay stable when their children change. All paths are relative and portable.
class FolderItem {
  final bool directory;
  final String token;
  final int size;
  // Ignores metadata changes caused solely by a rename (e.g. Unix ctime).
  final String? contentStamp;

  /// When the file last changed, where the provider reports it. For display.
  final DateTime? modified;
  const FolderItem(
    this.directory,
    this.token, [
    this.size = 0,
    this.contentStamp,
    this.modified,
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

  /// The bytes of file [path] from [offset], checking before and after
  /// reading that its token is still [expected]: an edit during the read
  /// fails it.
  Stream<List<int>> read(String path, String expected, {int offset = 0});

  /// Writes [data] to a temporary file beside [path], then replaces [path]
  /// with it only if [path]'s token is still [expected] (null: absent).
  Future<FolderItem> write(
    String path,
    Stream<List<int>> data,
    String? expected,
  );

  /// [length] bytes of file [path] from [offset], only while its content
  /// stamp (or token) is still [expected]; throws otherwise.
  Future<Uint8List> readRange(
    String path,
    int offset,
    int length,
    String expected,
  );
  Future<void> mkdir(String path);
  Future<void> move(String source, String destination, String expected);
  Future<void> remove(String path, String expected);

  /// Moves [path] out of the synced tree, keeping it, and returns where it
  /// went. Moved entries never sync again.
  Future<String> setAside(String path, String expected);
}

/// Why a large file waits: the app allows large transfers only in the
/// foreground and while charging, unless the person allows them always.
const waitingForPower =
    'Large file waits for charging with OurNet open (allow it in Files)';

/// The name of the folder, inside a synced folder, that holds entries set
/// aside where its parent cannot be reached. Names starting `.ournet-` are
/// never synced.
const notSyncedFolder = '.ournet-not-synced';

/// [e]'s path below drive folder [root]: empty for the root itself, null
/// outside it or where this device cannot write a name on the way.
String? _drivePath(
  String root,
  Map<String, DriveEntry> byId,
  DriveEntry e,
  Set<String> seen,
  void Function(String) report,
) {
  if (e.current.entry == root) return '';
  if (!seen.add(e.current.entry)) throw StateError('Folder cycle');
  final parent = byId[e.current.data['folder']];
  if (parent == null) return null;
  final prefix = _drivePath(root, byId, parent, seen, report);
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

/// Parents before children, then by name.
int _byDepth(String a, String b) {
  final d = a.split('/').length.compareTo(b.split('/').length);
  return d == 0 ? a.compareTo(b) : d;
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

  /// When the selected root and its ancestors were last checked. They are
  /// checked again a little later, not for every file: a sync pass touches
  /// thousands of files, and each check is several system calls.
  DateTime? _rootChecked;
  static const _rootRecheck = Duration(seconds: 2);

  Future<String> _path(String path) async {
    if (path.isNotEmpty && !safeFolderPath(path))
      throw StateError('Unsupported filename: $path');
    var current = Directory(location).absolute.path;
    final checked = _rootChecked;
    if (checked == null || DateTime.now().difference(checked) > _rootRecheck) {
      // Check every ancestor as well as descendants: an existing parent
      // junction must not redirect an operation outside the selected tree.
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
      _rootChecked = DateTime.now();
    }
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
      stat.modified,
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
    // A pass starts with a scan: the root is checked afresh for it.
    _rootChecked = null;
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
  Stream<List<int>> read(
    String path,
    String expected, {
    int offset = 0,
  }) async* {
    // Resolved and checked once; the token is compared before and after.
    final target = await _path(path);
    Future<void> check() async {
      if (_item(await FileStat.stat(target), path)?.token != expected)
        throw StateError(
          'File changed during sync: $path; retrying preserves your edit',
        );
    }

    await check();
    yield* File(target).openRead(offset);
    await check();
  }

  @override
  Future<FolderItem> write(
    String path,
    Stream<List<int>> data,
    String? expected,
  ) async {
    final target = await _path(path);
    final temp = File('${File(target).parent.path}/.ournet-${randomId()}.part');
    try {
      final output = temp.openWrite();
      try {
        await output.addStream(data);
      } finally {
        await output.close();
      }
      await _check(path, expected);
      await temp.rename(target);
      return (await stat(path))!;
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  @override
  Future<Uint8List> readRange(
    String path,
    int offset,
    int length,
    String expected,
  ) async {
    Future<void> check() async {
      final item = await stat(path);
      if (item == null || (item.contentStamp ?? item.token) != expected) {
        throw StateError('File changed: $path');
      }
    }

    await check();
    final file = await File(await _path(path)).open();
    try {
      await file.setPosition(offset);
      final bytes = await file.read(length);
      if (bytes.length != length) throw StateError('File changed: $path');
      await check();
      return bytes;
    } finally {
      await file.close();
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

  /// Into a sibling "<folder> (not synced)" folder, keeping the path below it,
  /// or into [notSyncedFolder] inside a folder with no parent.
  @override
  Future<String> setAside(String path, String expected) async {
    final source = await _path(path);
    final root = Directory(location).absolute;
    final aside = root.parent.path == root.path
        ? '${root.path}${Platform.pathSeparator}$notSyncedFolder'
        : '${root.path.replaceAll(RegExp(r'[\/]+$'), '')} (not synced)';
    final parts = path.split('/');
    final parent = Directory(
      [aside, ...parts.take(parts.length - 1)].join(Platform.pathSeparator),
    );
    await parent.create(recursive: true);
    var target = '${parent.path}${Platform.pathSeparator}${parts.last}';
    for (
      var n = 2;
      await FileSystemEntity.type(target) != FileSystemEntityType.notFound;
      n++
    ) {
      final dot = parts.last.lastIndexOf('.');
      final name = dot > 0
          ? '${parts.last.substring(0, dot)} ($n)${parts.last.substring(dot)}'
          : '${parts.last} ($n)';
      target = '${parent.path}${Platform.pathSeparator}$name';
    }
    await _check(path, expected);
    if (await Directory(source).exists()) {
      await Directory(source).rename(target);
    } else {
      await File(source).rename(target);
    }
    return aside;
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
    files.network.chunkSource = _chunkFromFolder;
    if (automatic) {
      _changes = node.onChangesTo(const {'drive'}, schedule);
      _poll();
      schedule();
    }
  }

  bool _background = false;

  /// Chunk [hash] of [object] made again from the synced file holding its
  /// plaintext, checked against the hash; null when no folder holds it as
  /// it was. A file changed or gone since is forgotten as a source.
  Future<List<int>?> _chunkFromFolder(SignedObject object, String hash) async {
    final source = node.store.chunkSource(hash);
    if (source == null) return null;
    final config = connections[source.root];
    final payload = await node.content(object);
    if (config == null || payload == null) return null;
    try {
      final plain = await backend(
        config['location'] as String,
      ).readRange(source.path, source.offset, source.length, source.token);
      final key = payload['key'] == null ? null : unb64(payload['key']);
      final sealed = await node.blobs.seal(plain, key);
      return blobHash(sealed) == hash ? sealed : null;
    } catch (_) {
      node.store.forgetChunkSources(source.root, source.path);
      return null;
    }
  }

  /// How often connections are checked for changes no notification reported.
  /// In the background the check slows down to save battery: an Android
  /// folder is rescanned whole each time. Drive changes still sync at once.
  Duration get pollInterval =>
      _background ? const Duration(minutes: 5) : const Duration(seconds: 15);

  /// Whether the app is in the background.
  /// Files added to the drive at once in a pass.
  static const concurrentAdds = 4;

  bool get background => _background;
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

  /// What connecting [location] to drive folder [root] would find, path by
  /// path, without writing to either side. Sizes and drive history decide
  /// the kinds; nothing is downloaded.
  Future<FirstSyncPlan> plan(String root, String location) async {
    final problems = <String>[];
    void report(String message) {
      if (problems.length < 8) problems.add(message);
    }

    final local = <String, FolderItem>{};
    final folded = <String>{};
    for (final e in (await backend(location).scan()).entries) {
      if (e.value.token == FolderItem.link) {
        report('Linked file or folder is not synced: ${e.key}');
      } else if (!safeFolderPath(e.key)) {
        report('Unsupported local filename: ${e.key}');
      } else if (!folded.add(e.key.toLowerCase())) {
        report('Local names differ only by case: ${e.key}');
      } else {
        local[e.key] = e.value;
      }
    }
    final entries = await Drive(node).entries();
    final byId = {for (final e in entries) e.current.entry: e};
    final live = <String, DriveEntry>{}, deleted = <String, DriveEntry>{};
    folded.clear();
    for (final entry in entries) {
      final String? path;
      try {
        path = _drivePath(root, byId, entry, {}, report);
      } on StateError catch (e) {
        report('$e');
        continue;
      }
      if (path == null || path.isEmpty) continue;
      if (entry.current.deleted) {
        if (!entry.conflicted) deleted[path] ??= entry;
      } else if (!folded.add(path.toLowerCase())) {
        report('Name collision: $path; resolve in drive history');
      } else {
        live[path] = entry;
      }
    }
    final items = <FirstSyncItem>[];
    for (final path in {...local.keys, ...live.keys}.toList()..sort(_byDepth)) {
      final item = local[path], entry = live[path];
      if (entry == null) {
        final gone = deleted[path];
        final match =
            gone != null &&
            gone.history.any(
              (h) =>
                  !h.deleted &&
                  h.isFolder == item!.directory &&
                  (item.directory || h.data['size'] == item.size),
            );
        items.add(
          FirstSyncItem(
            path,
            match ? .deletedElsewhere : .onlyHere,
            local: item,
            drive: match ? gone.current : null,
          ),
        );
        continue;
      }
      final v = entry.current;
      final FirstSyncKind kind;
      if (entry.conflicted) {
        kind = .driveConflict;
      } else if (item == null) {
        kind = .onlyDrive;
      } else if (item.directory != v.isFolder) {
        kind = .clash;
      } else if (item.directory || v.data['size'] == item.size) {
        kind = .identical;
      } else if (entry.history.any(
        (h) =>
            !h.deleted &&
            !h.isFolder &&
            h.data['size'] == item.size &&
            h.data['revision'] != v.data['revision'],
      )) {
        kind = .staleHere;
      } else {
        kind = .differs;
      }
      items.add(FirstSyncItem(path, kind, local: item, drive: v));
    }
    return FirstSyncPlan(root, location, items, problems);
  }

  /// [decisions] are first-sync choices from [FirstSyncPlan.decisions]. They
  /// apply only to paths that have never synced, until the first pass that
  /// completes them.
  Future<void> connect(
    String root,
    String location, {
    Map<String, Json> decisions = const {},
  }) async {
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
    configs[root] = {
      'location': location,
      if (decisions.isNotEmpty) 'firstSync': decisions,
    };
    node.store.set('folder-sync/connections', configs);
    schedule();
    onUpdate?.call();
  }

  Future<void> disconnect(String root) async {
    await _active;
    final configs = connections..remove(root);
    node.store.set('folder-sync/connections', configs);
    node.store.removeSettingsUnder('folder-sync/item/$root/');
    node.store.forgetFolderSources(root);
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
    ..remove('chunkTree')
    ..remove('chunkDepth')
    ..remove('chunkBytes')
    ..remove('nonces')
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

    String? pathFor(DriveEntry e, Set<String> seen) =>
        _drivePath(root, byId, e, seen, report);

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

    // A synced file's chunks are made again from the folder when asked for,
    // so this device keeps no copy of them: where each lies is recorded.
    void sourced(String path, FolderItem item, List<(String, int, int)> seen) {
      if (seen.isEmpty) return;
      node.store.recordChunkSources(
        root,
        path,
        item.contentStamp ?? item.token,
        seen,
      );
    }

    final drive = Drive(node);
    // Publishes [data] after [parents]: the local file at [path] for files,
    // a metadata-only revision for folders and deletions. Returns its revision.
    //
    // A synced file keeps no copy of its chunks here: they are made again
    // from the folder. [keepData] keeps them for a copy the folder may not
    // hold for long: a conflicting revision, or a local file about to be
    // replaced by the drive's.
    Future<String> revise(
      Json data,
      List<String> parents,
      String path,
      FolderItem? item, {
      bool keepData = false,
    }) async {
      // A folder's list of entries deleted with it belongs to that deletion.
      data = {...data};
      if (data['deleted'] != true || data['removed'] is! List)
        data.remove('removed');
      final SignedObject object;
      if (item == null || item.directory) {
        object = await drive.write(data, parents: parents);
      } else {
        // Encrypted straight from the folder; the read fails if the file
        // changes meanwhile.
        final seen = <(String, int, int)>[];
        if (!await Files.mayTransfer(item.size)) {
          throw StateError(waitingForPower);
        }
        object = await files.publishFrom(
          (offset) => fs.read(path, item.token, offset: offset),
          // An interrupted import of a large file carries on while the
          // file is unchanged.
          journal: 'folder:$root/$path',
          fingerprint: item.token,
          size: item.size,
          audience: [node.person],
          name: data['name'],
          drive: {
            ..._metadata(data),
            'revision': randomId(),
            'parents': parents,
          },
          onChunk: (hash, offset, length) => seen.add((hash, offset, length)),
          keepData: keepData,
        );
        sourced(path, item, seen);
      }
      return (await node.content(object))!['revision'];
    }

    // Whether the local file at [path] holds exactly the bytes of the drive
    // file [v]. Sizes are compared first; equal sizes compare the contents,
    // streamed side by side. Reading checks [item]'s token before and after,
    // so an edit made during the comparison fails this pass rather than
    // being adopted unseen.
    // A drive file whose chunk nonces come from its key and plaintext is
    // compared by sealing the local file with that key: the same chunk
    // names mean the same bytes, and nothing is fetched. Older ones are
    // fetched and compared byte for byte.
    Future<bool> sameFile(
      String path,
      FolderItem item,
      DriveVersion v, {
      ChunkSeen? onChunk,
    }) async {
      if (v.deleted || v.isFolder || v.data['size'] != item.size) return false;
      if (v.data['nonces'] == 'derived') {
        return files.sealsTo(
          fs.read(path, item.token),
          v.object,
          onChunk: onChunk,
        );
      }
      return sameBytes(fs.read(path, item.token), files.open(v.object));
    }

    // An earlier revision of [entry] the local file matches byte for byte:
    // the drive copy is newer, so this device fast-forwards to it. Checks the
    // newest few of the same size; one that cannot be fetched is no match.
    Future<String?> earlierFile(
      String path,
      FolderItem item,
      DriveEntry entry,
    ) async {
      final current = entry.current.data['revision'];
      final candidates =
          entry.history
              .where(
                (h) =>
                    !h.deleted &&
                    !h.isFolder &&
                    h.data['size'] == item.size &&
                    h.data['revision'] != current,
              )
              .toList()
            ..sort((a, b) => b.object.created.compareTo(a.object.created));
      for (final h in candidates.take(4)) {
        try {
          if (await sameFile(path, item, h)) return h.data['revision'];
        } on StateError catch (e) {
          if ('$e'.contains('changed during sync')) rethrow;
        }
      }
      return null;
    }

    // First-sync choices made when connecting. Each applies only to a path
    // that has never synced, and only while the entry is as it was when the
    // choice was made; otherwise both copies are kept, as without a choice.
    final first = {
      for (final e in ((config['firstSync'] as Map?) ?? const {}).entries)
        e.key as String: Map<String, dynamic>.from(e.value as Map),
    };
    final retry = <String>{}; // Choices to try again next pass.
    FirstSyncChoice keep(String path, FolderItem? item, DriveVersion? v) {
      final chosen = first[path];
      if (chosen == null ||
          synced.contains(path) ||
          chosen['token'] != item?.token ||
          chosen['revision'] != v?.data['revision'])
        return FirstSyncChoice.both;
      return FirstSyncChoice.values.byName(chosen['keep'] as String);
    }

    // Downloads [v] over the local [item] and records it as [revision].
    Future<void> fetch(
      String path,
      DriveVersion v,
      FolderItem? item,
      String revision,
    ) async {
      status[root] = 'Syncing $path';
      _show();
      FolderItem written;
      if (v.isFolder) {
        await fs.mkdir(path);
        written = const FolderItem(true, 'directory');
      } else {
        // Decrypted straight into a temporary file beside [path], once
        // there is room for it and its encrypted chunks.
        files.checkRoomFor(
          v.data,
          destination: fs.location.startsWith('content:') ? null : fs.location,
        );
        if (!await Files.mayTransfer(v.data['size'] as int)) {
          throw StateError(waitingForPower);
        }
        final seen = <(String, int, int)>[];
        written = await fs.write(
          path,
          files.open(
            v.object,
            onChunk: (hash, offset, length) => seen.add((hash, offset, length)),
            keepData: false,
          ),
          item?.token,
        );
        sourced(path, written, seen);
      }
      record(v.entry, path, revision, v.isFolder, written);
    }

    // Deletes [v] from the drive for a first-sync choice; restorable from
    // drive history. A folder lists the entries deleted with it.
    final removedHere = <String, List<String>>{};
    Future<void> deleteFromDrive(String path, DriveVersion v) async {
      final removed = removedHere[path];
      final revision = await revise(
        {
          ...v.data,
          'deleted': true,
          if (removed != null && removed.length <= 1000) 'removed': removed,
        },
        [v.data['revision'] as String],
        path,
        null,
      );
      state[v.entry] = {
        'path': path,
        'revision': revision,
        'token': null,
        'directory': v.isFolder,
      };
      persist(v.entry);
      if (path.contains('/'))
        (removedHere[path.substring(0, path.lastIndexOf('/'))] ??= []).add(
          v.entry,
        );
    }

    var setAside = 0;
    String? asideIn;
    // First-sync choices for the drive's copy: local entries it lacks (or
    // has as the other kind) move aside, parent-first. A folder moves whole
    // only when everything in it goes too.
    if (first.isNotEmpty) {
      bool goes(String path) {
        final chosen = first[path], item = local[path];
        return chosen != null &&
            item != null &&
            chosen['keep'] == FirstSyncChoice.drive.name &&
            chosen['token'] == item.token &&
            !synced.contains(path);
      }

      final moved = <String>[];
      for (final path in local.keys.toList()..sort(_byDepth)) {
        if (!goes(path) || moved.any((m) => path.startsWith('$m/'))) continue;
        final item = local[path]!, entry = remote[path];
        final clash =
            entry != null &&
            !entry.current.deleted &&
            entry.current.isFolder != item.directory;
        if (entry != null && !clash) continue;
        if (item.directory &&
            !clash &&
            local.keys.any((p) => p.startsWith('$path/') && !goes(p)))
          continue;
        try {
          asideIn = await fs.setAside(path, item.token);
          node.store.forgetChunkSources(root, path);
          moved.add(path);
          setAside++;
        } catch (e) {
          retry.add(path);
          report('$path: $e');
        }
      }
      if (moved.isNotEmpty)
        local = {
          for (final e in (await fs.scan()).entries)
            if (local.containsKey(e.key)) e.key: e.value,
        };
    }
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
        node.store.moveChunkSources(root, oldPath, moved.key);
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
    final departing = <String>{};
    for (final path in local.keys.toList()..sort(_byDepth)) {
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
    final paths = {...local.keys, ...remote.keys}.toList()..sort(_byDepth);
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
    // First-sync choices for this folder's copy: drive entries it lacks are
    // deleted from the drive, a folder only when everything in it goes too.
    // Files go in this loop; folders after it, deepest first.
    final deleting = <String>{};
    for (final path in remote.keys.toList()..sort((a, b) => _byDepth(b, a))) {
      final entry = remote[path]!, v = entry.current;
      if (local.containsKey(path) ||
          entry.conflicted ||
          v.deleted ||
          state[v.entry] != null ||
          keep(path, null, v) != FirstSyncChoice.here)
        continue;
      if (v.isFolder &&
          remote.entries.any(
            (e) =>
                e.key.startsWith('$path/') &&
                !e.value.current.deleted &&
                !deleting.contains(e.key),
          ))
        continue;
      deleting.add(path);
    }
    // What the pass is doing, shown a few times a second at most: every
    // update redraws the app.
    var shownAt = DateTime.fromMillisecondsSinceEpoch(0);
    void progress(String text) {
      status[root] = text;
      final now = DateTime.now();
      if (now.difference(shownAt) < const Duration(milliseconds: 250)) return;
      shownAt = now;
      _show();
    }

    // Files on both sides that have never synced: those the drive copy
    // matches, found a few at once (by sealing, for most, so nothing is
    // fetched), with where each chunk lies in the folder.
    final identicals = <String, List<(String, int, int)>>{};
    final checked = <String>{};
    final candidates = [
      for (final path in paths)
        if (local[path] case final item?
            when !item.directory &&
                remote[path] != null &&
                !remote[path]!.conflicted &&
                !remote[path]!.current.deleted &&
                !remote[path]!.current.isFolder &&
                remote[path]!.current.data['size'] == item.size &&
                state[remote[path]!.current.entry] == null)
          path,
    ];
    final checking = <Future<void>>[];
    for (final (i, path) in candidates.indexed) {
      if (_closed) break;
      checking.add(() async {
        final item = local[path]!, v = remote[path]!.current;
        final seen = <(String, int, int)>[];
        try {
          progress('Comparing $path · ${i + 1} of ${candidates.length}');
          if (await sameFile(
            path,
            item,
            v,
            onChunk: (hash, offset, length) => seen.add((hash, offset, length)),
          )) {
            identicals[path] = seen;
          }
          checked.add(path);
        } catch (_) {
          /* Checked again, alone, in the pass below. */
        }
      }());
      if (checking.length >= concurrentAdds) await checking.removeAt(0);
    }
    await Future.wait(checking);

    // Files only here, added a few at once with their progress shown.
    final adding = <Future<void>>[];
    var added = 0;
    final toAdd = paths
        .where(
          (p) =>
              remote[p] == null &&
              local[p] != null &&
              !local[p]!.directory &&
              !mappedPaths.contains(p),
        )
        .length;
    for (final path in paths) {
      if (_closed) {
        await Future.wait(adding);
        return;
      }
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
          if (item.directory) {
            record(
              data['entry'],
              path,
              await revise(data, const [], path, item),
              true,
              item,
            );
            folderIds[path] = data['entry'];
            continue;
          }
          // Files are added a few at once; their folders already exist.
          final number = ++added;
          adding.add(() async {
            try {
              progress('Adding $path · $number of $toAdd');
              // Preserve the snapshot token, not a newer edit made during
              // import.
              record(
                data['entry'],
                path,
                await revise(data, const [], path, item),
                false,
                item,
              );
            } catch (e) {
              retry.add(path);
              report('$path: $e');
            }
          }());
          if (adding.length >= concurrentAdds) await adding.removeAt(0);
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
                keepData: true,
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
          final rival =
              existing.conflicted || v.data['revision'] != baseRevision;
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
              keepData: rival,
            ),
            'token': item?.token,
            'directory': v.isFolder,
          };
          persist(v.entry);
          if (rival) conflicts++;
          continue;
        }
        if (existing.conflicted) {
          conflicts++;
          continue;
        }
        if (base?['revision'] == v.data['revision']) continue;
        if (deleting.contains(path)) {
          if (!v.isFolder) await deleteFromDrive(path, v);
          continue;
        }
        if (base == null && item != null && !(item.directory && v.isFolder)) {
          // Initial nonempty destination: retain its contents as a concurrent
          // revision. No timestamp winner and no first-sync overwrite.
          if (item.directory != v.isFolder) {
            conflicts++;
            continue;
          }
          // An identical file adopts the drive's revision instead: no
          // rival head and no upload. Most were checked a few at once
          // before this loop.
          final seen = identicals[path];
          if (seen != null ||
              (!checked.contains(path) &&
                  !v.deleted &&
                  await sameFile(path, item, v))) {
            record(v.entry, path, v.data['revision'], false, item);
            if (seen != null) sourced(path, item, seen);
            continue;
          }
          final choice = keep(path, item, v);
          if (!v.deleted && choice == FirstSyncChoice.here) {
            // Chosen: the local copy, as a normal edit of the drive's.
            record(
              v.entry,
              path,
              await revise(
                {...v.data, 'deleted': false},
                [v.data['revision'] as String],
                path,
                item,
              ),
              false,
              item,
            );
            continue;
          }
          final earlier = v.deleted
              ? null
              : await earlierFile(path, item, existing);
          if (earlier != null) {
            record(v.entry, path, earlier, false, item);
            await fetch(path, v, item, v.data['revision']);
            continue;
          }
          if (!v.deleted && choice == FirstSyncChoice.drive) {
            // Chosen: the drive's copy. The local one joins drive history
            // as a concurrent revision, merged at once in the drive's
            // favour, then the drive's copy replaces it here.
            final kept = await revise(
              {...v.data, 'deleted': false},
              const [],
              path,
              item,
              keepData: true,
            );
            record(v.entry, path, kept, false, item);
            final merged = await drive.write(
              {...v.data},
              parents: [v.data['revision'] as String, kept],
            );
            await fetch(
              path,
              v,
              item,
              (await node.content(merged))!['revision'],
            );
            continue;
          }
          record(
            v.entry,
            path,
            await revise(
              {...v.data, 'deleted': false},
              const [],
              path,
              item,
              keepData: true,
            ),
            false,
            item,
          );
          conflicts++;
          continue;
        }
        if (v.deleted) continue; // Delete leaves last, after children.
        await fetch(path, v, item, v.data['revision']);
      } catch (e) {
        retry.add(path);
        report('$path: $e');
      }
    }
    await Future.wait(adding);
    for (final path in deleting.toList()..sort((a, b) => _byDepth(b, a))) {
      final v = remote[path]!.current;
      if (!v.isFolder) continue;
      try {
        await deleteFromDrive(path, v);
      } catch (e) {
        retry.add(path);
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
        if (item != null) {
          await fs.remove(path, item.token);
          node.store.forgetChunkSources(root, path);
        }
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
              keepData: true,
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
        if (item != null) {
          await fs.remove(path, item.token);
          node.store.forgetChunkSources(root, path);
        }
        state[id] = {...base, 'token': null};
        persist(id);
      } catch (e) {
        report('$path: $e');
      }
    }
    // Synced files whose chunks this device has not yet traced to the
    // folder: added by earlier builds, which kept a copy of every chunk, or
    // found identical. Each chunk's place in the file is recorded, and the
    // copy is freed once the folder is shown to make the first chunk again
    // (chunks an earlier build sealed with random nonces it cannot, so
    // those stay). Nothing is published.
    for (final id in state.keys.toList()) {
      if (_closed) return;
      final base = state[id];
      if (base['sourced'] == true ||
          base['directory'] == true ||
          base['token'] == null)
        continue;
      final path = base['path'] as String;
      final item = local[path];
      final entry = byId[id];
      if (item == null ||
          item.token != base['token'] ||
          entry == null ||
          entry.conflicted ||
          entry.current.deleted ||
          entry.current.data['revision'] != base['revision'])
        continue;
      try {
        if (node.store.chunkSourcesOf(root, path).isEmpty) {
          final v = entry.current;
          final payload = v.data;
          final size = payload['size'] as int, bytes = payload['chunkBytes'];
          if (bytes is! int) continue;
          final key = payload['key'] == null ? null : unb64(payload['key']);
          final leaves = <String>[];
          await for (final segment in chunkSegments(
            payload,
            (hash) async =>
                (await node.blobs.decode(hash, key)) ??
                (throw StateError('List chunk not here')),
          )) {
            leaves.addAll(segment);
          }
          node.store
              .recordChunkSources(root, path, item.contentStamp ?? item.token, [
                for (final (i, hash) in leaves.indexed)
                  (hash, i * bytes, min(bytes, size - i * bytes)),
              ]);
          if (leaves.isNotEmpty &&
              await _chunkFromFolder(v.object, leaves.first) != null) {
            for (final hash in leaves.toSet()) {
              node.store.removeBlob(hash);
            }
          } else {
            node.store.forgetChunkSources(root, path);
          }
        }
        state[id] = {...base, 'sourced': true};
        persist(id);
      } catch (e) {
        report('$path: $e');
      }
    }
    // A completed pass has applied the first-sync choices it could; only
    // those that failed are tried again.
    if (first.isNotEmpty) {
      final configs = connections;
      if (configs[root] is Map) {
        final remaining = {
          for (final path in retry)
            if (first[path] != null) path: first[path],
        };
        configs[root] = {...configs[root] as Map}..remove('firstSync');
        if (remaining.isNotEmpty) configs[root]['firstSync'] = remaining;
        node.store.set('folder-sync/connections', configs);
      }
    }
    final aside = setAside == 0
        ? ''
        : '$setAside not-synced ${setAside == 1 ? 'item' : 'items'} '
              'moved to $asideIn\n';
    status[root] = errors.isNotEmpty
        ? aside + errors.join('\n')
        : conflicts == 0
        ? '${aside}Local folder up to date · peer delivery depends on connection'
        : '$aside$conflicts conflicts · local files preserved; resolve in drive history';
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
