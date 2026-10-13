import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:ournet_native/plugin_host.dart';

import 'model.dart';
import 'node.dart';
import 'plugin_manifest.dart';
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

/// Something a plugin said that the app may show: a notification, a log
/// line, or that it stopped.
typedef PluginNotice = ({
  String plugin,
  String kind,
  String title,
  String body,
});

/// A package as read from its file: `manifest.json`, `plugin.wasm`,
/// optionally `ui.rfwtxt` and files under `assets/`.
class PluginPackage {
  final PluginManifest manifest;
  final Uint8List wasm;
  final String? ui;
  final Map<String, Uint8List> assets;
  PluginPackage._(this.manifest, this.wasm, this.ui, this.assets);

  /// Largest package, unpacked: generous for code, small for a phone.
  static const maxBytes = 32 * 1024 * 1024;

  /// Reads a package, throwing [FormatException] for anything not to install.
  factory PluginPackage.read(Uint8List bytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const FormatException('Not a plugin package');
    }
    var total = 0;
    Json? manifest;
    Uint8List? wasm;
    String? ui;
    final assets = <String, Uint8List>{};
    for (final file in archive.files) {
      if (!file.isFile) continue;
      total += file.size;
      if (total > maxBytes) throw const FormatException('Package too large');
      final content = file.readBytes() ?? Uint8List(0);
      switch (file.name) {
        case 'manifest.json':
          manifest = jsonDecode(utf8.decode(content)) as Json;
        case 'plugin.wasm':
          wasm = content;
        case 'ui.rfwtxt':
          // RFW's parser takes Unix line ends only; Windows checkouts and
          // editors write others.
          ui = utf8.decode(content).replaceAll('\r\n', '\n');
        default:
          final name = file.name.startsWith('assets/')
              ? file.name.substring(7)
              : null;
          if (name != null && _assetName.hasMatch(name)) assets[name] = content;
      }
    }
    if (manifest == null || wasm == null) {
      throw const FormatException(
        'A package needs manifest.json and plugin.wasm',
      );
    }
    return PluginPackage._(PluginManifest.parse(manifest), wasm, ui, assets);
  }

  static final _assetName = RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}$');
}

/// An installed plugin and its state on this device.
class InstalledPlugin {
  PluginManifest manifest;
  final Set<String> granted;
  bool enabled;
  PluginStatus status = PluginStatus.stopped;
  String? error;
  String? ui;
  InstalledPlugin._(this.manifest, this.granted, this.enabled, this.ui);
  String get id => manifest.id;
}

/// Installs, runs and answers plugins (PLUGINS.md). Each runs in the native
/// host on a thread of its own; this side answers its imports from the node,
/// feeds it new objects of its kinds through insertion cursors (never a
/// history scan), carries its live messages and keeps what its surfaces
/// show. Its kinds, sections and live requests go into [Node.registry], next
/// to the built-in ones.
class Plugins {
  final Node node;

  /// Where packages are unpacked, one directory each, and compiled code is
  /// cached. Plugin storage lives in each plugin's directory.
  final String directory;
  final PluginHost? host;

  /// The network, once there is one: live messages need it.
  PluginLink? link;

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

  /// Closes what [openTun] opened for [plugin].
  void Function(String plugin)? closeTun;

  /// Where compiled code is kept; [directory]'s `.cache` unless given.
  final String cache;

  Plugins(
    this.node, {
    required this.directory,
    String? cache,
    PluginHost? host,
  }) : cache = cache ?? '$directory/.cache',
       host = host ?? PluginHost.instance {
    node.registry.handle(
      liveRequest,
      _answerRequest,
      owner: 'plugins',
      poolable: true,
    );
  }

  /// The live request type plugins' messages travel as.
  static const liveRequest = 'plugin';

  /// Largest live message, either way.
  static const maxLiveBytes = 256 * 1024;

  final _installed = <String, InstalledPlugin>{};
  final _running = <String, _Running>{};
  final _surfaces = <String, Map<String, Json>>{};
  final _changes = StreamController<String>.broadcast();
  final _tunPackets =
      StreamController<({String plugin, Uint8List packet})>.broadcast();
  final _notices = StreamController<PluginNotice>.broadcast();
  bool _closed = false;

  /// Whether plugins can run on this device at all.
  bool get available => host != null;

  /// Fires with a plugin's ID when its status or what it shows changes.
  Stream<String> get changes => _changes.stream;
  Stream<PluginNotice> get notices => _notices.stream;

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

  Json get _settings => (node.store.setting('plugins') as Map?)?.cast() ?? {};
  void _saveSettings(Json settings) => node.store.set('plugins', settings);

