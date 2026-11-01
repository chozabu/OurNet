import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/ui/liquid_page.dart';
import 'package:ournet_core/ournet_core.dart';

Future<void> settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 200)),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows proposals, votes through a representative, and '
      'lets a manual vote override', (tester) async {
    late Node a, b;
    late SignedObject proposal;
    await tester.runAsync(() async {
      a = Node(await LocalIdentity.create(), Store());
      b = Node(await LocalIdentity.create(), Store());
      await a.addContact(b.identity.certificate);
      await b.addContact(a.identity.certificate);
      a.subscribe('club', true);
      b.subscribe('club', true);
      proposal = await Liquid(b).propose(
        'club',
        title: 'Buy a telescope?',
        text: 'For the club',
        topic: 'science',
      );
      await Liquid(a).delegate('club', 'science', [b.person]);
      await Liquid(b).vote(proposal, 0);
      await syncPair(a, b);
    });
    addTearDown(() => tester.runAsync(() async {
      await a.close();
      await b.close();
    }));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LiquidPage(
            node: a,
            name: (p) => p == b.person ? 'Bob' : 'Me',
            friends: [b.person],
          ),
        ),
      ),
    );
    await settle(tester);
    expect(find.text('Buy a telescope?'), findsOneWidget);
    expect(find.text('Your vote: Yes, via Bob'), findsOneWidget);

    await tester.tap(find.text('Vote').last);
    await settle(tester);
    await settle(tester);
    expect(find.text('Your vote: No'), findsOneWidget);
    expect(find.text('Let my representative vote'), findsOneWidget);
  });
}
