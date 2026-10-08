import 'package:flutter/material.dart';

/// Pieces shared by direct-message and group-chat bubbles.

/// Local time of day for a message, as `HH:mm`.
String messageClock(int millisecondsSinceEpoch) {
  final time = DateTime.fromMillisecondsSinceEpoch(
    millisecondsSinceEpoch,
  ).toLocal();
  return '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}';
}

/// Full local date and time to the second, as `Tue 7 Oct 2026, 23:02:39`,
/// for message details.
String messageDateTime(int millisecondsSinceEpoch) {
  final t = DateTime.fromMillisecondsSinceEpoch(
    millisecondsSinceEpoch,
  ).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${days[t.weekday - 1]} ${t.day} ${months[t.month - 1]} ${t.year}, '
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

/// A bubble's colour, tinted while [highlighted], with the tail corner on the
/// first message of a run.
BoxDecoration bubbleDecoration(
  ColorScheme scheme, {
  required bool mine,
  required bool groupStart,
  required bool highlighted,
}) {
  const round = Radius.circular(16);
  const tail = Radius.circular(4);
  final base = mine ? scheme.primaryContainer : scheme.surface;
  return BoxDecoration(
    color: highlighted
        ? Color.alphaBlend(scheme.primary.withValues(alpha: .25), base)
        : base,
    borderRadius: BorderRadius.only(
      topLeft: !mine && groupStart ? tail : round,
      topRight: mine && groupStart ? tail : round,
      bottomLeft: round,
      bottomRight: round,
    ),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.08),
        blurRadius: 1,
        offset: const Offset(0, 1),
      ),
    ],
  );
}

/// The quoted original above a reply: author and a two-line preview.
class QuoteFrame extends StatelessWidget {
  final String author;
  final String preview;
  final VoidCallback? onTap;
  const QuoteFrame({
    super.key,
    required this.author,
    required this.preview,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Material(
      color: scheme.onSurface.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: scheme.primary, width: 3)),
          ),
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (author.isNotEmpty)
                Text(
                  author,
                  style: text.labelMedium?.copyWith(color: scheme.primary),
                ),
              Text(
                preview,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
