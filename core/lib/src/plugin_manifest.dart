import 'model.dart';
import 'registry.dart';
import 'scopes.dart';

/// What a plugin package declares in `manifest.json`: who it is, what it may
/// reach, the kinds it owns and how their payloads are checked, and where it
/// appears. See docs/PLUGINS.md.
class PluginManifest {
  /// Interfaces every plugin may use.
  static const always = {'log', 'clock', 'storage', 'ui'};

  /// Interfaces a plugin uses only when the person grants them at install:
  /// its own objects, names and groups, live messages to friends, a virtual
  /// network interface (a VPN), and requests from programs on this computer
  /// through the app's [LocalBridge] (git, for the Git plugin). Device
  /// monitoring, process control, input and clipboard writes are separate grants.
  static const grantable = {
    'objects',
    'identity',
    'live',
    'tun',
    'local',
    'system-monitor',
    'process-control',
    'remote-input',
    'clipboard-write',
  };

  /// The plugin API versions this build hosts. 0.3 adds permissioned device
  /// monitoring, process control, input and clipboard writes. 0.2 adds `files`.
  /// 0.4 adds bounded file ranges and disk-backed derived indexes.
  /// Packages declare the API they need so older builds refuse them when
  /// reading the package rather than failing to start them.
  static const apis = {'0.1', '0.2', '0.3', '0.4'};

  final String id;
  final String name;
  final String version;
  final String api;
  final String description;
  final Set<String> grants;

  /// For a language runtime (docs/SCRIPTING.md): what it runs, as
  /// `runtime:<language>@<major>`, such as `runtime:js@1`. A runtime has no
  /// grants, kinds or sections of its own; it runs only for script plugins,
  /// each time with theirs.
  final String? provides;

  /// For a script plugin: the runtime it needs, as `<language>@<major>`.
  /// Its package then carries scripts instead of `plugin.wasm`.
  final String? runtime;

  /// Checks for each kind the plugin owns, by full kind (`x.<id>.<name>`).
  final Map<String, ContentCheck> kinds;
  final List<PluginSection> sections;

  /// How search and the activity feed list its kinds, by full kind.
  final Map<String, PluginListing> search, activity;
  final Json json;

  PluginManifest._(
    this.json, {
    required this.id,
    required this.name,
    required this.version,
    required this.api,
    required this.description,
    required this.grants,
    required this.kinds,
    required this.sections,
    this.search = const {},
    this.activity = const {},
    this.provides,
    this.runtime,
  });

  bool get isRuntime => provides != null;
  bool get isScript => runtime != null;

