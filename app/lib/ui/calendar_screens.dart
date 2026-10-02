part of 'app.dart';

final _flowsFor = Expando<CalendarFlows>();

/// The calendar's place in the app: its own screen, a tab in each private
/// group, and the ways other screens reach an event (links, notifications,
/// the composers).
extension _CalendarScreens on _OurNetAppState {
  CalendarController get calendarController =>
      calendarControllerOrNull ??= _newCalendar(null);

  CalendarFlows get calendarFlows => _flows(calendarController);

  CalendarFlows _flows(CalendarController c) =>
      _flowsFor[c] ??= CalendarFlows(c, shareLink: shareEventLink);

  CalendarController _newCalendar(String? group) => CalendarController(
    node,
    Calendar(node, notes.state),
    group: group,
    speech: speech,
    files: files,
    personName: name,
    notify: calendarNotice,
  );

  void calendarNotice(
    String message, {
    String? action,
    VoidCallback? onAction,
  }) {
    final state = messenger.currentState;
    if (state == null) return;
    state
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: Duration(seconds: action == null ? 4 : 7),
          action: action == null || onAction == null
              ? null
              : SnackBarAction(label: action, onPressed: onAction),
        ),
      );
  }

  Widget calendarScreen(BuildContext context) => CalendarPage(
    controller: calendarController,
    flows: calendarFlows,
  );

  /// A private group's own calendar, shown in its Calendar tab.
  Widget groupCalendarView(BuildContext context, EverydayItem room) {
    final space = room.object.space;
    final c = groupCalendars[space] ??= _newCalendar(space);
    return CalendarPage(
      key: ValueKey('groupcalendar/$space'),
      controller: c,
      flows: _flows(c),
    );
  }

  /// Opens the event a link or a reminder names, on the Calendar screen.
  Future<void> openEventLink(String link) async {
    if (!mounted) return;
    final context = noteNavigator.currentContext;
    if (context == null) return;
    update(() {
      tab = Destination.calendar;
      activeRoom = null;
    });
    final opened = await calendarFlows.openLink(context, link);
    if (!opened) notice('That event is not available on this device yet.');
  }

  /// Chooses a chat to send an event's link to, and sends it there.
  Future<void> shareEventLink(Occurrence o) async {
    final context = noteNavigator.currentContext;
    if (context == null) return;
    final link = Calendar.link(
      o.calendar,
      o.entry,
      key: o.repeats ? o.key : null,
    );
    final rooms = (await Everyday(
      node,
    ).rooms()).where((r) => r.data['note'] != true).toList();
    if (!context.mounted) return;
    final group = o.calendar == Calendar.personal ? null : o.calendar;
    final target = await showDialog<({String? person, EverydayItem? room})>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Send the event link to…'),
        children: [
          if (group == null)
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                'This is a personal event. Only you can open its link; copy it into a group calendar to share the event itself.',
                style: TextStyle(fontSize: 12.5),
              ),
            ),
          for (final room in rooms)
            if (group == null || room.object.space == group)
              SimpleDialogOption(
                onPressed: () =>
                    Navigator.pop(context, (person: null, room: room)),
                child: Row(
                  children: [
                    const Icon(Icons.people_outline),
                    const SizedBox(width: 12),
                    Expanded(child: Text('${room.data['name']}')),
                  ],
                ),
              ),
          if (group == null)
            for (final person in people)
              SimpleDialogOption(
                onPressed: () =>
                    Navigator.pop(context, (person: person, room: null)),
                child: Row(
                  children: [
                    const Icon(Icons.person_outline),
                    const SizedBox(width: 12),
                    Expanded(child: Text(name(person))),
                  ],
                ),
              ),
        ],
      ),
    );
    if (target == null) return;
    try {
      if (target.room != null) {
        await Everyday(node).write({
          'type': 'note',
          'text': link,
          'sent': DateTime.now().millisecondsSinceEpoch,
        }, room: target.room);
      } else {
        await sendMessage(node, target.person!, link);
      }
      notice('Link sent');
    } catch (e) {
      notice('Could not send: $e');
    }
  }

  /// Puts a link to an event, chosen from the calendar, into a text field at
  /// the cursor. What the "mention an event" buttons do.
  Future<void> insertEventLink(
    BuildContext context,
    TextEditingController field,
  ) async {
    final link = await pickEventLink(context, calendarController);
    if (link == null) return;
    final text = field.text;
    final at = field.selection.isValid
        ? field.selection.start.clamp(0, text.length)
        : text.length;
    final before = text.substring(0, at);
    final needsSpace = before.isNotEmpty && !before.endsWith(' ') && !before.endsWith('\n');
    final insert = '${needsSpace ? ' ' : ''}$link ';
    field.value = TextEditingValue(
      text: before + insert + text.substring(at),
      selection: TextSelection.collapsed(offset: at + insert.length),
    );
  }
}
