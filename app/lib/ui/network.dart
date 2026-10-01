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
            onPressed: () => act(() async {
              final card = await ask(
                context,
                'Add a friend’s device',
                hint: 'Paste their contact card',
                lines: 4,
              );
              if (card != null) {
                await network.addCard(card);
              }
            }),
            icon: const Icon(Icons.person_add_alt),
            label: const Text('Add contact'),
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
        'A contact card binds a device to its owner. Confirm the identity with your friend. Both sides must add the other.',
      ),
      const SizedBox(height: 16),
      SizedBox(
        height: 220,
        child: CustomPaint(
          painter: NetworkPainter(node.person, node.contacts.values.toList()),
          child: const SizedBox.expand(),
        ),
      ),
      ...node.contacts.values.map(
        (c) => ListTile(
          leading: Icon(
            node.revoked.contains(c.device) ? Icons.block : Icons.devices,
          ),
          title: Text('${name(c.person)} · ${c.label}'),
          subtitle: node.revoked.contains(c.device)
              ? Text('${short(c.device)} · Access removed')
              : DeviceHealthText(
                  network: network,
                  device: c.device,
                  prefix: short(c.device),
                ),
          isThreeLine: true,
          trailing: Wrap(
            children: [
              IconButton(
                tooltip: 'Sync this device',
                onPressed: () => act(() => syncNow(c.device)),
                icon: const Icon(Icons.sync),
              ),
              if (c.person == node.person &&
                  c.device != node.identity.device &&
                  !node.revoked.contains(c.device))
                IconButton(
                  tooltip: 'Share your history with this device',
                  onPressed: () => act(() => shareHistoryWith(c)),
                  icon: const Icon(Icons.history),
                ),
              if (c.person == node.person && node.identity.holdsRoot)
                IconButton(
                  tooltip: 'Revoke this device',
                  onPressed: () => act(() async {
                    final root = await unlockRoot(context, node);
                    if (root != null) {
                      await node.revoke(c.device, unlocked: root);
                    }
                  }),
                  icon: const Icon(Icons.phonelink_erase),
                ),
              if (c.person != node.person)
                IconButton(
                  tooltip: 'Block or unblock person',
                  onPressed: () {
                    final unblock = node.blocked.contains(c.person);
                    node.block(c.person, !unblock);
                    // What was refused while blocked arrives on the next sync.
                    if (unblock && network.running) {
                      unawaited(network.sync(c.device));
                    }
                    refresh();
                  },
                  icon: Icon(
                    node.blocked.contains(c.person) ? Icons.undo : Icons.block,
                  ),
                ),
            ],
          ),
        ),
      ),
    ],
  );

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
        title: Text('Share your history with ${device.label}?'),
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
    notice('Preparing your history for ${device.label}…');
    final count = await shareAllHistory(node);
    if (count > 0 && network.running) unawaited(network.sync(device.device));
    notice(
      count == 0
          ? '${device.label} can already read everything this device can'
          : 'Shared $count items with ${device.label}. They appear there after it syncs.',
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
    final label = node.contacts[device]?.label ?? 'device';
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
