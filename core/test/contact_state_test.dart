import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';
import 'enrolment_test.dart' show befriend, enrol;

/// Blocking and disconnecting are a person's choices, so they hold on every
/// device of theirs, not only the one where they were made.
void main() {
  late Node laptop, phone, friend;

  setUp(() async {
    laptop = Node(await LocalIdentity.create(label: 'Laptop'), Store());
    friend = Node(await LocalIdentity.create(), Store());
    await befriend(laptop, friend);
    phone = await enrol(laptop);
    // The phone learns the friend from the laptop.
    await syncPair(laptop, phone);
    expect(phone.contacts.values.any((c) => c.person == friend.person), isTrue);
  });

  test('a block made on one device holds on the others', () async {
    await laptop.setContactState(friend.person, ContactState.blocked);
    expect(laptop.blocked, {friend.person});
    await syncPair(laptop, phone);
    expect(phone.blocked, {friend.person});

    await phone.setContactState(friend.person, ContactState.unblocked);
    await syncPair(phone, laptop);
    expect(laptop.blocked, isEmpty);
  });

  test('disconnecting forgets a friend everywhere until they are added '
      'again on purpose', () async {
    await laptop.setContactState(friend.person, ContactState.forgotten);
    expect(
      laptop.contacts.values.where((c) => c.person == friend.person),
      isEmpty,
    );
    await syncPair(laptop, phone);
    expect(phone.forgotten, {friend.person});
    expect(
      phone.contacts.values.where((c) => c.person == friend.person),
      isEmpty,
    );
    expect(phone.allowedPeer(friend.identity.device), isFalse);

    // Neither device hands the other the friend back.
    await syncPair(phone, laptop);
    expect(
      laptop.contacts.values.where((c) => c.person == friend.person),
      isEmpty,
    );

    // An invitation accepted on the phone reconnects both.
    await phone.addContact(friend.identity.certificate);
    expect(phone.forgotten, isEmpty);
    await syncPair(phone, laptop);
    expect(laptop.forgotten, isEmpty);
    expect(laptop.contacts.containsKey(friend.identity.device), isTrue);
  });

  test('blocking and disconnecting settle apart, whatever order they '
      'arrive in', () async {
    await phone.setContactState(friend.person, ContactState.blocked);
    await laptop.setContactState(friend.person, ContactState.forgotten);
    // The laptop hears of the older block after its own disconnect.
    await syncPair(phone, laptop);
    await syncPair(laptop, phone);
    for (final device in [laptop, phone]) {
      expect(device.blocked, {friend.person});
      expect(device.forgotten, {friend.person});
    }
    await laptop.setContactState(friend.person, ContactState.unblocked);
    await syncPair(laptop, phone);
    expect(phone.blocked, isEmpty);
    expect(phone.forgotten, {friend.person});
  });

  test('a new device says which device added it, and when', () async {
    final request = await LocalIdentity.create(label: 'Tablet');
    final approval = await laptop.identity.authorise(request.certificate);
    expect(approval.data['approvedBy'], laptop.identity.device);
    expect(approval.data['approved'], isA<int>());
    expect(await approval.valid(), isTrue);
    expect((await request.enrol(approval)).person, laptop.person);
  });

  test('a device is last seen by what it wrote', () async {
    expect(laptop.lastSeen(friend.identity.device), isNull);
    final post = await friend.publish('profile', {
      'name': 'Sam',
    }, space: '_identity');
    await syncPair(friend, laptop);
    expect(laptop.lastSeen(friend.identity.device), post.created);
  });
}
