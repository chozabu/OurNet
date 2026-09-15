import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ournet_core/ournet_core.dart' show randomId;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// A finished recording in a temporary file the caller must delete.
typedef VoiceRecording = ({
  String path,
  String name,
  int duration,
  String mime,
});

/// Recording longer than this stops automatically, keeping what was said.
const maxRecording = Duration(minutes: 30);

/// Opens a full-screen recorder that starts listening at once, like Keep.
/// Returns null when cancelled or when the microphone is unavailable.
Future<VoiceRecording?> recordVoice(
  BuildContext context, {
  AudioRecorder Function()? recorder,
}) => Navigator.of(context).push<VoiceRecording>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => VoiceRecorder(recorder: recorder),
  ),
);

class VoiceRecorder extends StatefulWidget {
  final AudioRecorder Function()? recorder;
  const VoiceRecorder({super.key, this.recorder});
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
  bool stopping = false;

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
      final file =
          '${folder.path}${Platform.pathSeparator}${randomId().replaceAll(RegExp('[^A-Za-z0-9]'), '')}.m4a';
      // Windows' AAC encoder accepts only 44.1/48 kHz; Android records
      // compact 16 kHz speech. Transcription resamples either way.
      await recorder.start(
        RecordConfig(
          encoder: AudioEncoder.aacLc,
          sampleRate: Platform.isWindows ? 44100 : 16000,
          bitRate: Platform.isWindows ? 96000 : 32000,
          numChannels: 1,
        ),
        path: file,
      );
      if (!mounted) {
        await recorder.cancel();
        return;
      }
      path = file;
      stopwatch.start();
      unawaited(HapticFeedback.mediumImpact());
      ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (stopwatch.elapsed >= maxRecording) unawaited(finish());
        if (mounted) setState(() {});
      });
      amplitude = recorder
          .onAmplitudeChanged(const Duration(milliseconds: 80))
          .listen((a) {
            // dBFS roughly -60 (quiet) to 0 (loud).
            final level = ((a.current + 60) / 60).clamp(0.04, 1.0);
            levels.add(level);
            if (levels.length > 64) levels.removeAt(0);
          });
      setState(() {});
    } catch (e) {
      if (mounted) setState(() => error = 'Recording is unavailable: $e');
    }
  }

  Future<void> finish() async {
    if (stopping || path == null) return;
    stopping = true;
    ticker?.cancel();
    stopwatch.stop();
    await amplitude?.cancel();
    final saved = await recorder.stop();
    final duration = stopwatch.elapsedMilliseconds;
    if (!mounted) return;
    if (saved == null || duration < 500) {
      if (saved != null) await _delete(saved);
      if (mounted) Navigator.pop(context);
      return;
    }
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    Navigator.pop<VoiceRecording>(context, (
      path: saved,
      name:
          'Recording ${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}.${two(now.minute)}.m4a',
      duration: duration,
      mime: 'audio/mp4',
    ));
  }

  Future<void> cancel() async {
    stopping = true;
    ticker?.cancel();
    await amplitude?.cancel();
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
    amplitude?.cancel();
    // Leaving without Done (e.g. system back) discards the recording.
    if (!stopping) {
      unawaited(
        recorder.cancel().catchError((Object _) {}).whenComplete(() async {
          if (path != null) await _delete(path!);
        }),
      );
    }
    unawaited(recorder.dispose().catchError((Object _) {}));
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
                onPressed: cancel,
                icon: const Icon(Icons.close),
              ),
              title: const Text('Voice note'),
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
                              recording ? 'Listening…' : 'Starting…',
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
                            Text(
                              'Audio and its transcript are saved in the note. Transcription runs on this device.',
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
                                child: const Icon(
                                  Icons.stop_rounded,
                                  size: 44,
                                  semanticLabel: 'Stop and save',
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            const Text('Tap to save'),
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
