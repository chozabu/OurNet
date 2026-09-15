/// On-device speech transcription with whisper.cpp.
///
/// Recordings are decoded by the platform (Android MediaCodec, Windows Media
/// Foundation) and transcribed in a background isolate. Nothing is sent over
/// the network; the model file is provided by the caller.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

class TranscriptionException implements Exception {
  final int code;
  final String message;
  const TranscriptionException(this.code, this.message);
  @override
  String toString() => message;
}

/// Lets a caller stop a running transcription.
class TranscriptionCancel {
  bool _cancelled = false;
  void Function()? _listener;
  bool get cancelled => _cancelled;
  void cancel() {
    _cancelled = true;
    _listener?.call();
  }
}

class Whisper {
  static bool get supported => Platform.isAndroid || Platform.isWindows;

  /// Recordings longer than this are refused rather than transcribed.
  static const maxSeconds = 30 * 60;

  static DynamicLibrary _open() => Platform.isWindows
      ? DynamicLibrary.open('ournet_speech.dll')
      : DynamicLibrary.open('libournet_speech.so');

  /// Transcribes [audioPath] with the model at [modelPath]. [language] is a
  /// code such as `en`, or `auto` to detect it. [onProgress] reports 0-100.
  static Future<String> transcribe({
    required String audioPath,
    required String modelPath,
    String language = 'auto',
    int? threads,
    void Function(int percent)? onProgress,
    TranscriptionCancel? cancel,
  }) async {
    if (!supported) {
      throw const TranscriptionException(
        -5,
        'Transcription is not available here.',
      );
    }
    final count = threads ?? Platform.numberOfProcessors.clamp(1, 4);
    final replies = ReceivePort();
    final isolate = await Isolate.spawn(_work, (
      replies.sendPort,
      audioPath,
      modelPath,
      language,
      count,
    ), debugName: 'ournet-transcribe');
    final result = Completer<String>();
    Timer? poll;
    SendPort? control;
    int? session;
    final bindings = _Bindings(_open());
    void stopPolling() {
      poll?.cancel();
      poll = null;
    }

    cancel?._listener = () {
      final handle = session;
      if (handle != null) bindings.cancel(Pointer.fromAddress(handle));
    };
    replies.listen((message) {
      if (message is List && message.first == 'session') {
        session = message[1] as int;
        control = message[2] as SendPort;
        if (cancel?.cancelled ?? false) {
          bindings.cancel(Pointer.fromAddress(session!));
        }
        poll = Timer.periodic(const Duration(milliseconds: 400), (_) {
          final handle = session;
          if (handle != null) {
            onProgress?.call(bindings.progress(Pointer.fromAddress(handle)));
          }
        });
      } else if (message is List && message.first == 'done') {
        // Stop reading the session before the worker frees it.
        stopPolling();
        session = null;
        control?.send('close');
        final code = message[1] as int;
        if (code == 0) {
          result.complete(message[2] as String);
        } else {
          result.completeError(TranscriptionException(code, _describe(code)));
        }
      } else if (message is List && message.first == 'failed') {
        stopPolling();
        session = null;
        final code = message[1] as int;
        result.completeError(TranscriptionException(code, _describe(code)));
      }
    });
    try {
      return await result.future;
    } finally {
      stopPolling();
      cancel?._listener = null;
      replies.close();
      // The worker exits once it has closed the session.
      Future<void>.delayed(const Duration(seconds: 5), () {
        isolate.kill(priority: Isolate.beforeNextEvent);
      });
    }
  }

  /// Decodes [audioPath] to raw 16 kHz mono 16-bit little-endian samples at
  /// [outPath], for speech services that take PCM. Returns the sample count.
  static Future<int> decodePcm16(String audioPath, String outPath) =>
      Isolate.run(() {
        final bindings = _Bindings(_open());
        final samples = calloc<Pointer<Float>>();
        final path = audioPath.toNativeUtf8();
        try {
          final count = bindings.decode(path, samples, maxSeconds);
          if (count < 0) throw TranscriptionException(count, _describe(count));
          final floats = samples.value.asTypedList(count);
          final pcm = Int16List(count);
          for (var i = 0; i < count; i++) {
            pcm[i] = (floats[i].clamp(-1.0, 1.0) * 32767).round();
          }
          bindings.free(samples.value.cast());
          File(outPath).writeAsBytesSync(pcm.buffer.asUint8List(), flush: true);
          return count;
        } finally {
          calloc.free(path);
          calloc.free(samples);
        }
      }, debugName: 'ournet-decode');

