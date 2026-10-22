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
  testWidgets('own devices sit in the ring and people around them by '
      'distance; tapping one reports it and depth changes who is shown', (
    tester,
  ) async {
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
      final friends = <String, LocalIdentity>{};
      for (final name in ['Henry', 'bvtest', 'Sam', 'Priya', 'Jo']) {
        final friend = await LocalIdentity.create(label: 'My phone');
        await node.addContact(friend.certificate);
        names[friend.person] = name;
        friendDevices.add(friend.certificate);
        friends[name] = friend;
      }
      // Henry and Sam know people this person does not, and each other.
      final further = <String>[];
      for (final name in ['Ana', 'Ben', 'Cy']) {
        final p = await LocalIdentity.create();
        names[p.person] = name;
        further.add(p.person);
      }
      for (final (who, theirs) in [
        ('Henry', [further[0], further[1], friends['Sam']!.person]),
        ('Sam', [further[2], friends['Henry']!.person]),
      ]) {
        final friend = Node(friends[who]!, Store());
        await friend.addContact(node.identity.certificate);
        await friend.publish(Connections.listKind, {
          'friends': [node.person, ...theirs],
          'devices': [friend.identity.certificate.toJson()],
        }, space: Connections.listSpace);
        await syncPair(node, friend);
        await friend.close();
      }
      return (node, names, phone.certificate, friendDevices);
    }))!;
    final network = PeerNetwork(node);
    final live = {phone.device, friendDevices[0].device};
    String? person;
    DeviceCertificate? device;
    final key = GlobalKey();
    tester.view.physicalSize = const Size(420, 420);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Widget graph() => NetworkGraph(
      network: network,
      name: (p) => names[p] ?? '?',
      onPerson: (p) => person = p,
      onDevice: (d) => device = d,
      connected: live.contains,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'Roboto'),
        home: Scaffold(
          body: RepaintBoundary(key: key, child: graph()),
        ),
      ),
    );
    NetworkGraphState state() => tester.state(find.byType(NetworkGraph));
    String? named(String n) =>
        names.entries.where((e) => e.value == n).firstOrNull?.key;

    expect(
      find.bySemanticsLabel(
        RegExp('2 of your devices, 5 friends, 3 friends of friends'),
      ),
      findsOneWidget,
    );
    await tester.tapAt(state().spotOf(node.person)!);
    expect(device?.device, node.identity.device);
    await tester.tapAt(state().spotOf(named('Ana')!)!);
    expect(names[person], 'Ana');
    expect(state().selected, named('Ana'));

    // The same graph lands the same way every time.
    final at = {
      for (final n in names.values)
        if (named(n) case final id?) n: state().spotOf(id),
    };
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: graph())));
    for (final MapEntry(key: n, value: offset) in at.entries) {
      expect(state().spotOf(named(n)!), offset, reason: n);
    }
    final g = node.connections.graph();
    expect(placeGraph(g), placeGraph(g));

    await tester.tap(find.widgetWithText(ChoiceChip, '1'));
    await tester.pump();
    expect(state().spotOf(named('Ana')!), isNull);
    expect(find.text('+3 more'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('5 friends, 0 friends of friends')),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('Full screen'));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.byTooltip('Full screen'), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '2'));
    await tester.pump();

    if (_folder.isNotEmpty) {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: 'Roboto'),
          home: Scaffold(
            body: RepaintBoundary(key: key, child: graph()),
          ),
        ),
      );
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
    await tester.runAsync(node.close);
  });

  test('a full graph is laid out in bounded steps', () {
    final people = [
      const GraphPerson('me', 0, null),
      for (var i = 1; i < 300; i++) GraphPerson('$i', i < 20 ? 1 : 2, null),
    ];
    final links = [
      for (var i = 1; i < 20; i++) (0, i),
      for (var i = 20; i < 300; i++) (1 + i % 19, i),
    ];
    final places = placeGraph(FriendGraph(people, links, 0));
    expect(places.first, Offset.zero);
    expect(places.every((p) => p.dx.isFinite && p.dy.isFinite), isTrue);
  });
}
