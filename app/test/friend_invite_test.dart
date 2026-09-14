import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/ui/friend_invite.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';

void main() {
  testWidgets('add friend shows both roles and rejects a copied non-invite', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final node = Node(await LocalIdentity.create(), Store());
    addTearDown(node.close);
    final network = PeerNetwork(node);
    await tester.pumpWidget(
      MaterialApp(
        home: FriendInvitePage(network: network, enablePlatform: false),
      ),
    );
    await tester.pump();
    expect(find.text('Show my invitation'), findsOneWidget);
    expect(find.text('Find theirs'), findsOneWidget);
    await tester.tap(find.text('Find theirs'));
    await tester.pumpAndSettle();
    expect(find.text('Paste invitation they sent'), findsOneWidget);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async =>
          call.method == 'Clipboard.getData' ? {'text': 'hello'} : null,
    );
    await tester.tap(find.text('Paste invitation they sent'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Copy the invitation'), findsOneWidget);
    expect(node.contacts, isEmpty);
    expect(tester.takeException(), isNull);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });
}
