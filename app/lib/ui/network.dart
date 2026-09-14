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
          subtitle: Text(
            '${short(c.device)} · ${network.lastSync[c.device] ?? 'Not yet synced'}',
          ),
          trailing: Wrap(
            children: [
              IconButton(
                tooltip: 'Sync this device',
                onPressed: () => act(() => network.sync(c.device)),
                icon: const Icon(Icons.sync),
              ),
              if (c.person == node.person)
                IconButton(
                  tooltip: 'Revoke this device',
                  onPressed: () => act(() async {
                    await node.revoke(c.device);
                  }),
                  icon: const Icon(Icons.phonelink_erase),
                ),
              if (c.person != node.person)
                IconButton(
                  tooltip: 'Block or unblock person',
                  onPressed: () =>
                      node.block(c.person, !node.blocked.contains(c.person)),
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
