import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/ui/header_when_room.dart';

void main() {
  Future<void> host(WidgetTester tester, double height) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 200,
              height: height,
              child: HeaderWhenRoom(
                header: const SizedBox(height: 60, child: Text('Title')),
                children: [
                  for (var i = 0; i < 5; i++)
                    SizedBox(height: 50, child: Text('Item $i')),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('keeps the header while everything fits', (tester) async {
    await host(tester, 400);
    expect(find.text('Title'), findsOneWidget);
  });

  testWidgets('drops the header when the items need the room', (tester) async {
    await host(tester, 300);
    expect(find.text('Title'), findsNothing);
    expect(find.text('Item 0'), findsOneWidget);
  });

  testWidgets('brings the header back when the room returns', (tester) async {
    await host(tester, 200);
    expect(find.text('Title'), findsNothing);
    await host(tester, 400);
    expect(find.text('Title'), findsOneWidget);
  });
}
