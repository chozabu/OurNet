import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart' show Files;

import '../services/speech.dart';
import 'inline_image.dart';
import 'voice_recorder.dart' show formatDuration;

/// Plays an encrypted audio attachment. The original is decrypted into
/// memory only while the clip is loaded for playback.
class AudioClip extends StatefulWidget {
  final Files files;
  final EverydayItem op;
  final Json meta;
  final Widget transcript;
  final TranscriptionStatus? status;
  final bool editable;
  final VoidCallback? onTranscribe;
  final VoidCallback? onCancelTranscription;
  final VoidCallback? onRemove;
  const AudioClip({
    super.key,
    required this.files,
    required this.op,
    required this.meta,
    required this.transcript,
    this.status,
    this.editable = true,
    this.onTranscribe,
    this.onCancelTranscription,
    this.onRemove,
  });
  @override
  State<AudioClip> createState() => _AudioClipState();
}

class _AudioClipState extends State<AudioClip> {
  AudioPlayer? player;
  final subscriptions = <StreamSubscription<Object?>>[];
  PlayerState state = PlayerState.stopped;
  Duration position = Duration.zero;
  Duration? total;
  bool loading = false;
  String? error;

  int get duration => widget.meta['duration'] as int? ?? 0;

  Future<void> toggle() async {
    if (loading) return;
    final current = player;
    if (current != null) {
      state == PlayerState.playing
          ? await current.pause()
          : await current.resume();
      return;
    }
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final Uint8List bytes = await widget.files.readBytes(
        widget.op.object,
        limit: Notes.maxFileSize,
      );
      final created = AudioPlayer();
      subscriptions.addAll([
        created.onPlayerStateChanged.listen((s) {
          if (mounted) setState(() => state = s);
        }),
        created.onPositionChanged.listen((p) {
          if (mounted) setState(() => position = p);
        }),
        created.onDurationChanged.listen((d) {
          if (mounted) setState(() => total = d);
        }),
        created.onPlayerComplete.listen((_) {
          if (mounted) setState(() => position = Duration.zero);
        }),
      ]);
      await created.play(
        BytesSource(bytes, mimeType: widget.meta['mime'] as String?),
      );
      if (!mounted) {
        await created.dispose();
        return;
      }
      player = created;
    } catch (e) {
      if (mounted) {
        setState(
          () => error = widget.files.cached(widget.op.data)
              ? 'This recording cannot be played here.'
              : 'Waiting for a device that has this recording.',
        );
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    for (final s in subscriptions) {
      s.cancel();
    }
    player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final length = total?.inMilliseconds ?? duration;
    final status = widget.status;
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .6),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: state == PlayerState.playing ? 'Pause' : 'Play',
                  onPressed: toggle,
                  icon: loading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          state == PlayerState.playing
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_fill,
                          size: 32,
                        ),
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      overlayShape: SliderComponentShape.noOverlay,
                    ),
                    child: Slider(
                      value: length <= 0
                          ? 0
                          : position.inMilliseconds.clamp(0, length).toDouble(),
                      max: length <= 0 ? 1 : length.toDouble(),
                      onChanged: player == null
                          ? null
                          : (v) =>
                                player!.seek(Duration(milliseconds: v.round())),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  player == null
                      ? formatDuration(duration)
                      : '${formatDuration(position.inMilliseconds)} / ${formatDuration(length)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Recording options',
                  onSelected: (value) => switch (value) {
                    'transcribe' => widget.onTranscribe?.call(),
                    'cancel' => widget.onCancelTranscription?.call(),
                    'remove' => widget.onRemove?.call(),
                    _ => null,
                  },
                  itemBuilder: (_) => [
                    if (widget.onTranscribe != null && widget.editable)
                      const PopupMenuItem(
                        value: 'transcribe',
                        child: Text('Transcribe again'),
                      ),
                    if (status != null && widget.onCancelTranscription != null)
                      const PopupMenuItem(
                        value: 'cancel',
                        child: Text('Stop transcribing'),
                      ),
                    if (widget.editable && widget.onRemove != null)
                      const PopupMenuItem(
                        value: 'remove',
                        child: Text('Remove recording'),
                      ),
                  ],
                ),
              ],
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 8, 4),
                child: Text(error!, style: theme.textTheme.bodySmall),
              ),
            if (status != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 8, 6),
                child: Row(
                  children: [
                    if (status.state != 'failed')
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          value:
                              status.state == 'running' && status.progress > 0
                              ? status.progress / 100
                              : null,
                        ),
                      )
                    else
                      Icon(
                        Icons.error_outline,
                        size: 16,
                        color: theme.colorScheme.error,
                      ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(switch (status.state) {
                        'queued' => 'Waiting to transcribe on this device…',
                        'running' =>
                          'Transcribing on this device… ${status.progress}%',
                        _ => status.error ?? 'Transcription failed',
                      }, style: theme.textTheme.bodySmall),
                    ),
                    if (status.state == 'failed' && widget.onTranscribe != null)
                      TextButton(
                        onPressed: widget.onTranscribe,
                        child: const Text('Retry'),
                      ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 4, 0),
              child: widget.transcript,
            ),
          ],
        ),
      ),
    );
  }
}

