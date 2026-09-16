import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/services/live_speech.dart';
import 'package:ournet/services/speech.dart';
import 'package:ournet/ui/speech_settings.dart';
import 'package:ournet/ui/voice_recorder.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';
import 'package:record/record.dart';

/// Records to a real file without a microphone.
class _FakeRecorder implements AudioRecorder {
  String? path;
  @override
  Future<bool> hasPermission({bool request = true}) async => true;
  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    File(path).writeAsBytesSync(List.filled(64, 1));
    this.path = path;
  }

  @override
  Future<String?> stop() async => path;
  @override
  Future<void> cancel() async {}
  @override
  Stream<Amplitude> onAmplitudeChanged(Duration interval) =>
      const Stream.empty();
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ournet/speech');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  late Directory temp;
  var status = <String, Object?>{};

  setUp(() {
    calls.clear();
    status = {'available': true, 'allowed': true, 'onDevice': true};
    temp = Directory.systemTemp.createTempSync('ournet-live-');
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => temp.path,
    );
    String? recording;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'liveStart' when (call.arguments as Map)['path'] != null:
          // The platform records to the path it is given, adding a type.
          recording = '${(call.arguments as Map)['path']}.m4a';
          File(recording!).writeAsBytesSync(List.filled(64, 1));
        case 'liveStop':
          return {
            'text': 'Buy more coffee',
            'path': ?recording,
            'mime': 'audio/mp4',
            'duration': 2000,
          };
      }
      return switch (call.method) {
        'liveStatus' => status,
        'available' => false,
        _ => null,
      };
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    temp.deleteSync(recursive: true);
  });

  Future<(Node, Notes, Speech)> setUpSpeech() async {
    final node = Node(await LocalIdentity.create(), Store());
    final notes = Notes(node);
    final speech = Speech(notes, Files(node, PeerNetwork(node)));
    await speech.start();
    return (node, notes, speech);
  }

  test('live speech is the default only when private or agreed to', () async {
    final (node, _, speech) = await setUpSpeech();
    expect(speech.engineChosen, false);
    // Windows with online recognition on; Android with on-device speech.
    expect(speech.engine, 'system');
    expect(speech.live(), isNotNull);
    expect(systemSpeechNeedsConsent(speech), false);

    status = {'available': true, 'allowed': false, 'onDevice': false};
    await speech.checkLive();
    expect(speech.engine, 'whisper');
    expect(speech.live(), isNull);
    expect(systemSpeechNeedsConsent(speech), true);

    // A knowing choice keeps system speech, e.g. Android's speech service.
    speech.engine = 'system';
    expect(speech.live(), isNotNull);
    // Without a file-based system service, later transcriptions use Whisper.
    expect(speech.usesWhisper, !speech.systemAvailable);
    speech.close();
    await node.close();
  });

  test('a live transcript is saved instead of queueing a job', () async {
    final (node, notes, speech) = await setUpSpeech();
    final note = await notes.create();
    final file = await notes.attach(
      note.id,
      note.epoch,
      Stream.value(List.filled(64, 1)),
      name: 'Recording.m4a',
      meta: {'kind': 'audio', 'mime': 'audio/mp4', 'duration': 900},
    );
    await transcribeRecording(null, speech, note.id, file, live: 'Hello');
    expect((await notes.get(note.id))!.transcript(file), 'Hello');
    expect(speech.status, isEmpty);

    // Live text that failed never prompts for a Whisper download.
    node.store.set('speech/verified/${speech.model.id}', false);
    await transcribeRecording(null, speech, note.id, file);
    expect(speech.status, isEmpty);
    speech.close();
    await node.close();
  });

  testWidgets('stopping turns the recorder into the saved note', (
    tester,
  ) async {
    VoiceRecording? saved;
    final live = LiveSpeech(language: 'en');
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<VoiceRecording>(
                builder: (_) => VoiceRecorder(
                  recorder: _FakeRecorder.new,
                  live: live,
                  save: (recording) async {
                    saved = recording;
                    File(recording.path).deleteSync();
                    return MaterialPageRoute<void>(
                      builder: (_) => Text('Note: ${recording.transcript}'),
                    );
                  },
                ),
              ),
            ),
            child: const Text('Record'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Record'));
    await tester.runAsync(() => Future<void>.delayed(Durations.short4));
    await tester.pump();
    expect(calls.map((c) => c.method), contains('liveStart'));

    await tester.runAsync(
      () => messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(
          const MethodCall('livePartial', {'text': 'Buy more'}),
        ),
        (_) {},
      ),
    );
    await tester.pump();
    expect(find.text('Buy more'), findsOneWidget);

    await tester.runAsync(() => Future<void>.delayed(Durations.long2));
    await tester.tap(find.byIcon(Icons.stop_rounded));
    for (var i = 0; i < 20 && saved == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(Durations.short1));
      await tester.pump(Durations.short4);
    }
    await tester.pumpAndSettle();
    final stop = calls.singleWhere((c) => c.method == 'liveStop');
    expect((stop.arguments as Map)['settle'], greaterThan(0));
    expect(saved?.transcript, 'Buy more coffee');
    expect(find.text('Note: Buy more coffee'), findsOneWidget);
    expect(find.byType(VoiceRecorder), findsNothing);
  });
}
