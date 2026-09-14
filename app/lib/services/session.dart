import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:path_provider/path_provider.dart';

String activeProfile = 'main';
RandomAccessFile? _profileLock;
bool needsSetup = false;

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
  final identity = saved == null
      ? await LocalIdentity.create(label: Platform.localHostname)
      : await LocalIdentity.restore(jsonDecode(saved));
  assert(_profileLock != null);
  return Node(identity, Store(path: '${directory.path}/ournet-$profile.db'));
}

Future<void> saveIdentity(LocalIdentity identity) async {
  await const FlutterSecureStorage().write(
    key: 'ournet/v2/$activeProfile',
    value: canonical(await identity.exportSecrets()),
  );
}
