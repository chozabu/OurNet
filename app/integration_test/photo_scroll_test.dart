import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ournet/services/thumbnails.dart';
import 'package:ournet/ui/app.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart'
    show Files, PeerNetwork, FolderSync, DiskFolderBackend;

import 'perf_support.dart';

/// Repeatable Notes photo-scrolling journey for physical devices.
///
/// Scenarios (select with `--dart-define=PHOTO_SCENARIO=...`):
///  * `four` (default): four 12 MP phone-sized JPEGs between text notes.
///  * `large`: a mixed collection (PHOTO_COUNT photos, NOTE_COUNT notes),
///    scrolled while photos are imported and notes arrive from another device.
///
/// Cold scrolling is the first pass after launch with empty in-memory image
/// state. Warm scrolling repeats the same passes. Budgets use the display's
/// reported refresh rate.
class CountingBinding extends IntegrationTestWidgetsFlutterBinding {
  int imageDecodes = 0;
  @override
  Future<ui.Codec> instantiateImageCodecWithSize(
    ui.ImmutableBuffer buffer, {
    ui.TargetImageSizeCallback? getTargetSize,
  }) {
    imageDecodes++;
    return super.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: getTargetSize,
    );
  }
}

class CountingBlobWorker extends BlobWorker {
  CountingBlobWorker(super.store);
  int chunkReads = 0;
  @override
  Future<Uint8List?> decode(String hash, List<int>? key, {List<int>? bytes}) {
    if (bytes == null) chunkReads++;
    return super.decode(hash, key, bytes: bytes);
  }

  @override
  Future<Uint8List?> readLocal(List<String> hashes, List<int>? key) {
    // Whole-file reads on a disk profile bypass decode; count their chunks.
    if (store.path != null) chunkReads += hashes.length;
    return super.readLocal(hashes, key);
  }
}

class CountingNode extends Node {
  CountingNode(super.identity, super.store);
  late final _blobs = CountingBlobWorker(store);
  @override
  CountingBlobWorker get blobs => _blobs;
}

const scenario = String.fromEnvironment('PHOTO_SCENARIO', defaultValue: 'four');
const enforce = bool.fromEnvironment('PERF_ENFORCE');
const warmCycles = int.fromEnvironment('WARM_CYCLES', defaultValue: 5);
const dragPx = int.fromEnvironment('DRAG_PX', defaultValue: 320);
const dragMs = int.fromEnvironment('DRAG_MS', defaultValue: 260);
// Gestures per downward pass; 0 scrolls to the end. The large collection uses a
// bounded window so repeated passes finish in minutes, not hours.
const passGestures = int.fromEnvironment('PASS_GESTURES', defaultValue: -1);

