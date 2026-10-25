import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ournet/services/remote_desktop.dart';
import 'package:ournet/ui/desktop_view.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';

/// The preview of this screen runs the whole picture path in the real
/// runner: capture, hardware encoding, decoding and the runner's texture.
/// Needs Windows with a GPU and an interactive desktop. Sends no input.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('a preview shows this screen through the texture', (
    tester,
  ) async {
    final node = Node(await LocalIdentity.create(), Store());
    final network = PeerNetwork(node);
    final dir = await Directory.systemTemp.createTemp('ournet-desktop');
    final plugins = Plugins(node, directory: dir.path);
    final desktops = RemoteDesktops(network, plugins);
    final id = desktops.open('remote-desktop', node.identity.device, {
      'width': 1280,
      'fps': 30,
      'kbps': 8000,
    });
    final session = desktops.session(id)!;
    final boundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RepaintBoundary(
            key: boundary,
            child: DesktopView(session: id, showStats: false),
          ),
        ),
      ),
    );
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (session.decoded < 10 && DateTime.now().isBefore(deadline)) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      // Fires the session's timers too, which read the decoder's figures.
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(session.error, isEmpty);
    expect(session.state, DesktopState.streaming);
    expect(session.decoded, greaterThanOrEqualTo(10));
    expect(session.textureId, isNotNull);
    expect(session.info['hardware'], isA<bool>());
    // What Flutter drew holds the picture, not the black backdrop.
    final image = await tester.runAsync(() async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final picture = await render.toImage();
      return picture.toByteData(format: ui.ImageByteFormat.rawRgba);
    });
    var lit = 0;
    for (var i = 0; i < image!.lengthInBytes; i += 4 * 97) {
      if (image.getUint8(i) + image.getUint8(i + 1) + image.getUint8(i + 2) >
          60) {
        lit++;
      }
    }
    debugPrint(
      'remote desktop preview: ${session.info}, frames '
      '${session.framesReceived}, decoded ${session.decoded}, decode ${session.decodeMicros} µs, lit $lit',
    );
    expect(lit, greaterThan(50));
    desktops.close(id);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    desktops.dispose();
    await plugins.close();
    await node.close();
  });
}
