import 'dart:async';
import 'dart:typed_data';

import 'builtin_modules.dart';
import 'model.dart';
import 'public_chats.dart';
import 'scopes.dart';

/// Decides whether a payload is acceptable content for one kind. Pure and
/// cheap: it runs for every object stored, received or read.
typedef ContentCheck = bool Function(Json payload);

/// Answers one live request from an admitted device: the device and the
/// request as sent (`{type, …}`), returning the reply. Nothing is stored.
typedef RequestHandler = Future<Json> Function(String device, Json request);

/// Takes one live datagram from an admitted device: unreliable, unordered,
/// and never answered.
typedef DatagramHandler = void Function(String device, Uint8List data);

/// What a feature contributes to the host: the kinds it owns and how their
/// content is checked. Built-in features declare one as a constant (see
/// `builtin_modules.dart`); plugins declare the same things at run time
/// through [Registry]. The host does not care which tier provides a kind.
class Module {
  /// Stable and unique: `notes`, `public_chats`, or a plugin's ID.
  final String id;
  final Map<String, ContentCheck> kinds;
  const Module(this.id, {this.kinds = const {}});
}

/// Every module compiled into this build.
const builtinModules = <Module>[
  notesModule,
  forumsModule,
  votingModule,
  listingsModule,
  groupsModule,
  messagesModule,
  driveModule,
  peopleModule,
  calendarModule,
  locationsModule,
  PublicChats.module,
];

/// Built-in checks by kind. Built from constants, so every isolate that
/// verifies objects has the same table without being handed it.
final Map<String, ContentCheck> _builtinKinds = {
  for (final module in builtinModules) ...module.kinds,
};

/// Kinds and spaces that belong to a plugin: `x.<plugin>.<name>`. Core kinds
/// are never prefixed, so the two cannot collide, and a build without the
/// plugin still stores and relays them (see [validContent]).
abstract final class PluginKinds {
  static const prefix = 'x.';

  /// A plugin ID: short, lower case, safe in a kind, a space and a path.
  static final id = RegExp(r'^[a-z][a-z0-9-]{0,23}$');

  /// The largest payload a plugin kind may carry, as canonical JSON. Objects
  /// have a hard cap of their own; this keeps one plugin from using all of it.
  static const maxPayloadBytes = 64 * 1024;

  /// [name] in [plugin]'s namespace.
  static String of(String plugin, String name) => '$prefix$plugin.$name';

  /// The plugin that owns [kindOrSpace], or null for a core one.
  static String? pluginOf(String kindOrSpace) {
    if (!kindOrSpace.startsWith(prefix)) return null;
    final end = kindOrSpace.indexOf('.', prefix.length);
    if (end < 0) return null;
    final plugin = kindOrSpace.substring(prefix.length, end);
    return id.hasMatch(plugin) && end < kindOrSpace.length - 1 ? plugin : null;
  }
}

/// Whether [p] is acceptable content for [kind], as every build checks it.
/// Fields any kind may carry (attachments, text) are checked first; then the
/// owning module's check. Plugin kinds are only held to a size cap here: the
/// plugin's own check runs where it is installed ([Registry.accepts]), so a
/// friend without the plugin still carries its data. Kinds nobody here knows
/// are accepted, so newer builds can add kinds older ones keep and relay.
bool validContent(String kind, Json p) {
  if (p['chunkBytes'] != null && !validChunkBytes(p['chunkBytes'])) {
    return false;
  }
  if (p['driveFormat'] != null && p['driveFormat'] is! int) return false;
  if (p['reg'] != null && p['reg'] is! int) return false;
  if (p['text'] != null &&
      (p['text'] is! String || (p['text'] as String).length > 65536)) {
    return false;
  }
  if (p['parent'] != null && p['parent'] is! String) return false;
  if (p['chunks'] != null) {
    if (p['chunks'] is! List ||
        (p['chunks'] as List).length > 513 ||
        !(p['chunks'] as List).every(
          (h) => h is String && _chunkHash.hasMatch(h),
        ) ||
        p['size'] is! int ||
        p['size'] < 0 ||
        p['size'] > 64 * 1024 * 1024 ||
        p['name'] is! String ||
        (p['name'] as String).length > 255 ||
        (p['key'] != null && p['key'] is! String)) {
      return false;
    }
  }
  final check = _builtinKinds[kind];
  if (check != null) return check(p);
  if (PluginKinds.pluginOf(kind) != null) {
    try {
      return bytes(p).length <= PluginKinds.maxPayloadBytes;
    } catch (_) {
      return false;
    }
  }
  return true;
}

final _chunkHash = RegExp(r'^[0-9a-f]{64}$');

