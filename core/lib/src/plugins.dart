import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:ournet_native/plugin_host.dart';

import 'fast_crypto.dart' show sha256Hex;
import 'model.dart';
import 'node.dart';
import 'plugin_manifest.dart';
import 'plugin_index.dart';
import 'chunk_tree.dart';
import 'plugin_release.dart';
import 'registry.dart';

/// How plugins reach their copies on friends' devices: the network.
abstract interface class PluginLink {
  /// Sends a live request to an admitted device and returns its reply.
  Future<Json> request(String device, Json request);

  /// Whether [device] said it runs [plugin].
  bool runs(String device, String plugin);

  /// Sends one unreliable datagram on [channel]; false if it could not go.
  Future<bool> datagram(String device, String channel, List<int> data);
}

/// A private group, as plugins see it.
typedef PluginGroup = ({String space, String name, List<String> members});

enum PluginStatus { stopped, starting, running, failed }

/// One of this person's other devices using a device capability here
/// (watching resources, ending processes, sending input or clipboard text)
/// through [plugin]. Live only: never stored or synced.
class RemoteSession {
  final String plugin, device;

  /// The capabilities it has used: `system-monitor`, `process-control`,
  /// `remote-input`, `clipboard-write`, `remote-desktop`.
  final Set<String> capabilities = {};
  final DateTime started;
  DateTime last;
  RemoteSession(this.plugin, this.device, this.started) : last = started;

  /// Whether it acts on this device rather than only reading from it.
  bool get controlling => capabilities.any((c) => c != 'system-monitor');
}

/// A line of the local remote-session log: [Plugins.remoteLog].
typedef RemoteLogEntry = ({
  DateTime at,
  String plugin,
  String device,
  String text,
});

/// Something a plugin said that the app may show: a notification, a log
/// line, or that it stopped.
typedef PluginNotice = ({
  String plugin,
  String kind,
  String title,
  String body,
});

/// A package: `manifest.json`, `plugin.wasm`, optionally `ui.rfwtxt` and
/// files under `assets/`, and `signature.json`, its [PluginRelease] when it
/// was published. A script plugin ([PluginManifest.isScript]) carries files
/// under `scripts/` instead of `plugin.wasm`, run by its runtime. The [digest] names the contents, not the zip, so the same
/// package zipped again is the same package.
class PluginPackage {
  final PluginManifest manifest;

  /// Every entry but `signature.json`, as it was in the zip.
  final Map<String, Uint8List> files;

  /// `signature.json`, unverified: see [Plugins.releaseOf].
  final Json? signature;

  /// SHA-256 over the canonical list of `[name, sha256(bytes)]` for [files],
  /// sorted by name (names are ASCII, so that is byte order).
  late final String digest = sha256Hex(
    bytes([
      for (final name in files.keys.toList()..sort())
        [name, sha256Hex(files[name]!)],
    ]),
  );
  late final String manifestHash = sha256Hex(files['manifest.json']!);

  PluginPackage._(this.manifest, this.files, this.signature);

  /// The component; null for a script plugin.
  Uint8List? get wasm => files['plugin.wasm'];

  /// A script plugin's scripts, by name (`scripts/main.js`), as text.
  Map<String, String> get scripts => {
    for (final MapEntry(:key, :value) in files.entries)
      if (key.startsWith('scripts/'))
        key: utf8.decode(value, allowMalformed: true),
  };

  /// RFW's parser takes Unix line ends only; Windows checkouts and editors
  /// write others.
  String? get ui => files['ui.rfwtxt'] == null
      ? null
      : utf8.decode(files['ui.rfwtxt']!).replaceAll('\r\n', '\n');

  /// Largest package, zipped or not: generous for code, small for a phone.
  static const maxBytes = 32 * 1024 * 1024;
  static const maxEntries = 300;

  /// Reads a package, throwing [FormatException] for anything not to
  /// install: an unexpected or repeated entry, or one larger than it says.
  /// Sizes are checked before anything is inflated.
  factory PluginPackage.read(Uint8List bytes) {
    if (bytes.length > maxBytes) throw const FormatException('Too large');
    final decoder = ZipDecoder();
    final Archive archive;
    try {
      archive = decoder.decodeBytes(bytes);
    } catch (_) {
      throw const FormatException('Not a plugin package');
    }
    final headers = decoder.directory.fileHeaders;
    final names = {for (final h in headers) h.filename};
    if (headers.length > maxEntries || names.length != headers.length) {
      throw const FormatException('Repeated or too many entries');
    }
    final entries = [
      for (final f in archive.files)
        if (f.isFile) f,
    ];
    if (entries.fold(0, (n, f) => n + f.size) > maxBytes) {
      throw const FormatException('Too large');
    }
    final files = <String, Uint8List>{};
    Json? signature;
    for (final f in entries) {
      if (!_entry.hasMatch(f.name)) {
        throw FormatException('Unexpected ${f.name}');
      }
      final out = _Capped(f.size);
      try {
        f.decompress(out);
      } on FormatException {
        rethrow;
      } catch (_) {
        throw FormatException('Damaged ${f.name}');
      }
      final content = out.getBytes();
      if (content.length != f.size) throw FormatException('Damaged ${f.name}');
      if (f.name == 'signature.json') {
        signature = _json(content);
      } else {
        files[f.name] = content;
      }
    }
    return PluginPackage.of(files, signature: signature);
  }

  /// [read] on another isolate: decoding and hashing keep off the caller's.
  static Future<PluginPackage> decode(Uint8List bytes) =>
      Isolate.run(() => PluginPackage.read(bytes)..digest);

  /// A package from its entries, as [read] gives them.
  factory PluginPackage.of(Map<String, Uint8List> files, {Json? signature}) {
    final json = files['manifest.json'];
    if (json == null) {
      throw const FormatException('A package needs manifest.json');
    }
    final manifest = PluginManifest.parse(_json(json));
    final hasScripts = files.keys.any((k) => k.startsWith('scripts/'));
    if (manifest.isScript) {
      if (files['plugin.wasm'] != null || !hasScripts) {
        throw const FormatException(
          'A script plugin carries scripts and no plugin.wasm',
        );
      }
    } else if (files['plugin.wasm'] == null || hasScripts) {
      throw const FormatException('A package needs plugin.wasm');
    }
    return PluginPackage._(manifest, Map.unmodifiable(files), signature);
  }

  /// This package as a zip, carrying [release] in `signature.json`.
  Uint8List signedWith(PluginRelease release) {
    final out = Archive();
    for (final MapEntry(:key, :value) in files.entries) {
      out.addFile(ArchiveFile.bytes(key, value));
    }
    out.addFile(
      ArchiveFile.bytes(
        'signature.json',
        utf8.encode(canonical(release.toJson())),
      ),
    );
    return ZipEncoder().encodeBytes(out);
  }

  static Json _json(List<int> content) {
    try {
      return jsonDecode(utf8.decode(content)) as Json;
    } catch (_) {
      throw const FormatException('Not JSON');
    }
  }

  static final _entry = RegExp(
    r'^(manifest\.json|plugin\.wasm|ui\.rfwtxt|signature\.json|'
    r'assets/[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}|'
    r'scripts/([A-Za-z0-9_][A-Za-z0-9_.-]{0,99}/){0,4}'
    r'[A-Za-z0-9_][A-Za-z0-9_.-]{0,99})$',
  );
}

/// Inflates into memory, refusing to grow past what the entry declared.
class _Capped extends OutputMemoryStream {
  final int limit;
  _Capped(this.limit);
  void _room(int n) {
    if (length + n > limit) throw const FormatException('Damaged package');
  }

