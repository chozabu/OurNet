import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/ui/app.dart';
import 'package:ournet/ui/avatar.dart';
import 'package:ournet/ui/avatar_editor.dart';
import 'package:ournet_core/ournet_core.dart';

/// A [width] by [height] image, red on the left half and blue on the right.
Future<ui.Image> halves(int width, int height) {
  final recorder = ui.PictureRecorder();
  Canvas(recorder)
    ..drawRect(
      Rect.fromLTWH(0, 0, width / 2, height * 1.0),
      Paint()..color = const Color(0xffff0000),
    )
    ..drawRect(
      Rect.fromLTWH(width / 2, 0, width / 2, height * 1.0),
      Paint()..color = const Color(0xff0000ff),
    );
  return recorder.endRecording().toImage(width, height);
}

/// Straight RGBA for a solid square.
Uint8List solid(int edge) {
  final pixels = Uint8List(edge * edge * 4);
  for (var i = 0; i < pixels.length; i += 4) {
    pixels
      ..[i] = 30
      ..[i + 1] = 140
      ..[i + 2] = 90
      ..[i + 3] = 255;
  }
  return pixels;
}

Future<void> settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 180)),
  );
  await tester.pumpAndSettle();
}

bool showsPicture(Widget w) =>
    w is CircleAvatar && w.foregroundImage is AvatarImage;

void main() {
  test('pictures are decoded at a few sizes, keyed by their object', () {
    expect(AvatarImage.bucket(40), 48);
    expect(AvatarImage.bucket(80), 96);
    expect(AvatarImage.bucket(150), 160);
    expect(AvatarImage.bucket(600), Avatars.edge);
    final a = Avatar('one', Uint8List(4), 1);
    expect(AvatarImage(a, 96), AvatarImage(Avatar('one', Uint8List(8), 1), 96));
    expect(AvatarImage(a, 96), isNot(AvatarImage(Avatar('two', a.bytes, 1), 96)));
    expect(AvatarImage(a, 96), isNot(AvatarImage(a, 48)));
    expect(ProfileAvatar.initial('  ana '), 'A');
    expect(ProfileAvatar.initial('🙂 Sam'), '🙂');
    expect(ProfileAvatar.initial(''), '?');
  });

  testWidgets('framing keeps exactly the part chosen', (tester) async {
    final rgba = await tester.runAsync(() async {
      final image = await halves(200, 100);
      // The right half only: all blue.
      return cropAvatar(image, const Rect.fromLTWH(100, 0, 100, 100));
    });
    expect(rgba!.length, Avatars.edge * Avatars.edge * 4);
    final centre = (Avatars.edge * Avatars.edge ~/ 2 + Avatars.edge ~/ 2) * 4;
    expect(rgba.sublist(centre, centre + 4), [0, 0, 255, 255]);
  });

  testWidgets('the framing page fills the circle and returns the pixels', (
    tester,
  ) async {
    final png = await tester.runAsync(() async {
      final image = await halves(300, 120);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    });
    Uint8List? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await Navigator.of(context).push<Uint8List>(
                MaterialPageRoute(builder: (_) => AvatarCropPage(bytes: png!)),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump();
    for (var i = 0; i < 20 && find.byType(RawImage).evaluate().isEmpty; i++) {
      await settle(tester);
    }
    expect(find.byType(RawImage), findsOneWidget);
    await tester.tap(find.text('Use'));
    for (var i = 0; i < 20 && result == null; i++) {
      await settle(tester);
    }
    expect(result?.length, Avatars.edge * Avatars.edge * 4);
    // Centred on a 300×120 picture split down the middle, the circle holds
    // both colours: red on the left, blue on the right.
    final row = Avatars.edge ~/ 2 * Avatars.edge * 4;
    expect(result!.sublist(row + 8, row + 11), [255, 0, 0]);
    final end = row + (Avatars.edge - 3) * 4;
    expect(result!.sublist(end, end + 3), [0, 0, 255]);
  });

  testWidgets('pictures show on the profile page and in the conversation list', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final node = Node(await LocalIdentity.create(), Store());
    final friend = Node(await LocalIdentity.create(), Store());
    await node.addContact(friend.identity.certificate);
    await friend.addContact(node.identity.certificate);
    await tester.runAsync(() async {
      await node.publish('profile', {'name': 'Me'}, space: '_identity');
      await friend.publish('profile', {'name': 'Friendly'}, space: '_identity');
      await friend.avatars.set(solid(64), 64, 64);
      await friend.publish(
        'message',
        {'text': 'hi'},
        space: '_messages',
        audience: [node.person],
      );
      await syncPair(friend, node);
    });
    expect(node.avatars.of(friend.person), isNotNull);

    await tester.pumpWidget(OurNetApp(node: node, enablePlatform: false));
    await settle(tester);
    await tester.tap(find.text('Direct messages').first);
    await settle(tester);
    expect(find.text('Friendly'), findsWidgets);
    expect(find.byWidgetPredicate(showsPicture), findsWidgets);

    // Without a picture, the profile offers one and shows an initial.
    await tester.tap(find.text('Settings').first);
    await settle(tester);
    await tester.tap(find.text('Profile and devices'));
    await settle(tester);
    expect(find.text('Add a picture'), findsWidgets);

    await tester.runAsync(() => node.avatars.set(solid(64), 64, 64));
    await settle(tester);
    expect(find.text('Change picture'), findsWidgets);
    expect(
      find.byWidgetPredicate(
        (w) =>
            showsPicture(w) &&
            ((w as CircleAvatar).foregroundImage as AvatarImage)
                    .avatar
                    .id ==
                node.avatars.of(node.person)!.id,
      ),
      findsWidgets,
    );

    await tester.runAsync(node.avatars.clear);
    await settle(tester);
    expect(find.text('Add a picture'), findsWidgets);
  });
}
