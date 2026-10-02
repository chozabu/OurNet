import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ournet_core/ournet_core.dart';

import '../controllers/calendar_controller.dart';
import 'calendar_dates.dart';

/// What event links in text need from the app: the calendar to look events up
/// in, and how to open one. Placed above the whole app, so any message or
/// post that mentions an event can show it and open it.
class EventLinks extends InheritedWidget {
  /// Null until the calendar has been set up; links then show as plain events.
  final CalendarController? Function() controller;
  final Future<bool> Function(BuildContext context, String link) open;
  const EventLinks({
    super.key,
    required this.controller,
    required this.open,
    required super.child,
  });

  static EventLinks? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<EventLinks>();

  @override
  bool updateShouldNotify(EventLinks oldWidget) => false;
}

/// An event link as a chip: its title and time, and a tap to open it.
class EventLinkChip extends StatefulWidget {
  final String link;
  final TextStyle? style;
  const EventLinkChip(this.link, {super.key, this.style});

  @override
  State<EventLinkChip> createState() => _EventLinkChipState();
}

class _EventLinkChipState extends State<EventLinkChip> {
  CalendarController? controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = EventLinks.maybeOf(context)?.controller();
    if (next != controller) {
      controller?.removeListener(_changed);
      controller = next?..addListener(_changed);
    }
  }

  @override
  void dispose() {
    controller?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final parsed = Calendar.parseLink(widget.link);
    Occurrence? found;
    if (parsed != null && controller != null) {
      found = controller!.calendar.occurrence(
        parsed.calendar,
        parsed.entry,
        key: parsed.key,
        after: DateTime.now().subtract(const Duration(days: 1)),
      );
    }
    final color = found == null ? scheme.outline : controller!.colorOf(found.event);
    final label = found == null
        ? 'Calendar event'
        : eventTitle(found.event);
    final when = found == null ? 'not on this device yet' : describeWhen(context, found);
    final base = widget.style ?? DefaultTextStyle.of(context).style;
    return Semantics(
      link: true,
      label: '$label, $when',
      child: Tooltip(
        message: found == null
            ? 'This event is not available here. It may be in a group you are not in, or still syncing.'
            : 'Open event',
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () async {
            final links = EventLinks.maybeOf(context);
            if (links == null) return;
            final opened = await links.open(context, widget.link);
            if (!opened && context.mounted) {
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                const SnackBar(
                  content: Text('That event is not available on this device yet.'),
                ),
              );
            }
          },
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 2),
            padding: const EdgeInsets.fromLTRB(8, 4, 10, 4),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(8),
              border: Border(left: BorderSide(color: color, width: 4)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.event, size: 15, color: scheme.primary),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: base.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
                Text(
                  when,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: base.copyWith(
                    fontSize: (base.fontSize ?? 14) * 0.85,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Chooses an event to mention: upcoming ones, or whatever a search finds.
/// Returns its link, or null.
Future<String?> pickEventLink(
  BuildContext context,
  CalendarController controller,
) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  useSafeArea: true,
  builder: (context) => _EventPicker(controller: controller),
);

class _EventPicker extends StatefulWidget {
  final CalendarController controller;
  const _EventPicker({required this.controller});

  @override
  State<_EventPicker> createState() => _EventPickerState();
}

class _EventPickerState extends State<_EventPicker> {
  final field = TextEditingController();
  List<Occurrence> shown = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final c = widget.controller;
    await c.calendar.refresh();
    _filter('');
  }

  void _filter(String query) {
    final c = widget.controller;
    final now = DateTime.now();
    final list = query.trim().isEmpty
        ? c.calendar
              .between(
                now.subtract(const Duration(days: 1)),
                now.add(const Duration(days: 60)),
                calendars: {for (final i in c.calendars) i.id},
              )
              .take(60)
              .toList()
        : c.calendar.search(query);
    if (mounted) setState(() => shown = list);
  }

  @override
  void dispose() {
    field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: field,
                autofocus: true,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Find an event to mention',
                ),
                onChanged: _filter,
              ),
            ),
            Expanded(
              child: shown.isEmpty
                  ? const Center(child: Text('No events'))
                  : ListView.builder(
                      itemCount: shown.length,
                      itemBuilder: (context, i) {
                        final o = shown[i];
                        return ListTile(
                          leading: CircleAvatar(
                            radius: 8,
                            backgroundColor: c.colorOf(o.event),
                          ),
                          title: Text(eventTitle(o.event)),
                          subtitle: Text(
                            [
                              describeWhen(context, o),
                              if (o.calendar != Calendar.personal) c.nameOf(o.calendar),
                            ].join(' · '),
                          ),
                          onTap: () => Navigator.pop(
                            context,
                            Calendar.link(
                              o.calendar,
                              o.entry,
                              key: o.repeats ? o.key : null,
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
