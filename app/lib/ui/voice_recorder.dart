import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ournet_core/ournet_core.dart' show randomId;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../services/live_speech.dart';
import '../services/speech.dart';
import 'speech_settings.dart';

/// A finished recording in a temporary file the caller must delete.
/// [transcript] is text recognised live, or null if live recognition was not
/// used or failed, in which case the recording should be transcribed.
typedef VoiceRecording = ({
  String path,
  String name,
  int duration,
  String mime,
  String? transcript,
});

/// Stores a finished recording (the caller deletes the temporary file) and
/// returns the page to show in the recorder's place, such as the new note.
typedef SaveRecording = Future<Route<void>?> Function(VoiceRecording recording);

/// Recording longer than this stops automatically, keeping what was said.
const maxRecording = Duration(minutes: 30);

/// Opens a full-screen recorder that starts listening at once, like Keep.
/// With [speech], the system speech service may write the text live.
///
/// With [save], stopping stores the recording and the recorder turns
/// straight into the page [save] returns, and this returns null. Otherwise
/// it returns the recording. Null also means cancelled or no microphone.
/// [message] labels the recorder for a voice message rather than a note.
Future<VoiceRecording?> recordVoice(
  BuildContext context, {
  AudioRecorder Function()? recorder,
  Speech? speech,
  SaveRecording? save,
  bool message = false,
}) async {
  if (speech != null) await chooseSpeechEngine(context, speech);
  if (!context.mounted) return null;
  return Navigator.of(context).push<VoiceRecording>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => VoiceRecorder(
        recorder: recorder,
        live: speech?.live(),
        save: save,
        message: message,
      ),
    ),
  );
}

class VoiceRecorder extends StatefulWidget {
  final AudioRecorder Function()? recorder;

  /// Live transcription, owned and disposed of by the recorder.
  final LiveSpeech? live;
  final SaveRecording? save;
  final bool message;
  const VoiceRecorder({
    super.key,
    this.recorder,
    this.live,
    this.save,
    this.message = false,
  });
  @override
  State<VoiceRecorder> createState() => _VoiceRecorderState();
}

class _VoiceRecorderState extends State<VoiceRecorder> {
  late final AudioRecorder recorder = (widget.recorder ?? AudioRecorder.new)();
  final stopwatch = Stopwatch();
  final levels = <double>[];
  Timer? ticker;
  StreamSubscription<Amplitude>? amplitude;
  String? path, error;
  String mime = 'audio/mp4';
  bool stopping = false, saving = false;

  /// Whether live speech is recording (otherwise the recorder plugin is).
  /// [liveSettled] once the recognizer listens or failed: Windows dictation
  /// takes about a second to connect, so "Listening…" waits for it.
  bool native = false, liveSettled = false;
  Timer? settleLater;
  LiveSpeech? get live => widget.live;

  @override
  void initState() {
    super.initState();
    unawaited(start());
  }

  Future<void> start() async {
    try {
      if (!await recorder.hasPermission()) {
        setState(
          () => error =
              'OurNet needs microphone access to record. Allow it in system settings, then try again.',
        );
        return;
      }
      final folder = Directory(
        '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}ournet-recordings',
      )..createSync(recursive: true);
      final base =
          '${folder.path}${Platform.pathSeparator}${randomId().replaceAll(RegExp('[^A-Za-z0-9]'), '')}';
      if (live case final live? when LiveSpeech.recordsAudio) {
        live.onLevel = _level;
        void settled() {
          if (!mounted || liveSettled || stopping) return;
          setState(() => liveSettled = true);
          unawaited(HapticFeedback.selectionClick());
        }

        live.ready.addListener(settled);
        live.error.addListener(settled);
        // Never leave the label waiting on a recognizer that stays silent.
        settleLater = Timer(const Duration(seconds: 3), settled);
        try {
          await live.start(path: base);
          native = true;
        } on LiveSpeechException catch (e) {
          // Record with the plugin; the file is transcribed afterwards.
          live.error.value = e.message;
        }
      }
      if (native) {
        _started(base);
        return;
      }
      final file = await _startPlugin(base);
      if (!mounted) {
        await recorder.cancel();
        return;
      }
      amplitude = recorder
          .onAmplitudeChanged(const Duration(milliseconds: 80))
          .listen((a) => _level(a.current));
      _started(file);
    } catch (e) {
      if (mounted) setState(() => error = 'Recording is unavailable: $e');
    }
  }

