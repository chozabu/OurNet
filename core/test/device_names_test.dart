import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';
import 'enrolment_test.dart' show befriend, enrol;

/// Devices linked as "My phone" can be told apart later: their owner renames
/// them, and the name reaches their other devices and their friends.
void main() {
  test(
    'a rename from another own device reaches friends; newest wins',
    () async {
      var time = 1000;
      final laptop = Node(
        await LocalIdentity.create(label: 'Laptop'),
        Store(),
        clock: () => time++,
      );
      final friend = Node(await LocalIdentity.create(), Store());
      await befriend(laptop, friend);
      final phone = await enrol(laptop, label: 'My phone');
      final device = phone.identity.device;

      await laptop.renameDevice(device, 'Blackview');
      await laptop.renameDevice(device, '  Pixel 8 Pro ');
      expect(laptop.deviceNames()[device], 'Pixel 8 Pro');

      await syncPair(laptop, phone);
      expect(phone.deviceNames()[device], 'Pixel 8 Pro');
      // The friend learns the phone from the laptop, then its name.
      await syncPair(laptop, friend);
      await syncPair(laptop, friend);
      expect(friend.contacts[device]?.label, 'My phone');
      expect(friend.deviceNames()[device], 'Pixel 8 Pro');
    },
  );

  test('nobody else can rename a device', () async {
    final laptop = Node(await LocalIdentity.create(), Store());
    final friend = Node(await LocalIdentity.create(), Store());
    await befriend(laptop, friend);
    await expectLater(
      friend.renameDevice(laptop.identity.device, 'Mine now'),
      throwsStateError,
    );
    // Published anyway, by a modified build: still not taken.
    await friend.publish('device_name', {
      'device': laptop.identity.device,
      'label': 'Mine now',
    }, space: '_identity');
    await syncPair(friend, laptop);
    expect(laptop.deviceNames(), isEmpty);
  });

  test('a removed device says when it was removed', () async {
    var time = 1000;
    final laptop = Node(
      await LocalIdentity.create(),
      Store(),
      clock: () => time,
    );
    final phone = await enrol(laptop);
    expect(laptop.revokedAt(), isEmpty);
    time = 9000;
    await laptop.revoke(phone.identity.device);
    expect(laptop.revokedAt(), {phone.identity.device: 9000});
  });
}
