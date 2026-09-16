import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ournet/ui/app.dart';
import 'package:ournet/ui/note_editor.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/src/sync_queue.dart';
import 'package:ournet_transport/ournet_transport.dart';

import 'perf_support.dart';

/// Camera return into a note in a profile with history and a live device.
///
/// Every note change reconciles with another device, so the cost of routine
/// work grows with local history. This journey builds NOTES notes with EDITS
/// saved revisions each (synthetic text, temporary databases), pairs a second
/// device of the same person and keeps it syncing like a connected device
/// (400 ms after each change, as `PeerNetwork` does, without sockets). It
/// then opens a note in the full app, returns a 12 MP photo from the "camera"
/// and types through several autosaves while the photo is stored and previewed.
///
/// Reported per phase: UI-thread CPU (Android), event-loop delay and frames.
const notesCount = int.fromEnvironment('NOTES', defaultValue: 25);
const edits = int.fromEnvironment('EDITS', defaultValue: 30);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('camera return with history and a syncing device', (
    tester,
  ) async {
    final report = <String, Object>{'notes': notesCount, 'edits': edits};
    (binding.reportData ??= {})['noteHistory'] = report;
    void log(String message) => debugPrint('note history: $message');
    final budget =
        1000 / binding.platformDispatcher.views.first.display.refreshRate;
    report['frameBudgetMs'] = budget;
    final fixtureCache = Directory(
      '${Directory.systemTemp.path}/ournet-fixtures',
    );
    await fixtureCache.create(recursive: true);
    final photo = (await fixtures(fixtureCache, 1, 4000, 3000)).single;
    final directory = await Directory.systemTemp.createTemp('ournet-history-');
    final owner = await LocalIdentity.create();
    final fresh = await LocalIdentity.create();
    final phone = Node(owner, Store(path: '${directory.path}/phone.db'));
    final other = Node(
      await fresh.enrol(await owner.authorise(fresh.certificate)),
      Store(path: '${directory.path}/other.db'),
    );
    StreamSubscription<void>? peer;
    Timer? debounce;
    Future<void>? syncing;
    FolderSync? folderSync;
    try {
      await phone.addContact(other.identity.certificate);
      await other.addContact(owner.certificate);
      final notes = Notes(phone);
      final setup = Stopwatch()..start();
      for (var n = 0; n < notesCount; n++) {
        var note = await notes.create(title: 'Note $n', text: 'Start');
        for (var e = 0; e < edits; e++) {
          await notes.edit(
            note.id,
            note.epoch,
            'text',
            'Revision $e of note $n. ' * 8,
            note.parents('text'),
          );
          note = (await notes.get(note.id))!;
        }
      }
      report['objects'] = phone.store.count;
      report['historyMs'] = setup.elapsedMilliseconds;
      log('${phone.store.count} objects in ${setup.elapsed}');

      final initial = PhaseRecorder(budget)..start();
      await syncPair(phone, other, rounds: 1000);
      report['initialSync'] = await initial.stop();
      log('initial sync ${report['initialSync']}');

      // A connected device: reconcile shortly after changes on either side.
      final queue = SyncQueue((_) => syncPair(phone, other));
      void schedule() {
        debounce ??= Timer(const Duration(milliseconds: 400), () {
          debounce = null;
          syncing = queue.schedule(other.identity.device);
        });
      }

      peer = phone.changes.stream.listen((_) => schedule());

      binding.testTextInput.register();
      addTearDown(binding.testTextInput.unregister);
      final picker = Completer<XFile?>();
      await tester.pumpWidget(
        OurNetApp(
          node: phone,
          enablePlatform: false,
          initialTab: 9,
          pickImage: (_) => picker.future,
        ),
      );
      Future<void> waitFor(Finder finder) async {
        final deadline = DateTime.now().add(const Duration(minutes: 2));
        while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(finder, findsWidgets);
      }

      // The most recently created note is first in the list.
      final title = 'Note ${notesCount - 1}';
      await waitFor(find.text(title));
      await Future<void>.delayed(const Duration(seconds: 2));
      await tester.tap(find.text(title).first);
      await waitFor(find.byType(NoteEditor));
      await Future<void>.delayed(const Duration(seconds: 2));
      final editor = tester.state<NoteEditorState>(find.byType(NoteEditor));

      // Keep a connected filesystem folder active while the editor saves.
      final localFolder = await Directory(
        '${directory.path}/connected',
      ).create();
      final driveRoot =
          (await phone.content(
                await Drive(phone).folder('Connected'),
              ))!['entry']
              as String;
      folderSync = FolderSync(
        Files(phone, PeerNetwork(phone)),
        DiskFolderBackend.new,
        automatic: false,
      );
      // Android's app cache path may include the /data/user/0 alias. Resolve
      // this fixture path before using the desktop backend's no-links policy.
      await folderSync.connect(
        driveRoot,
        await localFolder.resolveSymbolicLinks(),
      );
      final camera = PhaseRecorder(budget)..start();
      await File(
        '${localFolder.path}/added.txt',
      ).writeAsString('Independent folder addition');
      final folderJob = folderSync.sync();
      final capture = editor.addImage(ImageSource.camera);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await Future<void>.delayed(const Duration(seconds: 1));
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      picker.complete(XFile(photo.path));
      final text = find.byKey(const ValueKey('note-text'));
      for (var i = 1; i <= 4; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        await tester.enterText(text, 'Typed while the photo saves ($i)');
        // Longer than the editor's autosave delay: each pause saves.
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      await capture.timeout(const Duration(minutes: 2));
      await editor.flush();
      await folderJob;
      expect(folderSync.status[driveRoot], contains('up to date'));
      expect(
        (await Drive(
          phone,
        ).entries()).any((e) => e.current.data['name'] == 'added.txt'),
        true,
      );
      // Preview generation and reconciliation with the other device.
      await Future<void>.delayed(const Duration(seconds: 10));
      report['cameraReturn'] = await camera.stop();
      log('camera return ${report['cameraReturn']}');

      await syncing;
      await syncPair(phone, other);
      // The photo and final text were saved and reached the other device.
      for (final device in [phone, other]) {
        final saved = (await Notes(device).get(editor.id!))!;
        expect(saved.rawTitle, title);
        expect(saved.text, 'Typed while the photo saves (4)');
        expect(saved.files, hasLength(1));
      }
      expect(tester.takeException(), isNull);
      if (const bool.fromEnvironment('PERF_ENFORCE')) {
        for (final name in ['initialSync', 'cameraReturn']) {
          final phase = report[name] as Map;
          final frames = phase['frameStageMs'] as Map;
          final delay = phase['eventLoopDelayMs'] as Map;
          expect(phase['frames'], greaterThanOrEqualTo(11), reason: name);
          expect(frames['p95'], lessThan(budget), reason: '$name p95');
          expect(frames['p99'], lessThan(2 * budget), reason: '$name p99');
          expect(delay['max'], lessThan(100), reason: '$name event loop');
        }
      }
    } finally {
      await folderSync?.close();
      await peer?.cancel();
      debounce?.cancel();
      await syncing;
      await tester.pumpWidget(const SizedBox());
      await phone.close();
      await other.close();
      await directory.delete(recursive: true);
    }
  });
}
