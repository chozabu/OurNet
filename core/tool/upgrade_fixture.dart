/// Saves a profile made by this build, for `test/upgrade_test.dart` to open
/// with every later build. Run from `core` when releasing a version:
///
///     dart run tool/upgrade_fixture.dart 0.2.1
///
/// Keep what this writes stable: the test checks the same content in every
/// saved profile. Add to it only alongside a check that tolerates its absence
/// in older profiles.
import 'dart:convert';
import 'dart:io';

import 'package:ournet_core/ournet_core.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('Usage: dart run tool/upgrade_fixture.dart <version>');
    exit(64);
  }
  final dir = Directory('test/fixtures/upgrade/${args.single}');
  if (dir.existsSync()) {
    stderr.writeln('${dir.path} already exists');
    exit(1);
  }
  dir.createSync(recursive: true);
  final alice = Node(
    await LocalIdentity.create(label: 'Alice laptop'),
    Store(path: '${dir.path}/profile.db'),
  );
  final bob = Node(await LocalIdentity.create(label: 'Bob phone'), Store());
  await alice.addContact(bob.identity.certificate);
  await bob.addContact(alice.identity.certificate);

  final notes = Notes(alice);
  final plans = await notes.create(title: 'Plans', text: 'Upgrades keep this');
  await notes.create(
    title: 'Shopping',
    checklist: true,
    items: ['Eggs', 'Tea'],
  );
  await notes.pin(plans.id, true);
  await notes.attach(
    plans.id,
    plans.epoch,
    Stream.value(utf8.encode('recorded audio')),
    name: 'Recording.m4a',
    meta: {'kind': 'audio', 'mime': 'audio/mp4', 'duration': 1000},
  );

  final room = await Everyday(alice).createRoom('Family', [bob.person]);
  await syncPair(alice, bob);
  await Everyday(alice).write({
    'type': 'check',
    'text': 'Milk',
    'list': 'Shopping',
    'done': false,
  }, room: room);
  await Everyday(bob).write({
    'type': 'check',
    'text': 'Bread',
    'list': 'Shopping',
    'done': false,
  }, room: (await Everyday(bob).rooms()).single);

  await alice.publish(
    'message',
    {'text': 'Hello Bob'},
    space: '_messages',
    audience: [bob.person],
  );
  await bob.publish(
    'message',
    {'text': 'Hello Alice'},
    space: '_messages',
    audience: [alice.person],
  );
  await alice.publish('post', {'text': 'Hello general'});
  await Drive(alice).folder('Documents');
  await syncPair(alice, bob);

  File(
    '${dir.path}/identity.json',
  ).writeAsStringSync(jsonEncode(await alice.identity.exportSecrets()));
  await alice.close();
  await bob.close();
  stdout.writeln('Saved ${dir.path}');
}
