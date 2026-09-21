import 'dart:collection';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'package:crypto/crypto.dart' as digest;
import 'package:cryptography/cryptography.dart';

typedef Json = Map<String, dynamic>;

dynamic frozen(dynamic value) => value is Map
    ? Map<String, dynamic>.unmodifiable(
        value.map((k, v) => MapEntry(k as String, frozen(v))),
      )
    : value is List
    ? List<dynamic>.unmodifiable(value.map(frozen))
    : value;

/// Cooperative time slicing for long loops on an interactive isolate. Each
/// [pause] returns to the event loop once the budget is spent, so frames and
/// input continue while history is decrypted, verified or indexed.
class TimeSlice {
  /// Fake-clock widget tests never fire timers, so their harness disables this.
  static bool enabled = true;
  final int budgetMicroseconds;
  final _clock = Stopwatch()..start();
  TimeSlice([this.budgetMicroseconds = 4000]);
  Future<void> pause() async {
    if (!enabled || _clock.elapsedMicroseconds < budgetMicroseconds) return;
    await Future<void>.delayed(Duration.zero);
    _clock.reset();
  }
}

bool validContent(String kind, Json p) {
  if (p['text'] != null &&
      (p['text'] is! String || (p['text'] as String).length > 65536))
    return false;
  if (p['parent'] != null && p['parent'] is! String) return false;
  if (p['chunks'] != null) {
    if (p['chunks'] is! List ||
        (p['chunks'] as List).length > 513 ||
        !(p['chunks'] as List).every(
          (h) => h is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(h),
        ) ||
        p['size'] is! int ||
        p['size'] < 0 ||
        p['size'] > 64 * 1024 * 1024 ||
        p['name'] is! String ||
        (p['name'] as String).length > 255 ||
        (p['key'] != null && p['key'] is! String))
      return false;
  }
  return switch (kind) {
    'note_op' =>
      p['epoch'] is String &&
          _register(p) &&
          _noteValue(p['field'] as String, p['value'], p) &&
          (p['checkpoint'] == null || p['checkpoint'] is bool),
    'note_self' =>
      p['target'] is String &&
          (p['target'] as String).length <= 200 &&
          _register(p) &&
          _selfValue(p['field'] as String, p['value']),
    'forum' =>
      p['name'] is String &&
          (p['name'] as String).trim().isNotEmpty &&
          (p['name'] as String).length <= 100 &&
          p['description'] is String &&
          (p['description'] as String).length <= 4000,
    'forum_hide' => p['object'] is String,
    'room_leave' => p['epoch'] is String,
    'delivery' => p['object'] is String,
    'room' =>
      p['room'] is String &&
          p['owner'] is String &&
          p['name'] is String &&
          (p['name'] as String).trim().isNotEmpty &&
          (p['name'] as String).length <= 100 &&
          p['members'] is List &&
          (p['members'] as List).length <= 64 &&
          (p['members'] as List).every((v) => v is String) &&
          (p['generation'] == null ||
              p['generation'] is int &&
                  p['generation'] >= 0 &&
                  p['generation'] < 9007199254740991) &&
          (p['epoch'] == null || p['epoch'] is String) &&
          (p['archived'] == null || p['archived'] is bool) &&
          (p['certificates'] == null ||
              p['certificates'] is List &&
                  (p['certificates'] as List).length <= 256 &&
                  (p['certificates'] as List).every((c) => c is Map)),
    'inbox' || 'room_item' =>
      p['entry'] is String &&
          p['clock'] is int &&
          p['clock'] >= 0 &&
          p['clock'] < 9007199254740991 &&
          ['note', 'file', 'check', 'pin'].contains(p['type']) &&
          (!['note', 'check'].contains(p['type']) || p['text'] is String) &&
          (p['deleted'] == null || p['deleted'] is bool) &&
          (p['type'] != 'file' || p['chunks'] is List) &&
          (p['type'] != 'check' ||
              (p['done'] is bool && p['list'] is String)) &&
          (p['type'] != 'pin' ||
              (p['target'] is String && p['pinned'] is bool)),
    'drive' =>
      p['entry'] is String &&
          p['revision'] is String &&
          p['parents'] is List &&
          (p['parents'] as List).length <= 128 &&
          (p['parents'] as List).every((v) => v is String) &&
          p['name'] is String &&
          (p['name'] as String).trim().isNotEmpty &&
          (p['name'] as String).length <= 255 &&
          !RegExp(r'[/\\\x00-\x1f]').hasMatch(p['name']) &&
          (p['folder'] == null || p['folder'] is String) &&
          p['deleted'] is bool &&
          ['file', 'folder'].contains(p['type']) &&
          (p['type'] == 'folder' || p['chunks'] is List),
    'profile' =>
      p['name'] is String &&
          (p['name'] as String).isNotEmpty &&
          (p['name'] as String).length <= 100,
    'post' =>
      p['text'] is String &&
          (p['title'] == null ||
              (p['title'] is String && (p['title'] as String).length <= 200)),
    'message' => p['text'] is String || p['chunks'] is List,
    'file' => p['chunks'] is List,
    'vote' => p['object'] is String && [-1, 0, 1].contains(p['value']),
    'delegate' => p['person'] is String,
    'read' => p['object'] is String,
    'location' =>
      p['lat'] is String &&
          p['lng'] is String &&
          (double.tryParse(p['lat'])?.abs() ?? double.infinity) <= 90 &&
          (double.tryParse(p['lng'])?.abs() ?? double.infinity) <= 180,
    _ => true,
  };
}

