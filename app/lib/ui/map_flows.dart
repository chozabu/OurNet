part of 'app.dart';

extension _MapFlows on _OurNetAppState {
  Future<void> sharePlaceLink(PlaceLink place) async {
    final context = noteNavigator.currentContext;
    if (context == null) return;
    final rooms = (await Everyday(
      node,
    ).rooms()).where((r) => r.data['note'] != true).toList();
    if (!context.mounted) return;
    final target = await showDialog<({String? person, EverydayItem? room})>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Share this place with…'),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Text(
              'Sends the name, emoji and coordinates. Notes and lists stay private.',
            ),
          ),
          for (final room in rooms)
            SimpleDialogOption(
              onPressed: () =>
                  Navigator.pop(context, (person: null, room: room)),
              child: ListTile(
                leading: const Icon(Icons.group_outlined),
                title: Text('${room.data['name']}'),
              ),
            ),
          for (final person in people)
            SimpleDialogOption(
              onPressed: () =>
                  Navigator.pop(context, (person: person, room: null)),
              child: ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text(name(person)),
              ),
            ),
          if (rooms.isEmpty && people.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('Add a friend or create a group to share a place.'),
            ),
        ],
      ),
    );
    if (target == null) return;
    try {
      final link = Places.link(place);
      if (target.room != null) {
        await Everyday(node).write({
          'type': 'note',
          'text': link,
          'sent': node.now(),
        }, room: target.room);
      } else {
        await sendMessage(node, target.person!, link);
      }
      notice('Place shared');
    } catch (e) {
      notice('Could not share this place: $e');
    }
  }
}
