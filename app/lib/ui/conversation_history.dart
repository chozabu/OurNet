import 'package:flutter/material.dart';
import 'package:ournet_core/ournet_core.dart';

/// A reversed message list with day grouping. Its owner retains pagination,
/// drafts and scroll position; the widget only renders the supplied window.
class ConversationHistory extends StatelessWidget {
  final String peer;
  final List<SignedObject> objects;
  final ScrollController controller;
  final Widget Function(BuildContext, SignedObject, bool) bubble;
  const ConversationHistory({
    super.key,
    required this.peer,
    required this.objects,
    required this.controller,
    required this.bubble,
  });

  @override
  Widget build(BuildContext context) => ListView.builder(
    controller: controller,
    reverse: true,
    key: PageStorageKey('conversation/$peer'),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    itemCount: objects.length,
    itemBuilder: (context, index) {
      final object = objects[index];
      final older = index + 1 < objects.length ? objects[index + 1] : null;
      final day = messageDay(object);
      final newDay = older == null || messageDay(older) != day;
      return Column(
        children: [
          if (newDay) daySeparator(context, day),
          bubble(context, object, newDay || older.author != object.author),
        ],
      );
    },
  );
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
