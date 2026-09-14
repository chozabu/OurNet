import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';
import '../services/session.dart';
import '../services/pairing_discovery.dart';
import 'app.dart';

class SetupApp extends StatelessWidget {
  final Node node;
  const SetupApp({super.key, required this.node});
  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: ThemeData(
      colorSchemeSeed: const Color(0xff137d72),
      useMaterial3: true,
    ),
    home: SetupPage(node: node),
  );
}

class SetupPage extends StatefulWidget {
  final Node node;
  const SetupPage({super.key, required this.node});
  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  final name = TextEditingController();
  final device = TextEditingController(text: Platform.localHostname);
  final invitation = TextEditingController();
  String page = 'welcome', status = '';
  bool busy = false;
  List<String> nearby = [];
  PeerNetwork? network;
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
    return Node(
      await LocalIdentity.create(label: device.text.trim()),
      widget.node.store,
    );
  }

  Future<void> finish(Node node) async {
    await saveIdentity(node.identity);
    node.store.set('autoConnect', true);
    if (!mounted) return;
    runApp(OurNetApp(node: node, initialTab: page == 'create' ? 7 : 0));
  }

  Future<void> join() async {
    final parsed = PairingSession.parse(invitation.text.trim());
    final node = await fresh();
    final net = PeerNetwork(node);
    network = net;
    try {
      await net.start(automatic: false);
      if (!mounted) return;
      setState(
        () => status =
            'Compare this code on your other device:\n${PairingSession.code(parsed['token'], node.identity.certificate)}\nThen approve the connection there.',
      );
      final identity = await PairingSession.join(net, invitation.text.trim());
      await net.stop();
      await finish(Node(identity, node.store));
    } finally {
      await net.stop();
      network = null;
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
    canPop: !busy,
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
                      : page == 'create'
                      ? 'Create your profile'
                      : 'Connect your profile',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 12),
                Text(
                  page == 'welcome'
                      ? 'One profile for you, wherever you use OurNet.'
                      : page == 'create'
                      ? 'Choose how people see you and name this device.'
                      : 'On your original device, open Profile → Add device. Keep both apps open.',
                ),
                const SizedBox(height: 24),
                if (page == 'welcome') ...[
                  FilledButton.icon(
                    onPressed: () => setState(() => page = 'create'),
                    icon: const Icon(Icons.person_add_outlined),
                    label: const Text('Create a profile'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () => setState(() => page = 'join'),
                    icon: const Icon(Icons.devices),
                    label: const Text('Connect to my existing profile'),
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
                    OutlinedButton.icon(
                      onPressed: busy
                          ? null
                          : () => act(() async {
                              final results = await PairingDiscovery.find();
                              if (mounted) {
                                setState(() {
                                  nearby = results;
                                  status = results.isEmpty
                                      ? 'No devices found. Check that Add device is open and both devices use the same Wi-Fi, or scan the QR code.'
                                      : 'Choose your device, then compare the approval code.';
                                });
                              }
                            }),
                      icon: const Icon(Icons.wifi_find),
                      label: const Text('Find a nearby device'),
                    ),
                    ...nearby.map(
                      (text) => ListTile(
                        leading: const Icon(Icons.computer),
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
