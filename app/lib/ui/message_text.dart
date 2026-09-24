import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Message text with tappable links and light formatting, as other
/// messengers write it: `*bold*`, `_italic_`, `~strike~` and `` `code` ``.
/// Markers are ordinary characters, so builds without this show them as
/// written. A message of only a few emoji is shown large.
class MessageText extends StatefulWidget {
  final String text;
  final TextStyle? style;
  const MessageText(this.text, {super.key, this.style});

  static final _link = RegExp(
    r'''\b(?:https?://|www\.)[^\s<>"']+[^\s<>"'.,;:!?)\]}]''',
    caseSensitive: false,
  );
  static final _format = RegExp(
    r'(?<![\w*])\*(?=\S)([^*\n]+?)(?<=\S)\*(?![\w*])'
    r'|(?<![\w_])_(?=\S)([^_\n]+?)(?<=\S)_(?![\w_])'
    r'|(?<![\w~])~(?=\S)([^~\n]+?)(?<=\S)~(?![\w~])'
    r'|`([^`\n]+)`',
  );
  static final _emoji = RegExp(
    r'^(?:[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE0F}'
    r'\u{200D}\u{1F3FB}-\u{1F3FF}\u{20E3}\u{E0020}-\u{E007F}\s])+$',
    unicode: true,
  );

  /// Whether [text] is one to three emoji and nothing else.
  static bool onlyEmoji(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty || !_emoji.hasMatch(trimmed)) return false;
    final glyphs = trimmed.runes
        .where(
          (r) =>
              r != 0xFE0F &&
              r != 0x200D &&
              !(r >= 0x1F3FB && r <= 0x1F3FF) &&
              r != 0x20 &&
              !(r >= 0xE0020 && r <= 0xE007F),
        )
        .length;
    return glyphs <= 3;
  }

  /// [text] without formatting markers, for previews and copies.
  static String plain(String text) => text.replaceAllMapped(
    _format,
    (m) => m.group(1) ?? m.group(2) ?? m.group(3) ?? m.group(4) ?? '',
  );

  static Uri? linkUri(String link) {
    final uri = Uri.tryParse(link.startsWith('www.') ? 'https://$link' : link);
    return uri != null && (uri.scheme == 'https' || uri.scheme == 'http')
        ? uri
        : null;
  }

  @override
  State<MessageText> createState() => _MessageTextState();
}

class _MessageTextState extends State<MessageText> {
  final _recognizers = <TapGestureRecognizer>[];

  void _clear() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  List<InlineSpan> _formatted(String text, TextStyle base, Color code) {
    final spans = <InlineSpan>[];
    var at = 0;
    for (final m in MessageText._format.allMatches(text)) {
      if (m.start > at) spans.add(TextSpan(text: text.substring(at, m.start)));
      final (inner, style) = m.group(1) != null
          ? (m.group(1)!, const TextStyle(fontWeight: FontWeight.w600))
          : m.group(2) != null
          ? (m.group(2)!, const TextStyle(fontStyle: FontStyle.italic))
          : m.group(3) != null
          ? (
              m.group(3)!,
              const TextStyle(decoration: TextDecoration.lineThrough),
            )
          : (
              m.group(4)!,
              TextStyle(fontFamily: 'monospace', backgroundColor: code),
            );
      spans.add(TextSpan(text: inner, style: style));
      at = m.end;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    _clear();
    final theme = Theme.of(context);
    final base = widget.style ?? DefaultTextStyle.of(context).style;
    if (MessageText.onlyEmoji(widget.text)) {
      return Text(
        widget.text.trim(),
        style: base.copyWith(fontSize: (base.fontSize ?? 16) * 2.4),
      );
    }
    final code = theme.colorScheme.onSurface.withValues(alpha: 0.08);
    final link = base.copyWith(
      color: theme.colorScheme.primary,
      decoration: TextDecoration.underline,
      decorationColor: theme.colorScheme.primary,
    );
    final children = <InlineSpan>[];
    var at = 0;
    final text = widget.text;
    for (final m in MessageText._link.allMatches(text)) {
      final uri = MessageText.linkUri(m.group(0)!);
      if (uri == null) continue;
      if (m.start > at) {
        children.addAll(_formatted(text.substring(at, m.start), base, code));
      }
      final recognizer = TapGestureRecognizer()
        ..onTap = () => launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        ).catchError((Object _) => false);
      _recognizers.add(recognizer);
      children.add(
        TextSpan(
          text: m.group(0),
          style: link,
          recognizer: recognizer,
          mouseCursor: SystemMouseCursors.click,
        ),
      );
      at = m.end;
    }
    if (at < text.length) {
      children.addAll(_formatted(text.substring(at), base, code));
    }
    return Text.rich(TextSpan(style: base, children: children));
  }
}
