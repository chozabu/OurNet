import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';

class FriendInvitePage extends StatefulWidget {
  final PeerNetwork network;
  final bool enablePlatform;
  const FriendInvitePage({
    super.key,
    required this.network,
    this.enablePlatform = true,
  });
  @override
  State<FriendInvitePage> createState() => _FriendInvitePageState();
}

class _FriendInvitePageState extends State<FriendInvitePage> {
  final input = TextEditingController();
  FriendSession? invitation;
  Timer? timer;
  String status = 'Create an invitation, or accept one from your friend.';
  bool busy = false;
  @override
  void dispose() {
    timer?.cancel();
    invitation?.close();
    input.dispose();
    super.dispose();
  }

  Future<void> act(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => status = '$error');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> create() async {
    if (!widget.enablePlatform) {
      throw StateError('Invitations require a network connection.');
    }
    await widget.network.start();
    if (!mounted) return;
    invitation?.close();
    invitation = FriendSession(widget.network, (cert, code) async {
      if (!mounted) return false;
      BuildContext? dialogContext;
      final expiry = Timer(const Duration(seconds: 80), () {
        if (dialogContext?.mounted == true) {
          Navigator.pop(dialogContext!, false);
        }
      });
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) {
          dialogContext = context;
          return AlertDialog(
            title: Text('Connect with ${cert.label}?'),
            content: Text(
              'Check that your friend sees this same code:\n\n$code\n\nThis adds a friend. Your private Notes and drive stay private.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Decline'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Codes match · Connect'),
              ),
            ],
          );
        },
      );
      expiry.cancel();
      return approved == true;
    });
    setState(
      () => status =
          'Send this invitation or let your friend scan it. Keep this screen open.',
    );
    timer?.cancel();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || invitation == null) return;
      setState(() {
        if (!invitation!.available) {
          status = DateTime.now().isAfter(invitation!.expires)
              ? 'Invitation expired. Create a new invitation.'
              : 'Friend approved. Waiting for both devices to sync…';
        }
        if (!invitation!.available &&
            widget.network.lastSync.containsKey(invitation!.acceptedPeer)) {
          status = 'Friend added. Connected devices are syncing.';
        }
      });
    });
  }

  Future<void> accept() async {
    final text = input.text.trim();
    final decoded = jsonDecode(text) as Json;
    if (decoded['friend'] == 1) {
      final data = FriendSession.parse(text);
      if (!widget.enablePlatform) {
        throw StateError('Invitations require a network connection.');
      }
      await widget.network.start();
      if (!mounted) return;
      setState(
        () => status =
            'Ask your friend to confirm this code: ${FriendSession.code(data['token'], widget.network.node.identity.certificate)}',
      );
      await FriendSession.join(widget.network, text);
      if (!mounted) return;
      setState(
        () => status =
            'You are now friends. Both devices have confirmed the connection.',
      );
      unawaited(widget.network.syncAll());
    } else {
      await widget.network.addCard(text);
      if (!mounted) return;
      await Clipboard.setData(
        ClipboardData(text: widget.network.contactCard()),
      );
      setState(
        () => status =
            'Contact added. Your return card is copied; send it to your friend to finish connecting.',
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Add friend')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'Bring your people',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Invite someone you know. Each of you confirms the connection.',
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: busy ? null : () => act(create),
              icon: const Icon(Icons.qr_code),
              label: const Text('Create invitation'),
            ),
            if (invitation?.available == true) ...[
              Center(
                child: Container(
                  color: Colors.white,
                  padding: const EdgeInsets.all(12),
                  child: QrImageView(data: invitation!.invitation, size: 250),
                ),
              ),
              Text(
                'Expires in ${invitation!.expires.difference(DateTime.now()).inSeconds.clamp(0, 300)} seconds',
                textAlign: TextAlign.center,
              ),
              TextButton.icon(
                onPressed: () => Clipboard.setData(
                  ClipboardData(text: invitation!.invitation),
                ),
                icon: const Icon(Icons.copy),
                label: const Text('Copy invitation to share'),
              ),
            ],
            const Divider(height: 32),
            if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS)
              OutlinedButton.icon(
                onPressed: busy
                    ? null
                    : () async {
                        final value = await Navigator.push<String>(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const ScanFriendPage(),
                          ),
                        );
                        if (value != null && mounted) {
                          input.text = value;
                          await act(accept);
                        }
                      },
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Scan friend’s QR code'),
              ),
            const SizedBox(height: 12),
            TextField(
              controller: input,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Paste invitation or contact card',
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: busy ? null : () => act(accept),
              child: const Text('Accept invitation'),
            ),
            if (busy) const LinearProgressIndicator(),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: SelectableText(status),
            ),
          ],
        ),
      ),
    ),
  );
}

class ScanFriendPage extends StatefulWidget {
  const ScanFriendPage({super.key});
  @override
  State<ScanFriendPage> createState() => _ScanFriendPageState();
}

class _ScanFriendPageState extends State<ScanFriendPage> {
  bool done = false;
  String? error;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scan friend’s invitation')),
    body: Column(
      children: [
        Expanded(
          child: MobileScanner(
            errorBuilder: (_, _) => const Center(
              child: Text(
                'Camera unavailable. Go back and paste the invitation.',
              ),
            ),
            onDetect: (capture) {
              if (done) return;
              for (final code in capture.barcodes) {
                try {
                  final text = code.rawValue;
                  if (text == null) continue;
                  FriendSession.parse(text);
                  done = true;
                  Navigator.pop(context, text);
                  return;
                } catch (_) {
                  setState(
                    () => error = 'Use a current OurNet friend invitation.',
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
