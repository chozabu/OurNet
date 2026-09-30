import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:path_provider/path_provider.dart';

String activeProfile = 'main';
RandomAccessFile? _profileLock;
bool needsSetup = false;

/// Whether this profile holds history that no key on this device can read.
bool identityLost = false;

Future<Node> openNode({String profile = 'main'}) async {
  if (!RegExp(r'^[a-zA-Z0-9_-]{1,40}$').hasMatch(profile)) {
    throw ArgumentError('Invalid profile name');
  }
  final directory = await getApplicationSupportDirectory();
  await directory.create(recursive: true);
  final lock = await File(
    '${directory.path}/ournet-$profile.lock',
  ).open(mode: FileMode.append);
  try {
    await lock.lock(FileLock.exclusive);
  } catch (_) {
    await lock.close();
    throw StateError(
      'Profile "$profile" is already open. Choose another profile or close its other window.',
    );
  }
  // Retain the handle for the process lifetime; the OS releases it on exit.
  _profileLock = lock;
  activeProfile = profile;
  const vault = FlutterSecureStorage();
  final saved = await vault.read(key: 'ournet/v2/$profile');
  needsSetup = saved == null;
  final store = Store(path: '${directory.path}/ournet-$profile.db');
  // History with no vault entry: the keys that can read it are gone, for
  // example after restoring a backup without the platform key store.
  identityLost = needsSetup && store.count > 0;
  try {
    final identity = saved == null
        ? await LocalIdentity.create(label: Platform.localHostname)
        : await LocalIdentity.restore(jsonDecode(saved));
    assert(_profileLock != null);
    return Node(identity, store);
  } catch (_) {
    store.close();
    rethrow;
  }
}

/// Releases the profile lock taken by [openNode], after its node is closed.
Future<void> closeProfile() async {
  final lock = _profileLock;
  _profileLock = null;
  if (lock == null) return;
  await lock.unlock();
  await lock.close();
}

Future<void> saveIdentity(LocalIdentity identity) async {
  await const FlutterSecureStorage().write(
    key: 'ournet/v2/$activeProfile',
    value: canonical(await identity.exportSecrets()),
  );
}

/// Where a backup is unpacked before it replaces the profile: beside the
/// database, so that moving it into place is a rename.
Future<String> restoreStagingPath() async {
  final directory = await getApplicationSupportDirectory();
  await directory.create(recursive: true);
  return '${directory.path}/ournet-$activeProfile.db.restoring';
}

/// Replaces this profile's database and keys with [staged] and opens the
/// result. [current] is this profile's open node, which is closed first: the
/// caller must have stopped everything that uses it.
///
/// The old database and keys are kept aside until the restored profile has
/// opened, and put back if anything fails, so a bad restore loses nothing.
Future<Node> applyRestore(StagedRestore staged, Node current) async {
  final profile = activeProfile;
  final directory = await getApplicationSupportDirectory();
  final database = '${directory.path}/ournet-$profile.db';
  const vault = FlutterSecureStorage();
  final key = 'ournet/v2/$profile';
  final oldSecrets = await vault.read(key: key);
  const parts = ['', '-wal', '-shm'];
  await current.close();
  await closeProfile();
  try {
    for (final part in parts) {
      final aside = File('$database$part.before-restore');
      if (await aside.exists()) await aside.delete();
      final file = File('$database$part');
      if (await file.exists()) await file.rename(aside.path);
    }
    await File(staged.database).rename(database);
    await vault.write(key: key, value: canonical(staged.secrets));
    final node = await openNode(profile: profile);
    for (final part in parts) {
      final aside = File('$database$part.before-restore');
      if (await aside.exists()) await aside.delete();
    }
    return node;
  } catch (_) {
    await closeProfile();
    for (final part in parts) {
      final file = File('$database$part');
      if (await file.exists()) await file.delete();
      final aside = File('$database$part.before-restore');
      if (await aside.exists()) await aside.rename(file.path);
    }
    if (oldSecrets == null) {
      await vault.delete(key: key);
    } else {
      await vault.write(key: key, value: oldSecrets);
    }
    await staged.discard();
    rethrow;
  }
}
