import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// Format versions and rollout switches: what new builds write, and what they
/// still read from older ones. See PROTOCOL_CHANGELOG.md.
void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('ournet-format'));
  tearDown(() => temp.deleteSync(recursive: true));

  group('objects', () {
    test('new objects carry v 2 and never expire by default', () async {
      final node = Node(await LocalIdentity.create(), Store());
      final o = await node.publish('post', {'text': 'hi'});
      expect(o.data['v'], 2);
      expect(o.version, 2);
      expect(o.hasExpiry, isFalse);
      expect(await o.valid(), isTrue);
      final timed = await node.publish('post', {
        'text': 'soon',
      }, expires: node.now() + 1000);
      expect(timed.hasExpiry, isTrue);
    });

    Future<SignedObject> resigned(Node node, void Function(Json) edit) async {
      final o = await node.publish('post', {'text': 'hi'});
      final data = {...o.data};
      edit(data);
      return SignedObject(
        data,
        await sign(data, await node.identity.deviceKey.extract()),
        node.identity.certificate,
      );
    }

    test('objects from before v are valid; unknown versions are not', () async {
      final node = Node(await LocalIdentity.create(), Store());
      final old = await resigned(node, (d) => d.remove('v'));
      expect(old.version, 1);
      expect(await old.valid(), isTrue);
      final future = await resigned(node, (d) => d['v'] = 3);
      expect(await future.valid(), isFalse);
    });
  });

  group('database', () {
    test('a version 1 database is migrated and keeps its settings', () async {
      final alice = await LocalIdentity.create(label: 'Alice');
      final bob = await LocalIdentity.create(label: 'Bob');
      final carol = await LocalIdentity.create(label: 'Carol');
      final path = '${temp.path}/profile.db';
      // What version 1 wrote: the lists live in the settings blob.
      final old = sqlite3.open(path);
      old.execute('''
        CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        PRAGMA user_version=1;
      ''');
      for (final (k, v) in <(String, Object)>[
        ('contacts', [bob.certificate.toJson()]),
        ('subscriptions', ['general', 'garden']),
        ('revoked', [carol.device]),
        ('receivedBudget', 5),
      ]) {
        old.execute('INSERT INTO settings VALUES (?,?)', [k, canonical(v)]);
      }
      old.close();

      final node = Node(alice, Store(path: path));
      expect(node.store.db.select('PRAGMA user_version').first[0], 2);
      expect(node.contacts.keys, [bob.device]);
      expect(node.contacts[bob.device]!.label, 'Bob');
      expect(node.subscriptions, {'general', 'garden'});
      expect(node.revoked, {carol.device});
      // The moved keys are gone from settings; others stay.
      expect(node.store.setting('contacts'), isNull);
      expect(node.store.setting('subscriptions'), isNull);
      expect(node.store.setting('revoked'), isNull);
      expect(node.store.setting('receivedBudget'), 5);
      await node.close();

      // Reopening at version 2 changes nothing.
      final again = Node(alice, Store(path: path));
      expect(again.contacts.keys, [bob.device]);
      expect(again.subscriptions, {'general', 'garden'});
      await again.close();
    });

    test(
      'a version 1 database that never chose subscriptions gets general',
      () {
        final path = '${temp.path}/plain.db';
        final old = sqlite3.open(path);
        old.execute('''
        CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        PRAGMA user_version=1;
      ''');
        old.close();
        final store = Store(path: path);
        expect(store.subscribedSpaces(), {'general'});
        store.close();
      },
    );

    test('a new profile starts on general, and can leave it', () async {
      final node = Node(await LocalIdentity.create(), Store());
      expect(node.subscriptions, {'general'});
      node.subscribe('general', false);
      node.subscribe('garden', true);
      final reloaded = Node(node.identity, node.store);
      expect(reloaded.subscriptions, {'garden'});
    });

    test('contacts, revocations and learned devices persist as rows', () async {
      final a = Node(await LocalIdentity.create(), Store());
      final b = await LocalIdentity.create(label: 'Bob');
      await a.addContact(b.certificate);
      expect(Node(a.identity, a.store).contacts.keys, [b.device]);
      expect(
        a.store.db.select('SELECT label FROM device_contacts').single['label'],
        'Bob',
      );
    });

    test('a database from a newer version is refused', () {
      final path = '${temp.path}/newer.db';
      sqlite3.open(path)
        ..execute('PRAGMA user_version=99')
        ..close();
      expect(() => Store(path: path), throwsStateError);
    });
  });

  group('blobs', () {
    final key = SecretKey(List.filled(32, 7));

    test('versioned blobs lead with the version byte and open', () async {
      final sealed = await sealBlob(utf8.encode('chunk'), key, versioned: true);
      expect(sealed.first, blobVersion);
      expect(sealed.length, 1 + 12 + 5 + 16);
      expect(utf8.decode(await openBlob(sealed, key)), 'chunk');
    });

    test('legacy blobs open, even when the nonce starts with 1', () async {
      final legacy = await sealBlob(utf8.encode('old'), key, versioned: false);
      expect(utf8.decode(await openBlob(legacy, key)), 'old');
      final nonce = [blobVersion, ...List.filled(11, 9)];
      final unlucky = (await Chacha20.poly1305Aead().encrypt(
        utf8.encode('unlucky'),
        secretKey: key,
        nonce: nonce,
      )).concatenation();
      expect(unlucky.first, blobVersion);
      expect(utf8.decode(await openBlob(unlucky, key)), 'unlucky');
    });

    test('a tampered versioned blob is refused', () async {
      final sealed = await sealBlob(utf8.encode('chunk'), key, versioned: true);
      sealed[sealed.length - 1] ^= 1;
      await expectLater(
        openBlob(sealed, key),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('the worker writes plain blobs until versioning is on', () async {
      final node = Node(await LocalIdentity.create(), Store());
      addTearDown(node.close);
      final k = List.filled(32, 3);
      final plain = Uint8List.fromList(utf8.encode('payload'));
      final before = await node.blobs.encode(plain, k);
      expect(node.store.blob(before)!.length, 12 + 7 + 16);
      WireFormat.versionedBlobs = true;
      addTearDown(() => WireFormat.versionedBlobs = false);
      final after = await node.blobs.encode(plain, k);
      expect(node.store.blob(after)!.first, blobVersion);
      // Both open, whichever wrote them.
      for (final id in [before, after]) {
        expect(utf8.decode((await node.blobs.decode(id, k))!), 'payload');
      }
    });
  });

  group('wraps', () {
    test('both derivations decrypt, and each wrap names x25519', () async {
      final me = await LocalIdentity.create();
      for (final salted in [false, true]) {
        final box = await encryptFor(
          {'text': 'secret'},
          [me.certificate],
          saltedWraps: salted,
        );
        expect((box['wraps'] as List).single['kem'], 'x25519');
        expect(await decryptFor(box, me), {'text': 'secret'});
      }
    });

    test(
      'a salted wrap does not open under the empty-salt derivation',
      () async {
        final me = await LocalIdentity.create();
        final box = await encryptFor(
          {'a': 1},
          [me.certificate],
          saltedWraps: true,
        );
        final wrap = Map<String, dynamic>.from((box['wraps'] as List).single);
        final shared = await X25519().sharedSecretKey(
          keyPair: me.agreementKey,
          remotePublicKey: SimplePublicKey(
            unb64(wrap['ephemeral']),
            type: KeyPairType.x25519,
          ),
        );
        final legacyKey = await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
            .deriveKey(
              secretKey: shared,
              nonce: const [],
              info: utf8.encode('ournet/wrap/2/${me.device}'),
            );
        await expectLater(
          Chacha20.poly1305Aead().decrypt(
            SecretBox.fromConcatenation(
              unb64(wrap['box']),
              nonceLength: 12,
              macLength: 16,
            ),
            secretKey: legacyKey,
            aad: utf8.encode(me.device),
          ),
          throwsA(isA<SecretBoxAuthenticationError>()),
        );
      },
    );

    test('an unknown key agreement is refused', () async {
      final me = await LocalIdentity.create();
      final box = await encryptFor({'a': 1}, [me.certificate]);
      final wrap = Map<String, dynamic>.from((box['wraps'] as List).single)
        ..['kem'] = 'x25519+kyber768';
      await expectLater(
        decryptFor({
          ...box,
          'wraps': [wrap],
        }, me),
        throwsStateError,
      );
    });

    test(
      'published objects use the salted wrap only when switched on',
      () async {
        final a = Node(await LocalIdentity.create(), Store());
        final b = Node(await LocalIdentity.create(), Store());
        await a.addContact(b.identity.certificate);
        await b.addContact(a.identity.certificate);
        final o = await a.publish(
          'message',
          {'text': 'hi'},
          audience: [b.person],
        );
        expect((await b.content(o))!['text'], 'hi');
        WireFormat.saltedWraps = true;
        addTearDown(() => WireFormat.saltedWraps = false);
        final s = await a.publish(
          'message',
          {'text': 'salted'},
          audience: [b.person],
        );
        expect((await b.content(s))!['text'], 'salted');
      },
    );
  });

  group('tags', () {
    test('chunk sizes must be powers of two', () {
      for (final ok in [1024, 65536, 131072, 1 << 20]) {
        expect(validChunkBytes(ok), isTrue, reason: '$ok');
      }
      for (final bad in [0, 1000, 131073, 1 << 21, '131072', -1]) {
        expect(validChunkBytes(bad), isFalse, reason: '$bad');
      }
      expect(
        validContent('message', {'text': 'x', 'chunkBytes': 1000}),
        isFalse,
      );
      expect(
        validContent('message', {'text': 'x', 'chunkBytes': 131072}),
        isTrue,
      );
    });

    test('drive revisions and note registers are tagged', () async {
      final node = Node(await LocalIdentity.create(), Store());
      final folder = await Drive(node).folder('Docs');
      expect((await node.content(folder))!['driveFormat'], 1);
      final note = await Notes(node).create(title: 'T', text: 'x');
      final ops = node.store.allOf(kind: 'note_op', space: note.id);
      expect(ops, isNotEmpty);
      for (final op in ops) {
        expect((await node.content(op))!['reg'], 1);
      }
    });
  });

  test('new root seals cost 128 MiB over 3 passes', () {
    expect(SealedRoot.defaultMemory, 128 * 1024);
    expect(SealedRoot.defaultIterations, 3);
  });
}