  /// Reads installed plugins and starts the enabled ones.
  Future<void> load() async {
    final settings = _settings;
    for (final MapEntry(key: id, value: s) in settings.entries) {
      if (s is! Map) continue;
      try {
        final dir = '$directory/$id';
        final manifest = PluginManifest.parse(
          jsonDecode(await File('$dir/manifest.json').readAsString()) as Json,
        );
        final ui = File('$dir/ui.rfwtxt');
        final plugin = InstalledPlugin._(
          manifest,
          {...(s['grants'] as List? ?? const []).cast<String>()},
          s['enabled'] != false,
          await ui.exists() ? await ui.readAsString() : null,
        );
        _installed[id] = plugin;
        _register(plugin);
        if (plugin.enabled) await _start(plugin);
      } catch (e) {
        _notice(id, 'error', 'Could not load plugin', '$e');
      }
    }
  }

  /// Installs [package] with [grants] (which the person agreed to, from
  /// [PluginPackage.manifest]'s `grants`) and starts it. Installing a plugin
  /// already installed updates it in place: its storage stays, and a running
  /// one is reloaded with its state. A new version asking for more grants
  /// must be given them here.
  Future<InstalledPlugin> install(
    PluginPackage package, {
    required Set<String> grants,
  }) async {
    final manifest = package.manifest;
    if (!grants.containsAll(manifest.grants)) {
      throw StateError(
        'Grant ${manifest.grants.difference(grants).join(', ')} first',
      );
    }
    final dir = Directory('$directory/${manifest.id}');
    await dir.create(recursive: true);
    await File(
      '${dir.path}/manifest.json',
    ).writeAsString(jsonEncode(manifest.json));
    await File('${dir.path}/plugin.wasm').writeAsBytes(package.wasm);
    final ui = File('${dir.path}/ui.rfwtxt');
    if (package.ui != null) {
      await ui.writeAsString(package.ui!);
    } else if (await ui.exists()) {
      await ui.delete();
    }
    if (package.assets.isNotEmpty) {
      await Directory('${dir.path}/assets').create();
      for (final MapEntry(:key, :value) in package.assets.entries) {
        await File('${dir.path}/assets/$key').writeAsBytes(value);
      }
    }
    final existing = _installed[manifest.id];
    final plugin =
        existing ?? InstalledPlugin._(manifest, {...grants}, true, package.ui);
    plugin
      ..manifest = manifest
      ..ui = package.ui
      ..enabled = true;
    plugin.granted
      ..clear()
      ..addAll(grants.intersection(manifest.grants));
    _installed[manifest.id] = plugin;
    _saveSettings({
      ..._settings,
      manifest.id: {'grants': plugin.granted.toList()..sort(), 'enabled': true},
    });
    node.registry.removeOwner(manifest.id);
    _register(plugin);
    final running = _running[manifest.id];
    if (running != null && running.handle != null) {
      plugin.status = PluginStatus.starting;
      host!.reload(running.handle!, package.wasm);
    } else {
      await _start(plugin);
    }
    _changed(manifest.id);
    return plugin;
  }

  /// Removes [id] and everything it kept on this device. Objects it
  /// published stay: they are signed by this person and may have synced.
  Future<void> uninstall(String id) async {
    _stop(id);
    node.registry.removeOwner(id);
    _installed.remove(id);
    _surfaces.remove(id);
    _saveSettings({..._settings}..remove(id));
    node.store.set('pluginCursor/$id', null);
    final dir = Directory('$directory/$id');
    if (await dir.exists()) await dir.delete(recursive: true);
    _changed(id);
  }

  Future<void> setEnabled(String id, bool on) async {
    final plugin = _installed[id];
    if (plugin == null || plugin.enabled == on) return;
    plugin.enabled = on;
    final settings = _settings;
    _saveSettings({
      ...settings,
      id: {...(settings[id] as Map? ?? {}), 'enabled': on},
    });
    if (on) {
      await _start(plugin);
    } else {
      _stop(id);
    }
    _changed(id);
  }

  /// Starts a stopped or failed plugin again.
  Future<void> restart(String id) async {
    final plugin = _installed[id];
    if (plugin == null) return;
    _stop(id);
    await _start(plugin);
  }

  /// [surface] of [id] is being shown; [context] says in which scope.
  void open(String id, String surface, Json context) => _fire(id, {
    'call': 'open',
    'surface': surface,
    'context': jsonEncode(context),
  });

  /// A widget in [surface] fired [name] with [args].
  void event(String id, String surface, String name, Json args) => _fire(id, {
    'call': 'event',
    'surface': surface,
    'name': name,
    'args': jsonEncode(args),
  });