/// A navigation entry a plugin adds: a page showing one of its surfaces.
class PluginSection implements Section {
  /// `x.<plugin>.<name>`, like a kind.
  @override
  final String id;
  final String plugin;
  final String title;

  /// A Material icon name from the manifest, mapped by the app; unknown
  /// names get a generic icon.
  final String icon;

  /// The plugin surface the page renders.
  final String surface;
  @override
  final Set<ScopeKind> scopes;
  const PluginSection({
    required this.id,
    required this.plugin,
    required this.title,
    required this.icon,
    required this.surface,
    this.scopes = const {ScopeKind.personal, ScopeKind.group, ScopeKind.public},
  });
  @override
  bool allows(ScopeKind? scope) => scope == null || scopes.contains(scope);
}

/// What modules contribute at run time on this node: plugin kinds and their
/// checks, live request handlers and navigation sections. Built-in kinds are
/// in [builtinModules]; built-in features register their request handlers
/// here like plugins do, so the network has one table to answer from.
class Registry {
  final _kinds = <String, ({String owner, ContentCheck check})>{};
  final _requests =
      <String, ({String owner, RequestHandler handle, bool poolable})>{};
  final _sections = <String, PluginSection>{};
  final _capabilities = <String, String>{};
  final _datagrams = <String, ({String owner, DatagramHandler handle})>{};
  final _changes = StreamController<void>.broadcast();

  /// Fires when sections are added or removed.
  Stream<void> get changes => _changes.stream;

  /// Adds [owner]'s check for [kind], on top of [validContent]. Only plugin
  /// kinds in the owner's own namespace may be added.
  void addKind(String owner, String kind, ContentCheck check) {
    if (PluginKinds.pluginOf(kind) != owner) {
      throw ArgumentError('$owner may only declare x.$owner.* kinds');
    }
    _kinds[kind] = (owner: owner, check: check);
  }

  /// Whether [p] is acceptable content for [kind] on this node: what every
  /// build checks, and the installed plugin's own check for its kinds.
  bool accepts(String kind, Json p) {
    if (!validContent(kind, p)) return false;
    final plugin = _kinds[kind];
    if (plugin == null) return true;
    try {
      return plugin.check(p);
    } catch (_) {
      return false;
    }
  }

  /// The kinds [owner] declared.
  Iterable<String> kindsOf(String owner) => [
    for (final e in _kinds.entries)
      if (e.value.owner == owner) e.key,
  ];

  /// Answers live requests of [type] with [handler]. [poolable] requests are
  /// safe to send twice, so they may share a pooled connection. Replaces any
  /// earlier handler for the type.
  void handle(
    String type,
    RequestHandler handler, {
    String owner = 'app',
    bool poolable = false,
  }) => _requests[type] = (owner: owner, handle: handler, poolable: poolable);

  /// Stops answering [type]; when [handler] is given, only if it is still the
  /// one answering, so a newer owner is not removed by an older one.
  void unhandle(String type, [RequestHandler? handler]) {
    if (handler == null || _requests[type]?.handle == handler) {
      _requests.remove(type);
    }
  }

  RequestHandler? handler(String type) => _requests[type]?.handle;
  bool poolable(String type) => _requests[type]?.poolable ?? false;

  void addSection(PluginSection section) {
    _sections[section.id] = section;
    _changes.add(null);
  }

  /// Plugin sections, in the order they were added.
  List<PluginSection> get sections => List.unmodifiable(_sections.values);

  /// Tells peers [owner] can do [capability] (`p:<plugin>` for a plugin that
  /// takes live messages), in the capabilities sync messages carry.
  void advertise(String owner, String capability) =>
      _capabilities[capability] = owner;

  /// Takes datagrams on [channel] (`p:<plugin>` for a plugin's).
  void handleDatagrams(
    String channel,
    DatagramHandler handler, {
    required String owner,
  }) => _datagrams[channel] = (owner: owner, handle: handler);

  DatagramHandler? datagramHandler(String channel) =>
      _datagrams[channel]?.handle;

  /// Stops what [owner] offers while it runs: the capabilities it
  /// advertises and the datagrams it takes.
  void withdraw(String owner) {
    _capabilities.removeWhere((_, o) => o == owner);
    _datagrams.removeWhere((_, v) => v.owner == owner);
  }

  /// What modules add to this build's capabilities, sorted.
  List<String> get capabilities => _capabilities.keys.toList()..sort();

  /// Takes away everything [owner] contributed: on unloading a plugin, and
  /// before its new version registers again.
  void removeOwner(String owner) {
    _kinds.removeWhere((_, v) => v.owner == owner);
    _requests.removeWhere((_, v) => v.owner == owner);
    withdraw(owner);
    final before = _sections.length;
    _sections.removeWhere((_, v) => v.plugin == owner);
    if (_sections.length != before) _changes.add(null);
  }
}