/// Register fields: a name, or `name:<id>:name` for per-item values. Names
/// this build does not know are accepted with a bounded value, so newer builds
/// can add fields that older ones keep, replicate and simply do not display.
final _fieldName = RegExp(
  r'^[a-z][a-zA-Z0-9]{0,31}(:[a-zA-Z0-9_-]{1,80}:[a-z][a-zA-Z0-9]{0,31})?$',
);
// Order keys never end in '0', so a later key can always be placed before
// one: see `orderBetween`. Keys that do are rejected rather than stored.
final _orderKey = RegExp(r'^[0-9A-Za-z]{0,63}[1-9A-Za-z]$');
final _colorName = RegExp(r'^[a-z]{1,16}$');

bool _register(Json p) =>
    p['field'] is String &&
    _fieldName.hasMatch(p['field']) &&
    p['clock'] is int &&
    p['clock'] >= 0 &&
    p['clock'] < 9007199254740991 &&
    p['parents'] is List &&
    (p['parents'] as List).length <= 128 &&
    (p['parents'] as List).every((v) => v is String && v.length <= 128) &&
    (p['request'] == null ||
        p['request'] is String && (p['request'] as String).length <= 100);

bool _text(Object? v, [int limit = 16384]) => v is String && v.length <= limit;
bool _bounded(Object? v) {
  if (v is String) return v.length <= 16384;
  if (v is bool || v is int) return true;
  if (v is! Map && v is! List) return false;
  try {
    return bytes(v).length <= 8192;
  } catch (_) {
    return false;
  }
}

/// Known shared-note registers keep strict types; see `Notes` for meaning.
bool _noteValue(String field, Object? v, Json p) {
  final parts = field.split(':');
  final name = parts.last;
  if (parts.length == 1) {
    return switch (field) {
      'title' || 'text' => _text(v),
      'deleted' => v is bool,
      'color' ||
      'background' ||
      'format' => v is String && _colorName.hasMatch(v),
      'created' || 'edited' => v is int && v >= 0 && v < 253402300799999,
      _ => _bounded(v),
    };
  }
  if (parts.first == 'check') {
    return switch (name) {
      'text' => _text(v),
      'done' || 'deleted' => v is bool,
      'order' => v is String && _orderKey.hasMatch(v),
      'indent' => v is int && v >= 0 && v <= 1,
      _ => _bounded(v),
    };
  }
  if (parts.first == 'file') {
    return switch (name) {
      // The attachment itself: encrypted chunks travel in this same payload.
      'meta' =>
        v is Map &&
            _bounded(v) &&
            ['audio', 'image', 'drawing'].contains(v['kind']) &&
            p['chunks'] is List,
      'strokes' => v is Map && _bounded(v) && p['chunks'] is List,
      'transcript' => _text(v),
      'deleted' => v is bool,
      'order' => v is String && _orderKey.hasMatch(v),
      _ => _bounded(v),
    };
  }
  return _bounded(v);
}

