part of 'app.dart';

/// A member's request that the owner add people: see [Everyday.addRequests].
typedef AddRequest = ({
  SignedObject object,
  List<String> people,
  List certificates,
});

extension _GroupMemberPages on _OurNetAppState {
  /// What the group page's slim header leaves out: who is in it, who can
  /// add people, and how its sync is going. Reads only the room record.
  Future<void> groupInfo(BuildContext context, EverydayItem room) {
    final members = (room.data['members'] as List).cast<String>();
    final owner = room.data['owner'] as String?;
    final space = room.object.space;
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, change) {
          final theme = Theme.of(sheet);
          final muted = chatMuted(node, space);
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(sheet).height * .85,
              ),
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  Row(
                    children: [
                      const Icon(Icons.people_outline, size: 32),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              room.data['name'],
                              style: theme.textTheme.titleLarge,
                            ),
                            Text(
                              [
                                'Private group',
                                '${members.length} members',
                                if (owner != null)
                                  owner == node.person
                                      ? 'You own it'
                                      : 'Owned by ${name(owner)}',
                              ].join(' · '),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  SyncStatus(
                    network: network,
                    people: members,
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Files keep their originals intact. '
                    '${room.data['invite'] == 'members' ? 'Any member can add their friends.' : 'Only the owner adds people; members can ask.'}',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: busy
                            ? null
                            : () {
                                Navigator.pop(sheet);
                                act(() => manageGroup(context, room));
                              },
                        icon: const Icon(Icons.manage_accounts_outlined),
                        label: const Text('Members'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => change(() => toggleGroupMute(space)),
                        icon: Icon(
                          muted
                              ? Icons.volume_off_outlined
                              : Icons.volume_up_outlined,
                        ),
                        label: Text(muted ? 'Unmute' : 'Mute'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Members (${members.length})',
                    style: theme.textTheme.titleSmall,
                  ),
                  for (final person in members)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: conversationAvatar(person),
                      title: Text(name(person)),
                      subtitle: Text(
                        [
                          if (person == owner) 'Owner',
                          if (person == node.person)
                            'You'
                          else if (!node.connections.isFriend(person))
                            'Not your friend',
                        ].join(' · '),
                      ),
                      onTap: () =>
                          unawaited(showPersonDetails(context, person)),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> manageGroup(BuildContext context, EverydayItem room) async {
    final everyday = Everyday(node);
    room = await everyday.current(room);
    await everyday.prepare(room);
    final members = await everyday.members(room);
    final selected = members.toSet();
    // Friends a member adds, or asks the owner to add.
    final asking = <String>{};
    final owner = room.data['owner'] == node.person;
    // Whether members add people themselves, and whether the owner is
    // turning that on now. It is not turned off again.
    final open = room.data['invite'] == 'members';
    var opening = false;
    final adds = !owner && everyday.canInvite(room);
    if (!context.mounted) return;
    List<String> addable() => people.where((p) => !members.contains(p)).toList()
      ..sort((a, b) => name(a).toLowerCase().compareTo(name(b).toLowerCase()));
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
                        ? 'Untick someone to remove them; tick friends below to add them.'
                        : adds
                        ? 'Tick friends below to add them. They see everything the group already holds.'
                        : 'Tick friends below to ask ${name(room.data['owner'])}, the owner, to add them.',
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Members (${members.length})',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  for (final person in members)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: conversationAvatar(person),
                      title: Text(name(person)),
                      subtitle: Text(
                        [
                          if (person == room.data['owner']) 'Owner',
                          if (person == node.person)
                            'You'
                          else if (!node.connections.isFriend(person))
                            'Not your friend',
                        ].join(' · '),
                      ),
                      // The person, not the checkbox: who they are and how
                      // you are connected.
                      onTap: () =>
                          unawaited(showPersonDetails(context, person)),
                      trailing: owner && person != node.person
                          ? Checkbox(
                              value: selected.contains(person),
                              onChanged: (value) => change(() {
                                value == true
                                    ? selected.add(person)
                                    : selected.remove(person);
                              }),
                            )
                          : null,
                    ),
                  const SizedBox(height: 8),
                  Text(
                    'Add people',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  if (addable().isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text('All your friends are already members.'),
                    ),
                  for (final person in addable())
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      secondary: conversationAvatar(person),
                      title: Text(name(person)),
                      value: owner
                          ? selected.contains(person)
                          : asking.contains(person),
                      onChanged: (value) => change(() {
                        final set = owner ? selected : asking;
                        value == true ? set.add(person) : set.remove(person);
                      }),
                    ),
                  TextButton.icon(
                    onPressed: () async {
                      await addFriend(context);
                      change(() {});
                    },
                    icon: const Icon(Icons.person_add_alt),
                    label: const Text('Add a new friend'),
                  ),
                  if (owner) ...[
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Members can add people'),
                      subtitle: Text(
                        open
                            ? 'Anyone in the group can add their friends. This stays on.'
                            : opening
                            ? 'Once saved, anyone in the group can add their friends. This cannot be turned off.'
                            : 'Only you add people. Members can ask you to.',
                      ),
                      value: open || opening,
                      onChanged: open
                          ? null
                          : (value) => change(() => opening = value),
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
              )
            else if (adds)
              FilledButton(
                onPressed: asking.isEmpty
                    ? null
                    : () => Navigator.pop(context, 'add'),
                child: Text(asking.isEmpty ? 'Add' : 'Add ${asking.length}'),
              )
            else
              FilledButton(
                onPressed: asking.isEmpty
                    ? null
                    : () => Navigator.pop(context, 'ask'),
                child: Text(
                  asking.isEmpty
                      ? 'Ask owner to add'
                      : 'Ask owner to add ${asking.length}',
                ),
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
        tab = Destination.groups;
      });
    }
    if (action == 'add') {
      await everyday.invite(room, asking.toList());
      if (network.running) unawaited(network.syncAll());
      notice('Added ${asking.map(name).join(', ')}');
    }
    if (action == 'ask') {
      await everyday.askToAdd(room, asking.toList());
      if (network.running) unawaited(network.syncAll());
      notice(
        'Asked ${name(room.data['owner'])} to add '
        '${asking.map(name).join(', ')}',
      );
    }
    if (action == 'save') {
      final unchanged =
          selected.length == members.length && selected.containsAll(members);
      if (unchanged && !opening) return;
      await saveMembership(room, selected.toList(), membersInvite: opening);
    }
  }

  /// Members' requests to add people to [room], for its owner; read once
  /// per data change.
  Future<List<AddRequest>> groupAddRequests(EverydayItem room) =>
      addRequestsView.putIfAbsent(
        room.object.space,
        () => Everyday(node).addRequests(room).catchError((Object _) {
          return <AddRequest>[];
        }),
      );

  /// For the owner: members asking to add people, to approve or decline.
  Widget groupAddRequestsBanner(BuildContext context, EverydayItem room) {
    if (room.data['owner'] != node.person) return const SizedBox.shrink();
    return FutureBuilder(
      future: groupAddRequests(room),
      builder: (context, snapshot) => Column(
        children: [
          for (final request in snapshot.data ?? const <AddRequest>[])
            Card(
              margin: const EdgeInsets.only(top: 12),
              child: ListTile(
                leading: const Icon(Icons.group_add_outlined),
                title: Text(
                  '${name(request.object.author)} asks you to add '
                  '${request.people.map(name).join(', ')}',
                ),
                subtitle: Wrap(
                  spacing: 8,
                  children: [
                    FilledButton(
                      onPressed: busy
                          ? null
                          : () => act(() => approveAddRequest(room, request)),
                      child: const Text('Add'),
                    ),
                    TextButton(
                      onPressed: () {
                        Everyday(node).closeAddRequest(request.object);
                        update(() => addRequestsView.clear());
                      },
                      child: const Text('Decline'),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> approveAddRequest(EverydayItem room, AddRequest request) async {
    final everyday = Everyday(node);
    room = await everyday.current(room);
    await everyday.admitRequested(request.certificates, request.people);
    final members = await everyday.members(room);
    await saveMembership(room, {...members, ...request.people}.toList());
    everyday.closeAddRequest(request.object);
    addRequestsView.clear();
  }

  /// Publishes [room]'s new membership, [selected], as its owner. People
  /// joining always get the group's existing history. With [membersInvite]
  /// members may add people from then on.
  Future<void> saveMembership(
    EverydayItem room,
    List<String> selected, {
    bool membersInvite = false,
  }) async {
    final everyday = Everyday(node);
    final members = await everyday.members(room);
    // Only adding to a group with a key: an invite hands them the key, and
    // nothing has to be re-shared.
    if (!membersInvite &&
        room.data['groupKey'] != null &&
        members.every(selected.contains)) {
      await everyday.invite(room, selected);
      if (network.running) unawaited(network.syncAll());
      notice('Membership updated. Changes sync when devices reconnect.');
      return;
    }
    {
      // Keep a verified encrypted source for any files copied into the new epoch.
      for (final item in await everyday.items(room)) {
        if (item.data['type'] == 'file' && item.data['deleted'] != true) {
          await files.cache(item.object);
        }
      }
      final next = await everyday.changeMembers(
        room,
        selected,
        shareHistory: true,
        membersInvite: membersInvite || room.data['invite'] == 'members',
      );
      update(() {
        activeRoom = next;
        tab = Destination.groups;
        everydaySection = 'Conversation';
      });
      notice('Membership updated. Changes sync when devices reconnect.');
    }
  }
}