  /// Reads a manifest, throwing [FormatException] for anything this build
  /// would not run.
  factory PluginManifest.parse(Json j) {
    String text(String key, int max, {bool required = true}) {
      final v = j[key];
      if (v == null && !required) return '';
      if (v is! String || v.trim().isEmpty || v.length > max) {
        throw FormatException('manifest: $key must be text of up to $max');
      }
      return v.trim();
    }

    final id = text('id', 24);
    if (!PluginKinds.id.hasMatch(id)) {
      throw const FormatException('manifest: id must be like my-plugin');
    }
    final api = text('api', 8);
    if (!apis.contains(api)) {
      throw FormatException('manifest: API $api is not supported here');
    }
    final grants = <String>{};
    for (final g in j['grants'] as List? ?? const []) {
      if (g is! String || !grantable.contains(g)) {
        throw FormatException('manifest: unknown grant $g');
      }
      grants.add(g);
    }
    final kinds = <String, ContentCheck>{};
    final declared = j['kinds'] ?? const {};
    if (declared is! Map || declared.length > 32) {
      throw const FormatException('manifest: kinds must be a map');
    }
    for (final MapEntry(:key, :value) in declared.entries) {
      if (key is! String || !_name.hasMatch(key)) {
        throw FormatException('manifest: bad kind name $key');
      }
      if (value is! Map) throw FormatException('manifest: kind $key');
      kinds[PluginKinds.of(id, key)] = PayloadSchema.parse(value.cast());
    }
    final sections = <PluginSection>[];
    final listed = j['sections'] ?? const [];
    if (listed is! List || listed.length > 4) {
      throw const FormatException('manifest: at most 4 sections');
    }
    for (final s in listed) {
      if (s is! Map ||
          s['name'] is! String ||
          !_name.hasMatch(s['name']) ||
          s['title'] is! String ||
          (s['title'] as String).length > 40 ||
          s['surface'] is! String) {
        throw const FormatException('manifest: bad section');
      }
      final scopes = <ScopeKind>{
        for (final name
            in s['scopes'] as List? ?? ScopeKind.values.map((k) => k.name))
          ScopeKind.values.firstWhere(
            (k) => k.name == name,
            orElse: () => throw FormatException('manifest: scope $name'),
          ),
      };
      sections.add(
        PluginSection(
          id: PluginKinds.of(id, s['name']),
          plugin: id,
          title: s['title'],
          icon: s['icon'] is String ? s['icon'] : 'extension',
          surface: s['surface'],
          scopes: scopes,
        ),
      );
    }
    Map<String, PluginListing> listings(String key, {bool activity = false}) {
      final declared = j[key] ?? const {};
      if (declared is! Map) throw FormatException('manifest: $key is a map');
      final found = <String, PluginListing>{};
      for (final MapEntry(key: name, value: spec) in declared.entries) {
        final kind = PluginKinds.of(id, '$name');
        if (!kinds.containsKey(kind) || spec is! Map) {
          throw FormatException('manifest: $key names kind $name');
        }
        String? field(String k, {bool required = false}) {
          final v = spec[k];
          if (v == null && !required) return null;
          if (v is! String || !_field.hasMatch(v)) {
            throw FormatException('manifest: $key.$name.$k is a field name');
          }
          return v;
        }

        final says = spec['says'];
        if (activity &&
            (says is! String || says.trim().isEmpty || says.length > 40)) {
          throw FormatException('manifest: $key.$name.says is short text');
        }
        found[kind] = PluginListing(
          kind: kind,
          plugin: id,
          title: field('title', required: true)!,
          text: field('text'),
          key: field('key'),
          says: activity ? (says as String).trim() : 'added something',
        );
      }
      return found;
    }

    final provides = j['provides'];
    final runtime = j['runtime'];
    if (provides != null &&
        (provides is! String || !_runtime.hasMatch(provides))) {
      throw const FormatException(
        'manifest: provides must be like runtime:js@1',
      );
    }
    if (runtime != null &&
        (runtime is! String || !_language.hasMatch(runtime))) {
      throw const FormatException('manifest: runtime must be like js@1');
    }
    if (provides != null &&
        (runtime != null ||
            grants.isNotEmpty ||
            kinds.isNotEmpty ||
            sections.isNotEmpty)) {
      throw const FormatException(
        'manifest: a runtime has no grants, kinds, sections or runtime',
      );
    }
    final main = j['main'];
    if (main != null && (main is! String || !main.startsWith('scripts/'))) {
      throw const FormatException('manifest: main must be in scripts/');
    }
    return PluginManifest._(
      j,
      provides: provides as String?,
      runtime: runtime as String?,
      id: id,
      name: text('name', 50),
      version: text('version', 32),
      api: api,
      description: text('description', 500, required: false),
      grants: grants,
      kinds: kinds,
      sections: sections,
      search: listings('search'),
      activity: listings('activity', activity: true),
    );
  }