/// Personal note state, readable only by this person's own devices.
bool _selfValue(String field, Object? v) => switch (field) {
  'pin' || 'archive' || 'labelDeleted' => v is bool,
  // The removal (operation ID) this person emptied from Removed.
  'purged' => v is String && v.length <= 128,
  'order' || 'rank' => v is String && _orderKey.hasMatch(v),
  'labelName' => v is String && v.trim().isNotEmpty && v.length <= 50,
  'labels' =>
    v is List &&
        v.length <= 64 &&
        v.every((l) => l is String && l.length <= 64),
  'reminder' =>
    v is Map &&
        _bounded(v) &&
        (v.isEmpty ||
            (v['at'] is int &&
                v['at'] >= 0 &&
                [
                  'none',
                  'daily',
                  'weekly',
                  'monthly',
                  'yearly',
                ].contains(v['repeat'] ?? 'none'))),
  _ => _bounded(v),
};

/// Version 2 canonical JSON: sorted string keys, integers, strings, booleans,
/// null and arrays only. Floating point values are deliberately forbidden.
String canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return '{${keys.map((k) => '${jsonEncode(k)}:${canonical(value[k])}').join(',')}}';
  }
  if (value is List) return '[${value.map(canonical).join(',')}]';
  if (value == null || value is String || value is bool || value is int) {
    return jsonEncode(value);
  }
  throw FormatException('Unsupported signed value: ${value.runtimeType}');
}

List<int> bytes(Object? value) => utf8.encode(canonical(value));
String hash(Object? value) => canonicalHash(canonical(value));
String canonicalHash(String canonical) =>
    digest.sha256.convert(utf8.encode(canonical)).toString();
String blobHash(List<int> value) => digest.sha256.convert(value).toString();
String b64(List<int> value) => base64UrlEncode(value);
List<int> unb64(String value) => base64Url.decode(value);
String randomId() =>
    b64(List.generate(24, (_) => Random.secure().nextInt(256)));

final _signer = Ed25519();
Future<String> sign(Json value, SimpleKeyPair key) async =>
    b64((await _signer.sign(bytes(value), keyPair: key)).bytes);
Future<bool> verify(Json value, String signature, String publicKey) async {
  try {
    return await _signer.verify(
      bytes(value),
      signature: Signature(
        unb64(signature),
        publicKey: SimplePublicKey(unb64(publicKey), type: KeyPairType.ed25519),
      ),
    );
  } catch (_) {
    return false;
  }
}

/// An explicit, root-signed device certificate. The device key is also its
/// transport key. The agreement key is bound by the same certificate.
class DeviceCertificate {
  final Json data;
  final String signature;
  DeviceCertificate(Json data, this.signature)
    : data = frozen(jsonDecode(canonical(data)));
  String get person => data['person'] as String;
  String get device => data['device'] as String;
  String get agreement => data['agreement'] as String;
  String get label => data['label'] as String;
  Json toJson() => {'data': data, 'signature': signature};
  factory DeviceCertificate.fromJson(Json j) =>
      DeviceCertificate(j['data'] as Json, j['signature'] as String);
  // A person has few certificates, but every object and evidence record
  // carries one. Verify each distinct certificate once per isolate.
  static final _verified = LinkedHashSet<String>();

  Future<bool> valid() async {
    final key = '$signature${canonical(data)}';
    if (_verified.contains(key)) return true;
    try {
      final ok =
          data['domain'] == 'ournet/device/2' &&
          label.length <= 100 &&
          unb64(device).length == 32 &&
          unb64(agreement).length == 32 &&
          await verify(data, signature, person);
      if (ok && _verified.add(key) && _verified.length > 64) {
        _verified.remove(_verified.first);
      }
      return ok;
    } catch (_) {
      return false;
    }
  }
}

//// A person's root secret, encrypted under their recovery phrase.
///
/// Every device the person links may keep a copy, so any surviving device can
/// add and remove devices. The phrase is what separates holding a device from
/// holding the identity: the root is used only to add and remove devices, so
/// asking for it then costs little. Argon2id parameters travel with the copy,
/// so they can be raised later without breaking older copies.
class SealedRoot {
  static const minimumPhrase = 12;
  static const _domain = 'ournet/root/2';
  final Json data;
  SealedRoot._(Json data) : data = frozen(jsonDecode(canonical(data)));
  String get person => data['person'] as String;
  Json toJson() => data;