  @override
  void writeByte(int value) {
    _room(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _room(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _room(stream.length);
    super.writeStream(stream);
  }
}

/// A script plugin another plugin ([from]) offered to install, and where its
/// files came from.
typedef PluginOffered = ({PluginPackage package, String from, Json source});

/// A plugin offered to this person: shared by a friend, or a newer release
/// from the publisher of one installed here.
typedef PluginOffer = ({
  PluginRelease release,

  /// The `plugin_package` carrying it; its author shared it.
  SignedObject distribution,

  /// Installing it replaces a plugin of the same ID by another publisher.
  bool replaces,
});

/// An installed plugin and its state on this device.
class InstalledPlugin {
  PluginManifest manifest;
  final Set<String> granted;
  bool enabled;
  PluginStatus status = PluginStatus.stopped;
  String? error;
  String? ui;

  /// What it was installed from; null for an unsigned package.
  PluginRelease? release;

  /// Where its files came from when another plugin offered them (see
  /// [Plugins.offered]), such as `{"git": {repo, ref, commit, pusher}}`.
  Json? source;
  InstalledPlugin._(this.manifest, this.granted, this.enabled, this.ui);
  String get id => manifest.id;

  /// Who signed it; updates must come from them.
  String? get publisher => release?.publisher;
}

/// Installs, runs and answers plugins (docs/PLUGINS.md). Each runs in the native
/// host on a thread of its own; this side answers its imports from the node,
/// feeds it new objects of its kinds through insertion cursors (never a
/// history scan), carries its live messages and keeps what its surfaces
/// show. Its kinds, sections and live requests go into [Node.registry], next
/// to the built-in ones.
///
/// Signed releases (docs/STORE-PLAN.md): an installed plugin is pinned to
/// its publisher, and each version is unpacked into a directory of its own
/// (`<id>/v/<digest>`) before it replaces the last, which stays with a copy
/// of the storage it had. A new version that fails to start goes back to it.
class Plugins {
  final Node node;

  /// Where packages are unpacked, one directory each, and compiled code is
  /// cached. Plugin storage lives in each plugin's directory.
  final String directory;
  final PluginHost? host;

  /// The network, once there is one: live messages need it.
  PluginLink? link;

  /// Reads the package a `plugin_package` carries, fetching chunks this
  /// device lacks from friends. Without it, only local chunks are read.
  Future<Uint8List> Function(SignedObject distribution)? fetch;

  /// Private groups this person is in, for `identity.groups` and publishing
  /// to a group.
  Future<List<PluginGroup>> Function()? groups;

  /// A person's display name, where known.
  String? Function(String person)? nameOf;

  /// Follows a space on all this person's devices; defaults to this one.
  Future<void> Function(String space, bool on)? follow;

  /// Opens a virtual network interface for [plugin] (granted `tun`), asking
  /// the person or the system as the platform needs, and says how the host
  /// reaches it: `{"fd": n}` (Android), `{"wintun": name}` (Windows) or
  /// `{"memory": true}` (packets come to [tunPackets]). Null: no VPNs here.
  Future<Json> Function(String plugin, Json settings)? openTun;

  /// Whether a live request from [device] may reach device capabilities
  /// (`system-monitor`, `process-control`, `remote-input`,
  /// `clipboard-write`): [Node.ownDevice] unless replaced (tests). The native
  /// host refuses those capabilities to any other device, whatever the
  /// plugin itself decides.
  late bool Function(String device) ownDevice = node.ownDevice;

  /// Write-only clipboard capability, supplied by the foreground app.
  Future<void> Function(String text)? writeClipboard;

  /// Closes what [openTun] opened for [plugin].
  void Function(String plugin)? closeTun;

  /// Opens a view of [device]'s desktop for [plugin] (granted
  /// `remote-desktop`) and returns its session, for a `DesktopView`; it
  /// connects in the background. Null: no remote desktop here.
  String Function(String plugin, String device, Json options)? openDesktop;

  /// Ends a view [openDesktop] opened.
  void Function(String session)? closeDesktop;

  /// Ends the desktop streams this device serves for [plugin]: when it
  /// stops, or the person stops remote sessions.
  void Function(String plugin)? stopDesktops;

  /// How long a device a plugin admitted may take to open its stream.
  static const desktopAdmission = Duration(seconds: 15);

  /// Devices plugins admitted to open a desktop stream here, until when.
  final _desktopAdmitted = <(String, String), DateTime>{};

  /// Whether [device] may open a desktop stream served for [plugin] now:
  /// the plugin runs with `remote-desktop`, admitted the device in the last
  /// [desktopAdmission] (each admission is used once), and the device is
  /// one of this person's own. Called by the network for each stream.
  bool admitDesktop(String device, String plugin) {
    final until = _desktopAdmitted.remove((plugin, device));
    final running = _running[plugin];
    return until != null &&
        DateTime.now().isBefore(until) &&
        running != null &&
        running.plugin.status == PluginStatus.running &&
        running.plugin.granted.contains('remote-desktop') &&
        ownDevice(device);
  }

  /// A desktop stream served for [plugin] to [device] is still going: shown
  /// in the remote-session banner and log like the other capabilities.
  void desktopServing(String plugin, String device) =>
      _remoteUsed(plugin, {'device': device, 'capability': 'remote-desktop'});

  /// Reads the file attached to [object], fetching chunks this device
  /// lacks from friends, for `files.read`. Without it, only local chunks
  /// are read.
  Future<Uint8List> Function(SignedObject object, int limit)? readFile;

  /// Streaming attachment storage and reads, supplied by transport. Large
  /// local bridge transfers use these without crossing the plugin VM heap.
  Future<Json> Function(Stream<List<int>> source, int size, String name)?
  storeFileStream;
  Stream<List<int>> Function(SignedObject object)? openFileStream;

  Future<Uint8List> Function(SignedObject object, int offset, int length)?
  readFileRange;
  late final _index = PluginIndex('$directory/.indexes.sqlite');

  /// Where compiled code is kept; [directory]'s `.cache` unless given.
  final String cache;

  Plugins(this.node, {required this.directory, String? cache, PluginHost? host})
    : cache = cache ?? '$directory/.cache',
      host = host ?? PluginHost.instance {
    node.registry.handle(
      liveRequest,
      _answerRequest,
      owner: 'plugins',
      poolable: true,
    );
    unawaited(_warmDeviceNames());
  }

  /// The live request type plugins' messages travel as.
  static const liveRequest = 'plugin';

  /// The largest file `files.store` takes and `files.read` returns.
  static const maxFileBytes = 16 * 1024 * 1024;

  /// File handles a running plugin holds at once; the oldest go first.
  static const maxFileHandles = 64;

  /// Chunk size of files plugins store: the same as a picked file's.
  static const fileChunkBytes = 128 * 1024;

  /// Largest live message, either way.
  static const maxLiveBytes = 256 * 1024;

  final _installed = <String, InstalledPlugin>{};
  final _running = <String, _Running>{};
  final _surfaces = <String, Map<String, Json>>{};
  final _changes = StreamController<String>.broadcast();
  final _statusChanges = StreamController<String>.broadcast();
  final _tunPackets =
      StreamController<({String plugin, Uint8List packet})>.broadcast();
  final _notices = StreamController<PluginNotice>.broadcast();
  final _offered = StreamController<PluginOffered>.broadcast();
  final _remote = StreamController<void>.broadcast();
  final _sessions = <(String, String), RemoteSession>{};
  final _remoteLog = <RemoteLogEntry>[];
  Timer? _sessionExpiry;
  bool _closed = false;
  int _deviceNameCursor = 0;
  final _deviceNameRecords = <String, SignedObject>{};

  // identity.contacts is used at input rates. Consume each public rename
  // once, in bounded arrival-order pages, instead of scanning name history
  // for every pointer reply. Retain only the current name per known device.
  bool _advanceDeviceNames() {
    final page = node.store.objectsAfter('device_name', _deviceNameCursor);
    for (final (cursor, object) in page) {
      _deviceNameCursor = cursor;
      if (!object.isPublic || !node.visible(object)) continue;
      final payload = object.data['payload'];
      if (payload is! Map) continue;
      final device = payload['device'], label = payload['label'];
      if (device is! String || label is! String || label.isEmpty) continue;
      final owner = device == node.identity.device
          ? node.person
          : node.contacts[device]?.person;
      if (owner != object.author) continue;
      final previous = _deviceNameRecords[device];
      if (previous == null ||
          object.created > previous.created ||
          (object.created == previous.created &&
              object.id.compareTo(previous.id) < 0)) {
        _deviceNameRecords[device] = object;
      }
    }
    return page.length == 256;
  }

  Future<void> _warmDeviceNames() async {
    do {
      await Future<void>.delayed(Duration.zero);
      if (_closed) return;
    } while (_advanceDeviceNames());
  }

  Map<String, String> _deviceNames() {
    _advanceDeviceNames();
    return {
      for (final entry in _deviceNameRecords.entries)
        if (node.visible(entry.value))
          entry.key: '${(entry.value.data['payload'] as Map)['label']}',
    };
  }

  /// When each plugin last had an event from the person: offering a plugin
  /// to install is allowed only just after one.
  final _lastEvent = <String, DateTime>{};

  /// Whether plugins can run on this device at all.
  bool get available => host != null;

  /// Fires with a plugin's ID when its status or what it shows changes.
  Stream<String> get changes => _changes.stream;

  /// Like [changes], without what a plugin shows: fires when it is installed,
  /// removed, started, stopped or fails, not on every surface update.
  Stream<String> get statusChanges => _statusChanges.stream;
  Stream<PluginNotice> get notices => _notices.stream;

  /// Script plugins other plugins offer for the person to install (a Git
  /// repository's, say): the app asks them, then calls [install] with the
  /// [PluginOffered.source].
  Stream<PluginOffered> get offered => _offered.stream;

  /// How long a remote session lasts after the device last used a
  /// capability: the host reports use at most once a second, and a
  /// dashboard may sample every few seconds.
  static const remoteIdle = Duration(seconds: 12);

  /// Entries [remoteLog] keeps.
  static const remoteLogLimit = 200;

  /// Devices using device capabilities here now, oldest first.
  List<RemoteSession> get remoteSessions => List.unmodifiable(_sessions.values);

  /// Remote sessions started and ended and processes ended from other
  /// devices, newest first: in memory on this device only.
  List<RemoteLogEntry> get remoteLog => List.unmodifiable(_remoteLog);

  /// Fires when [remoteSessions] or [remoteLog] change.
  Stream<void> get remoteChanges => _remote.stream;

  /// A device's name as plugins see it.
  String deviceName(String device) {
    if (device == node.identity.device) return 'This device';
    return _deviceNames()[device] ??
        node.contacts[device]?.label ??
        device.substring(0, min(12, device.length));
  }

  void _logRemote(String plugin, String device, String text) {
    _remoteLog.insert(0, (
      at: DateTime.now(),
      plugin: plugin,
      device: device,
      text: text,
    ));
    if (_remoteLog.length > remoteLogLimit) _remoteLog.removeLast();
  }

  static String _capabilityText(String capability) => switch (capability) {
    'system-monitor' => 'viewing resources and processes',
    'process-control' => 'ending processes',
    'remote-input' => 'controlling mouse and keyboard',
    'clipboard-write' => 'sending clipboard text',
    'remote-desktop' => 'viewing and controlling the desktop',
    _ => capability,
  };

  void _remoteUsed(String plugin, Json h) {
    final device = '${h['device']}', capability = '${h['capability']}';
    final now = DateTime.now();
    final key = (plugin, device);
    var session = _sessions[key];
    if (session == null) {
      _logRemote(plugin, device, 'Session started');
      session = _sessions[key] = RemoteSession(plugin, device, now);
    }
    session.last = now;
    if (session.capabilities.add(capability)) {
      _logRemote(plugin, device, 'Started ${_capabilityText(capability)}');
    }
    _scheduleExpiry();
    if (!_remote.isClosed) _remote.add(null);
  }

  void _remoteAction(String plugin, Json h) {
    _logRemote(
      plugin,
      '${h['device']}',
      'Ended process ${h['name']} (PID ${h['pid']})',
    );
    if (!_remote.isClosed) _remote.add(null);
  }

  void _scheduleExpiry() {
    _sessionExpiry?.cancel();
    if (_sessions.isEmpty || _closed) return;
    final oldest = _sessions.values
        .map((s) => s.last)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    final wait = oldest.add(remoteIdle).difference(DateTime.now());
    _sessionExpiry = Timer(
      wait.isNegative ? Duration.zero : wait,
      _expireSessions,
    );
  }

  void _expireSessions() {
    final now = DateTime.now();
    final ended = [
      for (final s in _sessions.values)
        if (now.difference(s.last) >= remoteIdle) s,
    ];
    for (final s in ended) {
      _endSession(s, 'Session ended');
    }
    _scheduleExpiry();
    if (ended.isNotEmpty && !_remote.isClosed) _remote.add(null);
  }

  void _endSession(RemoteSession s, String why) {
    _sessions.remove((s.plugin, s.device));
    final seconds = s.last.difference(s.started).inSeconds;
    final length = seconds < 60
        ? '$seconds s'
        : '${seconds ~/ 60} min ${seconds % 60} s';
    _logRemote(s.plugin, s.device, '$why after $length');
  }

  /// Ends every remote session here now: tells each plugin serving one to
  /// switch its receiving permissions off (a `disable` event, which it
  /// saves), then restarts it.
  Future<void> stopRemoteSessions() async {
    final plugins = {for (final s in _sessions.values) s.plugin};
    for (final s in _sessions.values.toList()) {
      _endSession(s, 'Stopped on this device');
    }
    _scheduleExpiry();
    if (!_remote.isClosed) _remote.add(null);
    for (final id in plugins) {
      final running = _running[id];
      if (running != null) {
        try {
          await _call(running, {
            'call': 'event',
            'surface': '',
            'name': 'disable',
            'args': '{}',
          });
        } catch (_) {}
      }
      // Ends whatever the plugin still holds for its controllers.
      await restart(id);
    }
  }

  /// Packets plugins write to memory interfaces (see [openTun]).
  Stream<({String plugin, Uint8List packet})> get tunPackets =>
      _tunPackets.stream;

  /// Hands [packet] to [plugin] as if its interface received it from the
  /// system: for memory interfaces.
  void tunReceive(String plugin, Uint8List packet) {
    final running = _running[plugin];
    if (running?.handle == null) return;
    host!.call(running!.handle!, {'call': 'packet', 'quiet': true}, packet);
  }

  List<InstalledPlugin> get installed => List.unmodifiable(_installed.values);
  InstalledPlugin? operator [](String id) => _installed[id];

  /// What [surface] of [plugin] last asked to show.
  Json surface(String plugin, String surface) =>
      _surfaces[plugin]?[surface] ?? const {};

  /// Per plugin: `grants`, `enabled`, `active` (the digest of the version in
  /// use; absent for one installed before versions, kept in its directory),
  /// `release`, `trial` (a new version that has not yet started), `previous`
  /// (`{digest, grants, release}`, to go back to) and `skipped` releases.
  Json get _settings => (node.store.setting('plugins') as Map?)?.cast() ?? {};
  void _saveSettings(Json settings) => node.store.set('plugins', settings);
  Json _of(String id) => (_settings[id] as Map?)?.cast() ?? {};
  void _set(String id, Json? s) =>
      _saveSettings({..._settings, id: ?s}..removeWhere((k, v) => v == null));

  /// Where the code of [digest] (null: from before versions) is unpacked.
  String _code(String id, Object? digest) =>
      digest == null ? '$directory/$id' : '$directory/$id/v/$digest';

  /// Reads installed plugins and starts the enabled ones.
  Future<void> load() async {
    for (final MapEntry(key: id, value: s) in _settings.entries) {
      if (s is! Map) continue;
      try {
        final code = _code(id, s['active']);
        final manifest = PluginManifest.parse(
          jsonDecode(await File('$code/manifest.json').readAsString()) as Json,
        );
        final ui = File('$code/ui.rfwtxt');
        final plugin =
            InstalledPlugin._(
                manifest,
                {...(s['grants'] as List? ?? const []).cast<String>()},
                s['enabled'] != false,
                await ui.exists()
                    ? (await ui.readAsString()).replaceAll('\r\n', '\n')
                    : null,
              )
              ..release = s['release'] is Map
                  ? PluginRelease.of(SignedObject.fromJson(s['release']))
                  : null
              ..source = (s['source'] as Map?)?.cast();
        _installed[id] = plugin;
        _register(plugin);
      } catch (e) {
        _notice(id, 'error', 'Could not load plugin', '$e');
      }
    }
    // Once all are known, so a script plugin finds its runtime.
    for (final plugin in _installed.values.toList()) {
      if (plugin.enabled) await _start(plugin);
    }
  }

  /// The installed, enabled runtime that runs [plugin]'s scripts.
  InstalledPlugin? runtimeOf(PluginManifest plugin) =>
      runtimeFor(plugin.runtime);

  /// The installed, enabled runtime for [language] (`js@1`), if any.
  InstalledPlugin? runtimeFor(String? language) {
    if (language == null) return null;
    for (final p in _installed.values) {
      if (p.enabled && p.manifest.provides == 'runtime:$language') return p;
    }
    return null;
  }

  /// The installed plugins [runtime] runs.
  Iterable<InstalledPlugin> _scriptsOf(InstalledPlugin runtime) =>
      _installed.values.where(
        (p) =>
            p.manifest.isScript &&
            'runtime:${p.manifest.runtime}' == runtime.manifest.provides,
      );

  /// Starts again the enabled script plugins on [runtime] (installed,
  /// updated or switched on), or stops them (removed or switched off).
  Future<void> _restartScripts(InstalledPlugin runtime) async {
    for (final script in _scriptsOf(runtime).toList()) {
      _stop(script.id);
      if (script.enabled) await _start(script);
    }
  }

  /// A script plugin's scripts as installed, by name, to show the people
  /// running it (docs/SCRIPTING.md: the source is visible).
  Future<Map<String, String>> scriptsOf(String id) async {
    final code = Directory('${_code(id, _of(id)['active'])}/scripts');
    final found = <String, String>{};
    if (!await code.exists()) return found;
    await for (final f in code.list(recursive: true)) {
      if (f is File) {
        final name = f.path
            .substring(code.parent.path.length + 1)
            .replaceAll(r'\', '/');
        found[name] = utf8.decode(await f.readAsBytes(), allowMalformed: true);
      }
    }
    return Map.fromEntries(
      found.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
  }

  /// The release [package] carries, verified and checked against it; null
  /// for an unsigned package. Throws [FormatException] for one that does not
  /// verify.
  Future<PluginRelease?> releaseOf(PluginPackage package) async {
    if (package.signature == null) return null;
    final release = await PluginRelease.verify(package.signature, node);
    release.check(package);
    return release;
  }

  /// Installs [package] with [grants] (which the person agreed to, from
  /// [PluginPackage.manifest]'s `grants`) and starts it; a new version asking
  /// for more grants must be given them here. [release] (by default the one
  /// the package carries) must describe it.
  ///
  /// Installing over the same ID from the same publisher (or over an
  /// unsigned one) updates it: storage stays, a copy is kept, and if the new
  /// version fails to start the previous one comes back with that copy. From
  /// another publisher it is another plugin: the one installed is removed
  /// first, with everything it kept.
  Future<InstalledPlugin> install(
    PluginPackage package, {
    required Set<String> grants,
    PluginRelease? release,
    Json? source,
  }) async {
    final manifest = package.manifest;
    if (!grants.containsAll(manifest.grants)) {
      throw StateError(
        'Grant ${manifest.grants.difference(grants).join(', ')} first',
      );
    }
    if (release == null) {
      release = await releaseOf(package);
    } else {
      release.check(package);
    }
    final id = manifest.id;
    final existing = _installed[id];
    if (existing?.publisher != null &&
        existing!.publisher != release?.publisher) {
      await uninstall(id);
    }
    await _unpack(package);
    final old = _of(id);
    final update = old.isNotEmpty && old['active'] != package.digest;
    if (update) {
      final cursors = node.store.setting('pluginCursor/$id');
      node.store.set('pluginCursorSnapshot/$id', cursors);
    }
    _set(id, {
      'grants': grants.intersection(manifest.grants).toList()..sort(),
      'enabled': true,
      'active': package.digest,
      'release': ?release?.toJson(),
      'source': ?source,
      'skipped': ?old['skipped'],
      if (update) ...{
        'trial': true,
        'previous': {
          'digest': ?old['active'],
          'grants': old['grants'],
          'release': ?old['release'],
        },
      } else
        'previous': ?old['previous'],
    });
    _stop(id);
    final plugin = _installed[id] ??= InstalledPlugin._(
      manifest,
      {},
      true,
      package.ui,
    );
    plugin
      ..manifest = manifest
      ..ui = package.ui
      ..release = release
      ..source = source
      ..enabled = true;
    plugin.granted
      ..clear()
      ..addAll(grants.intersection(manifest.grants));
    node.registry.removeOwner(id);
    _register(plugin);
    if (release != null) await _followPublisher(release.publisher, true);
    await _start(plugin, storage: update ? 'snapshot' : null);
    if (manifest.isRuntime) await _restartScripts(plugin);
    _changed(id);
    return plugin;
  }

  /// Writes [package] to its version directory, whole or not at all.
  Future<void> _unpack(PluginPackage package) async {
    final code = Directory(_code(package.manifest.id, package.digest));
    if (await code.exists()) return;
    final part = Directory('${code.path}.part');
    if (await part.exists()) await part.delete(recursive: true);
    for (final MapEntry(:key, :value) in package.files.entries) {
      final file = File('${part.path}/$key');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(value, flush: true);
    }
    await part.rename(code.path);
  }

  /// The new version of [id] did not start: back to the previous one, with
  /// the storage and cursors it had, and the new release skipped.
  Future<void> _rollBack(String id, String error) async {
    final s = _of(id);
    final previous = (s['previous'] as Map?)?.cast<String, Object?>();
    final plugin = _installed[id];
    if (previous == null || plugin == null) return;
    _stop(id);
    final failed = s['release'] is Map
        ? SignedObject.fromJson(s['release']).id
        : null;
    _set(id, {
      'grants': previous['grants'],
      'enabled': true,
      'active': ?previous['digest'],
      'release': ?previous['release'],
      'skipped': [...?(s['skipped'] as List?), ?failed],
    });
    node.store.set(
      'pluginCursor/$id',
      node.store.setting('pluginCursorSnapshot/$id'),
    );
    node.store.set('pluginCursorSnapshot/$id', null);
    final code = _code(id, previous['digest']);
    final ui = File('$code/ui.rfwtxt');
    plugin
      ..manifest = PluginManifest.parse(
        jsonDecode(await File('$code/manifest.json').readAsString()) as Json,
      )
      ..ui = await ui.exists()
          ? (await ui.readAsString()).replaceAll('\r\n', '\n')
          : null
      ..release = previous['release'] is Map
          ? PluginRelease.of(
              SignedObject.fromJson((previous['release'] as Map).cast()),
            )
          : null;
    plugin.granted
      ..clear()
      ..addAll((previous['grants'] as List).cast());
    node.registry.removeOwner(id);
    _register(plugin);
    await _start(plugin, storage: 'restore');
    _notice(
      id,
      'error',
      '${plugin.manifest.name} went back to ${plugin.manifest.version}',
      error,
    );
    _changed(id);
  }

  /// The new version of [id] started: it stays, and versions other than it
  /// and the previous one go.
  Future<void> _confirm(String id) async {
    final s = _of(id);
    if (s['trial'] != true) return;
    _set(id, {...s}..remove('trial'));
    node.store.set('pluginCursorSnapshot/$id', null);
    final keep = {s['active'], (s['previous'] as Map?)?['digest']};
    final versions = Directory('$directory/$id/v');
    if (!await versions.exists()) return;
    await for (final dir in versions.list()) {
      if (!keep.contains(dir.uri.pathSegments.lastWhere((p) => p.isNotEmpty))) {
        await dir.delete(recursive: true);
      }
    }
  }

  /// Follows [publisher]'s releases on all this person's devices, while any
  /// installed plugin is theirs.
  Future<void> _followPublisher(String publisher, bool on) async {
    if (!on && _installed.values.any((p) => p.publisher == publisher)) return;
    final space = PluginRelease.space(publisher);
    await (follow?.call(space, on) ??
        Future.sync(() => node.subscribe(space, on)));
  }

  /// Signs [package] as a release by this person and offers it: publicly,
  /// in their release space, or only to [people]. Returns the package with
  /// its release, to share as a file.
  ///
  /// Refused for a plugin ID installed here from someone else, a version
  /// not after this person's last release of it, or a manifest friends on
  /// that release could not exchange data with
  /// ([PluginManifest.incompatibleWith]).
  Future<Uint8List> publish(
    PluginPackage package, {
    String changes = '',
    List<String> people = const [],
  }) async {
    final m = package.manifest;
    final publisher = _installed[m.id]?.publisher;
    if (publisher != null && publisher != node.person) {
      throw StateError('${m.name} here is someone else\'s');
    }
    final last = await _lastRelease(m.id);
    if (last != null) {
      final (release, before) = last;
      if (compareVersions(m.version, release.version) <= 0) {
        throw StateError('Publish a version after ${release.version}');
      }
      final problems = before?.manifest.incompatibleWith(m) ?? const [];
      if (problems.isNotEmpty) {
        throw StateError(
          'Friends on ${release.version} could not read its data: '
          '${problems.join(', ')}. Use new kinds or fields instead.',
        );
      }
    }
    final release = PluginRelease.of(
      await node.publish(
        PluginRelease.kind,
        PluginRelease.describe(package, changes: changes),
        space: PluginRelease.space(node.person),
        keep: people.isEmpty,
      ),
    )!;
    final signed = package.signedWith(release);
    await _distribute(release, signed, people);
    return signed;
  }

  /// This person's newest release of [plugin], and its package when its
  /// chunks are here.
  Future<(PluginRelease, PluginPackage?)?> _lastRelease(String plugin) async {
    for (final o in node.store.objects(
      kind: PluginRelease.packageKind,
      author: node.person,
      limit: 200,
    )) {
      final payload = await node.content(o);
      final release = payload == null
          ? null
          : PluginRelease.of(SignedObject.fromJson(payload['release']));
      if (release == null ||
          release.publisher != node.person ||
          release.plugin != plugin) {
        continue;
      }
      final bytes = await _readLocal(payload!);
      return (
        release,
        bytes == null ? null : await PluginPackage.decode(bytes),
      );
    }
    return null;
  }

  /// Shares installed plugin [id], as released, with [people].
  Future<void> share(String id, List<String> people) async {
    final plugin = _installed[id];
    final release = plugin?.release;
    if (release == null) throw StateError('Only signed plugins can be shared');
    final code = _code(id, _of(id)['active']);
    final files = <String, Uint8List>{};
    await for (final f in Directory(code).list(recursive: true)) {
      if (f is File) {
        files[f.path.substring(code.length + 1).replaceAll(r'\', '/')] = await f
            .readAsBytes();
      }
    }
    await _distribute(
      release,
      PluginPackage.of(files).signedWith(release),
      people,
    );
  }

  /// Stores [package]'s chunks (sealed with a new key unless public) and
  /// publishes a distribution of [release] for [people], or everyone
  /// following its publisher.
  Future<void> _distribute(
    PluginRelease release,
    Uint8List package,
    List<String> people,
  ) async {
    final key = people.isEmpty ? null : randomBytes(32);
    final chunks = [
      for (var at = 0; at < package.length; at += chunkBytes)
        await node.blobs.encode(
          Uint8List.sublistView(
            package,
            at,
            min(at + chunkBytes, package.length),
          ),
          key,
        ),
    ];
    await node.publish(
      PluginRelease.packageKind,
      {
        'release': release.toJson(),
        'name': '${release.plugin}-${release.version}.ournet-plugin',
        'size': package.length,
        'chunks': chunks,
        'chunkBytes': chunkBytes,
        'key': key == null ? null : b64(key),
      },
      space: PluginRelease.space(node.person),
      audience: people,
    );
  }

  Future<Uint8List?> _readLocal(Json payload) => node.blobs.readLocal(
    (payload['chunks'] as List).cast(),
    payload['key'] == null ? null : unb64(payload['key']),
    limit: PluginPackage.maxBytes,
    expectedSize: payload['size'] as int,
  );

  final _verified = <String, PluginRelease?>{};

  /// What is offered to this person, newest first: plugins friends shared
  /// that are not installed here, and newer releases from the publishers of
  /// installed ones. Reads the newest [limit] distributions, through the
  /// kind index; releases already checked are remembered.
  Future<List<PluginOffer>> offers({int limit = 200}) async {
    final found = <String, PluginOffer>{};
    for (final o in node.store.objects(
      kind: PluginRelease.packageKind,
      limit: limit,
    )) {
      final payload = await node.content(o);
      if (payload == null) continue;
      final wire = payload['release'];
      final key = wire is Map ? canonical(wire) : '';
      final PluginRelease? release;
      if (_verified.containsKey(key)) {
        release = _verified[key];
      } else {
        try {
          release = _verified[key] = await PluginRelease.verify(wire, node);
        } catch (_) {
          _verified[key] = null;
          continue;
        }
      }
      if (release == null) continue;
      final installed = _installed[release.plugin];
      final newest = found['${release.publisher} ${release.plugin}'];
      // Settings are read last: they are decoded afresh on every call.
      if ((installed != null &&
              installed.publisher == release.publisher &&
              compareVersions(release.version, installed.manifest.version) <=
                  0) ||
          (newest != null &&
              compareVersions(release.version, newest.release.version) <= 0) ||
          ((_of(release.plugin)['skipped'] as List?) ?? const []).contains(
            release.id,
          )) {
        continue;
      }
      found['${release.publisher} ${release.plugin}'] = (
        release: release,
        distribution: o,
        replaces: installed != null && installed.publisher != release.publisher,
      );
    }
    return found.values.toList();
  }

  /// Fetches, checks and installs [offer] with [grants] (see [install]).
  Future<InstalledPlugin> installOffer(
    PluginOffer offer, {
    required Set<String> grants,
  }) async {
    final payload = await node.content(offer.distribution);
    if (payload == null) throw StateError('Not readable here');
    final bytes =
        await (fetch?.call(offer.distribution) ?? _readLocal(payload)) ??
        (throw StateError('Not on this device yet'));
    return install(
      await PluginPackage.decode(bytes),
      grants: grants,
      release: offer.release,
    );
  }

  /// Removes [id] and everything it kept on this device. Objects it
  /// published stay: they are signed by this person and may have synced.
  Future<void> uninstall(String id) async {
    _stop(id);
    node.registry.removeOwner(id);
    node.store.setArrivalKinds(id, const []);
    final removed = _installed.remove(id);
    final publisher = removed?.publisher;
    if (removed != null && removed.manifest.isRuntime) {
      await _restartScripts(removed);
    }
    _surfaces.remove(id);
    _set(id, null);
    node.store.set('pluginCursor/$id', null);
    node.store.set('pluginCursorSnapshot/$id', null);
    final dir = Directory('$directory/$id');
    if (await dir.exists()) await dir.delete(recursive: true);
    if (publisher != null) await _followPublisher(publisher, false);
    _changed(id);
  }

  Future<void> setEnabled(String id, bool on) async {
    final plugin = _installed[id];
    if (plugin == null || plugin.enabled == on) return;
    plugin.enabled = on;
    _set(id, {..._of(id), 'enabled': on});
    if (on) {
      await _start(plugin);
    } else {
      _stop(id);
    }
    if (plugin.manifest.isRuntime) await _restartScripts(plugin);
    _changed(id);
  }

  /// Updates installed plugins to the newer versions among [packages] (the
  /// ones the app ships) without asking: only unsigned, enabled ones that
  /// were installed unsigned and need no new grant. Others wait for the
  /// person, in Settings. Returns the IDs updated.
  Future<List<String>> updateBundled(Iterable<PluginPackage> packages) async {
    final updated = <String>[];
    for (final package in packages) {
      final m = package.manifest;
      final installed = _installed[m.id];
      if (installed == null ||
          !installed.enabled ||
          installed.publisher != null ||
          package.signature != null ||
          compareVersions(m.version, installed.manifest.version) <= 0 ||
          !installed.granted.containsAll(m.grants)) {
        continue;
      }
      try {
        await install(package, grants: installed.granted.toSet());
        updated.add(m.id);
      } catch (e) {
        _notice(m.id, 'error', 'Could not update ${m.name}', '$e');
      }
    }
    return updated;
  }

  /// Starts a stopped or failed plugin again.
  Future<void> restart(String id) async {
    final plugin = _installed[id];
    if (plugin == null) return;
    _stop(id);
    await _start(plugin);
  }

  /// The CPU time [id]'s calls have used since it started (time waiting on
  /// the app excluded), and how many calls there were.
  Future<({Duration busy, int calls})> usage(String id) async {
    final running = _running[id];
    if (running == null) throw StateError('Not running');
    final usage = (await _call(running, {'call': 'usage'})).header['usage'];
    return (
      busy: Duration(microseconds: (usage as Map)['busy'] as int),
      calls: usage['calls'] as int,
    );
  }

  /// [surface] of [id] is being shown; [context] says in which scope.
  void open(String id, String surface, Json context) => _fire(id, {
    'call': 'open',
    'surface': surface,
    'context': jsonEncode(context),
  });

  /// A widget in [surface] fired [name] with [args].
  void event(String id, String surface, String name, Json args) {
    _lastEvent[id] = DateTime.now();
    _fire(id, {
      'call': 'event',
      'surface': surface,
      'name': name,
      'args': jsonEncode(args),
    });
  }

  /// Development: hot reloads an installed plugin, keeping its state,
  /// whenever its package in [folder] (`<id>.ournet-plugin`, as
  /// `plugins/pack --watch` writes) changes. Only plugins that are unsigned
  /// or this person's own, and only when the new version asks for no more
  /// than was granted. Desktop only: returns false where the folder cannot
  /// be watched.
  bool watch(String folder) {
    unwatch();
    final dir = Directory(folder);
    if (!dir.existsSync()) return false;
    try {
      _watching = dir.watch().listen((event) {
        final name = event.path.split(RegExp(r'[/\\]')).last;
        if (!name.endsWith('.ournet-plugin')) return;
        final id = name.substring(0, name.length - '.ournet-plugin'.length);
        final plugin = _installed[id];
        if (plugin == null) return;
        // Writers replace the file whole; several events come for one write.
        _reloads[id]?.cancel();
        _reloads[id] = Timer(const Duration(milliseconds: 200), () async {
          try {
            await _reload(
              plugin,
              await PluginPackage.decode(await File(event.path).readAsBytes()),
            );
          } catch (e) {
            _notice(id, 'error', 'Not reloaded', '$e');
          }
        });
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _reload(InstalledPlugin plugin, PluginPackage package) async {
    final id = plugin.id;
    if (plugin.publisher != null && plugin.publisher != node.person) {
      throw StateError("It is someone else's: install it instead");
    }
    if (!plugin.granted.containsAll(package.manifest.grants)) {
      throw StateError('It asks for more: reinstall it');
    }
    await _unpack(package);
    _set(id, {..._of(id), 'active': package.digest});
    plugin
      ..manifest = package.manifest
      ..ui = package.ui;
    node.registry.removeOwner(id);
    _register(plugin);
    final running = _running[id];
    final Uint8List? wasm;
    if (package.manifest.isScript) {
      final runtime = runtimeOf(package.manifest);
      wasm = runtime == null ? null : await _wasmOf(runtime);
    } else {
      wasm = package.wasm;
    }
    if (running?.handle != null && wasm != null) {
      plugin.status = PluginStatus.starting;
      // Its files unpacked to a new directory; then the code is swapped.
      host!.call(running!.handle!, {
        'call': 'package',
        'id': 0,
        'dir': _code(id, package.digest),
      });
      host!.reload(running.handle!, wasm);
    } else {
      _stop(id);
      await _start(plugin);
    }
    if (package.manifest.isRuntime) await _restartScripts(plugin);
    _notice(id, 'log', 'info', 'Reloaded ${package.manifest.version}');
    _changed(id);
  }

  void unwatch() {
    _watching?.cancel();
    _watching = null;
  }

  StreamSubscription<FileSystemEvent>? _watching;
  final _reloads = <String, Timer>{};

  Future<void> close() async {
    unwatch();
    _closed = true;
    for (final id in _running.keys.toList()) {
      _stop(id);
    }
    await _index.close();
    node.registry.unhandle(liveRequest, _answerRequest);
    _sessionExpiry?.cancel();
    await _remote.close();
    await _changes.close();
    await _statusChanges.close();
    await _tunPackets.close();
    await _notices.close();
    await _offered.close();
  }

  void _register(InstalledPlugin plugin) {
    for (final MapEntry(:key, :value) in plugin.manifest.kinds.entries) {
      node.registry.addKind(plugin.id, key, value);
    }
    for (final section in plugin.manifest.sections) {
      node.registry.addSection(section);
    }
    plugin.manifest.search.values.forEach(node.registry.addSearch);
    plugin.manifest.activity.values.forEach(node.registry.addActivity);
    node.store.setArrivalKinds(plugin.id, plugin.manifest.activity.keys);
  }

  /// Starts [plugin]; [storage] is `snapshot` or `restore` for the host to
  /// copy its storage aside first or put the copy back.
  Future<void> _start(InstalledPlugin plugin, {String? storage}) async {
    if (_closed || _running.containsKey(plugin.id)) return;
    final host = this.host;
    if (host == null) {
      plugin
        ..status = PluginStatus.failed
        ..error = 'Plugins do not run on this device';
      _changed(plugin.id);
      return;
    }
    // A runtime runs only for the script plugins that name it.
    if (plugin.manifest.isRuntime) return;
    final dir = '$directory/${plugin.id}';
    final code = _code(plugin.id, _of(plugin.id)['active']);
    final runtime = runtimeOf(plugin.manifest);
    if (plugin.manifest.isScript && runtime == null) {
      plugin
        ..status = PluginStatus.failed
        ..error = 'It needs the ${plugin.manifest.runtime} runtime: install it';
      _changed(plugin.id);
      return;
    }
    final Uint8List wasm;
    try {
      wasm = runtime == null
          ? await File('$code/plugin.wasm').readAsBytes()
          : (await _wasmOf(runtime))!;
    } catch (e) {
      plugin
        ..status = PluginStatus.failed
        ..error = 'Package missing: $e';
      _changed(plugin.id);
      return;
    }
    final running = _Running(plugin);
    _running[plugin.id] = running;
    plugin
      ..status = PluginStatus.starting
      ..error = null;
    running.handle = host.load(
      {
        'id': plugin.id,
        'dir': dir,
        'cache': cache,
        'grants': plugin.granted.toList(),
        'storage': ?storage,
        'package': code,
        if (runtime != null) 'runtime': true,
      },
      wasm,
      (message) => _received(running, message),
    );
    if (running.handle == null) {
      _running.remove(plugin.id);
      plugin
        ..status = PluginStatus.failed
        ..error = 'The plugin host refused it';
    }
    _changed(plugin.id);
  }

  /// [plugin]'s component, as installed.
  Future<Uint8List?> _wasmOf(InstalledPlugin plugin) async {
    try {
      return await File(
        '${_code(plugin.id, _of(plugin.id)['active'])}/plugin.wasm',
      ).readAsBytes();
    } catch (_) {
      return null;
    }
  }

  void _stop(String id) {
    final running = _running.remove(id);
    if (running == null) return;
    final sessions = [
      for (final s in _sessions.values)
        if (s.plugin == id) s,
    ];
    for (final s in sessions) {
      _endSession(s, 'Plugin stopped');
    }
    if (sessions.isNotEmpty) {
      _scheduleExpiry();
      if (!_remote.isClosed) _remote.add(null);
    }
    running.changes?.cancel();
    node.registry.withdraw(id);
    _desktopAdmitted.removeWhere((key, _) => key.$1 == id);
    stopDesktops?.call(id);
    if (running.handle != null) host?.stop(running.handle!);
    for (final call in running.calls.values) {
      call.completeError(StateError('Plugin stopped'));
    }
    running.calls.clear();
    final plugin = _installed[id];
    if (plugin != null && plugin.status != PluginStatus.failed) {
      plugin.status = PluginStatus.stopped;
    }
  }

  void _changed(String id, {bool surface = false}) {
    if (!_changes.isClosed) _changes.add(id);
    if (!surface && !_statusChanges.isClosed) _statusChanges.add(id);
  }

  void _notice(String plugin, String kind, String title, String body) {
    if (!_notices.isClosed) {
      _notices.add((plugin: plugin, kind: kind, title: title, body: body));
    }
  }

  /// Sends a call whose result nobody waits for; failures are noticed.
  void _fire(String id, Json header) {
    final running = _running[id];
    if (running == null) return;
    unawaited(_call(running, header).then((_) {}, onError: (Object _) {}));
  }

  Future<PluginMessage> _call(
    _Running running,
    Json header, [
    Uint8List? body,
  ]) {
    final handle = running.handle;
    if (handle == null || _running[running.plugin.id] != running) {
      return Future.error(StateError('Plugin not running'));
    }
    final id = ++running.nextCall;
    final result = Completer<PluginMessage>();
    running.calls[id] = result;
    if (!host!.call(handle, {...header, 'id': id}, body)) {
      running.calls.remove(id);
      return Future.error(StateError('Plugin not running'));
    }
    return result.future;
  }

  void _received(_Running running, PluginMessage message) {
    final plugin = running.plugin;
    if (_running[plugin.id] != running) return;
    final h = message.header;
    switch (message.type) {
      case 'loaded':
        unawaited(_ready(running, reloaded: h['reloaded'] == true));
      case 'failed':
        // A reload that failed leaves the previous version running.
        final reloaded = h['reloaded'] == true;
        plugin
          ..status = reloaded ? PluginStatus.running : PluginStatus.failed
          ..error = '${h['error']}';
        if (!reloaded) _stop(plugin.id);
        _notice(
          plugin.id,
          'error',
          '${plugin.manifest.name} did not start',
          '${h['error']}',
        );
        _changed(plugin.id);
        if (!reloaded) _failedTrial(plugin.id, '${h['error']}');
      case 'trap':
        plugin
          ..status = PluginStatus.failed
          ..error = '${h['error']}';
        _notice(
          plugin.id,
          'error',
          '${plugin.manifest.name} stopped',
          '${h['error']}',
        );
        _changed(plugin.id);
        _failedTrial(plugin.id, '${h['error']}');
      case 'result':
        final call = running.calls.remove(h['id']);
        if (call == null) return;
        if (h['error'] != null) {
          call.completeError(StateError('${h['error']}'));
        } else {
          call.complete(message);
        }
      case 'import':
        unawaited(
          _answer(
            running,
            h['id'] as int,
            '${h['fn']}',
            h['args'],
            message.body,
          ),
        );
      case 'send':
        unawaited(
          _send(running, h['request'] as int, '${h['device']}', message.body),
        );
      case 'refuse':
        _fire(plugin.id, {
          'call': 'reply',
          'request': h['request'],
          'error': h['error'],
        });
      case 'ui.update':
        final data = _decode(h['data']);
        if (data == null) return;
        final surfaces = _surfaces[plugin.id] ??= {};
        final surface = '${h['surface']}';
        surfaces[surface] = Map.unmodifiable(
          {...?surfaces[surface], ...data}..removeWhere((_, v) => v == null),
        );
        _changed(plugin.id, surface: true);
      case 'datagram':
        final link = this.link;
        if (link != null && plugin.granted.contains('live')) {
          unawaited(
            link.datagram('${h['device']}', 'p:${plugin.id}', message.body),
          );
        }
      case 'tun.write':
        if (!_tunPackets.isClosed) {
          _tunPackets.add((plugin: plugin.id, packet: message.body));
        }
      case 'tun.close':
        closeTun?.call(plugin.id);
      case 'ui.notify':
        _notice(plugin.id, 'notify', '${h['title']}', '${h['body']}');
      case 'log':
        _notice(plugin.id, 'log', '${h['level']}', '${h['message']}');
      case 'device.session':
        _remoteUsed(plugin.id, h);
      case 'device.action':
        _remoteAction(plugin.id, h);
    }
  }

  static Json? _decode(Object? text) {
    try {
      final v = jsonDecode('$text');
      return v is Map ? frozen(v) as Json : null;
    } catch (_) {
      return null;
    }
  }

  /// A new version that fails before it has started goes back.
  void _failedTrial(String id, String error) {
    if (_of(id)['trial'] == true) unawaited(_rollBack(id, error));
  }

  Future<void> _ready(_Running running, {required bool reloaded}) async {
    final plugin = running.plugin;
    // Running once it has set itself up: what it shows needs that.
    if (!reloaded) {
      try {
        await _call(running, {'call': 'init'});
      } catch (_) {
        return;
      }
    }
    plugin.status = PluginStatus.running;
    _changed(plugin.id);
    unawaited(_confirm(plugin.id));
    if (plugin.granted.contains('live')) {
      node.registry.advertise(plugin.id, 'p:${plugin.id}');
      node.registry.handleDatagrams('p:${plugin.id}', (device, data) {
        final handle = running.handle;
        if (handle == null || _running[plugin.id] != running) return;
        host!.call(handle, {
          'call': 'datagram',
          'device': device,
          'quiet': true,
        }, data);
      }, owner: plugin.id);
    }
    final kinds = plugin.manifest.kinds.keys.toSet();
    running.changes ??= node.onChangesTo(kinds, () => _feed(running));
    _feed(running);
  }

  /// Hands [running] the objects of its kinds stored since it last saw them,
  /// a page at a time, each once. Cursors move when the plugin has taken a
  /// page, so a page it crashed on is offered again after a restart.
  void _feed(_Running running) {
    if (running.feeding) {
      running.feedAgain = true;
      return;
    }
    running.feeding = true;
    unawaited(
      _feedAll(running).whenComplete(() {
        running.feeding = false;
        if (running.feedAgain && _running[running.plugin.id] == running) {
          running.feedAgain = false;
          _feed(running);
        }
      }),
    );
  }

  Future<void> _feedAll(_Running running) async {
    final id = running.plugin.id;
    final key = 'pluginCursor/$id';
    final cursors = <String, int>{
      ...?(node.store.setting(key) as Map?)?.cast<String, int>(),
    };
    for (final kind in running.plugin.manifest.kinds.keys) {
      while (_running[id] == running) {
        final page = node.store.objectsAfter(kind, cursors[kind] ?? 0);
        if (page.isEmpty) break;
        final objects = <Json>[];
        var bytes = 0;
        var last = cursors[kind] ?? 0;
        for (final (rowid, o) in page) {
          final object = await _object(o);
          last = rowid;
          if (object == null) continue;
          objects.add(object);
          bytes += (object['payload'] as String).length;
          if (bytes > 512 * 1024) break;
        }
        if (objects.isNotEmpty) {
          try {
            await _call(running, {'call': 'objects', 'objects': objects});
          } catch (_) {
            return;
          }
        }
        cursors[kind] = last;
        node.store.set(key, cursors);
      }
    }
  }

  /// [o] as a plugin sees it; null when this device cannot read it.
  Future<Json?> _object(SignedObject o) async {
    final content = await node.content(o);
    if (content == null) return null;
    return {
      'id': o.id,
      'author': o.author,
      'device': o.certificate.device,
      'kind': o.kind,
      'space': o.space,
      'audience': o.audience,
      'created': o.created,
      'payload': jsonEncode(content),
    };
  }

  Future<void> _answer(
    _Running running,
    int id,
    String fn,
    Object? args,
    Uint8List body,
  ) async {
    Json answer;
    Uint8List? bytes;
    try {
      final result = await _import(
        running.plugin,
        fn,
        args is Map ? args.cast() : const {},
        body,
      );
      // Bytes go after the answer as they are, not as JSON.
      if (result is Uint8List) {
        bytes = result;
        answer = {'ok': null};
      } else {
        answer = {'ok': result};
      }
    } catch (e) {
      answer = {'error': e is StateError ? e.message : '$e'};
    }
    final handle = running.handle;
    if (handle != null && _running[running.plugin.id] == running) {
      host!.answer(handle, id, answer, bytes);
    }
  }

  /// Hands [plugin] a handle to an attachment stored already (`name`,
  /// `size`, `chunks`, `chunkBytes`, `key`), such as a file the person
  /// picked, for `files.publish`. Null when it is not running.
  String? addFile(String plugin, Json file) {
    final running = _running[plugin];
    if (running == null) return null;
    final handle = 'f${running.nextFile++}';
    running.files[handle] = Map.unmodifiable({
      for (final key in const [
        'name',
        'size',
        'chunks',
        'chunkTree',
        'chunkDepth',
        'nonces',
        'chunkBytes',
        'key',
      ])
        if (file.containsKey(key)) key: file[key],
    });
    while (running.files.length > maxFileHandles) {
      running.files.remove(running.files.keys.first);
    }
    return handle;
  }

  /// Encrypts [data] into stored chunks, as `Files.store` does a picked
  /// file, and returns the fields that describe it.
  Future<Json> storeFile(String name, Uint8List data) async {
    final key = randomBytes(32);
    final chunks = <String>[];
    for (var at = 0; at < data.length; at += fileChunkBytes) {
      final end = min(at + fileChunkBytes, data.length);
      chunks.add(
        await node.blobs.encode(Uint8List.sublistView(data, at, end), key),
      );
    }
    return {
      'name': name,
      'size': data.length,
      'chunks': chunks,
      'chunkBytes': fileChunkBytes,
      'key': b64(key),
    };
  }

  /// The file attached to [o], at most [maxFileBytes].
  Future<Uint8List> _readFile(SignedObject o) async {
    final payload = await node.content(o);
    if (payload == null || payload['chunks'] is! List) {
      throw StateError('It has no file');
    }
    final size = payload['size'];
    if (size is! int || size > maxFileBytes) {
      throw StateError('Files are at most 16 MiB here');
    }
    final read = readFile;
    if (read != null) {
      // Answered before the host stops waiting, so the plugin hears why.
      return read(o, maxFileBytes).timeout(
        const Duration(seconds: 25),
        onTimeout: () => throw StateError('Not here yet: try again later'),
      );
    }
    final key = payload['key'];
    final local = await node.blobs.readLocal(
      (payload['chunks'] as List).cast(),
      key is String ? unb64(key) : null,
      limit: maxFileBytes,
      expectedSize: size,
    );
    if (local == null) throw StateError('Not here yet: try again later');
    return local;
  }

  Future<Uint8List> _fileRange(
    SignedObject object,
    int offset,
    int length,
  ) async {
    if (offset < 0 || length < 0 || length > 256 * 1024)
      throw StateError('Invalid file range');
    final payload = await node.content(object);
    final size = payload?['size'];
    if (payload == null ||
        size is! int ||
        offset > size ||
        length > size - offset)
      throw StateError('Range is outside file');
    final read = readFileRange;
    if (read != null)
      return read(object, offset, length).timeout(const Duration(seconds: 25));
    final key = payload['key'] is String ? unb64(payload['key']) : null;
    Future<Uint8List> open(String hash) async {
      final plain = await node.blobs.decode(hash, key);
      if (plain == null) throw StateError('File chunk is not here yet');
      return plain;
    }

    final bytes = payload['chunkBytes'] as int;
    final out = BytesBuilder(copy: false);
    var at = offset;
    while (at < offset + length) {
      final hash = await chunkHashAt(payload, at ~/ bytes, open);
      final data = await open(hash);
      final start = at % bytes;
      final n = min(offset + length - at, data.length - start);
      if (n <= 0) throw StateError('File chunk is cut short');
      out.add(Uint8List.sublistView(data, start, start + n));
      at += n;
    }
    return out.takeBytes();
  }

  /// Whether [space] belongs to [plugin]: `x.<plugin>` or under it.
  static bool _ownSpace(String plugin, String space) =>
      space == 'x.$plugin' || space.startsWith('x.$plugin.');

  static final _unsafeName = RegExp(r'[/\\\x00-\x1f]');

  /// Signs and publishes an object of [plugin]'s [kind] from an import's
  /// [args] (`space`, `to`, `payload`), with [file]'s fields attached.
  Future<String> _publish(
    InstalledPlugin plugin,
    String kind,
    Json args, {
    Json? file,
  }) async {
    final space = args['space'];
    if (space is! String || space.isEmpty || space.length > 128) {
      throw StateError('A space is needed');
    }
    final payload = jsonDecode('${args['payload']}');
    if (payload is! Map) throw StateError('A payload is a JSON object');
    final to = args['to'] as Map? ?? const {};
    final List<String> audience;
    if (to['personal'] == true) {
      audience = [node.person];
    } else if (to['people'] case final List people) {
      if (people.isEmpty || people.length > 63) {
        throw StateError('Between 1 and 63 people');
      }
      audience = people.cast<String>();
    } else if (to['group'] == true) {
      final group = (await groups?.call() ?? const <PluginGroup>[])
          .where((g) => g.space == space)
          .firstOrNull;
      if (group == null) throw StateError('Not a group of yours');
      audience = group.members;
    } else if (to['public'] == true) {
      if (!_ownSpace(plugin.id, space)) {
        throw StateError('Public objects go in x.${plugin.id} spaces');
      }
      audience = const [];
    } else {
      throw StateError('No audience');
    }
    final o = await node.publish(
      kind,
      {...(frozen(payload) as Map).cast<String, Object?>(), ...?file},
      space: space,
      audience: audience,
      app: '${plugin.id}@${plugin.manifest.version}',
    );
    return o.id;
  }

  Future<Object?> _import(
    InstalledPlugin plugin,
    String fn,
    Json args, [
    Uint8List? body,
  ]) async {
    // Files are attached to the plugin's own objects: part of that grant.
    final interface = switch (fn.split('.').first) {
      'files' || 'index' => 'objects',
      final other => other,
    };
    if (PluginManifest.grantable.contains(interface) &&
        !plugin.granted.contains(interface)) {
      throw StateError('$interface was not granted');
    }
    String own(Object? kind) {
      if (kind is! String || PluginKinds.pluginOf(kind) != plugin.id) {
        throw StateError('Only x.${plugin.id}.* kinds');
      }
      return kind;
    }

    switch (fn) {
      case 'plugins.offer':
        final last = _lastEvent[plugin.id];
        if (last == null ||
            DateTime.now().difference(last) > const Duration(seconds: 30)) {
          throw StateError('Only when the person asks for it');
        }
        final files = <String, Uint8List>{
          for (final MapEntry(:key, :value)
              in (args['files'] as Map? ?? const {}).entries)
            '$key': base64Decode('$value'),
        };
        final PluginPackage package;
        try {
          package = PluginPackage.of(files);
        } on FormatException catch (e) {
          throw StateError(e.message);
        }
        if (!package.manifest.isScript ||
            files.keys.any((k) => !PluginPackage._entry.hasMatch(k))) {
          throw StateError('Only script plugins can be offered');
        }
        final source = jsonDecode('${args['source']}');
        if (!_offered.isClosed) {
          _offered.add((
            package: package,
            from: plugin.id,
            source: source is Map ? source.cast() : const {},
          ));
        }
        return null;
      case 'objects.publish':
        return _publish(plugin, own(args['kind']), args);
      case 'files.store':
        final name = args['name'];
        if (name is! String ||
            name.trim().isEmpty ||
            name.length > 255 ||
            _unsafeName.hasMatch(name)) {
          throw StateError('A file needs a plain name');
        }
        if (body == null || body.length > maxFileBytes) {
          throw StateError('Files are at most 16 MiB');
        }
        if (_running[plugin.id] == null) throw StateError('Plugin not running');
        return addFile(plugin.id, await storeFile(name.trim(), body));
      case 'files.publish':
        final file = _running[plugin.id]?.files['${args['file']}'];
        if (file == null) throw StateError('No such file: store it first');
        return _publish(plugin, own(args['kind']), args, file: file);
      case 'index.get':
        final value =
            await _index.request(
                  plugin.id,
                  'get',
                  '${args['bucket']}',
                  key: '${args['key']}',
                )
                as Uint8List?;
        return Uint8List.fromList(value == null ? [0] : [1, ...value]);
      case 'index.put':
        await _index.request(
          plugin.id,
          'put',
          '${args['bucket']}',
          entries: [
            for (final e in (args['entries'] as List))
              (e[0] as String, Uint8List.fromList(unb64(e[1] as String))),
          ],
        );
        return null;
      case 'index.clear':
        await _index.request(plugin.id, 'clear', '${args['bucket']}');
        return null;
      case 'files.range':
        final o = node.store.get('${args['id']}');
        if (o == null || PluginKinds.pluginOf(o.kind) != plugin.id)
          throw StateError('No such object of this plugin');
        return _fileRange(o, args['offset'] as int, args['length'] as int);
      case 'files.read':
        final o = node.store.get('${args['id']}');
        if (o == null || PluginKinds.pluginOf(o.kind) != plugin.id) {
          throw StateError('No such object of this plugin');
        }
        return _readFile(o);
      case 'objects.get':
        final o = node.store.get('${args['id']}');
        if (o == null || PluginKinds.pluginOf(o.kind) != plugin.id) return null;
        return _object(o);
      case 'objects.query':
        final kind = own(args['kind']);
        final before = args['before'];
        final found = node.store.objects(
          kind: kind,
          space: args['space'] as String?,
          author: args['author'] as String?,
          after: before is List && before.length == 2
              ? (before[0] as int, before[1] as String)
              : null,
          limit: ((args['limit'] as int?) ?? 50).clamp(1, 500),
        );
        return [
          for (final o in found)
            if (await _object(o) case final Json object) object,
        ];
      case 'objects.follow':
        final space = '${args['space']}';
        if (!_ownSpace(plugin.id, space)) {
          throw StateError('Only x.${plugin.id} spaces');
        }
        final on = args['on'] == true;
        await (follow?.call(space, on) ??
            Future.sync(() => node.subscribe(space, on)));
        return null;
      case 'identity.me':
        return node.person;
      case 'clipboard-write.write':
        final text = args['text'];
        if (text is! String || utf8.encode(text).length > 16384) {
          throw StateError('Text exceeds 16 KiB');
        }
        final write = writeClipboard;
        if (write == null) throw StateError('Clipboard is unavailable');
        await write(text);
        return null;
      case 'identity.device':
        return node.identity.device;
      case 'identity.contacts':
        final names = _deviceNames();
        final now = node.now();
        final people = <String, List<Json>>{};
        for (final c in node.contacts.values) {
          if (!node.allowedPeer(c.device)) continue;
          final seen = node.lastSeen(c.device);
          (people[c.person] ??= []).add({
            'id': c.device,
            'name': names[c.device] ?? c.label,
            'online': seen != null && now - seen < 10 * 60 * 1000,
            'plugin': link?.runs(c.device, plugin.id) ?? false,
          });
        }
        return [
          for (final MapEntry(key: person, value: devices) in people.entries)
            {
              'person': person,
              'name': nameOf?.call(person) ?? '',
              'devices': devices,
            },
        ];
      case 'remote-desktop.admit':
        final device = '${args['device']}';
        // The native host has refused anyone else's device already.
        if (!ownDevice(device)) {
          throw StateError('remote-desktop is only for your own devices');
        }
        final now = DateTime.now();
        _desktopAdmitted.removeWhere((_, until) => now.isAfter(until));
        if (_desktopAdmitted.length >= 16) {
          throw StateError('Too many devices waiting to connect');
        }
        _desktopAdmitted[(plugin.id, device)] = now.add(desktopAdmission);
        return null;
      case 'remote-desktop.view':
        final open = openDesktop;
        if (open == null) {
          throw StateError('Remote desktop does not run on this device');
        }
        final device = '${args['device']}';
        if (device != node.identity.device && !ownDevice(device)) {
          throw StateError('remote-desktop is only for your own devices');
        }
        final options = jsonDecode('${args['options']}');
        return open(plugin.id, device, options is Map ? options.cast() : {});
      case 'remote-desktop.close':
        closeDesktop?.call('${args['session']}');
        return null;
      case 'tun.open':
        final open = openTun;
        if (open == null) throw StateError('VPNs do not run on this device');
        return open(plugin.id, args);
      case 'identity.groups':
        return [
          for (final g in await groups?.call() ?? const <PluginGroup>[])
            {'space': g.space, 'name': g.name, 'members': g.members},
        ];
    }
    throw StateError('Unknown import $fn');
  }

  Future<void> _send(
    _Running running,
    int request,
    String device,
    Uint8List body,
  ) async {
    Json reply;
    Uint8List? bytes;
    try {
      final link = this.link;
      if (link == null) throw StateError('Offline');
      if (!running.plugin.granted.contains('live')) {
        throw StateError('live was not granted');
      }
      if (body.length > maxLiveBytes) throw StateError('Message too large');
      final answer = await link.request(device, {
        'type': liveRequest,
        'plugin': running.plugin.id,
        // Receivers running another publisher's plugin of that ID refuse it;
        // builds before publishers ignore it.
        'publisher': ?running.plugin.publisher,
        'payload': b64(body),
      });
      bytes = Uint8List.fromList(unb64('${answer['payload']}'));
      reply = {'call': 'reply', 'request': request};
    } catch (e) {
      reply = {
        'call': 'reply',
        'request': request,
        'error': e is StateError ? e.message : 'Unreachable',
      };
    }
    if (_running[running.plugin.id] == running) {
      unawaited(
        _call(running, reply, bytes).then((_) {}, onError: (Object _) {}),
      );
    }
  }

  /// Whether a running plugin takes requests from this computer
  /// ([LocalBridge]).
  bool get takesLocal => _running.values.any(
    (r) => r.handle != null && r.plugin.granted.contains('local'),
  );

  _Running _localFiles(String plugin) {
    final running = _running[plugin];
    if (running == null ||
        running.handle == null ||
        !running.plugin.granted.contains('local') ||
        !running.plugin.granted.contains('objects')) {
      throw StateError('No plugin $plugin takes local files here');
    }
    return running;
  }

  Future<String> localStoreFile(
    String plugin,
    Stream<List<int>> source,
    int size,
  ) async {
    final running = _localFiles(plugin);
    final store = storeFileStream;
    if (store == null) throw StateError('Streaming files are unavailable here');
    if (size < 0) throw StateError('An exact file length is required');
    final file = await store(source, size, 'pack');
    if (_running[plugin] != running)
      throw StateError('Plugin stopped during upload');
    return addFile(plugin, file)!;
  }

  Future<(int, Stream<List<int>>)> localOpenFile(
    String plugin,
    String id,
  ) async {
    _localFiles(plugin);
    final object = node.store.get(id);
    if (object == null || PluginKinds.pluginOf(object.kind) != plugin) {
      throw StateError('No such object of this plugin');
    }
    final content = await node.content(object);
    final size = content?['size'];
    final open = openFileStream;
    if (size is! int || size < 0 || open == null)
      throw StateError('Streaming file unavailable');
    return (size, open(object));
  }

  /// Hands [plugin] (granted `local`) a request from a program on this
  /// computer, as its `on-request` from device `local`, and returns its
  /// answer. Throws [StateError] with the plugin's refusal.
  Future<Uint8List> local(String plugin, Uint8List body) async {
    final running = _running[plugin];
    if (running == null || !running.plugin.granted.contains('local')) {
      throw StateError('No plugin $plugin takes local requests here');
    }
    final result = await _call(running, {
      'call': 'request',
      'device': localDevice,
    }, body).timeout(const Duration(minutes: 5));
    return result.body;
  }

  /// The device a local request comes from, as plugins see it.
  static const localDevice = 'local';

  /// A live message from [device] for one of the plugins here.
  Future<Json> _answerRequest(String device, Json request) async {
    final running = _running['${request['plugin']}'];
    if (running == null || !running.plugin.granted.contains('live')) {
      throw StateError('Plugin not running');
    }
    final publisher = request['publisher'];
    if (publisher != null &&
        running.plugin.publisher != null &&
        publisher != running.plugin.publisher) {
      throw StateError('Another plugin by that name runs here');
    }
    final payload = request['payload'];
    if (payload is! String || payload.length > maxLiveBytes * 4 ~/ 3 + 4) {
      throw StateError('Invalid plugin message');
    }
    final result = await _call(running, {
      'call': 'request',
      'device': device,
      'own': ownDevice(device),
    }, Uint8List.fromList(unb64(payload))).timeout(const Duration(seconds: 10));
    return {'payload': b64(result.body)};
  }
}

class _Running {
  final InstalledPlugin plugin;
  int? handle;
  int nextCall = 0;
  final calls = <int, Completer<PluginMessage>>{};

  /// Files stored for it to attach, by handle ([Plugins.addFile]).
  final files = <String, Json>{};
  int nextFile = 0;
  StreamSubscription<Set<String>>? changes;
  bool feeding = false, feedAgain = false;
  _Running(this.plugin);
}
