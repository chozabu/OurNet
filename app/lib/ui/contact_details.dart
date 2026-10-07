part of 'app.dart';

/// One of this person's devices quiet for this long is probably gone.
const _quietDevice = Duration(days: 30);

/// A friend none of whose devices was heard from for this long cannot be
/// reached: what is sent to them waits.
const _quietPerson = Duration(days: 14);

/// What is known about a person or one of their devices, from anywhere that
/// shows them: who it is, when it was added, how it is connected, and what
/// can be done about it.
extension _ContactDetails on _OurNetAppState {
  /// What a device is called: the name its owner gave it, else the one it
  /// was linked with.
  String deviceLabel(DeviceCertificate c) =>
      memo('deviceNames', node.deviceNames)[c.device] ?? c.label;

  Map<String, ({int added, bool estimated})> get contactsAdded =>
      memo('contactsAdded', node.store.contactsAdded);

  String _dateTime(int millis) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final t = DateTime.fromMillisecondsSinceEpoch(millis).toLocal();
    return '${t.day} ${months[t.month - 1]} ${t.year}, '
        '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
  }

  /// When [device] was added here, or null when that is not known. Devices
  /// from before this was recorded are dated by their earliest activity.
  String? addedText(String device) {
    final certificate = device == node.identity.device
        ? node.identity.certificate
        : node.contacts[device];
    // Certificates from newer builds say when, and by which device.
    if (certificate?.data['approved'] case final int at) {
      final by = certificate!.data['approvedBy'];
      final approver = by == node.identity.device
          ? node.identity.certificate
          : node.contacts[by];
      return 'Added ${_dateTime(at)}'
          '${approver == null ? '' : ' by ${deviceLabel(approver)}'}';
    }
    return switch (contactsAdded[device]) {
      null => null,
      (added: final at, estimated: true) => 'Active since ${_dateTime(at)}',
      (added: final at, estimated: false) => 'Added ${_dateTime(at)}',
    };
  }

  /// When [device] was last heard from: what it last wrote, or the last
  /// sync or connection with it.
  int? lastSeenAt(String device) {
    var seen = memo('lastSeen/$device', () => node.lastSeen(device));
    for (final t in [network.lastSync[device], network.lastInbound[device]]) {
      final at = t?.millisecondsSinceEpoch;
      if (at != null && (seen == null || at > seen)) seen = at;
    }
    return seen;
  }

  /// "Not seen since ..." for a device that has gone quiet, else null.
  String? quietText(String device) {
    if (device == node.identity.device || node.revoked.contains(device)) {
      return null;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final seen = lastSeenAt(device);
    if (seen == null) {
      final added = contactsAdded[device]?.added;
      return added == null || now - added < _quietDevice.inMilliseconds
          ? null
          : 'Never seen';
    }
    return now - seen < _quietDevice.inMilliseconds
        ? null
        : 'Not seen since ${_dateTime(seen)}';
  }

  /// Why [person] cannot be reached, when none of their devices was heard
  /// from lately; null while they can be.
  String? reachText(String person) {
    final devices = activeDevices(person);
    if (devices.isEmpty) return 'No devices';
    final now = DateTime.now().millisecondsSinceEpoch;
    int? seen, added;
    for (final c in devices) {
      final at = lastSeenAt(c.device);
      if (at != null && (seen == null || at > seen)) seen = at;
      final since = contactsAdded[c.device]?.added;
      if (since != null && (added == null || since < added)) added = since;
    }
    if (seen == null) {
      return added == null || now - added < _quietPerson.inMilliseconds
          ? null
          : 'Never heard from';
    }
    return now - seen < _quietPerson.inMilliseconds
        ? null
        : 'No active devices since ${_dateTime(seen)}';
  }

  /// Blocks or unblocks [person] on all of this person's devices.
  Future<void> setBlocked(String person, bool block) async {
    try {
      await node.setContactState(
        person,
        block ? ContactState.blocked : ContactState.unblocked,
      );
    } catch (e) {
      notice('Could not ${block ? 'block' : 'unblock'}: $e');
      return;
    }
    // What was refused while blocked arrives on the next sync.
    if (!block && network.running) unawaited(network.syncAll());
    refresh();
  }

  /// Asks, then disconnects from [person] on all of this person's devices.
  Future<void> disconnect(BuildContext context, String person) async {
    final who = name(person);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Disconnect from $who?'),
        content: Text(
          'Your devices forget the devices of $who and stop syncing with '
          'them. Chats you already have stay. To connect again, either of '
          'you sends a new invitation. To stay connected but see nothing '
          'from them, block instead.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await node.setContactState(person, ContactState.forgotten);
    } catch (e) {
      notice('Could not disconnect: $e');
      return;
    }
    notice('Disconnected from $who');
    refresh();
  }

  /// When [device] lost access, as "Removed …"; plain when not known.
  String removedText(String device) =>
      switch (memo('revokedAt', node.revokedAt)[device]) {
        final at? => 'Removed ${_dateTime(at)}',
        null => 'Access removed',
      };

  /// When [person]'s first device was added here.
  String? personAddedText(String person) {
    ({int added, bool estimated})? first;
    for (final c in node.contacts.values) {
      if (c.person != person) continue;
      final at = contactsAdded[c.device];
      if (at != null && (first == null || at.added < first.added)) first = at;
    }
    if (first == null) return null;
    return first.estimated
        ? 'Known since ${_dateTime(first.added)}'
        : 'Friend since ${_dateTime(first.added)}';
  }

  Future<void> showPersonDetails(BuildContext context, String person) async {
    final me = person == node.person;
    final connections = node.connections;
    final friend = connections.isFriend(person);
    // Read before the sheet opens: both decrypt.
    final asked = me || friend
        ? null
        : (await connections.incoming())
              .where((r) => r.from == person)
              .firstOrNull;
    final sent = me || friend || asked != null
        ? null
        : await connections.sentTo(person);
    if (!context.mounted) return;
    final chain = me ? null : connections.chain(person);
    final theirFriends = me
        ? const <String>[]
        : (connections
              .neighbours(person)
              .where((p) => p != node.person)
              .toList()
            ..sort((a, b) {
              // Friends in common first, then by name.
              final common = (connections.isFriend(b) ? 1 : 0).compareTo(
                connections.isFriend(a) ? 1 : 0,
              );
              return common != 0
                  ? common
                  : name(a).toLowerCase().compareTo(name(b).toLowerCase());
            }));
    final devices = [
      if (me) node.identity.certificate,
      for (final c in node.contacts.values)
        if (c.person == person) c,
    ];
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheet) {
        final theme = Theme.of(sheet);
        final since = me ? null : personAddedText(person);
        final blocked = node.blocked.contains(person);
        final reach = me ? null : reachText(person);
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
                    if (node.avatars.of(person) case final avatar?)
                      // The picture, larger.
                      GestureDetector(
                        onTap: () => unawaited(
                          showImageViewer(
                            context,
                            bytes: Future.value(avatar.bytes),
                            title: name(person),
                          ),
                        ),
                        child: conversationAvatar(person, radius: 28),
                      )
                    else
                      conversationAvatar(person, radius: 28),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(name(person), style: theme.textTheme.titleLarge),
                          Text(
                            me
                                ? 'You'
                                : [
                                    if (node.forgotten.contains(person))
                                      'Disconnected'
                                    else if (!friend)
                                      'Not connected'
                                    else
                                      since ?? 'Friend',
                                    if (blocked) 'Blocked',
                                  ].join(' · '),
                            style: theme.textTheme.bodyMedium,
                          ),
                          if (reach != null)
                            Text(
                              reach,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.error,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (!me)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (asked != null)
                        FilledButton.icon(
                          onPressed: () {
                            Navigator.pop(sheet);
                            act(() => acceptConnection(asked));
                          },
                          icon: const Icon(Icons.how_to_reg_outlined),
                          label: const Text('Accept request'),
                        )
                      else if (!friend && sent == null)
                        FilledButton.icon(
                          onPressed: (chain?.length ?? 0) < 3
                              ? null
                              : () {
                                  Navigator.pop(sheet);
                                  unawaited(askToConnect(context, person));
                                },
                          icon: const Icon(Icons.person_add_alt),
                          label: const Text('Invite to connect'),
                        )
                      else if (sent != null)
                        OutlinedButton.icon(
                          onPressed: () {
                            Navigator.pop(sheet);
                            unawaited(askToConnect(context, person));
                          },
                          icon: const Icon(Icons.schedule_send_outlined),
                          label: Text(
                            'Invited ${_dateTime(sent.created)} · send again',
                          ),
                        ),
                      if (people.contains(person))
                        FilledButton.icon(
                          onPressed: () {
                            Navigator.pop(sheet);
                            openConversation(person);
                          },
                          icon: const Icon(Icons.chat_bubble_outline),
                          label: const Text('Message'),
                        ),
                      OutlinedButton.icon(
                        onPressed: () {
                          Navigator.pop(sheet);
                          unawaited(setBlocked(person, !blocked));
                        },
                        icon: Icon(blocked ? Icons.undo : Icons.block),
                        label: Text(blocked ? 'Unblock' : 'Block'),
                      ),
                      if (friend)
                        OutlinedButton.icon(
                          onPressed: () {
                            Navigator.pop(sheet);
                            unawaited(disconnect(context, person));
                          },
                          icon: const Icon(Icons.person_remove_outlined),
                          label: const Text('Disconnect'),
                        ),
                    ],
                  ),
                if (asked?.text case final text?)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.mail_outline),
                    title: Text(text),
                    subtitle: Text(
                      'Their request, ${_dateTime(asked!.object.created)}',
                    ),
                  ),
                if (!me) ...[
                  const SizedBox(height: 8),
                  Text(
                    'How you are connected',
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  connectionChain(sheet, chain, person),
                ],
                if (theirFriends.isNotEmpty)
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: EdgeInsets.zero,
                    title: Text('Their friends (${theirFriends.length})'),
                    subtitle: Text(switch (theirFriends
                        .where(connections.isFriend)
                        .length) {
                      0 => 'No friends in common',
                      1 => '1 friend in common',
                      final n => '$n friends in common',
                    }),
                    children: [
                      for (final p in theirFriends.take(200))
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: conversationAvatar(p),
                          title: Text(name(p)),
                          subtitle: connections.isFriend(p)
                              ? const Text('Your friend')
                              : null,
                          onTap: () {
                            Navigator.pop(sheet);
                            unawaited(showPersonDetails(context, p));
                          },
                        ),
                    ],
                  ),
                const SizedBox(height: 8),
                // Someone's devices are there to look at, not the point.
                if (devices.isNotEmpty)
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: EdgeInsets.zero,
                    title: Text(
                      '${me ? 'Your devices' : 'Devices'} (${devices.length})',
                    ),
                    children: [
                      for (final c in devices)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            node.revoked.contains(c.device)
                                ? Icons.block
                                : Icons.devices,
                          ),
                          title: Text(deviceLabel(c)),
                          subtitle: Text(
                            [
                              if (c.device == node.identity.device)
                                'This device'
                              else if (node.revoked.contains(c.device))
                                removedText(c.device)
                              else if (recentlyConnected(network, c.device))
                                'Connected'
                              else
                                ?quietText(c.device),
                              ?addedText(c.device),
                            ].join(' · '),
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {
                            Navigator.pop(sheet);
                            unawaited(showDeviceDetails(context, c));
                          },
                        ),
                    ],
                  ),
                const SizedBox(height: 8),
                _idRow(sheet, 'Person ID', person),
              ],
            ),
          ),
        );
      },
    );
  }

  /// [chain] from this person to [person]; each name between opens that
  /// person's details.
  Widget connectionChain(
    BuildContext sheet,
    List<String>? chain,
    String person,
  ) {
    final theme = Theme.of(sheet);
    if (chain == null) {
      return Text(
        'No chain of friends to ${name(person)} is known yet. Friend lists '
        'arrive as your friends sync; people on older versions do not '
        'share theirs.',
        style: theme.textTheme.bodySmall,
      );
    }
    if (chain.length == 2) {
      return Text(
        'You are friends directly.',
        style: theme.textTheme.bodySmall,
      );
    }
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 2,
      runSpacing: 4,
      children: [
        for (final (i, p) in chain.indexed) ...[
          if (i > 0) const Icon(Icons.chevron_right, size: 18),
          ActionChip(
            visualDensity: VisualDensity.compact,
            avatar: conversationAvatar(p, radius: 10),
            label: Text(p == node.person ? 'You' : name(p)),
            onPressed: p == node.person || p == person
                ? null
                : () {
                    Navigator.pop(sheet);
                    unawaited(showPersonDetails(context, p));
                  },
          ),
        ],
      ],
    );
  }

  /// Asks [person], reached through friends, to connect, with an optional
  /// note.
  Future<void> askToConnect(BuildContext context, String person) async {
    final route = node.connections.route(person);
    final note = TextEditingController();
    final send = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Invite ${name(person)} to connect?'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Your request travels through '
                '${route.map(name).join(', ')}, who pass it on without '
                'being able to read it. If ${name(person)} accepts, your '
                'devices connect as friends.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: note,
                autofocus: true,
                maxLength: 500,
                maxLines: 3,
                minLines: 1,
                decoration: const InputDecoration(
                  labelText: 'Note (optional)',
                  hintText: 'Say who you are',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Send request'),
          ),
        ],
      ),
    );
    final text = note.text;
    Future<void>.delayed(const Duration(seconds: 1), note.dispose);
    if (send != true) return;
    act(() async {
      await node.connections.request(person, text: text);
      if (network.running) unawaited(network.syncAll());
      notice('Request sent to ${name(person)}');
    });
  }

  /// Connects with whoever sent [request].
  Future<void> acceptConnection(ConnectRequest request) async {
    await node.connections.accept(request);
    if (network.running) unawaited(network.syncAll());
    notice('Connected with ${name(request.from)}');
    refresh();
  }

  Future<void> showDeviceDetails(
    BuildContext context,
    DeviceCertificate device,
  ) {
    final self = device.device == node.identity.device;
    final own = device.person == node.person;
    final removed = node.revoked.contains(device.device);
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheet) {
        final theme = Theme.of(sheet);
        final version = network.peerVersions[device.device];
        final build = network.peerBuilds[device.device];
        final added = addedText(device.device);
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
                    CircleAvatar(
                      radius: 28,
                      child: Icon(removed ? Icons.block : Icons.devices),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            deviceLabel(device),
                            style: theme.textTheme.titleLarge,
                          ),
                          Text(
                            self
                                ? 'This device'
                                : own
                                ? 'One of your devices'
                                : '${name(device.person)}’s device',
                            style: theme.textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (removed)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.block),
                    title: Text(removedText(device.device)),
                    subtitle: const Text(
                      'It can no longer sync with your devices or read anything new.',
                    ),
                  )
                else if (!self)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.sync),
                    title: const Text('Connection'),
                    subtitle: DeviceHealthText(
                      network: network,
                      device: device.device,
                    ),
                  ),
                if (quietText(device.device) case final quiet?)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      Icons.warning_amber_outlined,
                      color: theme.colorScheme.error,
                    ),
                    title: Text(quiet),
                    subtitle: own
                        ? const Text(
                            'If it is gone, remove its access: it can still read what arrives for you.',
                          )
                        : const Text(
                            'It may be switched off or no longer used.',
                          ),
                  ),
                if (added != null)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.event_outlined),
                    title: Text(added),
                    subtitle: contactsAdded[device.device]!.estimated
                        ? const Text(
                            'Added before this was recorded; dated by its earliest activity',
                          )
                        : null,
                  ),
                if (!self && (version != null || build != null))
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.info_outline),
                    title: Text('Runs OurNet ${version ?? 'unknown version'}'),
                    subtitle: build == null ? null : Text('Build $build'),
                  ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.person_outline),
                  title: Text(own ? 'Belongs to you' : name(device.person)),
                  subtitle: const Text('Owner'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.pop(sheet);
                    unawaited(showPersonDetails(context, device.person));
                  },
                ),
                const SizedBox(height: 8),
                if (!removed)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (!self)
                        FilledButton.tonalIcon(
                          onPressed: () => act(() => syncNow(device.device)),
                          icon: const Icon(Icons.sync),
                          label: const Text('Sync now'),
                        ),
                      if (own)
                        OutlinedButton.icon(
                          onPressed: () {
                            Navigator.pop(sheet);
                            act(() => renameDevice(context, device));
                          },
                          icon: const Icon(Icons.edit_outlined),
                          label: const Text('Rename'),
                        ),
                      if (own && !self)
                        OutlinedButton.icon(
                          onPressed: () {
                            Navigator.pop(sheet);
                            act(() => shareHistoryWith(device));
                          },
                          icon: const Icon(Icons.history),
                          label: const Text('Share history'),
                        ),
                      if (own && !self && node.identity.holdsRoot)
                        OutlinedButton.icon(
                          onPressed: () {
                            Navigator.pop(sheet);
                            act(() => removeDeviceAccess(context, device));
                          },
                          icon: const Icon(Icons.phonelink_erase),
                          label: const Text('Remove access'),
                        ),
                    ],
                  ),
                const SizedBox(height: 8),
                _idRow(sheet, 'Device ID', device.device),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _idRow(BuildContext context, String title, String id) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(title),
    subtitle: SelectableText(id, style: Theme.of(context).textTheme.bodySmall),
    trailing: IconButton(
      tooltip: 'Copy',
      icon: const Icon(Icons.copy),
      onPressed: () {
        unawaited(Clipboard.setData(ClipboardData(text: id)));
        notice('$title copied');
      },
    ),
  );

  /// Asks for a new name for one of this person's devices and publishes it
  /// to their other devices and friends.
  Future<void> renameDevice(
    BuildContext context,
    DeviceCertificate device,
  ) async {
    final value = await ask(
      context,
      'Device name',
      initial: deviceLabel(device),
    );
    if (value == null || value.trim().isEmpty) return;
    await node.renameDevice(device.device, value);
    if (network.running) unawaited(network.syncAll());
    refresh();
  }

  /// Asks, then removes [device]'s access to this person's content.
  Future<void> removeDeviceAccess(
    BuildContext context,
    DeviceCertificate device,
  ) async {
    final allow = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${deviceLabel(device)}?'),
        content: const Text(
          'This stops future access. Copies already downloaded stay on that device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove access'),
          ),
        ],
      ),
    );
    if (allow != true || !context.mounted) return;
    final root = await unlockRoot(context, node);
    if (root != null) await node.revoke(device.device, unlocked: root);
  }
}
