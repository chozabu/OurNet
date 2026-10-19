import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/ui/transfers_view.dart';
import 'package:ournet_transport/ournet_transport.dart';

void main() {
  testWidgets('large transfers show progress and can be stopped', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final transfers = Transfers();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TransfersView(transfers: transfers)),
      ),
    );
    expect(find.byType(ListTile), findsNothing);
    final small = transfers.start('note.txt', 100, upload: true);
    final film = transfers.start('film.mkv', 4 << 30, upload: true)
      ..progress(1 << 30);
    await tester.pump();
    expect(find.text('note.txt'), findsNothing); // Too small to show.
    expect(find.text('film.mkv'), findsOneWidget);
    expect(find.text('Adding · 1.00 GB of 4.00 GB'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      0.25,
    );
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(film.cancelled, isTrue);
    expect(() => film.check(), throwsA(isA<TransferCancelled>()));
    expect(find.text('Stopping…'), findsOneWidget);
    film.finish();
    small.finish();
    await tester.pump();
    expect(find.byType(ListTile), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
