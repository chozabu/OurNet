import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/ui/plugin_view.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:rfw/formats.dart';

const shots = String.fromEnvironment('BLAST_SHOTS');

void main() {
  test('standalone interface parses', () {
    final library = parseLibraryFile(
      File(
        '../plugins/blast-garden/ui.rfwtxt',
      ).readAsStringSync().replaceAll('\r\n', '\n'),
    );
    expect(library.widgets, isNotEmpty);
  });
  for (final size in [
    const Size(800, 600),
    const Size(360, 640),
    const Size(640, 360),
  ]) {
    testWidgets('real package lobby and arena at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        const base = 'C:/src/flutter/bin/cache/artifacts/material_fonts';
        if (!Directory(base).existsSync()) return;
        final loader = FontLoader('Roboto');
        for (final name in [
          'roboto-regular.ttf',
          'roboto-medium.ttf',
          'roboto-bold.ttf',
        ]) {
          loader.addFont(
            File('$base/$name').readAsBytes().then(ByteData.sublistView),
          );
        }
        await loader.load();
      });
      final temp = Directory.systemTemp.createTempSync('blast-garden-test');
      final pair = (await tester.runAsync(() async {
        final node = Node(await LocalIdentity.create(), Store());
        final plugins = Plugins(node, directory: temp.path);
        final package = PluginPackage.read(
          File(
            '../plugins/blast-garden/dist/blast-garden.ournet-plugin',
          ).readAsBytesSync(),
        );
        await plugins.install(package, grants: package.manifest.grants);
        return (node, plugins);
      }))!;
      final (node, plugins) = pair;
      addTearDown(() async {
        await tester.runAsync(() async {
          await plugins.close();
          await node.close();
          temp.deleteSync(recursive: true);
        });
      });
      Future<void> until(bool Function() ready) async {
        final end = DateTime.now().add(const Duration(seconds: 30));
        while (!ready()) {
          if (DateTime.now().isAfter(end))
            fail(
              'Plugin did not become ready: ${plugins['blast-garden']?.error}',
            );
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
        await tester.pump();
      }

      await until(
        () => plugins['blast-garden']?.status == PluginStatus.running,
      );
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: RepaintBoundary(
            key: key,
            child: Scaffold(
              body: PluginView(
                plugins: plugins,
                plugin: 'blast-garden',
                surface: 'BlastGarden',
                context: const {'scope': 'personal'},
                nameOf: (_) => 'Friend',
                avatar: (_, s) => CircleAvatar(radius: s / 2),
              ),
            ),
          ),
        ),
      );
      await until(() => find.text('Play solo').evaluate().isNotEmpty);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Co-op rescue'));
      await until(() => find.text('Co-op selected').evaluate().isNotEmpty);
      await tester.tap(find.text('Play solo'));
      await until(
        () =>
            find.bySemanticsLabel('Plant bomb').evaluate().isNotEmpty &&
            find.bySemanticsLabel('Movement thumb pad').evaluate().isNotEmpty &&
            plugins.surface('blast-garden', 'BlastGarden')['wide'] ==
                (size.width / size.height > 1.4),
      );
      expect(find.text('Garden rescue · stage 1 / 5'), findsOneWidget);
      double playerX() =>
          (plugins.surface('blast-garden', 'BlastGarden')['frame'] as List)
                  .cast<Map>()
                  .firstWhere((c) => c['text'] == 'YOU')['x']
              as double;
      final initialX = playerX();
      final thumb = await tester.startGesture(
        tester.getCenter(find.bySemanticsLabel('Movement thumb pad')) +
            const Offset(28, 0),
        pointer: 1,
        kind: ui.PointerDeviceKind.touch,
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await tester.pump();
      final intermediateX = playerX();
      expect(intermediateX, greaterThan(initialX));
      expect(
        intermediateX,
        lessThan(initialX + 16),
        reason: 'The gardener must travel through intermediate positions',
      );
      // A second finger can bomb without releasing or taking over the thumb pad.
      await tester.tap(
        find.bySemanticsLabel('Plant bomb'),
        pointer: 2,
        kind: ui.PointerDeviceKind.touch,
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pump();
      expect(
        (plugins.surface('blast-garden', 'BlastGarden')['stick']
            as List)[4]['x'],
        greaterThan(56),
      );
      await thumb.moveTo(
        tester.getCenter(find.bySemanticsLabel('Movement thumb pad')) +
            const Offset(-28, 0),
      );
      await thumb.cancel();
      await until(
        () =>
            (plugins.surface('blast-garden', 'BlastGarden')['stick']
                as List)[4]['x'] ==
            56.0,
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );
      await tester.pump();
      final stoppedX = playerX();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 180)),
      );
      await tester.pump();
      expect(
        playerX(),
        stoppedX,
        reason: 'Cancelled touches must not leave movement held',
      );
      expect(tester.takeException(), isNull);
      if (shots.isNotEmpty) {
        final boundary =
            key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = (await tester.runAsync(() => boundary.toImage()))!;
        final bytes = (await tester.runAsync(
          () => image.toByteData(format: ui.ImageByteFormat.png),
        ))!;
        await tester.runAsync(
          () => File(
            '$shots/arena-${size.width.toInt()}x${size.height.toInt()}.png',
          ).writeAsBytes(bytes.buffer.asUint8List()),
        );
        image.dispose();
      }
      if (size == const Size(360, 640)) {
        tester.view.physicalSize = const Size(640, 360);
        await tester.pump();
        await until(
          () => plugins.surface('blast-garden', 'BlastGarden')['wide'] == true,
        );
        expect(tester.takeException(), isNull);
        tester.view.physicalSize = size;
        await tester.pump();
        await until(
          () => plugins.surface('blast-garden', 'BlastGarden')['wide'] == false,
        );
      }
      await tester.tap(find.text('Use tap controls'));
      await until(() => find.text('RIGHT').evaluate().isNotEmpty);
      await tester.tap(find.text('RIGHT'));
      await tester.tap(find.text('Use thumb controls'));
      await until(
        () => find.bySemanticsLabel('Movement thumb pad').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('‹ Leave'));
      await until(() => find.text('Play solo').evaluate().isNotEmpty);
      await tester.tap(find.text('Versus arena'));
      await until(() => find.text('Versus selected').evaluate().isNotEmpty);
      await tester.tap(find.text('Play solo'));
      await until(
        () => find.text('Arena · last gardener standing').evaluate().isNotEmpty,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
