import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:cryptography/cryptography.dart';
import 'package:sqlite3/sqlite3.dart';

import 'fast_crypto.dart';
import 'model.dart';
import 'node.dart';
import 'store.dart';

/// What a backup says about itself, readable without the passphrase.
class BackupInfo {
  final int version, schema;
  final String appVersion, person, device, label;
  final DateTime created;
  final int objects;
  const BackupInfo({
    required this.version,
    required this.schema,
    required this.appVersion,
    required this.person,
    required this.device,
    required this.label,
    required this.created,
    required this.objects,
  });
  Json toJson() => {
    'format': Backup.format,
    'version': version,
    'schema': schema,
    'appVersion': appVersion,
    'person': person,
    'device': device,
    'label': label,
    'created': created.toUtc().toIso8601String(),
    'objects': objects,
  };
  factory BackupInfo.fromJson(Object? j) {
    if (j is! Map || j['format'] != Backup.format) {
      throw const FormatException('This is not an OurNet backup');
    }
    final version = j['version'], schema = j['schema'];
    if (version is! int ||
        schema is! int ||
        j['person'] is! String ||
        j['device'] is! String ||
        j['created'] is! String) {
      throw const FormatException('This backup is damaged');
    }
    return BackupInfo(
      version: version,
      schema: schema,
      appVersion: '${j['appVersion'] ?? ''}',
      person: j['person'],
      device: j['device'],
      label: '${j['label'] ?? ''}',
      created: DateTime.parse(j['created']),
      objects: j['objects'] is int ? j['objects'] : 0,
    );
  }
}

/// A backup that has been opened and checked, waiting to replace a profile.
class StagedRestore {
  final BackupInfo info;

  /// The unpacked database, next to where it will live.
  final String database;

  /// The identity secrets, for the platform vault.
  final Json secrets;
  StagedRestore._(this.info, this.database, this.secrets);

  /// Gives up the unpacked copy, if it was not used.
  Future<void> discard() async {
    final file = File(database);
    if (await file.exists()) await file.delete();
  }
}

/// One zip holding everything needed to bring a profile back: the database
/// (every note, message, file and contact) and the identity keys, which are
/// encrypted under a passphrase chosen for the backup.
///
/// Layout: `manifest.json` (plain), `identity.json` (sealed), `ournet.db`.
/// The database holds what the app already keeps on disk: signed objects whose
/// content is encrypted for their audience. The keys that open them are what
/// the passphrase protects.
///
/// Both directions stream between files in a separate isolate, so neither the
/// whole database nor any blob is held in memory or stalls the interface.
class Backup {
  static const format = 'ournet-backup';

  /// The newest layout this build writes and reads. Raise it only with a
  /// reader that still accepts every earlier one.
  static const version = 1;
  static const _domain = 'ournet/backup/1';
  static const _database = 'ournet.db';

  /// Shorter than a recovery phrase would be welcome, but a backup is
  /// copied around, so a weak passphrase is brute-forced offline.
  static const minimumPassphrase = SealedRoot.minimumPhrase;

  /// Writes a backup of [node] to [path], replacing any file there.
  static Future<BackupInfo> create(
    Node node,
    String path,
    String passphrase, {
    String appVersion = '',
    int memory = SealedRoot.defaultMemory,
    int iterations = SealedRoot.defaultIterations,
  }) async {
    final source = node.store.path;
    if (source == null) throw StateError('Only a stored profile can be saved');
    SealedRoot.checkPhrase(passphrase);
    final certificate = node.identity.certificate;
    final info = BackupInfo(
      version: version,
      schema: Store.schemaVersion,
      appVersion: appVersion,
      person: certificate.person,
      device: certificate.device,
      label: certificate.label,
      created: DateTime.now().toUtc(),
      objects: node.store.count,
    );
    final sealed = await _seal(
      canonical(await node.identity.exportSecrets()),
      passphrase,
      info.person,
      memory,
      iterations,
    );
    final partial = '$path.partial';
    final snapshot = '$path.snapshot';
    try {
      await Isolate.run(
        () => _write(
          source,
          snapshot,
          partial,
          utf8.encode(canonical(info.toJson())),
          utf8.encode(canonical(sealed)),
        ),
      );
      final target = File(path);
      if (await target.exists()) await target.delete();
      await File(partial).rename(path);
    } finally {
      for (final leftover in [partial, snapshot]) {
        final file = File(leftover);
        if (await file.exists()) await file.delete();
      }
    }
    return info;
  }

  /// Reads the manifest of the backup at [path]. Throws if it is not one.
  static Future<BackupInfo> inspect(String path) async {
    final json = await Isolate.run(() => _readEntry(path, 'manifest.json'));
    return BackupInfo.fromJson(jsonDecode(utf8.decode(json)));
  }

  /// Opens the backup at [path] with [passphrase] and unpacks its database to
  /// [database], ready to replace the live one. Nothing existing is touched.
  static Future<StagedRestore> stage(
    String path,
    String passphrase,
    String database,
  ) async {
    final info = await inspect(path);
    if (info.version > version) {
      throw StateError('This backup needs a newer OurNet version');
    }
    if (info.schema > Store.schemaVersion) {
      throw StateError('This backup needs a newer OurNet version');
    }
    final sealed = jsonDecode(
      utf8.decode(await Isolate.run(() => _readEntry(path, 'identity.json'))),
    );
    final secrets = jsonDecode(
      await _open(sealed, passphrase, info.person),
    ).cast<String, dynamic>();
    // The keys must be whole and belong to the person the manifest names.
    final identity = await LocalIdentity.restore(secrets);
    if (identity.certificate.person != info.person) {
      throw StateError('This backup is damaged');
    }
    try {
      await Isolate.run(() => _unpack(path, database));
    } catch (_) {
      await StagedRestore._(info, database, secrets).discard();
      rethrow;
    }
    return StagedRestore._(info, database, secrets);
  }

