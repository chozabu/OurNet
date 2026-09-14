import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';

import '../services/thumbnails.dart';

bool isImagePayload(Json p) =>
    p['chunks'] is List &&
    RegExp(
      r'\.(png|jpe?g|webp|gif|bmp)$',
      caseSensitive: false,
    ).hasMatch('${p['name']}');

/// A list preview for an image attachment. It displays the stored encrypted
/// thumbnail through a stable image cache key, so recreating the row (e.g. when
/// scrolling back) reuses the decoded image instead of reading the original.
class InlineImage extends StatefulWidget {
  final Files files;
  final SignedObject object;
  final Json payload;
  final bool online;
  final bool thumbnail;
  const InlineImage({
    super.key,
    required this.files,
    required this.object,
    required this.payload,
    required this.online,
    this.thumbnail = false,
  });
  @override
  State<InlineImage> createState() => _InlineImageState();
}

class _InlineImageState extends State<InlineImage> {
  late final thumbnails = Thumbnails.of(widget.files);
  bool manual = false;
  int attempt = 0;

  bool get available => widget.online || widget.files.cached(widget.payload);
  int get size => widget.payload['size'] as int? ?? 0;

  @override
  void initState() {
    super.initState();
    thumbnails.want(widget.object.id);
  }

  @override
  void didUpdateWidget(InlineImage old) {
    super.didUpdateWidget(old);
    if (old.object.id != widget.object.id) {
      thumbnails.release(old.object.id);
      thumbnails.want(widget.object.id);
      manual = false;
    }
  }

  @override
  void dispose() {
    thumbnails.release(widget.object.id);
    super.dispose();
  }

  Widget spinner() => const Center(
    child: SizedBox(
      width: 22,
      height: 22,
      child: CircularProgressIndicator(strokeWidth: 2),
    ),
  );

  void openOriginal(ImageProvider preview) => showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: InteractiveViewer(
              child: FutureBuilder<Uint8List>(
                future: widget.files.readBytes(
                  widget.object,
                  limit: Files.maxSize,
                ),
                builder: (context, snapshot) => snapshot.hasData
                    ? Image.memory(
                        snapshot.data!,
                        cacheWidth: 1600,
                        gaplessPlayback: true,
                        errorBuilder: (_, _, _) =>
                            const Text('Image could not be displayed'),
                      )
                    : snapshot.hasError
                    ? const Text('Image could not be displayed')
                    : Image(image: preview, gaplessPlayback: true),
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final available = this.available;
    final provider = ThumbnailImage(
      thumbnails,
      widget.object,
      generate:
          available &&
          size <= Files.maxSize &&
          (manual || size <= Thumbnails.automaticLimit),
      limit: manual ? Files.maxSize : Thumbnails.automaticLimit,
      attempt: attempt,
    );
    // Decode stored previews at display resolution: smaller textures upload
    // faster and more rows fit in the bounded image cache.
    final ImageProvider image = ResizeImage(
      provider,
      width: widget.thumbnail ? 160 : null,
      height: widget.thumbnail
          ? null
          : (230 * MediaQuery.devicePixelRatioOf(context)).round(),
      allowUpscaling: false,
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: widget.thumbnail ? 64 : double.infinity,
        height: widget.thumbnail ? 64 : 230,
        child: ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Image(
            image: image,
            fit: widget.thumbnail ? BoxFit.cover : BoxFit.contain,
            semanticLabel: widget.payload['name'],
            gaplessPlayback: true,
            frameBuilder: (context, child, frame, synchronous) =>
                frame != null || synchronous
                ? InkWell(onTap: () => openOriginal(provider), child: child)
                : spinner(),
            errorBuilder: (context, error, _) {
              final unavailable = error is ThumbnailUnavailable;
              final needsTap =
                  unavailable &&
                  available &&
                  !manual &&
                  size > Thumbnails.automaticLimit;
              final label = !available
                  ? 'Image available when connected'
                  : needsTap
                  ? 'Load image preview'
                  : 'Preview unavailable · tap to retry';
              return InkWell(
                onTap: available
                    ? () => setState(() {
                        thumbnails.retry(widget.object.id);
                        manual = true;
                        attempt++;
                      })
                    : null,
                child: Center(
                  child: widget.thumbnail
                      ? Tooltip(
                          message: label,
                          child: const Icon(Icons.image_outlined),
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.image_outlined),
                            const SizedBox(height: 8),
                            Text(label),
                          ],
                        ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
