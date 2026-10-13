import 'dart:collection';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'fast_crypto.dart';
import 'registry.dart';

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

/// Content keys one `keys` record carries. An entry is about 140 bytes, so a
/// full record stays well inside an object's size limit.
const maxGrantKeys = 400;

/// Switches for formats that builds before them cannot read. Reading is added
/// in one release and writing enabled in a later one, so friends on mixed
/// versions keep decrypting each other's content during a staged rollout.
/// They are read at the call site and passed to isolates explicitly: static
/// state does not cross an isolate boundary.
abstract final class WireFormat {
  /// Wraps use the salted HKDF derivation ([wrapSalt]) instead of an empty salt.
  /// On since peers older than 0.2.27 are refused: every peer reads it.
  static bool saltedWraps = true;

  /// New encrypted blobs carry a leading [blobVersion] byte. On, as above.
  static bool versionedBlobs = true;
}

/// HKDF salt of the second wrap derivation. Wraps made before it used none.
final wrapSalt = utf8.encode('ournet/wrap/2');

/// Leading byte of a versioned blob. Blobs written before versioning start
/// with their random nonce instead, and remain readable.
const blobVersion = 1;

/// Largest chunk a manifest may declare, and the largest this build writes.
const chunkBytes = 128 * 1024;

/// Whether [v] is a chunk size a manifest may declare: any power of two.
bool validChunkBytes(Object? v) =>
    v is int && v >= 1024 && v <= 1024 * 1024 && (v & (v - 1)) == 0;

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
String canonicalHash(String canonical) => sha256Hex(utf8.encode(canonical));
String blobHash(List<int> value) => sha256Hex(value);
String b64(List<int> value) => base64UrlEncode(value);
List<int> unb64(String value) => base64Url.decode(value);
String randomId() =>
    b64(List.generate(24, (_) => Random.secure().nextInt(256)));

/// The signature algorithm, named as `sig` inside what new builds sign, so a
/// successor can be introduced beside it. Signed data without `sig` is from
/// before the field and is Ed25519; builds that predate it verify over the
/// field like any other.
const signatureAlgorithm = 'ed25519';

/// The AEAD cipher, named as `aead` beside what new builds seal. Sealed data
/// without `aead` is from before the field and is ChaCha20-Poly1305.
const aeadAlgorithm = 'chacha20-poly1305';

/// Refuses a payload sealed with a cipher this build does not know, rather
/// than failing to authenticate it.
void _checkAead(Map sealed) {
  final aead = sealed['aead'];
  if (aead != null && aead != aeadAlgorithm) {
    throw StateError('Unsupported cipher');
  }
}

final _signer = Ed25519();
Future<String> sign(Json value, SimpleKeyPair key) async =>
    b64((await ed25519Sign(bytes(value), key)).bytes);