  /// Why friends on this version and [next] could not read each other's
  /// data; empty when they can. Each side checks the other's objects with
  /// its own rules, so an existing field's rule may not change either way,
  /// a kind may not go, and a new field may not be required (older objects
  /// lack it). New kinds and optional fields are fine. Semantics are not
  /// checked: no manifest can show them.
  List<String> incompatibleWith(PluginManifest next) {
    final problems = <String>[];
    final before = json['kinds'] as Map? ?? const {};
    final after = next.json['kinds'] as Map? ?? const {};
    for (final MapEntry(key: kind, value: fields) in after.entries) {
      final old = before[kind] as Map?;
      for (final MapEntry(key: field, value: rule) in (fields as Map).entries) {
        if (old?[field] == null) {
          if (old != null && rule is Map && rule['required'] == true) {
            problems.add('$kind.$field is new and required');
          }
        } else if (canonical(old![field]) != canonical(rule)) {
          problems.add('$kind.$field changed');
        }
      }
    }
    for (final MapEntry(key: kind, value: fields) in before.entries) {
      if (after[kind] == null) {
        problems.add('$kind is gone');
        continue;
      }
      for (final field in (fields as Map).keys) {
        if ((after[kind] as Map)[field] == null) {
          problems.add('$kind.$field is gone');
        }
      }
    }
    return problems;
  }

  static final _name = RegExp(r'^[a-z][a-z0-9_]{0,31}$');
  static final _field = RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,63}$');
  static final _language = RegExp(r'^[a-z][a-z0-9-]{0,23}@[0-9]{1,4}$');
  static final _runtime = RegExp(r'^runtime:[a-z][a-z0-9-]{0,23}@[0-9]{1,4}$');
}

/// A kind's payload rules, declared in the manifest so the host checks them
/// synchronously wherever objects are read, without calling the plugin:
///
/// ```json
/// "page": {
///   "title": {"type": "string", "max": 200, "required": true},
///   "body": {"type": "string", "max": 60000},
///   "rev": {"type": "int", "min": 0}
/// }
/// ```
///
/// Types are `string` (max: length), `int` (min, max), `bool`, `list` (max:
/// entries; `items`: a rule for each), `map` and `any` (max: bytes as
/// canonical JSON), each optionally `required` and limited to `values`.
/// Fields not declared are allowed, so a newer version can add some.
abstract final class PayloadSchema {
  static ContentCheck parse(Map<String, Object?> fields) {
    final rules = <String, _Rule>{
      for (final MapEntry(:key, :value) in fields.entries)
        key: _Rule.parse(key, value),
    };
    return (Json p) {
      for (final MapEntry(key: name, value: rule) in rules.entries) {
        final v = p[name];
        if (v == null) {
          if (rule.required) return false;
        } else if (!rule.accepts(v)) {
          return false;
        }
      }
      return true;
    };
  }
}

class _Rule {
  final String type;
  final int? min, max;
  final bool required;
  final List<Object?>? values;
  final _Rule? items;
  _Rule(this.type, this.min, this.max, this.required, this.values, this.items);

  static _Rule parse(String name, Object? spec) {
    if (spec is! Map ||
        !const {
          'string',
          'int',
          'bool',
          'list',
          'map',
          'any',
        }.contains(spec['type'])) {
      throw FormatException('manifest: field $name needs a type');
    }
    int? number(String key) {
      final v = spec[key];
      if (v != null && v is! int) {
        throw FormatException('manifest: $name.$key must be a whole number');
      }
      return v as int?;
    }

    return _Rule(
      spec['type'] as String,
      number('min'),
      number('max'),
      spec['required'] == true,
      spec['values'] is List ? List.unmodifiable(spec['values']) : null,
      spec['items'] == null ? null : _Rule.parse('$name.items', spec['items']),
    );
  }

  bool accepts(Object? v) {
    if (values != null && !values!.contains(v)) return false;
    switch (type) {
      case 'string':
        return v is String && v.length <= (max ?? 4096);
      case 'int':
        return v is int &&
            (min == null || v >= min!) &&
            (max == null || v <= max!);
      case 'bool':
        return v is bool;
      case 'list':
        return v is List &&
            v.length <= (max ?? 1000) &&
            (items == null || v.every(items!.accepts));
      case 'map':
        if (v is! Map) return false;
        continue sized;
      sized:
      case 'any':
        if (max == null) return true;
        try {
          return bytes(v).length <= max!;
        } catch (_) {
          return false;
        }
    }
    return false;
  }
}
