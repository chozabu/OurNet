part of 'app.dart';

extension _GroupMemberPages on _OurNetAppState {
  Future<void> manageGroup(BuildContext context, EverydayItem room) async {
    final everyday = Everyday(node);
    room = await everyday.current(room);
    await everyday.prepare(room);
    final members = await everyday.members(room);
    final selected = members.toSet();
    var shareHistory = false;
    final owner = room.data['owner'] == node.person;
    if (!context.mounted) return;
    final action = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, change) => AlertDialog(
          title: Text('${room.data['name']} · Members'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    owner
                        ? 'Choose who belongs to this group.'
                        : 'The owner manages invitations and membership.',
                  ),
                  const SizedBox(height: 12),
                  for (final person in {...members, if (owner) ...people})
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(name(person)),
                      subtitle: person == room.data['owner']
                          ? const Text('Owner')
                          : null,
                      value: selected.contains(person),
                      onChanged: !owner || person == node.person
                          ? null
                          : (value) => change(() {
                              value == true
                                  ? selected.add(person)
                                  : selected.remove(person);
                            }),
                    ),
                  if (owner) ...[
                    TextButton.icon(
                      onPressed: () async {
                        await addFriend(context);
                        change(() {});
                      },
                      icon: const Icon(Icons.person_add_alt),
                      label: const Text('Add friend to invite'),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        'Share existing history with new members',
                      ),
                      subtitle: const Text(
                        'Off: new members see future activity only. Existing members keep their history.',
                      ),
                      value: shareHistory,
                      onChanged: (value) => change(() => shareHistory = value),
                    ),
                    const Text(
                      'Membership changes apply as devices reconnect. Removed members keep copies they already received.',
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, 'leave'),
              child: Text(owner ? 'Close group' : 'Leave group'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            if (owner)
              FilledButton(
                onPressed: () => Navigator.pop(context, 'save'),
                child: const Text('Save membership'),
              ),
          ],
        ),
      ),
    );
    if (action == 'leave' && context.mounted) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(owner ? 'Close this group?' : 'Leave this group?'),
          content: Text(
            owner
                ? 'This closes the group for everyone as their devices reconnect. Existing downloaded copies are retained.'
                : 'You will stop receiving new group activity after other devices receive your departure. Downloaded copies are retained.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(owner ? 'Close group' : 'Leave group'),
            ),
          ],
        ),
      );
      if (confirm != true) return;
      await everyday.leave(room);
      update(() {
        activeRoom = null;
        tab = 10;
      });
    }
    if (action == 'save') {
      if (selected.length == members.length && selected.containsAll(members)) {
        return;
      }
      // Keep a verified encrypted source for any files copied into the new epoch.
      for (final item in await everyday.items(room)) {
        if (item.data['type'] == 'file' && item.data['deleted'] != true) {
          await files.cache(item.object);
        }
      }
      final next = await everyday.changeMembers(
        room,
        selected.toList(),
        shareHistory: shareHistory,
      );
      update(() {
        activeRoom = next;
        tab = 10;
        everydaySection = 'Conversation';
      });
      notice('Membership updated. Changes sync when devices reconnect.');
    }
  }
}
