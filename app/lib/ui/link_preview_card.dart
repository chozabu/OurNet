import 'package:flutter/material.dart';
import 'package:ournet_core/ournet_core.dart' show Json, LinkPreview;
import 'package:url_launcher/url_launcher.dart';

final _decoded = <String, (String, LinkPreview?)>{};

/// The link preview message [id] carries, decoded once per message and
/// text, so lists can ask on every build. Null when it has none or its link
/// was edited out of [text].
LinkPreview? messageLinkPreview(String id, Json payload, String text) {
  if (payload['link'] == null) return null;
  final hit = _decoded.remove(id);
  if (hit != null && hit.$1 == text) return (_decoded[id] = hit).$2;
  if (_decoded.length >= 256) _decoded.remove(_decoded.keys.first);
  final preview = LinkPreview.of(payload, text);
  _decoded[id] = (text, preview);
  return preview;
}

/// A link preview under a message: the site's real address first, then
/// what the sender's device found there. Tapping opens the link itself;
/// showing it makes no request.
class LinkPreviewCard extends StatelessWidget {
  final LinkPreview preview;

  /// In the composer: dismisses the preview before sending.
  final VoidCallback? onRemove;
  const LinkPreviewCard(this.preview, {super.key, this.onRemove});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final image = preview.image;
    final compact = onRemove != null;
    final details = Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: preview.url.toString(),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  preview.url.scheme == 'https'
                      ? Icons.lock_outline
                      : Icons.public,
                  size: 13,
                  color: scheme.primary,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    preview.host,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.labelMedium?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (preview.title case final title?)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: text.titleSmall,
              ),
            ),
          if (preview.description case final description?)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                description,
                maxLines: compact ? 1 : 3,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
    Widget? picture;
    if (image != null) {
      picture = Image.memory(
        image,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      );
    }
    final body = compact
        ? Row(
            children: [
              if (picture != null)
                SizedBox(width: 64, height: 64, child: picture),
              Expanded(child: details),
              IconButton(
                tooltip: 'Remove preview',
                onPressed: onRemove,
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (picture != null)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 180),
                  child: picture,
                ),
              details,
            ],
          );
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Material(
        color: scheme.onSurface.withValues(alpha: 0.05),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => launchUrl(
            preview.url,
            mode: LaunchMode.externalApplication,
          ).catchError((Object _) => false),
          child: body,
        ),
      ),
    );
  }
}