  /// Rejects anything malformed, and parameters that would let a copy make
  /// this device spend unbounded memory or time deriving a key.
  factory SealedRoot.fromJson(Object? j) {
    if (j is! Map ||
        j['domain'] != _domain ||
        j['kdf'] != 'argon2id' ||
        j['person'] is! String ||
        j['salt'] is! String ||
        j['box'] is! String) {
      throw const FormatException('Invalid sealed root');
    }
    final memory = j['memory'], iterations = j['iterations'];
    if (memory is! int ||
        memory < 8 * 1024 ||
        memory > 256 * 1024 ||
        iterations is! int ||
        iterations < 1 ||
        iterations > 10 ||
        unb64(j['salt']).length != 16 ||
        unb64(j['box']).length != 32 + 12 + 16 ||
        unb64(j['person']).length != 32) {
      throw const FormatException('Invalid sealed root');
    }
    return SealedRoot._(j.cast<String, dynamic>());
  }

  static void checkPhrase(String phrase) {
    if (phrase.trim().length < minimumPhrase) {
      throw StateError(
        'Use a recovery phrase of at least $minimumPhrase characters',
      );
    }
  }

  /// [memory] is in KiB. The defaults take under a second on a desktop and a
  /// few seconds on a phone; tests pass smaller values.
  static Future<SealedRoot> seal(
    SimpleKeyPair root,
    String phrase, {
    int memory = 64 * 1024,
    int iterations = 3,
  }) async {
    checkPhrase(phrase);
    final person = b64((await root.extractPublicKey()).bytes);
    final salt = List.generate(16, (_) => Random.secure().nextInt(256));
    final key = await _derive(phrase, salt, memory, iterations);
    final box = await Chacha20.poly1305Aead().encrypt(
      await root.extractPrivateKeyBytes(),
      secretKey: key,
      aad: utf8.encode('$_domain/$person'),
    );
    return SealedRoot._({
      'domain': _domain,
      'person': person,
      'kdf': 'argon2id',
      'memory': memory,
      'iterations': iterations,
      'salt': b64(salt),
      'box': b64(box.concatenation()),
    });
  }

  Future<SimpleKeyPair> open(String phrase) async {
    final key = await _derive(
      phrase,
      unb64(data['salt']),
      data['memory'],
      data['iterations'],
    );
    final List<int> seed;
    try {
      seed = await Chacha20.poly1305Aead().decrypt(
        SecretBox.fromConcatenation(
          unb64(data['box']),
          nonceLength: 12,
          macLength: 16,
        ),
        secretKey: key,
        aad: utf8.encode('$_domain/$person'),
      );
    } on SecretBoxAuthenticationError {
      throw StateError('That recovery phrase is not right');
    }
    final root = await _signer.newKeyPairFromSeed(seed);
    if (b64((await root.extractPublicKey()).bytes) != person) {
      throw StateError('Sealed root does not match its person');
    }
    return root;
  }

  /// Runs in its own isolate: Argon2id is pure Dart here, and would otherwise
  /// stall the caller's event loop (and a UI) for the whole derivation.
  static Future<SecretKey> _derive(
    String phrase,
    List<int> salt,
    int memory,
    int iterations,
  ) async {
    final password = phrase.trim();
    final key = await Isolate.run(
      () async => (await Argon2id(
        parallelism: 1,
        memory: memory,
        iterations: iterations,
        hashLength: 32,
      ).deriveKeyFromPassword(password: password, nonce: salt)).extractBytes(),
    );
    return SecretKey(key);
  }
}

/// Secrets are exported only to the platform vault, never the content store.
class LocalIdentity {
  /// The root in the clear: a new profile, or an original device from before
  /// recovery phrases that has not set one yet. Null once sealed.
  final SimpleKeyPair? root;

  /// This device's copy of the root, opened with the recovery phrase.
  final SealedRoot? sealedRoot;
  final SimpleKeyPair deviceKey;
  final SimpleKeyPair agreementKey;
  final DeviceCertificate certificate;
  LocalIdentity(
    this.root,
    this.deviceKey,
    this.agreementKey,
    this.certificate, {
    this.sealedRoot,
  });
  String get person => certificate.person;
  String get device => certificate.device;

  /// Whether this device can add and remove devices, given the phrase if the
  /// root is sealed.
  bool get holdsRoot => root != null || sealedRoot != null;
  static Future<LocalIdentity> create({
    String label = 'This device',
    SimpleKeyPair? root,
  }) async {
    root ??= await _signer.newKeyPair();
    final device = await _signer.newKeyPair();
    final agreement = await X25519().newKeyPair();
    final data = <String, dynamic>{
      'domain': 'ournet/device/2',
      'person': b64((await root.extractPublicKey()).bytes),
      'device': b64((await device.extractPublicKey()).bytes),
      'agreement': b64((await agreement.extractPublicKey()).bytes),
      'label': label,
    };
    return LocalIdentity(
      root,
      device,
      agreement,
      DeviceCertificate(data, await sign(data, root)),
    );
  }

