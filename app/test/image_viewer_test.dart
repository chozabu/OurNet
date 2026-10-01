import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/ui/image_viewer.dart';

final pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

void main() {
  testWidgets('image viewer pinches, pans and double-taps to zoom', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ImageViewer(bytes: Future.value(Uint8List.fromList(pixel))),
      ),
    );
    await tester.pump();
    final viewer = tester.state<State>(find.byType(InteractiveViewer));
    final controller = tester
        .widget<InteractiveViewer>(find.byType(InteractiveViewer))
        .transformationController!;
    expect(controller.value.getMaxScaleOnAxis(), 1);

    final center = tester.getCenter(find.byType(InteractiveViewer));
    final a = await tester.startGesture(center - const Offset(20, 0));
    final b = await tester.startGesture(center + const Offset(20, 0));
    for (var i = 0; i < 5; i++) {
      await a.moveBy(const Offset(-12, 0));
      await b.moveBy(const Offset(12, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await a.up();
    await b.up();
    await tester.pump();
    expect(controller.value.getMaxScaleOnAxis(), greaterThan(1.5));

    final before = controller.value.getTranslation().clone();
    await tester.dragFrom(center, const Offset(0, 40));
    await tester.pump();
    expect(controller.value.getTranslation(), isNot(before));
    expect(viewer, isNotNull);

    controller.value = Matrix4.identity();
    await tester.pump();
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(center);
    await tester.pumpAndSettle();
    expect(controller.value.getMaxScaleOnAxis(), greaterThan(2));
  });
}
