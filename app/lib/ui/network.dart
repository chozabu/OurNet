part of 'app.dart';

extension _NetworkPages on _OurNetAppState {
  Widget networkPage(BuildContext context) => ListView(
    children: [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton.icon(
            onPressed: () => act(() async {
              if (!network.running) await network.start();
              await Clipboard.setData(
                ClipboardData(text: network.contactCard()),
              );
              notice(
                'Contact card copied. Exchange through a trusted channel.',
              );
            }),
            icon: const Icon(Icons.copy),
            label: const Text('Copy your contact card'),
          ),
          OutlinedButton.icon(
            onPressed: () => addFriend(context),
            icon: const Icon(Icons.person_add_alt),
            label: const Text('Add friend'),
          ),
        ],
      ),
      const SizedBox(height: 12),
      ConnectionHealthCard(
        network: network,
        onRestart: () => act(() async {
          final local = network.running && network.local;
          await network.stop();
          await network.start(local: local);
          notice('Network restarted');
        }),
      ),
      const SizedBox(height: 12),
      const Text(
        'Add friend connects both of you at once: scan a QR code, find them on the same Wi-Fi, or paste an invitation. A contact card binds a device to its owner; if you use one instead, both sides must add the other.',
      ),
      const SizedBox(height: 16),
      NetworkGraph(
        network: network,
        name: name,
        deviceLabel: deviceLabel,
        onPerson: (person) => unawaited(showPersonDetails(context, person)),
        onDevice: (device) => unawaited(showDeviceDetails(context, device)),
      ),
      const SizedBox(height: 8),
      if (activeDevices(node.person) case final own when own.isNotEmpty)
        deviceGroup(
          context,
          leading: const Icon(Icons.devices),
          title: 'My devices (${own.length})',
          devices: own,
        ),
      for (final person in friendsByName)
        deviceGroup(
          context,
          leading: conversationAvatar(person),
          title: name(person),
          since: personAddedText(person),
          devices: activeDevices(person),
          person: person,
        ),
      if (node.contacts.values
              .where((c) => node.revoked.contains(c.device))
              .toList()
          case final removed when removed.isNotEmpty)
        ExpansionTile(
          leading: const Icon(Icons.block),
          title: Text('Removed devices (${removed.length})'),
          children: [for (final c in removed) networkDeviceTile(context, c)],
        ),
    ],
  );

  /// Devices of [person] that still have access, as linked.
  List<DeviceCertificate> activeDevices(String person) => [
    for (final c in node.contacts.values)
      if (c.person == person && !node.revoked.contains(c.device)) c,
  ];

  /// Friends with a device that still has access, by name.
  List<String> get friendsByName => memo(
    'friendsByName',
    () =>
        {
          for (final c in node.contacts.values)
            if (c.person != node.person && !node.revoked.contains(c.device))
              c.person,
        }.toList()..sort(
          (a, b) => name(a).toLowerCase().compareTo(name(b).toLowerCase()),
        ),
  );

  /// One person's devices folded under a single row that says how many are
  /// connected now. [person] adds a way to their details.
  Widget deviceGroup(
    BuildContext context, {
    required Widget leading,
    required String title,
    required List<DeviceCertificate> devices,
    String? since,
    String? person,
  }) => ExpansionTile(
    key: PageStorageKey('devices/${person ?? 'mine'}'),
    leading: leading,
    title: Text(title),
    // Blocking is about the person, and undoing it stays one tap away.
    trailing: person == null || !node.blocked.contains(person)
        ? null
        : IconButton(
            tooltip: 'Unblock ${name(person)}',
            onPressed: () => toggleBlock(person),
            icon: const Icon(Icons.undo),
          ),
    subtitle: NetworkHealthBuilder(
      network: network,
      builder: (context) {
        final live = devices
            .where((c) => recentlyConnected(network, c.device))
            .length;
        return Text(
          [
            devices.length == 1 ? '1 device' : '${devices.length} devices',
            '$live connected',
            ?since,
          ].join(' · '),
        );
      },
    ),
    children: [
      for (final c in devices) networkDeviceTile(context, c, owner: false),
      if (person != null)
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: Text('About ${name(person)}'),
          onTap: () => unawaited(showPersonDetails(context, person)),
        ),
    ],
  );

  Widget networkDeviceTile(
    BuildContext context,
    DeviceCertificate c, {
    bool owner = true,
  }) {
    final removed = node.revoked.contains(c.device);
    final added = addedText(c.device);
    return ListTile(
      leading: Icon(removed ? Icons.block : Icons.devices),
      title: Text(
        owner ? '${name(c.person)} · ${deviceLabel(c)}' : deviceLabel(c),
      ),
      subtitle: removed
          ? Text([short(c.device), removedText(c.device), ?added].join(' · '))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DeviceHealthText(
                  network: network,
                  device: c.device,
                  prefix: short(c.device),
                ),
                if (added != null)
                  Text(added, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
      isThreeLine: !removed,
      onTap: () => unawaited(showDeviceDetails(context, c)),
      trailing: removed
          ? null
          : Wrap(
              children: [
                IconButton(
                  tooltip: 'Sync this device',
                  onPressed: () => act(() => syncNow(c.device)),
                  icon: const Icon(Icons.sync),
                ),
                if (c.person == node.person && c.device != node.identity.device)
                  IconButton(
                    tooltip: 'Share your history with this device',
                    onPressed: () => act(() => shareHistoryWith(c)),
                    icon: const Icon(Icons.history),
                  ),
                if (c.person == node.person && node.identity.holdsRoot)
                  IconButton(
                    tooltip: 'Remove device access',
                    onPressed: () => act(() => removeDeviceAccess(context, c)),
                    icon: const Icon(Icons.phonelink_erase),
                  ),
                if (owner && c.person != node.person)
                  IconButton(
                    tooltip: 'Block or unblock person',
                    onPressed: () => toggleBlock(c.person),
                    icon: Icon(
                      node.blocked.contains(c.person)
                          ? Icons.undo
                          : Icons.block,
                    ),
                  ),
              ],
            ),
    );
  }

  void toggleBlock(String person) {
    final unblock = node.blocked.contains(person);
    node.block(person, !unblock);
    // What was refused while blocked arrives on the next sync.
    if (unblock && network.running) unawaited(network.syncAll());
    refresh();
  }

  /// Lets [device], one of this person's own, read the chats, groups and
  /// notes that were written before it was added.
  Future<void> shareHistoryWith(DeviceCertificate device) async {
    // This state sits above the app's Navigator, so its own context cannot
    // show dialogs.
    final dialogContext = noteNavigator.currentContext;
    if (dialogContext == null) return;
    final confirmed = await showDialog<bool>(
      context: dialogContext,
      builder: (context) => AlertDialog(
        title: Text('Share your history with ${deviceLabel(device)}?'),
        content: const Text(
          'Your devices will be able to read your earlier chats, groups, notes and files, including ones from before they were added. Only do this for a device you trust.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Share history'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    notice('Preparing your history for ${deviceLabel(device)}…');
    final count = await shareAllHistory(node);
    if (count > 0 && network.running) unawaited(network.sync(device.device));
    notice(
      count == 0
          ? '${deviceLabel(device)} can already read everything this device can'
          : 'Shared $count items with ${deviceLabel(device)}. They appear there after it syncs.',
    );
  }

  /// Once per own device, offers it the history from before it was linked.
  /// Devices linked by earlier builds, or without "Share history" at pairing,
  /// otherwise never read older chats and show friends as bare hashes.
  Future<void> offerHistory() async {
    // Only from the home screen, not over the Add device page, which offers
    // this itself.
    final dialogContext = noteNavigator.currentContext;
    if (_offeringHistory || !mounted || dialogContext == null) return;
    if (noteNavigator.currentState?.canPop() == true) return;
    final waiting = devicesAwaitingHistory(node);
    if (waiting.isEmpty) return;
    _offeringHistory = true;
    try {
      final names = waiting.map((c) => c.label).toSet().join(', ');
      final confirmed = await showDialog<bool>(
        context: dialogContext,
        builder: (context) => AlertDialog(
          title: const Text('Share your earlier history?'),
          content: Text(
            '$names can’t read chats, groups or notes from before it was linked. Share them so all your devices show the same history? Only do this for devices you trust.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Share history'),
            ),
          ],
        ),
      );
      markHistoryOffered(node);
      if (confirmed != true) {
        notice(
          'You can share history later with the history button beside a device in Settings.',
        );
        return;
      }
      notice('Preparing your history…');
      final count = await shareAllHistory(node);
      if (network.running) unawaited(network.syncAll());
      notice(
        count == 0
            ? 'Your devices can already read everything this device can'
            : 'Shared $count items. They appear on your other devices after they sync.',
      );
    } catch (e) {
      notice('Could not share history: $e');
    } finally {
      _offeringHistory = false;
    }
  }

  /// Syncs one device and reports the outcome, which [PeerNetwork.sync]
  /// records rather than throws.
  Future<void> syncNow(String device) async {
    if (!network.running) await network.start();
    final label = switch (node.contacts[device]) {
      final c? => deviceLabel(c),
      null => 'device',
    };
    notice('Syncing with $label…');
    await network.sync(device);
    final error = network.syncErrors[device];
    notice(
      error == null
          ? 'Synced with $label'
          : 'Couldn’t sync with $label. ${friendlySyncError(error)}',
    );
  }

  Widget locations(BuildContext context) => ListView(
    children: [
      WorldMap(node: node),
      const SizedBox(height: 16),
      const Text(
        'Share a place with someone you choose',
        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      const Text(
        'Coordinates are encrypted for the selected person and expire after one hour. This does not erase copies they already received.',
      ),
      const SizedBox(height: 12),
      FilledButton.icon(
        onPressed: people.isEmpty
            ? null
            : () => act(() async {
                final target = contact ?? await choosePerson(context);
                if (target == null || !context.mounted) return;
                final coordinates = await ask(
                  context,
                  'Latitude, longitude',
                  hint: '51.5074, -0.1278',
                );
                if (coordinates == null) return;
                final parts = coordinates
                    .split(',')
                    .map((v) => double.tryParse(v.trim()))
                    .toList();
                if (parts.length != 2 ||
                    parts.any((p) => p == null) ||
                    parts[0]!.abs() > 90 ||
                    parts[1]!.abs() > 180) {
                  throw StateError('Enter valid latitude and longitude');
                }
                await node.publish(
                  'location',
                  {'lat': parts[0].toString(), 'lng': parts[1].toString()},
                  space: '_location',
                  audience: [target],
                  expires: node.now() + 3600000,
                );
              }),
        icon: const Icon(Icons.location_on_outlined),
        label: const Text('Share coordinates'),
      ),
      ...node.store
          .objects(kind: 'location')
          .where(node.visible)
          .map(
            (o) => FutureBuilder<Json?>(
              future: node.content(o),
              builder: (context, snapshot) {
                final p = snapshot.data;
                if (p == null) return const SizedBox.shrink();
                return ListTile(
                  leading: const Icon(Icons.place),
                  title: Text(name(o.author)),
                  subtitle: SelectableText(
                    '${p['lat']}, ${p['lng']} · expires ${DateTime.fromMillisecondsSinceEpoch(o.expires)}',
                  ),
                  onTap: () => provenance(context, o),
                );
              },
            ),
          ),
    ],
  );
  Future<String?> choosePerson(BuildContext context) => showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('Choose a person'),
      children: people
          .map(
            (p) => SimpleDialogOption(
              onPressed: () => Navigator.pop(context, p),
              child: Text(name(p)),
            ),
          )
          .toList(),
    ),
  );
}