  Future<Json> exportSecrets() async => {
    'root': root == null ? null : b64(await root!.extractPrivateKeyBytes()),
    'sealedRoot': sealedRoot?.toJson(),
    'device': b64(await deviceKey.extractPrivateKeyBytes()),
    'agreement': b64(await agreementKey.extractPrivateKeyBytes()),
    'certificate': certificate.toJson(),
  };
  static Future<LocalIdentity> restore(Json j) async {
    final root = j['root'] == null
        ? null
        : await _signer.newKeyPairFromSeed(unb64(j['root']));
    final sealed = j['sealedRoot'] == null
        ? null
        : SealedRoot.fromJson(j['sealedRoot']);
    final device = await _signer.newKeyPairFromSeed(unb64(j['device']));
    final agreement = await X25519().newKeyPairFromSeed(unb64(j['agreement']));
    final cert = DeviceCertificate.fromJson(j['certificate']);
    if (!await cert.valid() ||
        (root != null &&
            b64((await root.extractPublicKey()).bytes) != cert.person) ||
        (sealed != null && sealed.person != cert.person) ||
        b64((await device.extractPublicKey()).bytes) != cert.device ||
        b64((await agreement.extractPublicKey()).bytes) != cert.agreement) {
      throw StateError('Identity vault does not match certificate');
    }
    return LocalIdentity(root, device, agreement, cert, sealedRoot: sealed);
  }

  /// This device with its root sealed under [phrase], and no longer held in
  /// the clear.
  Future<LocalIdentity> seal(
    String phrase, {
    int memory = 64 * 1024,
    int iterations = 3,
  }) async {
    final clear = root;
    if (clear == null) throw StateError('This device has no root to seal');
    return LocalIdentity(
      null,
      deviceKey,
      agreementKey,
      certificate,
      sealedRoot: await SealedRoot.seal(
        clear,
        phrase,
        memory: memory,
        iterations: iterations,
      ),
    );
  }

  /// The root, for adding or removing a device. [phrase] opens a sealed copy.
  Future<SimpleKeyPair> unlockRoot([String? phrase]) async {
    if (root case final clear?) return clear;
    final sealed = sealedRoot;
    if (sealed == null) {
      throw StateError('This device cannot add or remove devices');
    }
    if (phrase == null) throw StateError('Enter your recovery phrase');
    return sealed.open(phrase);
  }

  /// [unlocked] is the root from [unlockRoot], needed once it is sealed.
  Future<DeviceCertificate> authorise(
    DeviceCertificate request, {
    SimpleKeyPair? unlocked,
  }) async {
    final key = unlocked ?? root;
    if (key == null) {
      throw StateError('Enter your recovery phrase to add a device');
    }
    if (b64((await key.extractPublicKey()).bytes) != person) {
      throw StateError('That root is not this person');
    }
    if (!await request.valid()) throw StateError('Invalid enrolment request');
    final data = <String, dynamic>{...request.data, 'person': person};
    return DeviceCertificate(data, await sign(data, key));
  }

  /// [sealedRoot] is the copy the approving device sent, if it shared one.
  Future<LocalIdentity> enrol(
    DeviceCertificate approval, {
    SealedRoot? sealedRoot,
  }) async {
    if (!await approval.valid() ||
        approval.device != device ||
        approval.agreement != certificate.agreement) {
      throw StateError('Approval is not for this device');
    }
    if (sealedRoot != null && sealedRoot.person != approval.person) {
      throw StateError('Sealed root is for another person');
    }
    return LocalIdentity(
      null,
      deviceKey,
      agreementKey,
      approval,
      sealedRoot: sealedRoot,
    );
  }
}

