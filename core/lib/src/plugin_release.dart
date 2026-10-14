import 'model.dart';
import 'node.dart';
import 'plugins.dart';
import 'registry.dart';

/// What a publisher signed about one version of a plugin (docs/STORE-PLAN.md):
/// its identity, grants and kinds, and the digest of its package's contents.
///
/// An ordinary [SignedObject], public-shaped, so verifying it is
/// [SignedObject.valid] and no new signature scheme exists. A public release
/// is stored in its publisher's [space] and syncs to whoever follows it. A
/// package carries its release in `signature.json`; a distribution
/// ([packageKind]) carries it, with the chunks of one encoding of the package,
/// to whoever the distribution is for, who need not be its publisher's friends.
/// Releases are identified by their object ID, never by version text.
class PluginRelease {
  static const kind = 'plugin_release';

  /// A distribution: a release and the chunks of a package, signed by
  /// whoever shares it (the distributor), for any audience.
  static const packageKind = 'plugin_package';

  /// Where [publisher]'s public releases live.
  static String space(String publisher) => '_plugins:$publisher';

  final SignedObject object;
  PluginRelease._(this.object);

  String get id => object.id;
  String get publisher => object.author;
  Json get _payload => object.data['payload'] as Json;
  String get plugin => _payload['id'] as String;
  String get version => _payload['version'] as String;
  String get name => _payload['name'] as String;
  String get summary => _payload['summary'] as String;
  String get changes => _payload['changes'] as String? ?? '';
  String get digest => _payload['digest'] as String;
  Set<String> get grants => {...(_payload['grants'] as List).cast<String>()};

  /// For a script plugin, the runtime it needs (`js@1`); for a runtime,
  /// what it provides (`runtime:js@1`). Absent from releases before scripts.
  String? get runtime => _payload['runtime'] as String?;
  String? get provides => _payload['provides'] as String?;

  /// As it travels in `signature.json` and in distributions.
  Json toJson() => object.toJson();

  /// The payload a publisher signs for [package].
  static Json describe(PluginPackage package, {String changes = ''}) {
    final m = package.manifest;
    return {
      'id': m.id,
      'version': m.version,
      'api': m.api,
      'name': m.name,
      'summary': m.description,
      'grants': m.grants.toList()..sort(),
      'kinds': [
        for (final kind in m.kinds.keys) kind.substring('x.${m.id}.'.length),
      ]..sort(),
      'runtime': ?m.runtime,
      'provides': ?m.provides,
      'manifest': package.manifestHash,
      'digest': package.digest,
      if (changes.trim().isNotEmpty) 'changes': changes.trim(),
    };
  }

  /// [object] as a release, if it is one: no checks.
  static PluginRelease? of(SignedObject object) =>
      object.kind == kind ? PluginRelease._(object) : null;

  /// Reads a release as it travels and checks it: a valid signature by a
  /// device of its publisher, public-shaped, valid content, and neither the
  /// publisher blocked nor the device revoked here. Throws
  /// [FormatException] otherwise.
  static Future<PluginRelease> verify(Object? wire, Node node) async {
    final SignedObject object;
    try {
      object = SignedObject.fromJson((wire as Map).cast());
    } catch (_) {
      throw const FormatException('Not a plugin release');
    }
    if (object.kind != kind ||
        !object.isPublic ||
        !validContent(kind, object.data['payload'] as Json) ||
        !await object.valid()) {
      throw const FormatException('The release signature does not verify');
    }
    if (node.blocked.contains(object.author)) {
      throw const FormatException('Its publisher is blocked');
    }
    if (node.revoked.contains(object.certificate.device)) {
      throw const FormatException('It was signed by a removed device');
    }
    return PluginRelease._(object);
  }

  /// Throws [FormatException] unless [package] is exactly what this release
  /// describes.
  void check(PluginPackage package) {
    final m = package.manifest;
    final described = describe(package)..remove('changes');
    final signed = {..._payload}..remove('changes');
    if (canonical(described) != canonical(signed)) {
      throw FormatException(
        package.digest != digest
            ? 'The package is not the one ${m.name} $version names'
            : 'The package manifest differs from its release',
      );
    }
  }
}

/// Orders plugin versions: dot-separated numbers, compared as numbers;
/// anything after `-` or `+` is ignored. Positive when [a] is newer.
int compareVersions(String a, String b) {
  List<int> parts(String v) => [
    for (final p in v.split(RegExp(r'[-+]')).first.split('.'))
      int.tryParse(p) ?? 0,
  ];
  final (x, y) = (parts(a), parts(b));
  for (var i = 0; i < x.length || i < y.length; i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d;
  }
  return 0;
}
