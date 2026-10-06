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
      ...newDeviceBanners(context),
      myDevicesRow(context),
      const Divider(),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: TextField(
          controller: networkSearch,
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            hintText: 'Search friends',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          onChanged: (_) => update(() {}),
        ),
      ),
      Wrap(
        spacing: 8,
        children: [
          for (final (value, label) in const [
            ('all', 'All'),
            ('connected', 'Connected'),
            ('unreachable', 'Can’t reach'),
          ])
            ChoiceChip(
              label: Text(label),
              selected: networkFilter == value,
              onSelected: (_) => update(() => networkFilter = value),
            ),
        ],
      ),
      const SizedBox(height: 4),
      if (shownFriends.isEmpty)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            friendsByName.isEmpty
                ? 'No friends yet. Add one with Add friend above.'
                : 'No friends match.',
          ),
        )
      else
        for (final person in shownFriends) friendRow(context, person),
      if (node.blocked.where((p) => p != node.person).toList()
          case final blocked when blocked.isNotEmpty)
        ExpansionTile(
          leading: const Icon(Icons.block),
          title: Text('Blocked (${blocked.length})'),
          subtitle: const Text(
            'Remembered, but nothing of theirs is shown or exchanged',
          ),
          children: [
            for (final person in blocked)
              ListTile(
                leading: conversationAvatar(person),
                title: Text(name(person)),
                subtitle: node.forgotten.contains(person)
                    ? const Text('Also disconnected')
                    : null,
                trailing: TextButton(
                  onPressed: () => unawaited(setBlocked(person, false)),
                  child: const Text('Unblock'),
                ),
                onTap: () => unawaited(showPersonDetails(context, person)),
              ),
          ],
        ),
    ],
  );

  /// This person's devices are managed under Profile and devices; here they
  /// are one line of connection status.
  Widget myDevicesRow(BuildContext context) {
    final own = activeDevices(node.person);
    final quiet = own.where((c) => quietText(c.device) != null).length;
    return ListTile(
      leading: const Icon(Icons.devices),
      title: const Text('My devices'),
      subtitle: NetworkHealthBuilder(
        network: network,
        builder: (context) {
          final live = own
              .where((c) => recentlyConnected(network, c.device))
              .length;
          return Text(
            own.isEmpty
                ? 'Only this device'
                : [
                    'This device and ${own.length} more',
                    '$live connected',
                    if (quiet > 0) '$quiet not seen lately',
                  ].join(' · '),
          );
        },
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => update(() => tab = Destination.profile),
    );
  }

  /// Devices of [person] that still have access, as linked.
  List<DeviceCertificate> activeDevices(String person) => [
    for (final c in node.contacts.values)
      if (c.person == person && !node.revoked.contains(c.device)) c,
  ];

  /// Friends with a device that still has access, by name. Blocked people
  /// are listed apart.
  List<String> get friendsByName => memo(
    'friendsByName',
    () =>
        {
          for (final c in node.contacts.values)
            if (c.person != node.person &&
                !node.revoked.contains(c.device) &&
                !node.forgotten.contains(c.person) &&
                !node.blocked.contains(c.person))
              c.person,
        }.toList()..sort(
          (a, b) => name(a).toLowerCase().compareTo(name(b).toLowerCase()),
        ),
  );

  /// [friendsByName] narrowed by the search box and filter.
  List<String> get shownFriends {
    final query = networkSearch.text.trim().toLowerCase();
    return [
      for (final person in friendsByName)
        if ((query.isEmpty || name(person).toLowerCase().contains(query)) &&
            switch (networkFilter) {
              'connected' => activeDevices(
                person,
              ).any((c) => recentlyConnected(network, c.device)),
              'unreachable' => reachText(person) != null,
              _ => true,
            })
          person,
    ];
  }

  /// One friend: how many of their devices are connected, or why they
  /// cannot be reached. Their devices fold away beneath.
  Widget friendRow(BuildContext context, String person) {
    final devices = activeDevices(person);
    final reach = reachText(person);
    final theme = Theme.of(context);
    return ExpansionTile(
      key: PageStorageKey('devices/$person'),
      leading: conversationAvatar(person),
      title: Text(name(person)),
      subtitle: NetworkHealthBuilder(
        network: network,
        builder: (context) {
          final live = devices
              .where((c) => recentlyConnected(network, c.device))
              .length;
          return Text(
            [
              if (live > 0)
                '$live of ${devices.length} connected'
              else
                reach ?? 'Not connected now',
              ?personAddedText(person),
            ].join(' · '),
            style: live == 0 && reach != null
                ? theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                  )
                : null,
          );
        },
      ),
      children: [
        for (final c in devices) networkDeviceTile(context, c),
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: Text('About ${name(person)}'),
          subtitle: const Text('Message, block or disconnect'),
          onTap: () => unawaited(showPersonDetails(context, person)),
        ),
      ],
    );
  }

  /// A friend's device, with how it is doing.
  Widget networkDeviceTile(BuildContext context, DeviceCertificate c) {
    final quiet = quietText(c.device);
    final added = addedText(c.device);
    final small = Theme.of(context).textTheme.bodySmall;
    return ListTile(
      contentPadding: const EdgeInsets.only(left: 32, right: 16),
      leading: const Icon(Icons.devices),
      title: Text(deviceLabel(c)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DeviceHealthText(network: network, device: c.device),
          if (quiet != null) Text(quiet, style: small),
          if (added != null) Text(added, style: small),
        ],
      ),
      isThreeLine: true,
      onTap: () => unawaited(showDeviceDetails(context, c)),
      trailing: IconButton(
        tooltip: 'Sync this device',
        onPressed: () => act(() => syncNow(c.device)),
        icon: const Icon(Icons.sync),
      ),
    );
  }

  /// Own devices this one has not been told about yet, when they were added
  /// elsewhere. Empty until devices are first recorded here, so a new
  /// install does not announce every device it finds.
  List<DeviceCertificate> get newOwnDevices {
    final known = node.store.setting('knownOwnDevices');
    final own = activeDevices(node.person);
    if (known is! List) {
      node.store.set('knownOwnDevices', [for (final c in own) c.device]);
      return const [];
    }
    return [
      for (final c in own)
        if (!known.contains(c.device) &&
            c.data['approvedBy'] != node.identity.device)
          c,
    ];
  }

  void acknowledgeOwnDevice(String device) {
    final known = [
      ...?(node.store.setting('knownOwnDevices') as List?)?.cast<String>(),
      device,
    ];
    node.store.set('knownOwnDevices', known);
    refresh();
  }

  /// A device added to this person's account somewhere else: shown until
  /// looked at, since an unexpected one is how a mistake or a stolen phrase
  /// shows itself.
  List<Widget> newDeviceBanners(BuildContext context) => [
    for (final c in newOwnDevices)
      Card(
        color: Theme.of(context).colorScheme.tertiaryContainer,
        child: ListTile(
          leading: const Icon(Icons.new_releases_outlined),
          title: Text('New device on your account: ${deviceLabel(c)}'),
          subtitle: Text(
            '${addedText(c.device) ?? 'Added from another of your devices'}. '
            'Not you? Remove its access.',
          ),
          onTap: () => unawaited(showDeviceDetails(context, c)),
          trailing: TextButton(
            onPressed: () => acknowledgeOwnDevice(c.device),
            child: const Text('OK'),
          ),
        ),
      ),
  ];

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
