import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';
import '../services/session.dart';
import '../services/device_model.dart';
import '../services/pairing_discovery.dart';
import '../services/wake.dart' show FcmChannel;
import 'app.dart';
import 'backup.dart';
import 'friend_invite.dart' show CodeText;

class SetupApp extends StatelessWidget {
  final Node node;

  /// Same-network device discovery; disabled in widget tests.
  final bool discover;

  /// See [SetupPage.askReachability].
  final bool? askReachability;

  /// See [SetupPage.pushAvailable].
  final Future<bool> Function()? pushAvailable;
  const SetupApp({
    super.key,
    required this.node,
    this.discover = true,
    this.askReachability,
    this.pushAvailable,
  });
  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: ThemeData(
      colorSchemeSeed: const Color(0xff137d72),
      useMaterial3: true,
    ),
    home: SetupPage(
      node: node,
      discover: discover,
      askReachability: askReachability,
      pushAvailable: pushAvailable,
    ),
  );
}

/// How a phone keeps receiving while OurNet is closed, chosen once during
/// setup and changeable later in Settings (each maps onto the existing
/// `stayConnected`, `pushWake` and `backgroundSync` settings).
enum Reachability {
  /// Push wake-up and periodic sync, no foreground service.
  batterySaver,

  /// The "Stay connected" foreground service (push wake kept as a backup).
  alwaysConnected,

  /// Periodic sync only.
  minimal,
}

/// Whether this device can be woken by push: FCM gives it a token.
Future<bool> fcmAvailable() async {
  try {
    final token = await FcmChannel.token().timeout(const Duration(seconds: 5));
    return token != null && token.isNotEmpty;
  } catch (_) {
    return false;
  }
}

class SetupPage extends StatefulWidget {
  final Node node;
  final bool discover;

  /// Ask how to stay reachable in the background before opening the app.
  /// Defaults to Android, the only platform with these settings.
  final bool? askReachability;

  /// Whether push wake-up works on this device; picks the suggested option.
  /// Defaults to [fcmAvailable].
  final Future<bool> Function()? pushAvailable;
  const SetupPage({
    super.key,
    required this.node,
    this.discover = true,
    this.askReachability,
    this.pushAvailable,
  });
  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  final name = TextEditingController();
  // Android reports "localhost"; offer a name people recognise instead.
  final device = TextEditingController(
    text: Platform.isAndroid || Platform.localHostname == 'localhost'
        ? 'My phone'
        : Platform.localHostname,
  );
  final invitation = TextEditingController();
  String page = 'welcome', status = '';
  String? code;
  bool busy = false;
  List<String> nearby = [];
  int searches = 0;
  PeerNetwork? network;

  /// The profile set up here, waiting on the reachability choice.
  Node? ready;
  bool created = false;
  bool? push;

  @override
  void initState() {
    super.initState();
    // Several phones all called "My phone" cannot be told apart later.
    unawaited(
      deviceModel().then((model) {
        if (model != null && mounted && device.text == 'My phone') {
          device.text = model;
        }
      }),
    );
  }

