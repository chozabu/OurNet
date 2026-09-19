part of 'app.dart';

extension _SettingsPages on _OurNetAppState {
  Widget profile(BuildContext context) => ListView(
    children: [
      Text(name(node.person), style: Theme.of(context).textTheme.headlineLarge),
      const SizedBox(height: 12),
      FilledButton(
        onPressed: () => act(() async {
          final value = await ask(
            context,
            'Display name',
            initial: name(node.person),
          );
          if (value != null && value.isNotEmpty) {
            await node.publish('profile', {'name': value}, space: '_identity');
          }
        }),
        child: const Text('Edit display name'),
      ),
      const SizedBox(height: 24),
      const Text('Persistent person identity'),
      SelectableText(node.person),
      const SizedBox(height: 16),
      const Text('This device'),
      SelectableText(node.identity.device),
      const SizedBox(height: 16),
      const Text(
        'Your signing and encryption secrets are stored in the operating system vault, separately from the content database.',
      ),
      const SizedBox(height: 24),
      Text('Devices', style: Theme.of(context).textTheme.titleLarge),
      const Text(
        'Calls from your linked devices answer automatically while OurNet is running. '
        'Video calls turn on the camera and microphone; voice calls turn on the microphone.',
      ),
      if (node.store.count == 0 && node.identity.root != null)
        TextButton(
          onPressed: () => runApp(SetupApp(node: node)),
          child: const Text(
            'Connect this empty profile to my existing profile',
          ),
        ),
      const SizedBox(height: 12),
      if (node.identity.root != null)
        FilledButton.icon(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => AddDevicePage(network: network)),
          ),
          icon: const Icon(Icons.add_to_photos_outlined),
          label: const Text('Add device'),
        )
      else
        const Text(
          'To add another device, open OurNet on your original owner device.',
        ),
      ListTile(
        leading: const Icon(Icons.devices),
        title: Text(node.identity.certificate.label),
        subtitle: const Text('This device'),
      ),
      ...node.contacts.values
          .where((c) => c.person == node.person)
          .map(
            (c) => ListTile(
              leading: Icon(
                node.revoked.contains(c.device) ? Icons.block : Icons.devices,
              ),
              title: Text(c.label),
              subtitle: node.revoked.contains(c.device)
                  ? const Text('Access removed')
                  : DeviceHealthText(network: network, device: c.device),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (calls.isOwnDevice(c.device)) ...[
                    IconButton(
                      tooltip: 'Call device (auto-answer)',
                      icon: const Icon(Icons.call),
                      onPressed: calls.phase != 'idle'
                          ? null
                          : () => callAct(() async {
                              if (!network.running) await network.start();
                              await calls.call(c.device);
                            }),
                    ),
                    IconButton(
                      tooltip: 'Video call device (auto-answer)',
                      icon: const Icon(Icons.videocam),
                      onPressed: calls.phase != 'idle'
                          ? null
                          : () => callAct(() async {
                              if (!network.running) await network.start();
                              await calls.call(c.device, video: true);
                            }),
                    ),
                  ],
                  if (node.identity.root != null &&
                      !node.revoked.contains(c.device))
                    IconButton(
                      tooltip: 'Remove device access',
                      icon: const Icon(Icons.phonelink_erase),
                      onPressed: () => act(() async {
                        final allow = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: Text('Remove ${c.label}?'),
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
                        if (allow == true) await node.revoke(c.device);
                      }),
                    ),
                ],
              ),
            ),
          ),
    ],
  );
  Widget settings(BuildContext context) => ListView(
    children: [
      ListTile(
        leading: const Icon(Icons.account_circle_outlined),
        title: const Text('Profile and devices'),
        subtitle: const Text('Your name, linked devices and device access'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => update(() => tab = Destination.profile),
      ),
      ListTile(
        leading: const Icon(Icons.hub_outlined),
        title: const Text('Network and connections'),
        subtitle: const Text('Connection status, contacts and sync controls'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => update(() => tab = Destination.network),
      ),
      ListTile(
        title: const Text('OurNet $appVersion'),
        subtitle: const Text('Build $buildId'),
        trailing: TextButton(
          onPressed: () => act(() async {
            await Clipboard.setData(
              ClipboardData(
                text: canonical({
                  'version': appVersion,
                  'build': buildId,
                  'platform': Platform.operatingSystem,
                  'objects': node.store.count,
                  'devices': node.contacts.length,
                  'networkRunning': network.running,
                  'sync': syncDiagnostics(network),
                  'driveOffline': driveSync.enabled,
                  'driveError': driveSync.error,
                  'performance': performance.snapshot(),
                }),
              ),
            );
            notice(
              'Diagnostics copied; message contents and keys are excluded',
            );
          }),
          child: const Text('Copy diagnostics'),
        ),
      ),
      SwitchListTile(
        title: const Text('Compact spacing'),
        value: compact,
        onChanged: (value) {
          update(() => compact = value);
          node.store.set('compact', value);
        },
      ),
      ListTile(
        title: const Text('Accent colour'),
        subtitle: Wrap(
          spacing: 8,
          children: [
            for (final colour in [
              0xff137d72,
              0xff365bd6,
              0xff8654b5,
              0xffb65d23,
            ])
              IconButton(
                tooltip: 'Use ${colour.toRadixString(16)} accent',
                onPressed: () {
                  update(() => accent = colour);
                  node.store.set('accent', colour);
                },
                icon: Icon(
                  accent == colour ? Icons.check_circle : Icons.circle,
                  color: Color(colour),
                ),
              ),
          ],
        ),
      ),
      SwitchListTile(
        title: const Text('Notifications'),
        subtitle: Text(
          Platform.isAndroid
              ? 'Messages, replies to you and forum activity. Choose which sound in Android settings.'
              : 'Messages, replies to you and forum activity.',
        ),
        value: notifications.enabled,
        onChanged: (v) => act(() async {
          await notifications.setEnabled(v);
          refresh();
        }),
      ),
      SwitchListTile(
        title: const Text('Show message text in notifications'),
        subtitle: const Text(
          'Off shows only who wrote. Android can also hide it on the lock screen.',
        ),
        value: notifications.previews,
        onChanged: notifications.enabled
            ? (v) => update(() => node.store.set('notificationPreviews', v))
            : null,
      ),
      const Divider(),
      SpeechSettings(speech: speech, notice: notice),
      ListTile(
        leading: const Icon(Icons.label_outline),
        title: const Text('Note labels'),
        subtitle: const Text(
          'Private to you and synced between your own devices',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          await manageLabels(context, notes.state, notice: notice);
          update(() {});
        },
      ),
      const Divider(),
      SwitchListTile(
        title: const Text('Dark appearance'),
        value: dark,
        onChanged: (v) {
          update(() => dark = v);
          node.store.set('dark', v);
        },
      ),
      ListTile(
        title: const Text('Network'),
        subtitle: Text(
          network.error ??
              'Internet mode uses iroh’s default discovery and relays. Local mode disables relays.',
        ),
        trailing: OutlinedButton(
          onPressed: () => act(
            network.running ? network.stop : () => network.start(local: true),
          ),
          child: Text(network.running ? 'Disconnect' : 'Connect locally'),
        ),
      ),
      if (Platform.isAndroid)
        SwitchListTile(
          title: const Text('Background sync'),
          subtitle: const Text(
            'Exchange with friends about every 15 minutes while OurNet is closed, so messages arrive without both of you having it open.',
          ),
          value: node.store.setting('backgroundSync') != false,
          onChanged: (v) => act(() async {
            await scheduleBackgroundSync(enabled: v);
            node.store.set('backgroundSync', v);
            refresh();
          }),
        ),
      if (Platform.isAndroid && ownsProfile)
        SwitchListTile(
          title: const Text('Stay connected'),
          subtitle: const Text(
            'Keep a connection to friends open while OurNet is closed, so messages and calls arrive straight away. Android shows a notification while it is on, and it uses more battery.',
          ),
          value: stayConnected,
          onChanged: node.store.setting('autoConnect') == false
              ? null
              : (v) => act(() async {
                  node.store.set('stayConnected', v);
                  await keepConnected(v);
                  refresh();
                }),
        ),
      ListTile(
        title: const Text('Call connectivity'),
        subtitle: const Text(
          'STUN/TURN servers as a JSON array. Unset uses public STUN servers (none in local mode); an empty array uses direct candidates only.',
        ),
        trailing: TextButton(
          onPressed: () => act(() async {
            final text = await ask(
              context,
              'ICE servers',
              initial: jsonEncode(
                node.store.setting('iceServers') ?? defaultIceServers,
              ),
              lines: 4,
            );
            if (text != null) {
              final servers = jsonDecode(text);
              if (servers is! List) throw StateError('Expected a JSON array');
              node.store.set('iceServers', servers);
            }
          }),
          child: const Text('Configure'),
        ),
      ),
      const Divider(),
      const ListTile(
        title: Text('Prototype limits'),
        subtitle: Text(
          '10,000 local objects · 128 evidence records per object · 64 MiB per file. No guaranteed incoming calls while the mobile app is suspended.',
        ),
      ),
      const Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          'Network activity',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      ...network.events
          .take(30)
          .map(
            (e) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: SelectableText(e),
            ),
          ),
    ],
  );
}
