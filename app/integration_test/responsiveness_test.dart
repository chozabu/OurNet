import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ournet/services/performance.dart';
import 'package:ournet/ui/app.dart';
import 'package:ournet_core/ournet_core.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('import an image while typing, saving and filtering notes', (
    tester,
  ) async {
    // Desktop integration bindings use native text input by default. Register
    // the test channel so enterText exercises the actual editor deterministically.
    binding.testTextInput.register();
    addTearDown(binding.testTextInput.unregister);
    final directory = await Directory.systemTemp.createTemp('ournet-ui-perf-');
    final node = Node(
      await LocalIdentity.create(),
      Store(path: '${directory.path}/profile.db'),
    );
    final monitor = PerformanceMonitor();
    try {
      // Deterministic synthetic image, no user files or profile data involved.
      final random = Random(7);
      final pixels = Uint8List(1024 * 1024 * 4);
      for (var i = 0; i < pixels.length; i += 4) {
        pixels[i] = random.nextInt(256);
        pixels[i + 1] = random.nextInt(256);
        pixels[i + 2] = random.nextInt(256);
        pixels[i + 3] = 255;
      }
      final decoded = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        pixels,
        1024,
        1024,
        ui.PixelFormat.rgba8888,
        decoded.complete,
      );
      final image = await decoded.future;
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final source = File('${directory.path}/test-image.png');
      await source.writeAsBytes(png!.buffer.asUint8List());
      for (var i = 0; i < 60; i++) {
        await Everyday(
          node,
        ).write({'type': 'note', 'text': 'Existing note $i'});
      }
      await tester.pumpWidget(
        OurNetApp(
          node: node,
          enablePlatform: false,
          initialTab: 9,
          pickAttachment: () async =>
              (path: source.path, name: 'test-image.png'),
        ),
      );
      await tester.pumpAndSettle();
      // The engine batches FrameTiming callbacks. Flush startup frames before
      // measuring this journey (the same boundary used by watchPerformance).
      await Future<void>.delayed(const Duration(seconds: 2));
      Future<void> exercise() async {
        monitor.start();
        await tester.tap(find.byTooltip('Add original file'));
        await tester.pump();
        expect(find.text('Saving attachment locally…'), findsOneWidget);
        await tester.enterText(
          find.byType(TextField).last,
          'Typed during import',
        );
        await tester.pump();
        expect(
          tester
              .widget<TextField>(find.byType(TextField).last)
              .controller!
              .text,
          'Typed during import',
        );
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Save note'),
              )
              .onPressed,
          isNotNull,
        );
        await tester.tap(find.text('Save note'));
        await tester.pump();
        await tester.tap(find.widgetWithText(ChoiceChip, 'Text'));
        await tester.pump();
        expect(
          tester
              .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Text'))
              .selected,
          isTrue,
        );
        await tester.drag(find.byType(ListView).last, const Offset(0, -200));
        final deadline = DateTime.now().add(const Duration(seconds: 45));
        while (find.text('Saving attachment locally…').evaluate().isNotEmpty &&
            DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(find.text('Saving attachment locally…'), findsNothing);
        await tester.tap(find.widgetWithText(ChoiceChip, 'All'));
        await tester.pumpAndSettle();
        // Include automatic image preview/decryption in the measured journey.
        await tester.pump(const Duration(milliseconds: 500));
        final items = await Everyday(node).items();
        expect(
          items.where((i) => i.data['name'] == 'test-image.png'),
          hasLength(1),
        );
        expect(
          (await Notes(
            node,
          ).summaries()).where((i) => i.data['text'] == 'Typed during import'),
          hasLength(1),
        );
        expect(tester.takeException(), isNull);
        await Future<void>.delayed(const Duration(seconds: 2));
        monitor.stop();
      }

      if (const bool.fromEnvironment('PERF_TRACE')) {
        await binding.traceAction(exercise);
      } else {
        await exercise();
      }
      final result = monitor.snapshot();
      (binding.reportData ??= {})['responsiveness'] = result;
      // Timing gates belong on a consistent profile-mode device, not shared
      // debug CI runners. Functional assertions above always run.
      // Budgets follow the display's actual refresh rate (e.g. 8.3 ms at 120 Hz).
      final budget =
          1000 / binding.platformDispatcher.views.first.display.refreshRate;
      result['frameBudgetMs'] = budget;
      if (const bool.fromEnvironment('PERF_ENFORCE')) {
        final frames = monitor.frames.snapshot();
        expect(frames['count'] as int, greaterThan(10));
        expect(frames['p95'] as double, lessThan(budget));
        expect(frames['p99'] as double, lessThan(2 * budget));
        expect(monitor.eventLoop.maximum, lessThan(100));
      }
    } finally {
      monitor.stop();
      await tester.pumpWidget(const SizedBox());
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await node.close();
      for (final file in await directory.list().toList()) {
        await file.delete();
      }
      await directory.delete();
    }
  });
}
