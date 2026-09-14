import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';

/// Interactive personal node. Its private vault is password encrypted, with
/// the password read without echo. No HTTP admin port is exposed.
Future<void> main(List<String> args) async {
  final paths = args.where((a) => !a.startsWith('--')).toList();
  final directory = Directory(paths.isEmpty ? 'ournet-data' : paths.single);
  await directory.create(recursive: true);
  final lock = await File(
    '${directory.path}/node.lock',
  ).open(mode: FileMode.append);
  try {
    await lock.lock(FileLock.exclusive);
    await runNode(directory, local: args.contains('--local'));
  } finally {
    await lock.close();
  }
}

Future<void> runNode(Directory directory, {required bool local}) async {
  stdout.write('Vault password: ');
  String? password;
  try {
    stdin.echoMode = false;
    password = stdin.readLineSync();
  } finally {
    stdin.echoMode = true;
    stdout.writeln();
  }
  if (password == null || password.length < 12)
    throw StateError('Use a password of at least 12 characters');
  final vault = File('${directory.path}/vault.json');
  final Json stored = await vault.exists()
      ? jsonDecode(await vault.readAsString())
      : {'salt': randomId()};
  final key = await Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: 600000,
    bits: 256,
  ).deriveKeyFromPassword(password: password, nonce: unb64(stored['salt']));
  final cipher = Chacha20.poly1305Aead();
  final identity = stored['box'] == null
      ? await LocalIdentity.create(label: 'Personal node')
      : await LocalIdentity.restore(
          jsonDecode(
            utf8.decode(
              await cipher.decrypt(
                SecretBox.fromConcatenation(
                  unb64(stored['box']),
                  nonceLength: 12,
                  macLength: 16,
                ),
                secretKey: key,
              ),
            ),
          ),
        );
  if (stored['box'] == null) {
    stored['box'] = b64(
      (await cipher.encrypt(
        bytes(await identity.exportSecrets()),
        secretKey: key,
      )).concatenation(),
    );
    final pending = File('${vault.path}.pending');
    await pending.writeAsString(canonical(stored), flush: true);
    await pending.rename(vault.path);
  }
  final node = Node(identity, Store(path: '${directory.path}/content.db'));
  final network = PeerNetwork(node);
  await network.start(local: local);
  stdout.writeln(
    'Person: ${node.person}\nCommands: card, add <card>, sync, subscribe <space>, post <text>, quit',
  );
  try {
    await for (final line
        in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      try {
        if (line == 'quit') break;
        if (line == 'card')
          stdout.writeln(network.contactCard());
        else if (line.startsWith('add '))
          await network.addCard(line.substring(4));
        else if (line == 'sync')
          await network.syncAll();
        else if (line.startsWith('subscribe '))
          node.subscribe(line.substring(10), true);
        else if (line.startsWith('post '))
          await node.publish('post', {'text': line.substring(5)});
        else
          stdout.writeln('Unknown command');
      } catch (e) {
        stderr.writeln(e);
      }
    }
  } finally {
    await network.stop();
    await node.close();
  }
}
