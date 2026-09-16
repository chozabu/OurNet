import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ournet/services/folder_connections.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';

/// Interactive SAF acceptance. Select an EMPTY disposable folder when the
/// system picker opens. Run in the separate org.chozabu.ournet.profile app:
/// flutter drive --profile -d DEVICE --driver=test_driver/performance.dart
///   --target=integration_test/folder_provider_test.dart
///   --dart-define=SAF_PICKER_TEST=true
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android document tree imports, replaces and deletes safely',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('Choose an empty test folder')),
        ),
      );
      final location = await pickSyncFolder();
      expect(location, startsWith('content:'));
      final fs = folderBackend(location!);
      expect(
        await fs.scan(),
        isEmpty,
        reason: 'Use an empty disposable test folder',
      );
      final directory = await Directory.systemTemp.createTemp(
        'ournet-saf-test-',
      );
      final node = Node(
        await LocalIdentity.create(),
        Store(path: '${directory.path}/test.db'),
      );
      final sync = FolderSync(
        Files(node, PeerNetwork(node)),
        folderBackend,
        automatic: false,
      );
      try {
        final root =
            (await node.content(await Drive(node).folder('SAF test')))!['entry']
                as String;
        await sync.connect(root, location);
        final source = File('${directory.path}/source');
        await source.writeAsString('Created on phone');
        await fs.put('phone.txt', source.path, null);
        await sync.sync();
        expect(sync.status[root], contains('up to date'));
        var entry = (await Drive(
          node,
        ).entries()).singleWhere((e) => e.current.data['name'] == 'phone.txt');
        final output = File('${directory.path}/output');
        await Files(
          node,
          PeerNetwork(node),
        ).save(entry.current.object, output.path);
        expect(await output.readAsString(), 'Created on phone');
        // A second adapter uses the persisted tree URI, not a filesystem path.
        final reopened = folderBackend(location);
        final token = (await reopened.stat('phone.txt'))!.token;
        await source.writeAsString('Edited on phone, different size');
        await reopened.put('phone.txt', source.path, token);
        await sync.sync();
        entry = (await Drive(
          node,
        ).entries()).singleWhere((e) => e.current.data['name'] == 'phone.txt');
        await Drive(node).revise(entry, {'deleted': true});
        await sync.sync();
        expect(await reopened.stat('phone.txt'), isNull);
        expect(sync.status[root], contains('up to date'));
        await reopened.mkdir('nested');
        await reopened.put('nested/new.txt', source.path, null);
        await sync.sync();
        expect(
          (await Drive(
            node,
          ).entries()).any((e) => e.current.data['name'] == 'new.txt'),
          true,
        );
        final oldFolder = (await Drive(
          node,
        ).entries()).singleWhere((e) => e.current.data['name'] == 'nested');
        await Drive(node).revise(oldFolder, {'name': 'renamed'});
        await sync.sync();
        expect(await reopened.stat('nested'), isNull);
        expect(await reopened.stat('renamed/new.txt'), isNotNull);
        final child = (await Drive(
          node,
        ).entries()).singleWhere((e) => e.current.data['name'] == 'new.txt');
        await Drive(node).revise(child, {'folder': root});
        await sync.sync();
        expect(await reopened.stat('new.txt'), isNotNull);
        expect(await reopened.stat('renamed/new.txt'), isNull);
      } finally {
        await sync.close();
        // Only the three exact names this test created are removed, nonrecursively.
        for (final path in [
          'nested/new.txt',
          'renamed/new.txt',
          'new.txt',
          'nested',
          'renamed',
          'phone.txt',
        ]) {
          final item = await fs.stat(path);
          if (item != null) await fs.remove(path, item.token);
        }
        await node.close();
        await directory.delete(recursive: true);
      }
    },
    skip: !Platform.isAndroid || !const bool.fromEnvironment('SAF_PICKER_TEST'),
  );
}