/// Keep-style photo grid at the top of a note: one wide image, or rows of two
/// or three. Previews come from durable encrypted thumbnails.
class NoteImages extends StatelessWidget {
  final Files files;
  final List<EverydayItem> images;
  final bool online;
  final void Function(int index) onOpen;
  final double height;
  const NoteImages({
    super.key,
    required this.files,
    required this.images,
    required this.online,
    required this.onOpen,
    this.height = 240,
  });

  @override
  Widget build(BuildContext context) {
    if (images.isEmpty) return const SizedBox.shrink();
    final rows = <List<int>>[];
    for (var i = 0; i < images.length;) {
      final take = images.length - i == 4 ? 2 : (images.length - i).clamp(1, 3);
      rows.add([for (var j = i; j < i + take; j++) j]);
      i += take;
    }
    return Column(
      children: [
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              children: [
                for (final index in row)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1),
                      child: InlineImage(
                        key: ValueKey(images[index].object.id),
                        files: files,
                        object: images[index].object,
                        payload: images[index].data,
                        online: online,
                        height: row.length == 1 ? height : height / 2,
                        fit: BoxFit.cover,
                        radius: 6,
                        onTap: () => onOpen(index),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// A full-screen, zoomable viewer for a note's images with a remove action.
Future<void> viewNoteImages(
  BuildContext context, {
  required Files files,
  required List<EverydayItem> images,
  required int initial,
  Future<void> Function(EverydayItem image)? onRemove,
  List<Widget> Function(EverydayItem image)? actions,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (_) => _ImageViewer(
      files: files,
      images: images,
      initial: initial,
      onRemove: onRemove,
      actions: actions,
    ),
  ),
);

class _ImageViewer extends StatefulWidget {
  final Files files;
  final List<EverydayItem> images;
  final int initial;
  final Future<void> Function(EverydayItem image)? onRemove;
  final List<Widget> Function(EverydayItem image)? actions;
  const _ImageViewer({
    required this.files,
    required this.images,
    required this.initial,
    this.onRemove,
    this.actions,
  });
  @override
  State<_ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<_ImageViewer> {
  late final controller = PageController(initialPage: widget.initial);
  late int page = widget.initial;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = widget.images[page];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('${page + 1} of ${widget.images.length}'),
        actions: [
          ...?widget.actions?.call(image),
          if (widget.onRemove != null)
            IconButton(
              tooltip: 'Remove image',
              onPressed: () async {
                await widget.onRemove!(image);
                if (context.mounted) Navigator.pop(context);
              },
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: PageView.builder(
        controller: controller,
        itemCount: widget.images.length,
        onPageChanged: (value) => setState(() => page = value),
        itemBuilder: (context, index) => FutureBuilder<Uint8List>(
          future: widget.files.readBytes(
            widget.images[index].object,
            limit: 32 * 1024 * 1024,
          ),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return const Center(
                child: Text(
                  'This image is not available on this device yet.',
                  style: TextStyle(color: Colors.white),
                ),
              );
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            return InteractiveViewer(
              maxScale: 6,
              child: Center(child: Image.memory(snapshot.data!)),
            );
          },
        ),
      ),
    );
  }
}
