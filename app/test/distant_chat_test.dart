import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/ui/app.dart';
import 'package:ournet_core/ournet_core.dart';
import 'chat_features_test.dart' show inChat, wide;
import 'features_test.dart' show settled;

void main() {
  testWidgets('a message from a friend of a friend waits as a request', (
    tester,
  ) async {
    wide(tester);
    // me - bob - carol
    final me = Node(await LocalIdentity.create(), Store());
    final bob = Node(await LocalIdentity.create(), Store());
    final carol = Node(await LocalIdentity.create(), Store());
    for (final (a, b) in [(me, bob), (bob, carol)]) {
      await a.addContact(b.identity.certificate);
      await b.addContact(a.identity.certificate);
    }
    await bob.publish('profile', {'name': 'Bob'}, space: '_identity');
    await carol.publish('profile', {'name': 'Carol'}, space: '_identity');
    Future<void> spread() => tester.runAsync(() async {
      for (final n in [me, bob, carol]) {
        await n.connections.publish();
      }
      for (var i = 0; i < 3; i++) {
        await syncPair(me, bob);
        await syncPair(bob, carol);
      }
    });
    await spread();
    await tester.runAsync(
      () => carol.distant.send(me.person, {
        'text': 'Can I borrow your ladder?',
        'title': 'Ladder',
      }),
    );
    await spread();

    await tester.pumpWidget(
      OurNetApp(
        node: me,
        enablePlatform: false,
        initialTab: Destination.messages,
      ),
    );
    await settled(tester);
    expect(find.text('Message requests (1)'), findsOneWidget);
    expect(find.text('Carol'), findsNothing);
    await tester.tap(find.text('Message requests (1)'));
    await settled(tester);
    await tester.tap(find.text('Carol').first);
    await settled(tester);
    expect(find.text('Not a contact · via Bob'), findsOneWidget);
    expect(inChat('Ladder'), findsOneWidget);
    expect(find.textContaining('Carol is not your friend'), findsOneWidget);
    // Calls need admitted devices.
    expect(find.byTooltip('Voice call'), findsNothing);

    await tester.tap(find.text('Ignore'));
    await settled(tester);
    expect(find.textContaining('Message requests'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      for (final n in [me, bob, carol]) {
        await n.close();
      }
    });
  });
}