// Every object verifies without downloading any other application history.
class SignedObject {
  final Json data;
  final String signature;
  final DeviceCertificate certificate;
  SignedObject(Json data, this.signature, this.certificate)
    : data = frozen(jsonDecode(canonical(data)));
  // Data, signature and certificate are immutable, so the canonical encoding,
  // its size and the content hash are computed at most once.
  late final String wire = canonical(toJson());
  late final String id = canonicalHash(wire);
  late final int encodedLength = utf8.encode(wire).length;
  String get author => certificate.person;
  String get kind => data['kind'];
  String get space => data['space'];
  int get created => data['created'];
  int get expires => data['expires'];
  List<String> get audience => (data['audience'] as List).cast<String>();
  bool get isPublic => audience.isEmpty;
  Json toJson() => {
    'data': data,
    'signature': signature,
    'certificate': certificate.toJson(),
  };
  factory SignedObject.fromJson(Json j) => SignedObject(
    j['data'],
    j['signature'],
    DeviceCertificate.fromJson(j['certificate']),
  );
  Future<bool> valid() async {
    try {
      if (data['domain'] != 'ournet/object/2' ||
          kind.length > 64 ||
          space.length > 128 ||
          created < 0 ||
          created > 253402300799999 ||
          expires < 0 ||
          expires > 253402300799999 ||
          audience.length > 64 ||
          (data['via'] as List).length > 64 ||
          !(data['via'] as List).every((v) => v is String) ||
          data['payload'] is! Map<String, dynamic>)
        return false;
      if (isPublic && !validContent(kind, data['payload'])) return false;
      if (!isPublic &&
          (data['payload']['box'] is! String ||
              data['payload']['wraps'] is! List ||
              (data['payload']['wraps'] as List).length > 128))
        return false;
      return await certificate.valid() &&
          await verify(data, signature, certificate.device);
    } catch (_) {
      return false;
    }
  }
}

/// A sender-signed handoff addressed to a particular device. A receipt signs
/// this exact handoff; neither proves unrecorded/off-protocol history.
class Evidence {
  final Json data;
  final String signature;
  final DeviceCertificate certificate;
  Evidence(Json data, this.signature, this.certificate)
    : data = frozen(jsonDecode(canonical(data)));
  late final String wire = canonical(toJson());
  late final String id = canonicalHash(wire);
  String get objectId => data['object'];
  Json toJson() => {
    'data': data,
    'signature': signature,
    'certificate': certificate.toJson(),
  };
  factory Evidence.fromJson(Json j) => Evidence(
    j['data'],
    j['signature'],
    DeviceCertificate.fromJson(j['certificate']),
  );
  Future<bool> valid() async =>
      ['ournet/handoff/2', 'ournet/receipt/2'].contains(data['domain']) &&
      await certificate.valid() &&
      await verify(data, signature, certificate.device);
}

Future<Json> encryptFor(Json plain, List<DeviceCertificate> recipients) async {
  final cipher = Chacha20.poly1305Aead();
  final contentKey = await cipher.newSecretKey();
  final box = await cipher.encrypt(bytes(plain), secretKey: contentKey);
  final wraps = <Json>[];
  for (final recipient in {for (final r in recipients) r.device: r}.values) {
    final ephemeral = await X25519().newKeyPair();
    final shared = await X25519().sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: SimplePublicKey(
        unb64(recipient.agreement),
        type: KeyPairType.x25519,
      ),
    );
    final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: shared,
      nonce: const [],
      info: utf8.encode('ournet/wrap/2/${recipient.device}'),
    );
    final wrapped = await cipher.encrypt(
      await contentKey.extractBytes(),
      secretKey: key,
      aad: utf8.encode(recipient.device),
    );
    wraps.add({
      'device': recipient.device,
      'ephemeral': b64((await ephemeral.extractPublicKey()).bytes),
      'box': b64(wrapped.concatenation()),
    });
  }
  return {'box': b64(box.concatenation()), 'wraps': wraps};
}

Future<Json> decryptFor(Json encrypted, LocalIdentity identity) async {
  final wrap = (encrypted['wraps'] as List).cast<Json>().firstWhere(
    (w) => w['device'] == identity.device,
  );
  final shared = await X25519().sharedSecretKey(
    keyPair: identity.agreementKey,
    remotePublicKey: SimplePublicKey(
      unb64(wrap['ephemeral']),
      type: KeyPairType.x25519,
    ),
  );
  final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
    secretKey: shared,
    nonce: const [],
    info: utf8.encode('ournet/wrap/2/${identity.device}'),
  );
  final cipher = Chacha20.poly1305Aead();
  final raw = await cipher.decrypt(
    SecretBox.fromConcatenation(
      unb64(wrap['box']),
      nonceLength: 12,
      macLength: 16,
    ),
    secretKey: key,
    aad: utf8.encode(identity.device),
  );
  return jsonDecode(
        utf8.decode(
          await cipher.decrypt(
            SecretBox.fromConcatenation(
              unb64(encrypted['box']),
              nonceLength: 12,
              macLength: 16,
            ),
            secretKey: SecretKey(raw),
          ),
        ),
      )
      as Json;
}
