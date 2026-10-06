part of 'app.dart';

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
  String? addedText(String device) => switch (contactsAdded[device]) {
    null => null,
    (added: final at, estimated: true) => 'Active since ${_dateTime(at)}',
    (added: final at, estimated: false) => 'Added ${_dateTime(at)}',
  };

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

  Future<void> showPersonDetails(BuildContext context, String person) {
    final me = person == node.person;
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
                    conversationAvatar(person, radius: 28),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(name(person), style: theme.textTheme.titleLarge),
                          Text(
                            me ? 'You' : since ?? 'Friend',
                            style: theme.textTheme.bodyMedium,
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
                          toggleBlock(person);
                        },
                        icon: Icon(blocked ? Icons.undo : Icons.block),
                        label: Text(blocked ? 'Unblock' : 'Block'),
                      ),
                    ],
                  ),
                const SizedBox(height: 8),
                Text(
                  me ? 'Your devices' : 'Devices',
                  style: theme.textTheme.titleMedium,
                ),
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
                          'Connected',
                        ?addedText(c.device),
                      ].join(' · '),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.pop(sheet);
                      unawaited(showDeviceDetails(context, c));
                    },
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
