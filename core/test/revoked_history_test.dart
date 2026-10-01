import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';
import 'enrolment_test.dart' show befriend, enrol;

/// Devices get removed over the years. What they wrote, and what reached the
/// person only through them, must still reach the devices added afterwards.
void main() {
  late Node laptop, friend, old;

  Future<void> setUpDevices() async {
    laptop = Node(await LocalIdentity.create(), Store());
    friend = Node(await LocalIdentity.create(), Store());
    await befriend(laptop, friend);
    // An older phone of the same person, which the friend also knows.
    old = Node(
      await LocalIdentity.create(root: laptop.identity.root, label: 'Old'),
      Store(),
    );
    await laptop.addContact(old.identity.certificate);
    await old.addContact(laptop.identity.certificate);
    await old.addContact(friend.identity.certificate);
    await friend.addContact(old.identity.certificate);
  }

  test('a message written on a removed device reaches a new device', () async {
    await setUpDevices();
    final written = await old.publish(
      'message',
      {'text': 'from the old phone'},
      space: '_messages',
      audience: [laptop.person, friend.person],
    );
    await syncPair(old, laptop);
    await laptop.revoke(old.identity.device);

    final phone = await enrol(laptop);
    expect(phone.store.get(written.id), isNotNull);
    final text = (await phone.content(phone.store.get(written.id)!))?['text'];
    expect(text, 'from the old phone');
  });

  test(
    'a friend\'s profile that arrived through a removed device reaches a new device',
    () async {
      await setUpDevices();
      final profile = await friend.publish('profile', {
        'name': 'Henry',
      }, space: '_identity');
      await syncPair(friend, old);
      await syncPair(old, laptop);
      expect(laptop.store.get(profile.id), isNotNull);
      await laptop.revoke(old.identity.device);

      final phone = await enrol(laptop);
      expect(phone.store.get(profile.id), isNotNull);
    },
  );

  test('a removed device still cannot hand content to a friend', () async {
    await setUpDevices();
    final written = await old.publish(
      'message',
      {'text': 'from the old phone'},
      space: '_messages',
      audience: [laptop.person, friend.person],
    );
    await syncPair(old, laptop);
    await laptop.revoke(old.identity.device);
    final other = Node(await LocalIdentity.create(), Store());
    await befriend(laptop, other);
    await syncPair(laptop, other);
    expect(other.store.get(written.id), isNull);
  });

  test(
    'a device that does not ask for relayed objects is not sent any',
    () async {
      await setUpDevices();
      final written = await old.publish(
        'message',
        {'text': 'from the old phone'},
        space: '_messages',
        audience: [laptop.person, friend.person],
      );
      await syncPair(old, laptop);
      await laptop.revoke(old.identity.device);
      final phone = Node(
        await LocalIdentity.create(root: laptop.identity.root, label: 'New'),
        Store(),
      );
      await laptop.addContact(phone.identity.certificate);
      await phone.addContact(laptop.identity.certificate);
      final inventory = phone.inventoryAfter(peerDevice: laptop.identity.device)
        ..remove('ownRelay');
      final offered = await laptop.offer(phone.identity.device, inventory);
      expect(
        [for (final item in offered) item['object']['data']['kind']],
        isNot(contains('message')),
        reason: written.id,
      );
    },
  );

  test('an edit to a message not yet readable applies once it is', () async {
    final laptop = Node(await LocalIdentity.create(), Store());
    final friend = Node(await LocalIdentity.create(), Store());
    await befriend(laptop, friend);
    final message = await friend.publish(
      'message',
      {'text': 'first'},
      space: '_messages',
      audience: [laptop.person],
    );
    await MessageUpdates(friend).edit(message, 'fixed');
    await syncPair(laptop, friend);
    final phone = Node(
      await LocalIdentity.create(root: laptop.identity.root, label: 'Phone'),
      Store(),
    );
    await laptop.addContact(phone.identity.certificate);
    await phone.addContact(laptop.identity.certificate);
    await syncPair(laptop, phone, rounds: 64);
    final updates = MessageUpdates(phone);
    await updates.catchUp();
    final held = phone.store.get(message.id)!;
    expect(updates.editedText(held), isNull);

    await laptop.shareKeys(history: true);
    await syncPair(laptop, phone, rounds: 64);
    await updates.catchUp();
    expect(updates.editedText(held), 'fixed');
  });
}
