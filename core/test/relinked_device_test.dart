import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';
import 'enrolment_test.dart' show befriend, enrol;

/// A phone linked from an old phone that is then removed, before the old
/// phone synced with the person's other devices: the rest still find it.
void main() {
  late Node laptop, old, friend;

  setUp(() async {
    laptop = Node(await LocalIdentity.create(), Store());
    friend = Node(await LocalIdentity.create(), Store());
    await befriend(laptop, friend);
    old = Node(
      await LocalIdentity.create(root: laptop.identity.root, label: 'Old'),
      Store(),
    );
    await laptop.addContact(old.identity.certificate);
    await old.addContact(laptop.identity.certificate);
    await syncPair(laptop, old);
    await syncPair(laptop, friend);
    await syncPair(old, friend);
  });

  test('the laptop learns a phone linked and kept by the old phone, through '
      'a friend', () async {
    final pixel = await enrol(old, label: 'Pixel');
    await syncPair(old, friend);
    expect(friend.contacts.containsKey(pixel.identity.device), isTrue);
    await pixel.revoke(old.identity.device);
    await syncPair(pixel, friend);
    expect(laptop.contacts.containsKey(pixel.identity.device), isFalse);

    await syncPair(friend, laptop);
    expect(laptop.ownDevice(pixel.identity.device), isTrue);
    expect(laptop.allowedPeer(pixel.identity.device), isTrue);
    expect(laptop.revoked, contains(old.identity.device));

    // Once admitted, the two sync directly.
    final note = await laptop.publish(
      'message',
      {'text': 'hi'},
      audience: [friend.person],
    );
    await syncPair(laptop, pixel);
    expect(pixel.store.get(note.id), isNotNull);
  });

  test('an object carrying an own device certificate introduces it', () async {
    final pixel = await enrol(old, label: 'Pixel');
    await syncPair(old, friend);
    // A friend on an earlier build shares only its own devices; the phone's
    // profile, relayed by the friend, still introduces it.
    await pixel.publish('profile', {'name': 'Henry'}, space: '_identity');
    await syncPair(pixel, friend);
    // [receive] admits nothing from the inventory's certificates: only the
    // relayed profile can introduce the phone here.
    final page = await friend.offer(
      laptop.identity.device,
      laptop.inventoryAfter(peerDevice: friend.identity.device),
    );
    expect(laptop.contacts.containsKey(pixel.identity.device), isFalse);
    await laptop.receive(friend.identity.device, page);
    expect(laptop.ownDevice(pixel.identity.device), isTrue);
  });

  test(
    'a friend still cannot introduce a stranger\'s or a removed device',
    () async {
      final stranger = Node(await LocalIdentity.create(), Store());
      final pixel = await enrol(old, label: 'Pixel');
      await old.revoke(pixel.identity.device);
      await syncPair(old, laptop);
      expect(laptop.revoked, contains(pixel.identity.device));
      expect(
        await laptop.learnCertificates(friend.identity.device, [
          stranger.identity.certificate.toJson(),
          pixel.identity.certificate.toJson(),
        ]),
        isEmpty,
      );
    },
  );
}