  Future<void> act(Future<void> Function() action) async {
    setState(() {
      busy = true;
      status = '';
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => status = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<Node> fresh() async {
    if (device.text.trim().isEmpty) throw StateError('Give this device a name');
    // The setup node is replaced, not closed: it shares this store. Closing
    // its change stream leaves no listeners attached to the discarded node.
    await widget.node.changes.close();
    return Node(
      await LocalIdentity.create(label: device.text.trim()),
      widget.node.store,
    );
  }

  Future<void> finish(Node node) async {
    await saveIdentity(node.identity);
    node.store.set('autoConnect', true);
    if (!mounted) return;
    created = page == 'create';
    if (widget.askReachability ?? Platform.isAndroid) {
      setState(() {
        ready = node;
        page = 'reach';
        status = '';
      });
      final available = await (widget.pushAvailable ?? fcmAvailable)();
      if (!mounted) return;
      setState(() => push = available);
      return;
    }
    launch(node);
  }

  void launch(Node node) => runApp(
    OurNetApp(
      node: node,
      initialTab: created ? Destination.profile : Destination.notes,
    ),
  );

  /// Stores the reachability choice, asks for notifications with the reason
  /// on screen, and opens the app.
  Future<void> applyReachability(Reachability choice) async {
    final node = ready!;
    storeReachability(node.store, choice);
    node.store.set('notificationsAsked', true);
    try {
      await FlutterLocalNotificationsPlugin()
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
    } catch (_) {
      // Settings › Notifications asks again.
    }
    if (mounted) launch(node);
  }

  /// Looks for an open Add device screen on this network while joining.
  Future<void> searchNearby() async {
    final generation = ++searches;
    while (mounted && page == 'join' && generation == searches) {
      if (!busy) {
        try {
          final results = await PairingDiscovery.find();
          if (!mounted || generation != searches) return;
          setState(() => nearby = results);
        } catch (_) {
          return;
        }
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  Future<void> join() async {
    final parsed = PairingSession.parse(invitation.text.trim());
    final node = await fresh();
    final net = PeerNetwork(node);
    network = net;
    try {
      await net.start(automatic: false);
      if (!mounted) return;
      setState(() {
        code = PairingSession.code(parsed['token'], node.identity.certificate);
        status =
            'Check that your other device shows this code, then approve there.';
      });
      final identity = await PairingSession.join(net, invitation.text.trim());
      await net.stop();
      // Enrolment replaces this node's identity; the store carries over.
      await node.changes.close();
      await finish(Node(identity, node.store));
    } finally {
      await net.stop();
      network = null;
      if (mounted) setState(() => code = null);
    }
  }

  @override
  void dispose() {
    unawaited(network?.stop());
    name.dispose();
    device.dispose();
    invitation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    // The profile already exists on the reachability page.
    canPop: !busy && page != 'reach',
    child: Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(28),
              children: [
                const Icon(
                  Icons.hub_outlined,
                  size: 64,
                  color: Color(0xff137d72),
                ),
                const SizedBox(height: 24),
                Text(
                  page == 'welcome'
                      ? 'Your people. Your devices.'
                      : page == 'reach'
                      ? 'Staying reachable'
                      : page == 'create'
                      ? 'Create your profile'
                      : 'Connect your profile',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 12),
                Text(
                  page == 'welcome'
                      ? 'One profile for you, wherever you use OurNet. There '
                            'is no OurNet server holding your notes and '
                            'messages: your devices and your friends’ devices '
                            'sync directly with each other.'
                      : page == 'reach'
                      ? 'Because there is no server to hold messages for you, '
                            'OurNet needs a way to hear from friends while it '
                            'is closed. Choose how.'
                      : page == 'create'
                      ? 'Choose how people see you and name this device.'
                      : 'On a device already linked to your profile, open Profile → Add device. Keep both apps open.',
                ),
                const SizedBox(height: 24),
                if (page == 'welcome') ...[
                  if (identityLost) ...[
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: const Padding(
                        padding: EdgeInsets.all(12),
                        child: Text(
                          'This profile already holds notes and messages, but '
                          'the keys that can read them are missing from this '
                          'device’s secure storage. Nothing here can recover '
                          'them: restore an OurNet backup or the device backup that '
                          'holds those keys, or carry on and start fresh, which leaves '
                          'that history unreadable on this device.',
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  FilledButton.icon(
                    onPressed: () => setState(() => page = 'create'),
                    icon: const Icon(Icons.person_add_outlined),
                    label: const Text('Create a profile'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () {
                      setState(() => page = 'join');
                      if (widget.discover) unawaited(searchNearby());
                    },
                    icon: const Icon(Icons.devices),
                    label: const Text('Connect to my existing profile'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: busy
                        ? null
                        : () => act(
                            () => restoreBackup(
                              context,
                              widget.node,
                              replacing: false,
                            ),
                          ),
                    icon: const Icon(Icons.unarchive_outlined),
                    label: const Text('Restore from a backup'),
                  ),
                ] else if (page == 'reach') ...[
                  if (push != null)
                    ReachabilityChoice(
                      push: push!,
                      enabled: !busy,
                      onChoose: (choice) =>
                          act(() => applyReachability(choice)),
                    ),
                ] else ...[
                  if (page == 'create') ...[
                    TextField(
                      controller: name,
                      enabled: !busy,
                      maxLength: 80,
                      decoration: const InputDecoration(
                        labelText: 'Display name',
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  TextField(
                    controller: device,
                    enabled: !busy,
                    maxLength: 80,
                    decoration: const InputDecoration(
                      labelText: 'Device name',
                      hintText: 'Home PC or Alex’s phone',
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (page == 'create')
                    FilledButton(
                      onPressed: busy
                          ? null
                          : () => act(() async {
                              if (name.text.trim().isEmpty) {
                                throw StateError('Enter your display name');
                              }
                              final node = await fresh();
                              await saveIdentity(node.identity);
                              await node.publish('profile', {
                                'name': name.text.trim(),
                              }, space: '_identity');
                              await finish(node);
                            }),
                      child: const Text('Create profile'),
                    ),
                  if (page == 'join') ...[
                    if (Platform.isAndroid || Platform.isIOS)
                      FilledButton.icon(
                        onPressed: busy
                            ? null
                            : () async {
                                final result = await Navigator.of(context)
                                    .push<String>(
                                      MaterialPageRoute(
                                        builder: (_) => const ScanPairingPage(),
                                      ),
                                    );
                                if (result != null && mounted) {
                                  invitation.text = result;
                                  await act(join);
                                }
                              },
                        icon: const Icon(Icons.qr_code_scanner),
                        label: const Text('Scan QR code'),
                      ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: widget.discover
                                ? const CircularProgressIndicator(
                                    strokeWidth: 2,
                                  )
                                : const Icon(Icons.wifi_find, size: 16),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              nearby.isEmpty
                                  ? 'Looking for your other device on this Wi-Fi…'
                                  : 'Choose your device, then compare the code.',
                            ),
                          ),
                        ],
                      ),
                    ),
                    ...nearby.map(
                      (text) => ListTile(
                        leading: const Icon(Icons.devices),
                        title: Text(
                          DeviceCertificate.fromJson(
                            jsonDecode(text)['card']['certificate'],
                          ).label,
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: busy
                            ? null
                            : () {
                                invitation.text = text;
                                act(join);
                              },
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: invitation,
                      enabled: !busy,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Or paste a pairing invitation',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: busy ? null : () => act(join),
                      child: const Text('Connect'),
                    ),
                  ],
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => setState(() {
                            page = 'welcome';
                            status = '';
                          }),
                    child: const Text('Back'),
                  ),
                ],
                if (busy && code != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 20),
                    child: Center(child: CodeText(code!)),
                  ),
                if (busy) const LinearProgressIndicator(),
                if (status.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 20),
                    child: SelectableText(status, textAlign: TextAlign.center),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Maps a [Reachability] choice onto the settings the app reads.
void storeReachability(Store store, Reachability choice) {
  store.set('stayConnected', choice == Reachability.alwaysConnected);
  store.set('pushWake', choice != Reachability.minimal);
  store.set('backgroundSync', true);
}

/// The "Staying reachable" options, with the suggestion depending on
/// whether [push] wake-up works on this device.
class ReachabilityChoice extends StatefulWidget {
  final bool push;
  final bool enabled;
  final void Function(Reachability choice) onChoose;
  const ReachabilityChoice({
    super.key,
    required this.push,
    required this.onChoose,
    this.enabled = true,
  });
  @override
  State<ReachabilityChoice> createState() => _ReachabilityChoiceState();
}

class _ReachabilityChoiceState extends State<ReachabilityChoice> {
  // Without push, saving battery would mean slow messages and calls that
  // never ring, so staying connected is suggested instead.
  late Reachability choice = widget.push
      ? Reachability.batterySaver
      : Reachability.alwaysConnected;

  Widget option(
    Reachability value,
    String title,
    String subtitle, {
    bool suggested = false,
  }) => RadioListTile<Reachability>(
    value: value,
    enabled: widget.enabled,
    contentPadding: EdgeInsets.zero,
    title: Text(suggested ? '$title (suggested)' : title),
    subtitle: Text(subtitle),
  );

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      RadioGroup<Reachability>(
        groupValue: choice,
        onChanged: (v) => setState(() => choice = v ?? choice),
        child: Column(
          children: [
            option(
              Reachability.batterySaver,
              'Save battery',
              widget.push
                  ? 'Friends’ devices wake OurNet through Google’s push '
                        'service when they have something for you, so '
                        'messages arrive soon and calls ring. Wakes carry '
                        'nothing: messages still come straight from friends.'
                  : 'Push wake-up is not available on this phone, so '
                        'messages arrive about every 15 minutes and calls '
                        'ring only while OurNet is open.',
              suggested: widget.push,
            ),
            option(
              Reachability.alwaysConnected,
              'Always connected',
              'Keeps a connection to friends open, without Google. Fastest '
                  'messages and calls, but uses more battery and shows a '
                  'notification while on. Some phones also need battery '
                  'optimisation turned off for OurNet.',
              suggested: !widget.push,
            ),
            option(
              Reachability.minimal,
              'Only check now and then',
              'Exchange with friends about every 15 minutes while closed, '
                  'with no push. Calls ring only while OurNet is open.',
            ),
          ],
        ),
      ),
      const SizedBox(height: 8),
      Text(
        'Next, Android asks to allow notifications, so you see messages and '
        'calls while OurNet is closed. You can change all of this in '
        'Settings.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: widget.enabled ? () => widget.onChoose(choice) : null,
        child: const Text('Continue'),
      ),
    ],
  );
}

class ScanPairingPage extends StatefulWidget {
  const ScanPairingPage({super.key});
  @override
  State<ScanPairingPage> createState() => _ScanPairingPageState();
}

class _ScanPairingPageState extends State<ScanPairingPage> {
  bool done = false;
  String? error;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scan your other device’s QR code')),
    body: Column(
      children: [
        Expanded(
          child: MobileScanner(
            errorBuilder: (context, error) => const Center(
              child: Text(
                'Camera unavailable. Go back and use nearby discovery or paste an invitation.',
              ),
            ),
            onDetect: (capture) {
              if (done) return;
              for (final barcode in capture.barcodes) {
                try {
                  final value = barcode.rawValue;
                  if (value == null) continue;
                  PairingSession.parse(value);
                  done = true;
                  Navigator.of(context).pop(value);
                  return;
                } catch (_) {
                  setState(
                    () => error = 'Use a current OurNet pairing QR code.',
                  );
                }
              }
            },
          ),
        ),
        if (error != null)
          Padding(padding: const EdgeInsets.all(16), child: Text(error!)),
      ],
    ),
  );
}
