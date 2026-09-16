import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Live transcription by the system speech service while a voice note
/// records. The platform records the audio itself: on Android the same
/// samples feed the saved file and the recognizer; on Windows dictation
/// listens to the microphone alongside, and native capture stops at once
/// where the recorder plugin takes about a second.
class LiveSpeech {
  final MethodChannel channel;
  final String language;

  /// Android recognizer: `device` keeps audio on the phone, `cloud` uses the
  /// speech service, `auto` picks on-device when available.
  final String engine;

  /// For tests: raw 16 kHz mono PCM that Android records in place of the
  /// microphone, in real time.
  final String? source;
  LiveSpeech({
    required this.language,
    this.engine = 'auto',
    this.source,
    this.channel = const MethodChannel('ournet/speech'),
  });

  /// Whether [start] records the audio file itself.
  static bool get recordsAudio => Platform.isAndroid || Platform.isWindows;

  /// Everything recognised so far, including the phrase being spoken.
  final text = ValueNotifier('');

  /// Why live text stopped, if it did. The recording carries on regardless.
  final error = ValueNotifier<String?>(null);

  /// Whether the recognizer is listening. Windows dictation takes about a
  /// second to connect after recording starts.
  final ready = ValueNotifier(false);

  /// Microphone level in dBFS, when [recordsAudio].
  void Function(double decibels)? onLevel;

  /// Starts listening. [path] is where [recordsAudio] platforms save the
  /// recording, without an extension: the platform picks AAC (`.m4a`) or,
  /// where its encoder is broken, WAV.
  Future<void> start({String? path}) async {
    channel.setMethodCallHandler(_handle);
    try {
      await channel.invokeMethod<void>('liveStart', {
        'language': language,
        'path': ?path,
        'source': ?source,
        'engine': engine,
      });
    } on PlatformException catch (e) {
      channel.setMethodCallHandler(null);
      throw LiveSpeechException(e.message ?? 'Live transcription failed.');
    }
  }

  /// Stops listening, waiting at most [settle] for the final words. [text] is
  /// null when recognition failed part-way, so the recording should be
  /// transcribed another way. [path] and [mime] describe the saved recording
  /// when [recordsAudio].
  Future<LiveResult> stop({
    Duration settle = const Duration(milliseconds: 1500),
  }) async {
    try {
      final result = await channel.invokeMapMethod<String, Object?>(
        'liveStop',
        {'settle': settle.inMilliseconds},
      );
      return (
        text: result?['text'] as String?,
        duration: (result?['duration'] as num?)?.toInt(),
        path: result?['path'] as String?,
        mime: result?['mime'] as String?,
      );
    } on PlatformException catch (e) {
      throw LiveSpeechException(e.message ?? 'Live transcription failed.');
    } finally {
      channel.setMethodCallHandler(null);
    }
  }

  Future<void> cancel() async {
    channel.setMethodCallHandler(null);
    try {
      await channel.invokeMethod<void>('liveCancel');
    } catch (_) {
      /* Nothing more to stop. */
    }
  }

  Future<Object?> _handle(MethodCall call) async {
    final args = (call.arguments as Map?) ?? const {};
    switch (call.method) {
      case 'livePartial':
        text.value = args['text'] as String? ?? '';
      case 'liveReady':
        ready.value = true;
      case 'liveError':
        error.value = args['message'] as String?;
      case 'liveLevel':
        onLevel?.call((args['level'] as num).toDouble());
    }
    return null;
  }

  void dispose() {
    text.dispose();
    error.dispose();
    ready.dispose();
  }
}

typedef LiveResult = ({
  String? text,
  int? duration,
  String? path,
  String? mime,
});

class LiveSpeechException implements Exception {
  final String message;
  const LiveSpeechException(this.message);
  @override
  String toString() => message;
}