  static String _describe(int code) => switch (code) {
    -1 => 'The recording could not be opened.',
    -2 => 'This recording format cannot be decoded here.',
    -3 => 'Recordings over 30 minutes are not transcribed.',
    -4 => 'Not enough memory to transcribe this recording.',
    -6 =>
      'The speech model could not be loaded. Download it again in Settings.',
    -8 => 'Transcription was cancelled.',
    _ => 'Transcription failed.',
  };

  static Future<void> _work(
    (SendPort, String, String, String, int) args,
  ) async {
    final (reply, audio, model, language, threads) = args;
    final bindings = _Bindings(_open());
    final samples = calloc<Pointer<Float>>();
    final path = audio.toNativeUtf8();
    final count = bindings.decode(path, samples, maxSeconds);
    calloc.free(path);
    if (count < 0) {
      calloc.free(samples);
      reply.send(['failed', count]);
      return;
    }
    final modelPath = model.toNativeUtf8();
    final session = bindings.open(modelPath);
    calloc.free(modelPath);
    if (session == nullptr) {
      bindings.free(samples.value.cast());
      calloc.free(samples);
      reply.send(['failed', -6]);
      return;
    }
    final control = ReceivePort();
    reply.send(['session', session.address, control.sendPort]);
    final text = calloc<Pointer<Utf8>>();
    final lang = language.toNativeUtf8();
    final code = bindings.transcribe(
      session,
      samples.value,
      count,
      lang,
      threads,
      text,
    );
    calloc.free(lang);
    bindings.free(samples.value.cast());
    calloc.free(samples);
    final transcript = code == 0 ? text.value.toDartString() : '';
    if (text.value != nullptr) bindings.free(text.value.cast());
    calloc.free(text);
    reply.send(['done', code, transcript]);
    await control.first;
    control.close();
    bindings.close(session);
  }
}

class _Bindings {
  _Bindings(DynamicLibrary lib)
    : decode = lib
          .lookupFunction<
            Int64 Function(Pointer<Utf8>, Pointer<Pointer<Float>>, Int32),
            int Function(Pointer<Utf8>, Pointer<Pointer<Float>>, int)
          >('os_decode'),
      open = lib
          .lookupFunction<
            Pointer<Void> Function(Pointer<Utf8>),
            Pointer<Void> Function(Pointer<Utf8>)
          >('os_open'),
      progress = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('os_progress'),
      cancel = lib
          .lookupFunction<
            Void Function(Pointer<Void>),
            void Function(Pointer<Void>)
          >('os_cancel'),
      transcribe = lib
          .lookupFunction<
            Int32 Function(
              Pointer<Void>,
              Pointer<Float>,
              Int64,
              Pointer<Utf8>,
              Int32,
              Pointer<Pointer<Utf8>>,
            ),
            int Function(
              Pointer<Void>,
              Pointer<Float>,
              int,
              Pointer<Utf8>,
              int,
              Pointer<Pointer<Utf8>>,
            )
          >('os_transcribe'),
      close = lib
          .lookupFunction<
            Void Function(Pointer<Void>),
            void Function(Pointer<Void>)
          >('os_close'),
      free = lib
          .lookupFunction<
            Void Function(Pointer<Void>),
            void Function(Pointer<Void>)
          >('os_free');

  final int Function(Pointer<Utf8>, Pointer<Pointer<Float>>, int) decode;
  final Pointer<Void> Function(Pointer<Utf8>) open;
  final int Function(Pointer<Void>) progress;
  final void Function(Pointer<Void>) cancel;
  final int Function(
    Pointer<Void>,
    Pointer<Float>,
    int,
    Pointer<Utf8>,
    int,
    Pointer<Pointer<Utf8>>,
  )
  transcribe;
  final void Function(Pointer<Void>) close;
  final void Function(Pointer<Void>) free;
}
