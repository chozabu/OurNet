import 'dart:io';

import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';

/// People and devices show when they were added, so a device linked by
/// mistake can be told apart from the one that was meant.
void main() {
  test('a contact keeps the time it was first added', () async {
    var time = 1000;
    final laptop = Node(
      await LocalIdentity.create(),
      Store(),
      clock: () => time,
    );
    final friend = Node(await LocalIdentity.create(), Store());
    await laptop.addContact(friend.identity.certificate);
    time = 5000;
    await laptop.addContact(friend.identity.certificate);
    expect(laptop.store.contactsAdded()[friend.identity.device], (
      added: 1000,
      estimated: false,
    ));
  });

  test('contacts from before times were recorded are dated by their '
      'earliest object', () async {
    final directory = await Directory.systemTemp.createTemp('ournet-added');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/profile.db';
    var store = Store(path: path);
    final laptop = Node(await LocalIdentity.create(), store);
    var time = 2000;
    final friend = Node(
      await LocalIdentity.create(),
      Store(),
      clock: () => time,
    );
    await laptop.addContact(friend.identity.certificate);
    await friend.addContact(laptop.identity.certificate);
    await friend.publish('profile', {'name': 'Henry'}, space: '_identity');
    time = 3000;
    await friend.publish('profile', {'name': 'Henry B'}, space: '_identity');
    await syncPair(friend, laptop);
    // As an earlier build left it.
    store.db.execute('DROP TABLE device_added');
    store.close();

    store = Store(path: path);
    addTearDown(store.close);
    expect(store.contactsAdded()[friend.identity.device], (
      added: 2000,
      estimated: true,
    ));
  });
}
