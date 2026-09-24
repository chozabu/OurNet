import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ournet_core/ournet_core.dart';

/// A reversed message list with day grouping. Its owner retains pagination,
/// drafts and scroll position; the widget only renders the supplied window.
/// [footer] (messages still being sent, the typing indicator) sits below the
/// newest message.
class ConversationHistory extends StatelessWidget {
  final String peer;
  final List<SignedObject> objects;
  final ScrollController controller;
  final Widget Function(BuildContext, SignedObject, bool) bubble;
  final List<Widget> footer;

  /// The oldest message that was unread when the conversation was opened.
  final String? unreadMarker;
  final GlobalKey Function(String id)? keyFor;
  const ConversationHistory({
    super.key,
    required this.peer,
    required this.objects,
    required this.controller,
    required this.bubble,
    this.footer = const [],
    this.unreadMarker,
    this.keyFor,
  });

  @override
  Widget build(BuildContext context) => ListView.builder(
    controller: controller,
    reverse: true,
    key: PageStorageKey('conversation/$peer'),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    itemCount: footer.length + objects.length,
    itemBuilder: (context, index) {
      if (index < footer.length) return footer[footer.length - 1 - index];
      index -= footer.length;
      final object = objects[index];
      final older = index + 1 < objects.length ? objects[index + 1] : null;
      final day = messageDay(object);
      final newDay = older == null || messageDay(older) != day;
      final marker = object.id == unreadMarker;
      return Column(
        key: keyFor?.call(object.id),
        children: [
          if (newDay) daySeparator(context, day),
          if (marker) unreadDivider(context),
          bubble(
            context,
            object,
            newDay || marker || older.author != object.author,
          ),
        ],
      );
    },
  );

  Widget unreadDivider(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(child: Divider(color: scheme.primary.withValues(alpha: .4))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              'Unread messages',
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: scheme.primary),
            ),
          ),
          Expanded(child: Divider(color: scheme.primary.withValues(alpha: .4))),
        ],
      ),
    );
  }

  DateTime messageDay(SignedObject o) {
    final t = DateTime.fromMillisecondsSinceEpoch(o.created).toLocal();
    return DateTime(t.year, t.month, t.day);
  }

  Widget daySeparator(BuildContext context, DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final gap = today.difference(day).inDays;
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    const weekdays = [
      'Monday', 'Tuesday', 'Wednesday', 'Thursday', //
      'Friday', 'Saturday', 'Sunday',
    ];
    final label = gap == 0
        ? 'Today'
        : gap == 1
        ? 'Yesterday'
        : gap < 7 && gap > 0
        ? weekdays[day.weekday - 1]
        : '${day.day} ${months[day.month - 1]}'
              '${day.year == now.year ? '' : ' ${day.year}'}';
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Text(label, style: Theme.of(context).textTheme.labelMedium),
          ),
        ),
      ),
    );
  }
}

/// A round button that returns to the newest message, shown when the reader
/// has scrolled away from it or newer messages are waiting. Listens to the
/// scroll position itself, so scrolling rebuilds only this button.
class JumpToLatest extends StatefulWidget {
  final ScrollController controller;
  final bool pending;
  final int unread;
  final VoidCallback onPressed;
  const JumpToLatest({
    super.key,
    required this.controller,
    required this.pending,
    required this.unread,
    required this.onPressed,
  });

  @override
  State<JumpToLatest> createState() => _JumpToLatestState();
}

class _JumpToLatestState extends State<JumpToLatest> {
  bool away = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_scrolled);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrolled());
  }

  @override
  void didUpdateWidget(JumpToLatest old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_scrolled);
      widget.controller.addListener(_scrolled);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_scrolled);
    super.dispose();
  }

  void _scrolled() {
    final c = widget.controller;
    final now = c.hasClients && c.positions.length == 1 && c.offset > 240;
    if (now != away && mounted) setState(() => away = now);
  }

  @override
  Widget build(BuildContext context) {
    final visible = away || widget.pending;
    final scheme = Theme.of(context).colorScheme;
    return AnimatedScale(
      scale: visible ? 1 : 0,
      duration: const Duration(milliseconds: 150),
      child: Badge(
        isLabelVisible: widget.unread > 0,
        label: Text('${widget.unread > 99 ? '99+' : widget.unread}'),
        child: FloatingActionButton.small(
          heroTag: null,
          tooltip: 'Show latest messages',
          backgroundColor: scheme.surfaceContainerHigh,
          foregroundColor: scheme.onSurfaceVariant,
          elevation: 2,
          onPressed: visible ? widget.onPressed : null,
          child: const Icon(Icons.keyboard_double_arrow_down),
        ),
      ),
    );
  }
}

/// Drag a message sideways to reply to it, as on phones. The bubble follows
/// the finger a little way; letting go past the threshold replies.
class SwipeToReply extends StatefulWidget {
  final Widget child;
  final VoidCallback onReply;
  final bool enabled;
  const SwipeToReply({
    super.key,
    required this.child,
    required this.onReply,
    this.enabled = true,
  });

  @override
  State<SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<SwipeToReply> {
  static const _threshold = 56.0;
  double dx = 0;
  bool armed = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return GestureDetector(
      onHorizontalDragUpdate: (d) {
        final next = (dx + d.delta.dx).clamp(0.0, _threshold * 1.4);
        final nowArmed = next >= _threshold;
        if (nowArmed && !armed) HapticFeedback.selectionClick();
        setState(() {
          dx = next;
          armed = nowArmed;
        });
      },
      onHorizontalDragEnd: (_) {
        if (armed) widget.onReply();
        setState(() {
          dx = 0;
          armed = false;
        });
      },
      onHorizontalDragCancel: () => setState(() {
        dx = 0;
        armed = false;
      }),
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          Opacity(
            opacity: (dx / _threshold).clamp(0.0, 1.0),
            child: const Padding(
              padding: EdgeInsets.only(left: 4),
              child: Icon(Icons.reply, size: 20),
            ),
          ),
          AnimatedContainer(
            duration: dx == 0
                ? const Duration(milliseconds: 150)
                : Duration.zero,
            transform: Matrix4.translationValues(dx, 0, 0),
            child: widget.child,
          ),
        ],
      ),
    );
  }
}