  /// Development: reinstalls a plugin whenever its package in [folder]
  /// (`<id>.ournet-plugin`, as `plugins/pack --watch` writes) changes, hot
  /// reloading it with its state. Only plugins already installed, and only
  /// when the new version asks for no more than was granted. Desktop only:
  /// returns false where the folder cannot be watched.
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
            final package = PluginPackage.read(
              await File(event.path).readAsBytes(),
            );
            if (!plugin.granted.containsAll(package.manifest.grants)) {
              _notice(
                id,
                'error',
                'Not reloaded',
                'It asks for more: reinstall it',
              );
              return;
            }
            await install(package, grants: plugin.granted);
            _notice(id, 'log', 'info', 'Reloaded ${package.manifest.version}');
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
    node.registry.unhandle(liveRequest, _answerRequest);
    await _changes.close();
    await _tunPackets.close();
    await _notices.close();
  }

  void _register(InstalledPlugin plugin) {
    for (final MapEntry(:key, :value) in plugin.manifest.kinds.entries) {
      node.registry.addKind(plugin.id, key, value);
    }
    for (final section in plugin.manifest.sections) {
      node.registry.addSection(section);
    }
  }

  Future<void> _start(InstalledPlugin plugin) async {
    if (_closed || _running.containsKey(plugin.id)) return;
    final host = this.host;
    if (host == null) {
      plugin
        ..status = PluginStatus.failed
        ..error = 'Plugins do not run on this device';
      _changed(plugin.id);
      return;
    }
    final dir = '$directory/${plugin.id}';
    final Uint8List wasm;
    try {
      wasm = await File('$dir/plugin.wasm').readAsBytes();
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

  void _stop(String id) {
    final running = _running.remove(id);
    if (running == null) return;
    running.changes?.cancel();
    node.registry.withdraw(id);
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

  void _changed(String id) {
    if (!_changes.isClosed) _changes.add(id);
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
      case 'result':
        final call = running.calls.remove(h['id']);
        if (call == null) return;
        if (h['error'] != null) {
          call.completeError(StateError('${h['error']}'));
        } else {
          call.complete(message);
        }
      case 'import':
        unawaited(_answer(running, h['id'] as int, '${h['fn']}', h['args']));
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
        _changed(plugin.id);
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
  ) async {
    Json answer;
    try {
      answer = {
        'ok': await _import(
          running.plugin,
          fn,
          args is Map ? args.cast() : const {},
        ),
      };
    } catch (e) {
      answer = {'error': e is StateError ? e.message : '$e'};
    }
    final handle = running.handle;
    if (handle != null && _running[running.plugin.id] == running) {
      host!.answer(handle, id, answer);
    }
  }

  /// Whether [space] belongs to [plugin]: `x.<plugin>` or under it.
  static bool _ownSpace(String plugin, String space) =>
      space == 'x.$plugin' || space.startsWith('x.$plugin.');

  Future<Object?> _import(InstalledPlugin plugin, String fn, Json args) async {
    final interface = fn.split('.').first;
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
      case 'objects.publish':
        final kind = own(args['kind']);
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
          (frozen(payload) as Map).cast(),
          space: space,
          audience: audience,
          app: '${plugin.id}@${plugin.manifest.version}',
        );
        return o.id;
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
      case 'identity.device':
        return node.identity.device;
      case 'identity.contacts':
        final names = node.deviceNames();
        final now = node.now();
        final people = <String, List<Json>>{};
        for (final c in node.contacts.values) {
          if (!node.allowedPeer(c.device)) continue;
          final seen = node.lastSeen(c.device);
          (people[c.person] ??= []).add({
            'id': c.device,
            'name': names[c.device] ?? '',
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

  /// A live message from [device] for one of the plugins here.
  Future<Json> _answerRequest(String device, Json request) async {
    final running = _running['${request['plugin']}'];
    if (running == null || !running.plugin.granted.contains('live')) {
      throw StateError('Plugin not running');
    }
    final payload = request['payload'];
    if (payload is! String || payload.length > maxLiveBytes * 4 ~/ 3 + 4) {
      throw StateError('Invalid plugin message');
    }
    final result = await _call(running, {
      'call': 'request',
      'device': device,
    }, Uint8List.fromList(unb64(payload))).timeout(const Duration(seconds: 10));
    return {'payload': b64(result.body)};
  }
}

class _Running {
  final InstalledPlugin plugin;
  int? handle;
  int nextCall = 0;
  final calls = <int, Completer<PluginMessage>>{};
  StreamSubscription<Set<String>>? changes;
  bool feeding = false, feedAgain = false;
  _Running(this.plugin);
}
