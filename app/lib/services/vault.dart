import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

/// Where a profile's identity secrets are kept.
///
/// Android and Windows use the platform key store. Linux keeps each secret in
/// a file only this person can read, beside the profile's database: a Secret
/// Service is often missing or locked there (a Steam Deck in Game Mode has
/// none), and a read that came back empty would look like a new device and
/// make a new identity. Under Flatpak that folder is the app's own.
abstract class Vault {
  static Future<Vault> open() async => files
      ? FileVault((await getApplicationSupportDirectory()).path)
      : _SecureVault();

  /// Whether secrets are kept in files. Widget tests use the platform key
  /// store's mock on every host.
  @visibleForTesting
  static bool files = Platform.isLinux;

  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

final class _SecureVault implements Vault {
  static const _storage = FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Secrets as files in [directory], named from their keys.
final class FileVault implements Vault {
  FileVault(this.directory);

  final String directory;

  File _file(String key) =>
      File('$directory/${key.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_')}.key');

  @override
  Future<String?> read(String key) async {
    final file = _file(key);
    return await file.exists() ? await file.readAsString() : null;
  }

  @override
  Future<void> write(String key, String value) async {
    final file = _file(key);
    await file.parent.create(recursive: true);
    final next = File('${file.path}.next');
    await next.writeAsString('');
    // Before the secret is in it: only this person may read it.
    final mode = await Process.run('chmod', ['600', next.path]);
    if (mode.exitCode != 0) {
      await next.delete();
      throw FileSystemException('Could not protect key file', next.path);
    }
    await next.writeAsString(value, flush: true);
    await next.rename(file.path);
  }

  @override
  Future<void> delete(String key) async {
    final file = _file(key);
    if (await file.exists()) await file.delete();
  }
}
