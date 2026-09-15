import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ournet/services/speech.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';

import 'fixtures/speech_sample.dart';

/// End-to-end voice note transcription with the bundled whisper.cpp library.
///
/// flutter test integration_test/voice_note_test.dart -d windows
///   [--dart-define=VOICE_SAMPLE=path/to/speech.m4a]
///   [--dart-define=VOICE_TEXT=expected words]
///
/// On Android, run it as a profile build so the everyday app is untouched:
/// flutter drive --profile -d DEVICE --driver=test_driver/performance.dart
///   --target=integration_test/voice_note_test.dart
///
/// The Fast model is downloaded and verified on first use (32 MB) into the
/// application support folder, where the app reuses it.
const sample = String.fromEnvironment('VOICE_SAMPLE');
const modelId = String.fromEnvironment('VOICE_MODEL', defaultValue: 'tiny');
const expected = String.fromEnvironment('VOICE_TEXT', defaultValue: 'country');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'a recorded voice note is transcribed on this device',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp('ournet-voice-');
      final node = Node(
        await LocalIdentity.create(),
        Store(path: '${directory.path}/profile.db'),
      );
      final notes = Notes(node);
      final speech = Speech(notes, Files(node, PeerNetwork(node)));
      try {
        speech.modelId = modelId;
        speech.language = 'en';
        await speech.start();
        final model = await speech.modelFile(speech.model);
        if (await model.exists() && await model.length() == speech.model.size) {
          // Reuse a verified download from an earlier run.
          node.store.set('speech/verified/$modelId', true);
        } else {
          final watch = Stopwatch()..start();
          await speech.download(speech.model);
          // ignore: avoid_print
          print('Model downloaded and verified in ${watch.elapsed}');
        }
        expect(await speech.installed(speech.model), true);

        final note = await notes.create();
        final file = await notes.attach(
          note.id,
          note.epoch,
          sample.isEmpty
              ? Stream.value(base64.decode(speechSampleBase64))
              : File(sample).openRead(),
          name: 'Recording.m4a',
          meta: {'kind': 'audio', 'mime': 'audio/mp4', 'duration': 11000},
        );
        final watch = Stopwatch()..start();
        speech.transcribe(note.id, file);
        String transcript = '';
        while (watch.elapsed < const Duration(minutes: 3)) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          transcript = (await notes.get(note.id))!.transcript(file);
          final status = speech.status[file];
          if (status?.state == 'failed') {
            fail('Transcription failed: ${status!.error}');
          }
          if (transcript.isNotEmpty) break;
        }
        // ignore: avoid_print
        print('Transcribed in ${watch.elapsed}: $transcript');
        expect(transcript.toLowerCase(), contains(expected.toLowerCase()));
        final summary = (await notes.summaries()).single.data;
        expect(summary['transcript'], transcript);
        expect(node.store.setting('speech/jobs'), isEmpty);
      } finally {
        speech.close();
        await node.close();
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