void main() {
  final binding = CountingBinding();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('Notes photo scrolling ($scenario)', (tester) async {
    final large = scenario == 'large';
    final photoCount = int.fromEnvironment(
      'PHOTO_COUNT',
      defaultValue: large ? 300 : 4,
    );
    final noteCount = int.fromEnvironment(
      'NOTE_COUNT',
      defaultValue: large ? 700 : 6,
    );
    final report = <String, Object>{
      'scenario': scenario,
      'platform': Platform.operatingSystem,
      'photos': photoCount,
      'notes': noteCount,
    };
    (binding.reportData ??= {})['photoScroll'] = report;
    final fixtureCache = Directory(
      '${Directory.systemTemp.path}/ournet-fixtures',
    );
    await fixtureCache.create(recursive: true);
    final directory = await Directory.systemTemp.createTemp('ournet-scroll-');
    final node = CountingNode(
      await LocalIdentity.create(),
      Store(path: '${directory.path}/profile.db'),
    );
    Node? other;
    FolderSync? folderSync;
    try {
      final setup = Stopwatch()..start();
      // Phone camera photos for the four-photo case. The large collection uses
      // smaller originals so hundreds fit within the local blob quota.
      final sources = large
          ? await fixtures(fixtureCache, 8, 2016, 1512)
          : await fixtures(fixtureCache, 4, 4032, 3024);
      report['fixtureMs'] = setup.elapsedMilliseconds;
      debugPrint('photo scroll: fixtures ready');
      report['sourceBytes'] = [for (final s in sources) await s.length()];
      final files = Files(node, PeerNetwork(node));
      final thumbnails = Thumbnails.of(files);
      final total = photoCount + noteCount;
      var clock = 0;
      // Interleave photos evenly between notes, newest first in the list.
      final stride = photoCount == 0 ? total + 1 : total / photoCount;
      var nextPhoto = 0.0;
      var photos = 0;
      for (var i = 0; i < total; i++) {
        clock++;
        if (photos < photoCount && i >= nextPhoto) {
          await files.publish(
            sources[photos % sources.length].path,
            name: 'photo-$photos.jpg',
            audience: [node.person],
            everyday: {'type': 'file', 'entry': randomId(), 'clock': clock},
          );
          photos++;
          nextPhoto += stride;
        } else {
          await node.publish(
            'inbox',
            {
              'type': 'note',
              'text':
                  'Note ${i + 1}: remember to check the list and '
                  'reply about the weekend plans.',
              'entry': randomId(),
              'clock': clock,
            },
            space: '_inbox',
            audience: [node.person],
          );
        }
      }
      report['importMs'] =
          setup.elapsedMilliseconds - (report['fixtureMs'] as int);

      // Include the bounded shared-checklist row projection among the photos.
      // No originals are touched when its checkbox or collaborator badge updates.
      final notebook = Notes(node);
      final checklist = await notebook.create(title: 'Photo journey checklist');
      await notebook.edit(
        checklist.id,
        checklist.epoch,
        'check:review:text',
        'Review photos',
        [],
      );
      final friend = Node(await LocalIdentity.create(), Store());
      await node.addContact(friend.identity.certificate);
      await notebook.changeMembers(checklist.id, [friend.person]);
      await friend.close();
      report['sharedChecklistRows'] = 1;

      // A second device of the same person prepares notes to deliver during
      // the loaded phase. Pages are prepared before measurement so only the
      // receiving device's work is measured.
      final syncPages = <List<Json>>[];
      if (large) {
        final fresh = await LocalIdentity.create();
        final paired = await fresh.enrol(
          await node.identity.authorise(fresh.certificate),
        );
        other = Node(paired, Store());
        await node.addContact(paired.certificate);
        await other.addContact(node.identity.certificate);
        for (var i = 0; i < 96; i++) {
          await other.publish(
            'inbox',
            {
              'type': 'note',
              'text': 'Synced note $i',
              'entry': randomId(),
              'clock': total + 100 + i,
            },
            space: '_inbox',
            audience: [node.person],
          );
        }
        final have = <String, dynamic>{};
        while (true) {
          final page = await other.offer(node.identity.device, {
            'version': 2,
            'subscriptions': ['general'],
            'have': have,
            'revoked': <String>[],
          });
          if (page.isEmpty) break;
          for (final item in page) {
            have[SignedObject.fromJson(item['object']).id] = hash(
              (item['evidence'] as List)
                  .map((e) => Evidence.fromJson(e).id)
                  .toList()
                ..sort(),
            );
          }
          syncPages.add(page);
        }
        report['syncPages'] = syncPages.length;
      }

      final display = binding.platformDispatcher.views.first.display;
      final refreshRate = display.refreshRate;
      final budget = 1000 / refreshRate;
      report['refreshRateHz'] = refreshRate;
      report['frameBudgetMs'] = budget;
      report['devicePixelRatio'] = display.devicePixelRatio;

      var picks = 0;
      final listFinder = find.byKey(const PageStorageKey('everyday/self/All'));
      Future<void> launch() async {
        await tester.pumpWidget(
          OurNetApp(
            node: node,
            enablePlatform: false,
            initialTab: 9,
            pickAttachment: () async {
              final source = sources[picks++ % sources.length];
              return (path: source.path, name: 'imported-$picks.jpg');
            },
          ),
        );
        final deadline = DateTime.now().add(const Duration(minutes: 2));
        while (listFinder.evaluate().isEmpty &&
            DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(listFinder, findsOneWidget);
      }

      // An idle connected folder remains active while lists scroll. No
      // original file may be read just because presentation state changes.
      final connected = await Directory('${directory.path}/connected').create();
      final driveRoot =
          (await node.content(await Drive(node).folder('Connected')))!['entry']
              as String;
      folderSync = FolderSync(files, DiskFolderBackend.new);
      await folderSync.connect(driveRoot, connected.path);
      await folderSync.sync();
      debugPrint('photo scroll: launching');
      await launch();
      debugPrint('photo scroll: list shown');
      report['firstListMs'] = setup.elapsedMilliseconds;
      await Future<void>.delayed(const Duration(seconds: 2));

      ScrollPosition position() => tester
          .state<ScrollableState>(
            find.descendant(of: listFinder, matching: find.byType(Scrollable)),
          )
          .position;

      Future<void> settle() async {
        final end = DateTime.now().add(const Duration(seconds: 5));
        while (position().isScrollingNotifier.value &&
            DateTime.now().isBefore(end)) {
          await tester.pump(const Duration(milliseconds: 16));
        }
      }

      // Finger-speed drags followed by the ballistic fling, down then up.
      final gestureLimit = passGestures >= 0
          ? passGestures
          : large
          ? 60
          : 0;
      Future<int> pass(Offset delta, bool Function() done, int limit) async {
        var gestures = 0;
        while (!done() && gestures < (limit == 0 ? 4000 : limit)) {
          await tester.timedDrag(
            listFinder,
            delta,
            const Duration(milliseconds: dragMs),
          );
          await settle();
          gestures++;
        }
        return gestures;
      }

      Future<Map<String, Object>> cycle(String name) async {
        final chunkReads = node.blobs.chunkReads;
        final decodes = binding.imageDecodes;
        final generated = thumbnails.generated;
        debugPrint('photo scroll: $name');
        final recorder = PhaseRecorder(budget)..start();
        // Sample (outside frames) whether a loading placeholder is visible in
        // the list viewport: this is the photo "pop-in" users perceive as lag.
        var samples = 0, placeholderSamples = 0, run = 0, longestRun = 0;
        final sampler = Timer.periodic(const Duration(milliseconds: 50), (_) {
          if (listFinder.evaluate().isEmpty) return;
          final list = listFinder.evaluate().first.renderObject as RenderBox;
          final viewport = list.localToGlobal(Offset.zero) & list.size;
          final visible = find
              .descendant(
                of: listFinder,
                matching: find.byType(CircularProgressIndicator),
              )
              .evaluate()
              .any((e) {
                final box = e.renderObject as RenderBox?;
                if (box == null || !box.attached || !box.hasSize) return false;
                final rect = box.localToGlobal(Offset.zero) & box.size;
                return rect.overlaps(viewport);
              });
          samples++;
          if (visible) {
            placeholderSamples++;
            run++;
            longestRun = max(longestRun, run);
          } else {
            run = 0;
          }
        });
        final watch = Stopwatch()..start();
        final down = await pass(
          Offset(0, -dragPx.toDouble()),
          () => position().pixels >= position().maxScrollExtent - 1,
          gestureLimit,
        );
        final travelled = position().pixels;
        final up = await pass(
          Offset(0, dragPx.toDouble()),
          () => position().pixels <= position().minScrollExtent + 1,
          0,
        );
        sampler.cancel();
        final result = await recorder.stop();
        return {
          'name': name,
          'ms': watch.elapsedMilliseconds,
          'gestures': down + up,
          'extentPx': position().maxScrollExtent,
          'travelledPx': travelled,
          'originalChunkReads': node.blobs.chunkReads - chunkReads,
          'placeholderVisiblePct': samples == 0
              ? 0
              : 100 * placeholderSamples / samples,
          'longestPlaceholderMs': longestRun * 50,
          'imageDecodes': binding.imageDecodes - decodes,
          'thumbnailsGenerated': thumbnails.generated - generated,
          'rssMiB': ProcessInfo.currentRss / 1048576,
          'imageCacheMiB':
              PaintingBinding.instance.imageCache.currentSizeBytes / 1048576,
          'imageCacheEntries': PaintingBinding.instance.imageCache.currentSize,
          ...result,
        };
      }

      // Rebuilding Notes data runs on the UI isolate after every change.
      final query = Stopwatch()..start();
      await Everyday(node).items();
      report['itemsQueryMs'] = query.elapsedMilliseconds;
      final cycles = <Map<String, Object>>[];
      report['cycles'] = cycles;
      cycles.add(await cycle('cold'));
      for (var i = 1; i <= warmCycles; i++) {
        cycles.add(await cycle('warm$i'));
      }
      if (!large) {
        // Relaunch with empty in-memory image state but durable previews.
        await tester.pumpWidget(const SizedBox());
        PaintingBinding.instance.imageCache
          ..clear()
          ..clearLiveImages();
        debugPrint('photo scroll: relaunching');
        await launch();
        await Future<void>.delayed(const Duration(seconds: 1));
        cycles.add(await cycle('relaunch'));
      }

      if (large) {
        // Scroll while importing photos and receiving synced notes.
        final imports = Stopwatch()..start();
        final beforeItems = (await Everyday(node).items()).length;
        Future<void> waitForImport() async {
          final end = DateTime.now().add(const Duration(minutes: 1));
          while (find
                  .text('Saving attachment locally…')
                  .evaluate()
                  .isNotEmpty &&
              DateTime.now().isBefore(end)) {
            await tester.pump(const Duration(milliseconds: 50));
          }
        }

        await tester.tap(find.byTooltip('Add original file'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save an original file'));
        final syncing = () async {
          for (final page in syncPages) {
            await node.receive(other!.identity.device, page);
            await Future<void>.delayed(const Duration(milliseconds: 150));
          }
        }();
        cycles.add(await cycle('loaded1'));
        await waitForImport();
        await tester.tap(find.byTooltip('Add original file'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save an original file'));
        cycles.add(await cycle('loaded2'));
        await syncing;
        await waitForImport();
        report['loadedMs'] = imports.elapsedMilliseconds;
        final afterItems = (await Everyday(node).items()).length;
        report['itemsAdded'] = afterItems - beforeItems;
        expect(afterItems - beforeItems, 96 + 2);
      }
      expect(tester.takeException(), isNull);

      // Efficiency expectations: warm passes over already-seen photos must not
      // re-read originals or re-decode images, and memory must stabilise.
      final warm = cycles
          .where((c) => '${c['name']}'.startsWith('warm'))
          .toList();
      if (!large) {
        for (final c in warm) {
          expect(
            c['originalChunkReads'],
            0,
            reason: '${c['name']} re-read originals',
          );
          expect(
            c['imageDecodes'],
            0,
            reason: '${c['name']} re-decoded images',
          );
        }
      }
      for (final c in cycles.where((c) => c['name'] == 'relaunch')) {
        expect(c['originalChunkReads'], 0, reason: 'relaunch read originals');
      }
      final rssGrowth =
          (warm.last['rssMiB'] as double) - (warm.first['rssMiB'] as double);
      report['warmRssGrowthMiB'] = rssGrowth;
      expect(rssGrowth, lessThan(32));

      expect(tester.takeException(), isNull);
      if (enforce) {
        for (final c in cycles) {
          final stage = c['frameStageMs'] as Map<String, double>;
          expect(c['frames'] as int, greaterThan(10));
          expect(stage['p95']!, lessThan(budget), reason: '${c['name']} p95');
          expect(
            stage['p99']!,
            lessThan(2 * budget),
            reason: '${c['name']} p99',
          );
          expect(
            (c['eventLoopDelayMs'] as Map<String, double>)['max']!,
            lessThan(100),
            reason: '${c['name']} event loop',
          );
        }
      }
    } finally {
      await folderSync?.close();
      debugPrint('photo scroll: cleanup');
      await tester.pumpWidget(const SizedBox());
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await other?.close();
      debugPrint('photo scroll: closing node');
      await node.close();
      debugPrint('photo scroll: node closed');
      await directory.delete(recursive: true);
    }
  });
}