  /// Records AAC, or 16 kHz WAV on phones whose AAC encoder fails.
  Future<String> _startPlugin(String base) async {
    try {
      // Windows' AAC encoder accepts only 44.1/48 kHz; Android records
      // compact 16 kHz speech. Transcription resamples either way.
      await recorder.start(
        RecordConfig(
          encoder: AudioEncoder.aacLc,
          sampleRate: Platform.isWindows ? 44100 : 16000,
          bitRate: Platform.isWindows ? 96000 : 32000,
          numChannels: 1,
        ),
        path: '$base.m4a',
      );
      return '$base.m4a';
    } catch (_) {
      if (Platform.isWindows) rethrow;
      await _delete('$base.m4a');
      await recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: '$base.wav',
      );
      mime = 'audio/wav';
      return '$base.wav';
    }
  }

  void _started(String file) {
    path = file;
    if (!mounted) {
      unawaited(cancel());
      return;
    }
    stopwatch.start();
    unawaited(HapticFeedback.mediumImpact());
    ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (stopwatch.elapsed >= maxRecording) unawaited(finish());
      if (mounted) setState(() {});
    });
    setState(() {});
  }

  void _level(double decibels) {
    // dBFS roughly -60 (quiet) to 0 (loud).
    levels.add(((decibels + 60) / 60).clamp(0.04, 1.0));
    if (levels.length > 64) levels.removeAt(0);
  }

  Future<void> finish() async {
    if (stopping || path == null) return;
    setState(() => stopping = true);
    ticker?.cancel();
    stopwatch.stop();
    unawaited(HapticFeedback.lightImpact());
    await amplitude?.cancel();
    String? saved, transcript;
    var duration = stopwatch.elapsedMilliseconds;
    if (native) {
      try {
        final result = await live!.stop();
        saved = result.path ?? path;
        mime = result.mime ?? mime;
        transcript = result.text;
        duration = result.duration ?? duration;
      } on LiveSpeechException catch (e) {
        if (mounted) setState(() => error = e.message);
        return;
      }
    } else {
      saved = await recorder.stop();
    }
    if (!mounted) {
      if (saved != null) await _delete(saved);
      return;
    }
    if (saved == null || duration < 500) {
      if (saved != null) await _delete(saved);
      if (mounted) Navigator.pop(context);
      return;
    }
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final recording = (
      path: saved,
      name:
          'Recording ${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}.${two(now.minute)}.${mime == 'audio/wav' ? 'wav' : 'm4a'}',
      duration: duration,
      mime: mime,
      transcript: transcript,
    );
    final save = widget.save;
    if (save == null) {
      Navigator.pop<VoiceRecording>(context, recording);
      return;
    }
    setState(() => saving = true);
    final navigator = Navigator.of(context);
    try {
      final next = await save(recording);
      if (!mounted) return;
      if (next == null) {
        navigator.pop();
      } else {
        unawaited(navigator.pushReplacement(next));
      }
    } catch (e) {
      if (mounted) setState(() => error = 'Could not save the recording: $e');
    }
  }

  Future<void> cancel() async {
    if (saving) return;
    stopping = true;
    ticker?.cancel();
    await amplitude?.cancel();
    await live?.cancel();
    try {
      await recorder.cancel();
    } catch (_) {}
    if (path != null) await _delete(path!);
    if (mounted) Navigator.pop(context);
  }

  static Future<void> _delete(String file) async {
    try {
      await File(file).delete();
    } catch (_) {}
  }

  @override
  void dispose() {
    ticker?.cancel();
    settleLater?.cancel();
    amplitude?.cancel();
    // Leaving without Done (e.g. system back) discards the recording.
    if (!stopping) {
      final live = this.live;
      unawaited(
        Future.wait([
          recorder.cancel().catchError((Object _) {}),
          ?live?.cancel(),
        ]).whenComplete(() async {
          if (path != null) await _delete(path!);
        }),
      );
    }
    unawaited(recorder.dispose().catchError((Object _) {}));
    live?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final elapsed = stopwatch.elapsed;
    final recording = path != null && error == null;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(cancel());
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              unawaited(cancel()),
          const SingleActivator(LogicalKeyboardKey.enter): () =>
              unawaited(finish()),
          const SingleActivator(LogicalKeyboardKey.space): () =>
              unawaited(finish()),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            appBar: AppBar(
              leading: IconButton(
                tooltip: 'Discard recording',
                onPressed: saving ? null : cancel,
                icon: const Icon(Icons.close),
              ),
              title: Text(widget.message ? 'Voice message' : 'Voice note'),
            ),
            body: SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: error != null
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.mic_off, size: 56, color: colors.error),
                            const SizedBox(height: 16),
                            Text(error!, textAlign: TextAlign.center),
                          ],
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              stopping
                                  ? 'Saving…'
                                  : recording && (live == null || liveSettled)
                                  ? 'Listening…'
                                  : 'Starting…',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 24),
                            SizedBox(
                              height: 96,
                              width: 320,
                              child: CustomPaint(
                                painter: _LevelPainter(levels, colors.primary),
                              ),
                            ),
                            const SizedBox(height: 24),
                            Text(
                              formatDuration(elapsed.inMilliseconds),
                              style: Theme.of(context).textTheme.displaySmall
                                  ?.copyWith(
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                            ),
                            const SizedBox(height: 8),
                            if (live case final live?)
                              _LiveText(live: live, message: widget.message)
                            else
                              Text(
                                widget.message
                                    ? 'The audio is sent with its transcript. Transcription runs on this device.'
                                    : 'Audio and its transcript are saved in the note. Transcription runs on this device.',
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            const SizedBox(height: 40),
                            SizedBox(
                              width: 88,
                              height: 88,
                              child: FilledButton(
                                style: FilledButton.styleFrom(
                                  shape: const CircleBorder(),
                                  padding: EdgeInsets.zero,
                                ),
                                onPressed: recording && !stopping
                                    ? finish
                                    : null,
                                child: stopping
                                    ? const SizedBox.square(
                                        dimension: 32,
                                        child: CircularProgressIndicator(),
                                      )
                                    : const Icon(
                                        Icons.stop_rounded,
                                        size: 44,
                                        semanticLabel: 'Stop and save',
                                      ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              widget.message ? 'Tap to send' : 'Tap to save',
                            ),
                          ],
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The words recognised so far, newest in view, or why live text stopped.
class _LiveText extends StatelessWidget {
  final LiveSpeech live;
  final bool message;
  const _LiveText({required this.live, this.message = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([live.text, live.error]),
      builder: (context, _) {
        final text = live.text.value;
        final error = live.error.value;
        return ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480, maxHeight: 132),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (text.isNotEmpty)
                Flexible(
                  child: SingleChildScrollView(
                    reverse: true,
                    child: Text(
                      text,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyLarge,
                    ),
                  ),
                )
              else if (error == null)
                Text(
                  message
                      ? 'Your words will appear here. The audio is sent too.'
                      : 'Your words will appear here. The audio is saved in the note too.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Live text unavailable: $error',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              if (needsSpeechPrivacySetting(error))
                const TextButton(
                  onPressed: openSpeechPrivacySettings,
                  child: Text('Open Windows settings'),
                ),
            ],
          ),
        );
      },
    );
  }
}

String formatDuration(int milliseconds) {
  final seconds = (milliseconds / 1000).floor();
  final minutes = seconds ~/ 60;
  return '$minutes:${(seconds % 60).toString().padLeft(2, '0')}';
}

class _LevelPainter extends CustomPainter {
  final List<double> levels;
  final Color color;
  _LevelPainter(this.levels, this.color);
  @override
  void paint(Canvas canvas, Size size) {
    const bars = 40;
    final width = size.width / bars;
    final paint = Paint()
      ..color = color
      ..strokeCap = StrokeCap.round
      ..strokeWidth = math.max(2, width * .55);
    for (var i = 0; i < bars; i++) {
      final index = levels.length - bars + i;
      final level = index >= 0 ? levels[index] : 0.04;
      final height = math.max(3.0, level * size.height);
      final x = i * width + width / 2;
      canvas.drawLine(
        Offset(x, size.height / 2 - height / 2),
        Offset(x, size.height / 2 + height / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_LevelPainter old) => true;
}