/// False for data naming a signature algorithm other than [signatureAlgorithm].
Future<bool> verify(Json value, String signature, String publicKey) async {
  final sig = value['sig'];
  if (sig != null && sig != signatureAlgorithm) return false;
  try {
    return await ed25519Verify(
      bytes(value),
      unb64(signature),
      unb64(publicKey),
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
        (j['aead'] != null && j['aead'] != aeadAlgorithm) ||
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

  /// Argon2id cost of new seals, in KiB and passes. Copies made earlier keep
  /// the cost recorded in them.
  static const defaultMemory = 128 * 1024;
  static const defaultIterations = 3;

  /// [memory] is in KiB. The defaults take about a second on a desktop and a
  /// few seconds on a phone; tests pass smaller values.
  static Future<SealedRoot> seal(
    SimpleKeyPair root,
    String phrase, {
    int memory = defaultMemory,
    int iterations = defaultIterations,
  }) async {
    checkPhrase(phrase);
    final person = b64((await root.extractPublicKey()).bytes);
    final salt = List.generate(16, (_) => Random.secure().nextInt(256));
    final key = await _derive(phrase, salt, memory, iterations);
    final box = await aead.encrypt(
      await root.extractPrivateKeyBytes(),
      secretKey: key,
      aad: utf8.encode('$_domain/$person'),
    );
    return SealedRoot._({
      'domain': _domain,
      'person': person,
      'kdf': 'argon2id',
      'aead': aeadAlgorithm,
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
      seed = await aead.decrypt(
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
      () => argon2id(
        utf8.encode(password),
        salt,
        memory: memory,
        iterations: iterations,
      ),
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
    final agreement = await newAgreementKeyPair();
    final data = <String, dynamic>{
      'domain': 'ournet/device/2',
      'sig': signatureAlgorithm,
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
    int memory = SealedRoot.defaultMemory,
    int iterations = SealedRoot.defaultIterations,
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
    final data = <String, dynamic>{
      ...request.data,
      // A request from a build before `sig` carries none.
      'sig': signatureAlgorithm,
      'person': person,
      // Optional, for showing who added a device and when; earlier builds
      // verify the signature over them like any other field.
      'approvedBy': device,
      'approved': DateTime.now().millisecondsSinceEpoch,
    };
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

  /// Object format: absent on objects from before versioning, 2 since.
  int get version => data['v'] as int? ?? 1;

  /// 0 is the wire value for "never expires"; any other value is a time in
  /// milliseconds since the epoch. Prefer this over comparing with 0.
  int get expires => data['expires'];
  bool get hasExpiry => expires != 0;
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
      // Objects from before `v` carry none; a version this build does not know
      // is refused rather than misread.
      if (data['domain'] != 'ournet/object/2' ||
          (data['v'] != null && data['v'] != 2) ||
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

/// A group's key as a room record or invite carries it: `id` names it in
/// what it seals, `key` is 32 bytes.
bool validGroupKey(Object? k) =>
    k is Map &&
    k['id'] is String &&
    (k['id'] as String).length <= 64 &&
    k['key'] is String &&
    (k['key'] as String).length == 44;

/// A group key: what [encryptFor] seals a content key with, beside the wraps
/// for each device, so a member who joins later can open what the group was
/// sent. See `GroupAccess`.
typedef GroupKey = ({String id, List<int> key});

GroupKey groupKeyFrom(Json k) => (id: k['id'] as String, key: unb64(k['key']));

Json newGroupKey() => {
  'id': randomId(),
  'key': b64(List<int>.generate(32, (_) => _secure.nextInt(256))),
};

final _secure = Random.secure();

/// The id of the group key [encrypted] is also sealed with, if any.
String? groupSealOf(Json encrypted) {
  final group = encrypted['group'];
  return group is Map && group['id'] is String && group['box'] is String
      ? group['id'] as String
      : null;
}

List<int> _groupAad(String id) => utf8.encode('ournet/group/2/$id');

/// The content key [encrypted] seals under [group]. Throws when it cannot.
Future<List<int>> unsealGroup(Json encrypted, GroupKey group) async {
  final seal = encrypted['group'] as Map;
  if (seal['id'] != group.id) throw StateError('Another group key');
  _checkAead(encrypted);
  return aead.decrypt(
    SecretBox.fromConcatenation(
      unb64(seal['box'] as String),
      nonceLength: 12,
      macLength: 16,
    ),
    secretKey: SecretKey(group.key),
    aad: _groupAad(group.id),
  );
}

/// [saltedWraps] chooses the wrap key derivation; callers on another isolate
/// pass [WireFormat.saltedWraps] read on their own side. With [group], the
/// content key is also sealed under that group key; builds without it ignore
/// the extra field.
Future<Json> encryptFor(
  Json plain,
  List<DeviceCertificate> recipients, {
  bool saltedWraps = false,
  GroupKey? group,
}) async {
  final cipher = aead;
  final contentKey = await cipher.newSecretKey();
  final box = await cipher.encrypt(bytes(plain), secretKey: contentKey);
  final wraps = <Json>[];
  for (final recipient in {for (final r in recipients) r.device: r}.values) {
    final ephemeral = await newAgreementKeyPair();
    final shared = await x25519Agree(ephemeral, unb64(recipient.agreement));
    final key = await _wrapKey(shared, recipient.device, salted: saltedWraps);
    final wrapped = await cipher.encrypt(
      await contentKey.extractBytes(),
      secretKey: key,
      aad: utf8.encode(recipient.device),
    );
    wraps.add({
      'device': recipient.device,
      // How the key was agreed, so a hybrid post-quantum scheme can be added
      // beside it. Builds that predate the field ignore it.
      'kem': 'x25519',
      'ephemeral': b64((await ephemeral.extractPublicKey()).bytes),
      'box': b64(wrapped.concatenation()),
    });
  }
  return {
    // The cipher of the box, the wraps and the group seal alike.
    'aead': aeadAlgorithm,
    'box': b64(box.concatenation()),
    'wraps': wraps,
    if (group != null)
      'group': {
        'id': group.id,
        'box': b64(
          (await cipher.encrypt(
            await contentKey.extractBytes(),
            secretKey: SecretKey(group.key),
            aad: _groupAad(group.id),
          )).concatenation(),
        ),
      },
  };
}

Future<SecretKey> _wrapKey(
  SecretKey shared,
  String device, {
  required bool salted,
}) => Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
  secretKey: shared,
  nonce: salted ? wrapSalt : const [],
  info: utf8.encode('ournet/wrap/2/$device'),
);

Future<Json> decryptFor(Json encrypted, LocalIdentity identity) async =>
    decryptWith(
      encrypted,
      await unwrapFor(encrypted, identity.agreementKey, identity.device),
    );

/// Whether [encrypted] carries a content key wrapped for [device].
bool wrappedFor(Json encrypted, String device) =>
    encrypted['wraps'] is List &&
    (encrypted['wraps'] as List).any((w) => w is Map && w['device'] == device);

/// The content key [encrypted] wraps for [device], opened with its
/// agreement key. Throws when there is none for [device].
Future<List<int>> unwrapFor(
  Json encrypted,
  SimpleKeyPair agreementKey,
  String device,
) async {
  final wrap = (encrypted['wraps'] as List).cast<Json>().firstWhere(
    (w) => w['device'] == device,
  );
  if (wrap['kem'] != null && wrap['kem'] != 'x25519') {
    throw StateError('Unsupported key agreement');
  }
  _checkAead(encrypted);
  final shared = await x25519Agree(agreementKey, unb64(wrap['ephemeral']));
  final sealed = SecretBox.fromConcatenation(
    unb64(wrap['box']),
    nonceLength: 12,
    macLength: 16,
  );
  // Salted derivation first; wraps from builds before it used no salt.
  for (final salted in [true, false]) {
    try {
      return await aead.decrypt(
        sealed,
        secretKey: await _wrapKey(shared, device, salted: salted),
        aad: utf8.encode(device),
      );
    } on SecretBoxAuthenticationError {
      if (!salted) rethrow;
    }
  }
  throw StateError('unreachable');
}

/// Opens [encrypted] with its content key, however that key was obtained.
Future<Json> decryptWith(Json encrypted, List<int> contentKey) async {
  _checkAead(encrypted);
  return jsonDecode(
        utf8.decode(
          await aead.decrypt(
            SecretBox.fromConcatenation(
              unb64(encrypted['box']),
              nonceLength: 12,
              macLength: 16,
            ),
            secretKey: SecretKey(contentKey),
          ),
        ),
      )
      as Json;
}

/// Encrypts one file chunk. A versioned blob is [blobVersion] followed by the
/// nonce, ciphertext and tag, with the version byte authenticated as AAD.
Future<Uint8List> sealBlob(
  List<int> plain,
  SecretKey key, {
  required bool versioned,
}) async {
  final box = await aead.encrypt(
    plain,
    secretKey: key,
    aad: versioned ? const [blobVersion] : const [],
  );
  return Uint8List.fromList([
    if (versioned) blobVersion,
    ...box.concatenation(),
  ]);
}

/// Opens a blob written by [sealBlob], or by builds before versioning, whose
/// blobs are nonce, ciphertext and tag with no leading byte. A nonce is random,
/// so its first byte can equal [blobVersion]; that case is tried as a versioned
/// blob and, failing authentication, as a legacy one. Any other first byte can
/// only be legacy, so a future version byte cannot be told apart from it:
/// unknown versions fail authentication rather than being named.
Future<List<int>> openBlob(List<int> stored, SecretKey key) async {
  final cipher = aead;
  if (stored.isNotEmpty && stored.first == blobVersion) {
    try {
      return await cipher.decrypt(
        SecretBox.fromConcatenation(
          stored.sublist(1),
          nonceLength: 12,
          macLength: 16,
        ),
        secretKey: key,
        aad: const [blobVersion],
      );
    } on SecretBoxAuthenticationError {
      // Legacy blob whose nonce happens to start with the version byte.
    }
  }
  return cipher.decrypt(
    SecretBox.fromConcatenation(stored, nonceLength: 12, macLength: 16),
    secretKey: key,
  );
}
