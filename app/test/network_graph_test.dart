import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/ui/network_graph.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';

/// Set NETWORK_SHOTS to a folder to also write the graph as a PNG:
///
///   flutter test test/network_graph_test.dart --dart-define=NETWORK_SHOTS=C:/tmp/shots
const _folder = String.fromEnvironment('NETWORK_SHOTS');

Future<void> _loadFonts() async {
  const base = 'C:/src/flutter/bin/cache/artifacts/material_fonts';
  Future<ByteData> bytes(String name) async =>
      ByteData.sublistView(await File('$base/$name').readAsBytes());
  final roboto = FontLoader('Roboto')
    ..addFont(bytes('roboto-regular.ttf'))
    ..addFont(bytes('roboto-medium.ttf'));
  await roboto.load();
}

void main() {
  testWidgets('own devices sit in the ring and friends around it; '
      'tapping one reports it', (tester) async {
    if (_folder.isNotEmpty) await tester.runAsync(_loadFonts);
    final (
      node,
      names,
      phone,
      friendDevices,
    ) = (await tester.runAsync(() async {
      final node = Node(await LocalIdentity.create(label: 'WindTop'), Store());
      final names = <String, String>{node.person: 'AlexPB'};
      final phone = await LocalIdentity.create(
        root: node.identity.root,
        label: 'p8pro',
      );
      await node.addContact(phone.certificate);
      final friendDevices = <DeviceCertificate>[];
      for (final name in ['Henry', 'bvtest', 'Sam', 'Priya', 'Jo']) {
        final friend = await LocalIdentity.create(label: 'My phone');
        await node.addContact(friend.certificate);
        names[friend.person] = name;
        friendDevices.add(friend.certificate);
      }
      return (node, names, phone.certificate, friendDevices);
    }))!;
    final network = PeerNetwork(node);
    final live = {phone.device, friendDevices[0].device};
    String? person;
    DeviceCertificate? device;
    final key = GlobalKey();
    tester.view.physicalSize = const Size(420, 340);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'Roboto'),
        home: Scaffold(
          body: RepaintBoundary(
            key: key,
            child: NetworkGraph(
              network: network,
              name: (p) => names[p] ?? '?',
              onPerson: (p) => person = p,
              onDevice: (d) => device = d,
              connected: live.contains,
            ),
          ),
        ),
      ),
    );

    final origin = tester.getTopLeft(find.byType(NetworkGraph));
    final size = tester.getSize(find.byType(NetworkGraph));
    final centre = origin + Offset(size.width / 2, size.height / 2);
    // This device is first in the ring, at its top.
    await tester.tapAt(centre + const Offset(0, -24));
    expect(device?.device, node.identity.device);
    // The first friend by name (bvtest) sits just clockwise of the top.
    await tester.tapAt(
      Offset(
        centre.dx + (size.width / 2 - 48) * 0.5878,
        centre.dy - (size.height / 2 - 28) * 0.8090,
      ),
    );
    expect(names[person], 'bvtest');

    if (_folder.isNotEmpty) {
      final boundary =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await tester.runAsync(() => boundary.toImage());
      final data = await tester.runAsync(
        () => image!.toByteData(format: ui.ImageByteFormat.png),
      );
      await tester.runAsync(
        () => File(
          '$_folder/network_graph.png',
        ).writeAsBytes(data!.buffer.asUint8List()),
      );
    }
  });
}