  // The steps below run in an isolate.

  static Future<void> _write(
    String source,
    String snapshot,
    String partial,
    List<int> manifest,
    List<int> identity,
  ) async {
    final stale = File(snapshot);
    if (stale.existsSync()) stale.deleteSync();
    // A second connection reads a consistent snapshot of the live database
    // while the app carries on writing to it.
    final db = sqlite3.open(source);
    try {
      db.execute('PRAGMA busy_timeout=30000');
      db.execute('VACUUM INTO ?', [snapshot]);
    } finally {
      db.close();
    }
    // A restored profile is this one as it was: peers' records of what it
    // held since no longer apply, so it starts a new change log epoch.
    final copy = sqlite3.open(snapshot);
    try {
      copy.execute(
        "DELETE FROM settings WHERE key IN ('syncEpoch','syncMarks')",
      );
    } finally {
      copy.close();
    }
    final zip = ZipFileEncoder()..create(partial);
    try {
      zip.addArchiveFile(ArchiveFile.bytes('manifest.json', manifest));
      zip.addArchiveFile(ArchiveFile.bytes('identity.json', identity));
      // Mostly ciphertext, which does not compress: store it as it is.
      await zip.addFile(File(snapshot), _database, 0);
    } finally {
      await zip.close();
    }
  }

  static List<int> _readEntry(String path, String name) {
    final input = InputFileStream(path);
    try {
      final archive = ZipDecoder().decodeStream(input);
      final file = archive.files.where((f) => f.name == name).firstOrNull;
      if (file == null || !file.isFile || file.size > 1024 * 1024) {
        throw const FormatException('This is not an OurNet backup');
      }
      return file.readBytes()!;
    } on ArchiveException {
      throw const FormatException('This is not an OurNet backup');
    } finally {
      input.closeSync();
    }
  }

  static void _unpack(String path, String database) {
    final input = InputFileStream(path);
    try {
      final file = ZipDecoder()
          .decodeStream(input)
          .files
          .where((f) => f.name == _database)
          .firstOrNull;
      if (file == null || !file.isFile) {
        throw const FormatException('This backup has no database');
      }
      final output = OutputFileStream(database);
      try {
        file.writeContent(output);
      } finally {
        output.closeSync();
      }
    } finally {
      input.closeSync();
    }
    // A damaged copy must fail now, not after it has replaced a good one.
    final db = sqlite3.open(database, mode: OpenMode.readOnly);
    try {
      final check = db.select('PRAGMA quick_check(1)').first.values.first;
      if (check != 'ok') throw const FormatException('This backup is damaged');
      final schema =
          db.select('PRAGMA user_version').first['user_version'] as int;
      if (schema > Store.schemaVersion) {
        throw StateError('This backup needs a newer OurNet version');
      }
    } finally {
      db.close();
    }
  }

  // Sealing: Argon2id from the passphrase, then ChaCha20-Poly1305. The cost
  // travels with the backup, so it can be raised later.

  static Future<Json> _seal(
    String secrets,
    String passphrase,
    String person,
    int memory,
    int iterations,
  ) async {
    final salt = SecretKeyData.random(length: 16).bytes;
    final key = await _derive(passphrase, salt, memory, iterations);
    final box = await aead.encrypt(
      utf8.encode(secrets),
      secretKey: key,
      aad: utf8.encode('$_domain/$person'),
    );
    return {
      'domain': _domain,
      'kdf': 'argon2id',
      'aead': aeadAlgorithm,
      'memory': memory,
      'iterations': iterations,
      'salt': b64(salt),
      'box': b64(box.concatenation()),
    };
  }

  static Future<String> _open(
    Object? sealed,
    String passphrase,
    String person,
  ) async {
    if (sealed is! Map ||
        sealed['domain'] != _domain ||
        sealed['kdf'] != 'argon2id' ||
        sealed['salt'] is! String ||
        sealed['box'] is! String) {
      throw const FormatException('This backup is damaged');
    }
    if (sealed['aead'] != null && sealed['aead'] != aeadAlgorithm) {
      throw StateError('This backup needs a newer OurNet version');
    }
    final memory = sealed['memory'], iterations = sealed['iterations'];
    // The backup chooses the cost of opening it: bound it.
    if (memory is! int ||
        memory < 8 * 1024 ||
        memory > 256 * 1024 ||
        iterations is! int ||
        iterations < 1 ||
        iterations > 10) {
      throw const FormatException('This backup is damaged');
    }
    final key = await _derive(
      passphrase,
      unb64(sealed['salt']),
      memory,
      iterations,
    );
    try {
      return utf8.decode(
        await aead.decrypt(
          SecretBox.fromConcatenation(
            unb64(sealed['box']),
            nonceLength: 12,
            macLength: 16,
          ),
          secretKey: key,
          aad: utf8.encode('$_domain/$person'),
        ),
      );
    } on SecretBoxAuthenticationError {
      throw StateError('That passphrase is not right');
    }
  }

  static Future<SecretKey> _derive(
    String passphrase,
    List<int> salt,
    int memory,
    int iterations,
  ) async {
    final password = passphrase.trim();
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
