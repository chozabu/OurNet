import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart' show XFile;
import 'package:ournet/ui/keep_import.dart';
import 'package:ournet_core/ournet_core.dart';

final class _File extends PlatformFile {
  final File file;
  _File(String path) : file = File(path);

  @override
  String get name => 'takeout.zip';
  @override
  Uri get uri => file.uri;
  @override
  XFile get xFile => XFile(file.path);
  @override
  int? lengthSync() => file.lengthSync();
  @override
  Future<int> length() => file.length();
  @override
  Future<Uint8List> readAsBytes() => file.readAsBytes();
  @override
  Stream<Uint8List> readAsByteStream() =>
      file.openRead().map(Uint8List.fromList);
}

class _Picker extends FilePickerPlatform {
  final String path;
  _Picker(this.path);

  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => [_File(path)];
}

Future<void> waitFor(WidgetTester tester, Finder finder) async {
  await waitUntil(tester, () => finder.evaluate().isNotEmpty);
  expect(finder, findsWidgets);
}

Future<void> waitUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
}

void main() {
  testWidgets('imports a Takeout zip after confirming', (tester) async {
    late Directory directory;
    late Node node;
    late Notes notes;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('ournet-keep-');
      node = Node(await LocalIdentity.create(), Store());
      notes = Notes(node);
      final archive = Archive();
      void add(String name, List<int> bytes) =>
          archive.add(ArchiveFile.bytes('Takeout/Keep/$name', bytes));
      Map<String, Object?> note(String title, {bool trashed = false}) => {
        'color': 'YELLOW',
        'isTrashed': trashed,
        'isPinned': false,
        'isArchived': false,
        'title': title,
        'textContent': 'Body of $title',
        'createdTimestampUsec': 1700000000000000,
        'userEditedTimestampUsec': 1710000000000000,
      };
      add('Groceries.json', utf8.encode(jsonEncode(note('Groceries'))));
      add('Old.json', utf8.encode(jsonEncode(note('Old', trashed: true))));
      add('Groceries.html', utf8.encode('<html></html>'));
      add('Labels.txt', utf8.encode('Home\n'));
      await File(
        '${directory.path}/takeout.zip',
      ).writeAsBytes(ZipEncoder().encodeBytes(archive));
    });
    FilePickerPlatform.instance = _Picker('${directory.path}/takeout.zip');

    int? imported;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                imported = await importKeepNotes(context, notes),
            child: const Text('Start'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Start'));
    await waitFor(tester, find.text('Import'));
    expect(find.text('1 note will be added.'), findsOneWidget);
    expect(find.text('Not imported: 1 · In Keep’s trash'), findsOneWidget);

    await tester.tap(find.text('Import'));
    await waitFor(tester, find.text('Import finished'));
    expect(find.text('1 note imported.'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await waitUntil(tester, () => imported != null);
    expect(imported, 1);

    await tester.runAsync(() async {
      final summaries = await notes.summaries();
      expect(summaries.single.data['title'], 'Groceries');
      expect(summaries.single.data['color'], 'sand');
      // Sorted and shown by the time it was last edited in Keep.
      expect(summaries.single.data['updated'], 1710000000000);
      await node.close();
      await directory.delete(recursive: true);
    });
  });
}
