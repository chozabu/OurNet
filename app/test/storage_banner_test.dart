import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/ui/storage_banner.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart' show PeerNetwork;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the storage banner warns, can be put off, and stays when full', (
    tester,
  ) async {
    final node = await tester.runAsync(
      () async => Node(await LocalIdentity.create(), Store()),
    );
    addTearDown(() => tester.runAsync(node!.close));
    final store = node!.store;
    final network = PeerNetwork(node);
    await tester.runAsync(
      () => node.publish('post', {'text': 'x' * 2000}),
    );
    final used = store.storedBytes;
    var opened = 0;
    Widget app() => MaterialApp(
      home: Scaffold(
        body: StorageBanner(network: network, openSettings: () => opened++),
      ),
    );
    final banner = find.byKey(const Key('storage-banner'));

    // Under the warning: nothing.
    await tester.pumpWidget(app());
    expect(banner, findsNothing);

    // Past the warning: a warning that can be put off.
    store.set('storageWarning', used - 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app());
    expect(banner, findsOneWidget);
    await tester.tap(find.text('Storage settings'));
    expect(opened, 1);
    await tester.tap(find.text('Not now'));
    await tester.pump();
    expect(banner, findsNothing);

    // At the limit: shown again, and not dismissable.
    store.set('storageLimit', used);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app());
    expect(banner, findsOneWidget);
    expect(find.textContaining('not being received'), findsOneWidget);
    expect(find.text('Not now'), findsNothing);
  });

  test('sizes are typed in GB', () {
    expect(gigabytes('20'), 20 * 1024 * 1024 * 1024);
    expect(gigabytes(' 0.5 '), 512 * 1024 * 1024);
    expect(gigabytes('0'), isNull);
    expect(gigabytes('lots'), isNull);
    expect(gigabytesText(Store.defaultStorageLimit), '20');
    expect(gigabytesText(1536 * 1024 * 1024), '1.50');
  });
}
