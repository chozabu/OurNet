import 'dart:convert';
import 'dart:typed_data';

import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';
import 'enrolment_test.dart' show befriend;

/// A solid square of straight RGBA pixels.
Uint8List square(int edge, {int r = 200, int g = 80, int b = 40, int a = 255}) {
  final pixels = Uint8List(edge * edge * 4);
  for (var i = 0; i < pixels.length; i += 4) {
    pixels
      ..[i] = r
      ..[i + 1] = g
      ..[i + 2] = b
      ..[i + 3] = a;
  }
  return pixels;
}

/// Profile pictures travel like names: to friends, and on from them to
/// their friends, newest first, and a removal hides older pictures.
void main() {
  late Node alice, bob, carol;

  setUp(() async {
    alice = Node(await LocalIdentity.create(), Store());
    bob = Node(await LocalIdentity.create(), Store());
    carol = Node(await LocalIdentity.create(), Store());
    await befriend(alice, bob);
    await befriend(bob, carol);
  });

  tearDown(() async {
    for (final n in [alice, bob, carol]) {
      await n.close();
    }
  });

  test('a picture reaches friends and their friends', () async {
    expect(alice.avatars.of(alice.person), isNull);
    final object = await alice.avatars.set(square(256), 256, 256);
    final own = alice.avatars.of(alice.person)!;
    expect(own.id, object.id);
    // A JPEG, well inside the limit.
    expect(own.bytes.sublist(0, 3), [0xff, 0xd8, 0xff]);
    expect(own.bytes.length, lessThan(Avatars.maxBytes));

    expect(bob.avatars.of(alice.person), isNull);
    await syncPair(alice, bob);
    expect(bob.avatars.of(alice.person)?.id, object.id);
    // Carol is not Alice's friend, but sees her name and picture via Bob.
    await syncPair(bob, carol);
    expect(carol.avatars.of(alice.person)?.id, object.id);
  });

  test('the newest picture wins, and a removal hides the rest', () async {
    await alice.avatars.set(square(64), 64, 64);
    await syncPair(alice, bob);
    final first = bob.avatars.of(alice.person)!;

    final second = await alice.avatars.set(square(64, g: 200), 64, 64);
    await syncPair(alice, bob);
    // The cached first picture is replaced when the second arrives.
    expect(bob.avatars.of(alice.person)?.id, second.id);
    expect(second.id, isNot(first.id));

    await alice.avatars.clear();
    expect(alice.avatars.of(alice.person), isNull);
    await syncPair(alice, bob);
    expect(bob.avatars.of(alice.person), isNull);
  });

  test('transparency is flattened onto white', () async {
    final object = await alice.avatars.set(square(32, a: 0), 32, 32);
    final avatar = decodeAvatar(object)!;
    expect(avatar.bytes.sublist(0, 3), [0xff, 0xd8, 0xff]);
  });

  test('a blocked person shows no picture, until unblocked', () async {
    await alice.avatars.set(square(32), 32, 32);
    await syncPair(alice, bob);
    bob.blocked.add(alice.person);
    expect(bob.avatars.of(alice.person), isNull);
    bob.blocked.remove(alice.person);
    expect(bob.avatars.of(alice.person), isNotNull);
  });

  test('pictures that are oversized or not images are refused', () async {
    expect(
      validContent('avatar', {
        'image': 'A' * (64 * 1024 + 4),
        'type': 'image/jpeg',
      }),
      isFalse,
    );
    expect(
      validContent('avatar', {'image': 'AAAA', 'type': 'text/html'}),
      isFalse,
    );
    expect(validContent('avatar', {}), isTrue);
    await expectLater(
      alice.blobs.encodeAvatar(Uint8List(10), 2, 2, maxBytes: 1000),
      throwsStateError,
    );
    // Bytes that are not a JPEG or PNG are never handed to a decoder.
    final junk = await alice.publish('avatar', {
      'image': base64Encode(utf8.encode('<svg></svg>')),
      'type': 'image/png',
    }, space: Avatars.space);
    expect(decodeAvatar(junk), isNull);
    expect(alice.avatars.of(alice.person), isNull);
  });
}
