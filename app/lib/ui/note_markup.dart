import 'package:flutter/material.dart';

/// Lightweight formatting for notes whose `format` register is `markup`:
/// `**bold**`, `*italic*`, `__underline__`, and lines starting `# ` or `## `
/// for headings. Markers are ordinary characters, so every collaborator's
/// build keeps, merges and replicates the writing; builds that do not format
/// simply show the markers.
class NoteMarkup {
  static final _heading = RegExp(r'^(#{1,2}) ');
  static final _inline = RegExp(
    r'(\*\*(?=\S)(.+?)(?<=\S)\*\*)|(__(?=\S)(.+?)(?<=\S)__)|((?<![*\w])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?![*\w]))',
  );

  /// Plain text without formatting markers, for copies, cards and widgets.
  static String plain(String text) => text
      .split('\n')
      .map((line) => line.replaceFirst(_heading, ''))
      .join('\n')
      .replaceAllMapped(
        _inline,
        (m) => m.group(2) ?? m.group(4) ?? m.group(6) ?? '',
      );

  /// Styled spans. With [markers] the formatting characters stay visible but
  /// faint (for editing); otherwise they are omitted (for reading).
  static TextSpan spans(
    String text,
    TextStyle base, {
    bool markers = false,
    Color? faint,
  }) {
    final children = <InlineSpan>[];
    final hidden = base.copyWith(
      color: faint ?? base.color?.withValues(alpha: .35),
      fontWeight: FontWeight.w400,
      fontStyle: FontStyle.normal,
      decoration: TextDecoration.none,
    );
    final lines = text.split('\n');
    for (var l = 0; l < lines.length; l++) {
      var line = lines[l];
      var style = base;
      final heading = _heading.firstMatch(line);
      if (heading != null) {
        final level = heading.group(1)!.length;
        style = base.copyWith(
          fontSize: (base.fontSize ?? 16) * (level == 1 ? 1.45 : 1.2),
          fontWeight: FontWeight.w600,
          height: 1.3,
        );
        if (markers) {
          children.add(TextSpan(text: heading.group(0), style: hidden));
        }
        line = line.substring(heading.group(0)!.length);
      }
      var cursor = 0;
      for (final m in _inline.allMatches(line)) {
        if (m.start > cursor) {
          children.add(
            TextSpan(text: line.substring(cursor, m.start), style: style),
          );
        }
        final (marker, inner, styled) = m.group(1) != null
            ? ('**', m.group(2)!, style.copyWith(fontWeight: FontWeight.w700))
            : m.group(3) != null
            ? (
                '__',
                m.group(4)!,
                style.copyWith(decoration: TextDecoration.underline),
              )
            : ('*', m.group(6)!, style.copyWith(fontStyle: FontStyle.italic));
        if (markers) children.add(TextSpan(text: marker, style: hidden));
        children.add(TextSpan(text: inner, style: styled));
        if (markers) children.add(TextSpan(text: marker, style: hidden));
        cursor = m.end;
      }
      if (cursor < line.length) {
        children.add(TextSpan(text: line.substring(cursor), style: style));
      }
      if (l < lines.length - 1) {
        children.add(TextSpan(text: '\n', style: style));
      }
    }
    return TextSpan(style: base, children: children);
  }

  /// Toggles [marker] around the selection, or around the word at the caret.
  static TextEditingValue wrap(TextEditingValue value, String marker) {
    final text = value.text;
    var start = value.selection.start, end = value.selection.end;
    if (start < 0) return value;
    if (start == end) {
      while (start > 0 && !_space(text[start - 1])) {
        start--;
      }
      while (end < text.length && !_space(text[end])) {
        end++;
      }
      if (start == end) return value;
    }
    final m = marker.length;
    final before = text.substring(0, start);
    final selected = text.substring(start, end);
    final after = text.substring(end);
    if (before.endsWith(marker) && after.startsWith(marker)) {
      return TextEditingValue(
        text:
            before.substring(0, before.length - m) +
            selected +
            after.substring(m),
        selection: TextSelection(baseOffset: start - m, extentOffset: end - m),
      );
    }
    if (selected.length > 2 * m &&
        selected.startsWith(marker) &&
        selected.endsWith(marker)) {
      return TextEditingValue(
        text: before + selected.substring(m, selected.length - m) + after,
        selection: TextSelection(baseOffset: start, extentOffset: end - 2 * m),
      );
    }
    final trimmed = selected.trimRight();
    final trailing = selected.substring(trimmed.length);
    return TextEditingValue(
      text: '$before$marker$trimmed$marker$trailing$after',
      selection: TextSelection(
        baseOffset: start + m,
        extentOffset: start + m + trimmed.length,
      ),
    );
  }

  /// Sets the heading level (0 for normal text) of each selected line.
  static TextEditingValue heading(TextEditingValue value, int level) {
    final text = value.text;
    final selection = value.selection;
    if (selection.start < 0) return value;
    final lineStart = _lineStart(text, selection.start);
    var lineEnd = text.indexOf('\n', selection.end);
    if (lineEnd < 0) lineEnd = text.length;
    final lines = text.substring(lineStart, lineEnd).split('\n');
    final prefix = level == 0 ? '' : '${'#' * level} ';
    var delta = 0, firstDelta = 0;
    final replaced = <String>[];
    for (final (i, line) in lines.indexed) {
      final existing = _heading.firstMatch(line)?.group(0) ?? '';
      final next = prefix + line.substring(existing.length);
      if (i == 0) firstDelta = next.length - line.length;
      delta += next.length - line.length;
      replaced.add(next);
    }
    return TextEditingValue(
      text:
          text.substring(0, lineStart) +
          replaced.join('\n') +
          text.substring(lineEnd),
      selection: TextSelection(
        baseOffset: (selection.baseOffset + firstDelta).clamp(
          lineStart,
          text.length + delta,
        ),
        extentOffset: (selection.extentOffset + delta).clamp(
          lineStart,
          text.length + delta,
        ),
      ),
    );
  }

  /// The heading level of the line holding the caret.
  static int headingAt(TextEditingValue value) {
    final offset = value.selection.start;
    if (offset < 0) return 0;
    final lineStart = _lineStart(value.text, offset);
    return _heading
            .firstMatch(value.text.substring(lineStart))
            ?.group(1)
            ?.length ??
        0;
  }

  static int _lineStart(String text, int offset) =>
      offset <= 0 ? 0 : text.lastIndexOf('\n', offset - 1) + 1;

  static bool _space(String c) => c == ' ' || c == '\n' || c == '\t';
}

/// A text field controller that renders [NoteMarkup] while editing.
class MarkupEditingController extends TextEditingController {
  bool enabled;
  MarkupEditingController({this.enabled = false});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    if (!enabled) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final base = style ?? DefaultTextStyle.of(context).style;
    return NoteMarkup.spans(
      text,
      base,
      markers: true,
      faint: Theme.of(
        context,
      ).colorScheme.onSurfaceVariant.withValues(alpha: .45),
    );
  }
}

/// Read-only formatted text for cards.
class MarkupText extends StatelessWidget {
  final String text;
  final bool markup;
  final int? maxLines;
  final TextStyle? style;
  const MarkupText(
    this.text, {
    super.key,
    required this.markup,
    this.maxLines,
    this.style,
  });
  @override
  Widget build(BuildContext context) {
    final base = style ?? DefaultTextStyle.of(context).style;
    if (!markup) {
      return Text(
        text,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: base,
      );
    }
    return Text.rich(
      NoteMarkup.spans(text, base),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
    );
  }
}
