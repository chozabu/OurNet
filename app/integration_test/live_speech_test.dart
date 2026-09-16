import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ournet/services/live_speech.dart';
import 'package:ournet/services/speech.dart';
import 'package:ournet/ui/app.dart';
import 'package:ournet/ui/note_editor.dart';
import 'package:ournet/ui/voice_recorder.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_speech/ournet_speech.dart';

import 'fixtures/speech_sample.dart';

/// Live transcription through the platform speech recognizer.
///
/// Android (13+) streams the speech sample through the same pipe as the
/// microphone, in real time: first to each recognizer, then through the
/// voice-note button, timing Stop until the note is open with its
/// transcript. Run it as a profile build so the everyday app is untouched,
/// and grant microphone access once installed (the speech service requires
/// it even for a file):
/// flutter drive --profile -d DEVICE --driver=test_driver/performance.dart
///   --target=integration_test/live_speech_test.dart
/// adb shell pm grant org.chozabu.ournet.profile android.permission.RECORD_AUDIO
///
/// Windows dictation listens to the microphone itself, so there this checks
/// the native recording and that dictation starts and stops cleanly, and
/// times the voice-note button the same way:
/// flutter drive --profile -d windows --driver=test_driver/performance.dart
///   --target=integration_test/live_speech_test.dart
/// Add --dart-define=NOTES=190 for a profile with history.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  String? source;
  var seconds = 3;

  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('ournet-live-');
    if (!Platform.isAndroid) return; // Windows listens to the microphone.
    final m4a = File('${temp.path}/sample.m4a')
      ..writeAsBytesSync(base64.decode(speechSampleBase64));
    source = '${temp.path}/sample.pcm';
    final samples = await Whisper.decodePcm16(m4a.path, source!);
    seconds = (samples / 16000).ceil() + 1;
  });
  tearDownAll(() => temp.delete(recursive: true));

  void log(String message) {
    // ignore: avoid_print
    print(message);
  }

  Future<void> recognize(String engine) async {
    final live = LiveSpeech(language: 'auto', engine: engine, source: source);
    final status = await live.channel.invokeMapMethod<String, Object?>(
      'liveStatus',
      {'language': 'auto'},
    );
    log('[$engine] status: $status');
    if (status?['available'] != true) return;
    final path = LiveSpeech.recordsAudio ? '${temp.path}/$engine' : null;
    final updates = <(Duration, String)>[];
    final watch = Stopwatch()..start();
    live.text.addListener(() => updates.add((watch.elapsed, live.text.value)));
    try {
      await live.start(path: path);
    } on LiveSpeechException catch (e) {
      log('[$engine] could not start: $e');
      rethrow;
    }
    log('[$engine] started in ${watch.elapsed}');
    live.error.addListener(
      () => log('[$engine] ${watch.elapsed} error: ${live.error.value}'),
    );
    await Future<void>.delayed(Duration(seconds: seconds));
    final stopping = watch.elapsed;
    final result = await live.stop();
    for (final (at, text) in updates) {
      log('[$engine] $at: $text');
    }
    log(
      '[$engine] stopped in ${watch.elapsed - stopping}: $result, '
      'error: ${live.error.value}',
    );
    if (path != null) {
      final saved = result.path!;
      log('[$engine] saved ${await File(saved).length()} bytes');
      expect(result.duration, greaterThan(10000));
      // The recording must decode for playback and later transcription.
      final decoded = await Whisper.decodePcm16(saved, '$saved.pcm');
      expect(decoded / 16000, closeTo(result.duration! / 1000, 1));
      if (source != null) {
        expect(result.text?.toLowerCase(), contains('country'));
      }
    }
    live.dispose();
  }

  if (Platform.isAndroid) {
    testWidgets(
      'on-device recognizer',
      (_) => recognize('device'),
      skip: const bool.fromEnvironment('FLOW_ONLY'),
    );
    testWidgets(
      'speech service recognizer',
      (_) => recognize('cloud'),
      skip: const bool.fromEnvironment('FLOW_ONLY'),
    );
  } else {
    testWidgets('dictation starts and stops', (_) async {
      // Plays the sample aloud so a microphone near the speakers can hear it.
      final m4a = File('${temp.path}/sample.m4a')
        ..writeAsBytesSync(base64.decode(speechSampleBase64));
      final samples = await Whisper.decodePcm16(m4a.path, '${temp.path}/s.pcm');
      seconds = (samples / 16000).ceil() + 2;
      final pcm = File('${temp.path}/s.pcm').readAsBytesSync();
      final header = ByteData(44)
        ..setUint32(0, 0x52494646)
        ..setUint32(4, 36 + pcm.length, Endian.little)
        ..setUint32(8, 0x57415645)
        ..setUint32(12, 0x666d7420)
        ..setUint32(16, 16, Endian.little)
        ..setUint16(20, 1, Endian.little)
        ..setUint16(22, 1, Endian.little)
        ..setUint32(24, 16000, Endian.little)
        ..setUint32(28, 32000, Endian.little)
        ..setUint16(32, 2, Endian.little)
        ..setUint16(34, 16, Endian.little)
        ..setUint32(36, 0x64617461)
        ..setUint32(40, pcm.length, Endian.little);
      final wav = File('${temp.path}/sample.wav')
        ..writeAsBytesSync([...header.buffer.asUint8List(), ...pcm]);
      Future<void>.delayed(const Duration(milliseconds: 1500), () async {
        await Process.run('powershell', [
          '-NoProfile',
          '-Command',
          "(New-Object Media.SoundPlayer '${wav.path}').PlaySync()",
        ]);
      });
      await recognize('auto');
    });
  }

  testWidgets('the voice button opens a transcribed note on stop', (
    tester,
  ) async {
    final node = Node(
      await LocalIdentity.create(),
      Store(path: '${temp.path}/profile.db'),
    );
    // Optional history, as a long-used profile has (--dart-define=NOTES=200).
    final notes = Notes(node);
    for (var n = 0; n < const int.fromEnvironment('NOTES'); n++) {
      var note = await notes.create(title: 'Note $n', text: 'Start');
      for (var e = 0; e < 10; e++) {
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
    log('history: ${node.store.count} objects');
    await tester.pumpWidget(
      OurNetApp(node: node, enablePlatform: false, initialTab: 9),
    );
    final speech =
        (tester.state(find.byType(OurNetApp)) as dynamic).speech as Speech;
    speech.liveSource = const bool.fromEnvironment('MIC') ? null : source;
    await speech.start();
    log('engine ${speech.engine}, on device ${speech.liveOnDevice}');
    expect(speech.engine, 'system');
    await Future<void>.delayed(const Duration(seconds: 3));

    Future<void> waitFor(Finder finder) async {
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(finder, findsWidgets);
    }

    await waitFor(find.byTooltip('New voice note'));
    final watch = Stopwatch()..start();
    await tester.tap(find.byTooltip('New voice note'));
    await waitFor(find.text('Listening…'));
    log('listening after ${watch.elapsed}');
    final deadline = DateTime.now().add(Duration(seconds: seconds));
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    if (source != null && !const bool.fromEnvironment('MIC')) {
      expect(find.textContaining('country can do'), findsOneWidget);
    }

    watch.reset();
    await tester.tap(find.byIcon(Icons.stop_rounded));
    final transcript = find.byWidgetPredicate(
      (w) =>
          w is TextField &&
          w.decoration?.hintText == 'Transcript' &&
          (const bool.fromEnvironment('MIC') ||
              source == null ||
              (w.controller?.text.contains('country') ?? false)),
    );
    await waitFor(find.byType(NoteEditor));
    final opened = watch.elapsed;
    await waitFor(transcript);
    log(
      'note open ${opened.inMilliseconds} ms after stop, transcript '
      'shown after ${watch.elapsed.inMilliseconds} ms',
    );
    await tester.pumpAndSettle();
    expect(find.byType(VoiceRecorder), findsNothing);
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));

    await tester.pumpWidget(const SizedBox());
    await node.close();
  });
}
