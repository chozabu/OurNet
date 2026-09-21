import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';
import '../services/pairing_discovery.dart';
import 'friend_invite.dart' show CodeText;

class AddDevicePage extends StatefulWidget {
  final PeerNetwork network;
  const AddDevicePage({super.key, required this.network});
  @override
  State<AddDevicePage> createState() => _AddDevicePageState();
}

class _AddDevicePageState extends State<AddDevicePage> {
  PairingSession? session;
  RawDatagramSocket? discovery;
  Timer? timer;
  String status = 'Preparing a secure connection…';
  bool shareHistory = true;
  @override
  void initState() {
    super.initState();
    unawaited(start());
  }

  Future<void> start() async {
    session?.close();
    discovery?.close();
    timer?.cancel();
    try {
      await widget.network.start();
      widget.network.node.store.set('autoConnect', true);
      if (!mounted) return;
      final pairing = PairingSession(widget.network, (cert, code) async {
        if (!mounted) return false;
        BuildContext? approvalContext;
        final expiry = Timer(const Duration(seconds: 85), () {
          if (approvalContext?.mounted == true) {
            Navigator.of(approvalContext!).pop(false);
          }
        });
        final approved = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) {
            approvalContext = context;
            return AlertDialog(
              title: Text('Allow ${cert.label} to join?'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Only approve if your new device shows this code:',
                  ),
                  const SizedBox(height: 12),
                  Center(child: CodeText(code)),
                  const SizedBox(height: 12),
                  const Text('It will have access to your profile.'),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Decline'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Codes match · Allow'),
                ),
              ],
            );
          },
        );
        expiry.cancel();
        return approved == true;
      });
      setState(() {
        session = pairing;
        status =
            'On your new device, open OurNet and choose Connect to my existing profile. On the same Wi-Fi it finds this device by itself; otherwise scan this code.';
      });
      try {
        final socket = await PairingDiscovery.advertise(pairing);
        if (!mounted) {
          socket.close();
          return;
        }
        discovery = socket;
      } catch (_) {
        if (mounted) {
          setState(
            () => status =
                'Scan the QR code or copy the invitation. Nearby discovery is unavailable on this network.',
          );
        }
      }
      timer = Timer.periodic(const Duration(seconds: 1), (_) async {
        if (!mounted) return;
        if (!pairing.available) {
          timer?.cancel();
          discovery?.close();
          final expired = DateTime.now().isAfter(pairing.expires);
          if (expired) {
            // Keep a usable invitation on screen instead of a dead end.
            unawaited(start());
            return;
          }
          setState(
            () => status = 'Device approved. Your new device is connecting.',
          );
          if (!expired && shareHistory) {
            try {
              final node = widget.network.node;
              await Drive(node).shareHistory();
              await Everyday(node).shareHistory();
              // Re-encrypted for the device just added: without this its
              // groups and notes stay unreadable there for good, since a
              // later edit arrives in a space it has no record for.
              await Everyday(node).shareRooms();
              await Notes(node).shareNotes();
              await widget.network.syncAll();
              if (mounted) {
                setState(
                  () => status =
                      'Device added. Notes, groups you own, files and inbox history are ready to sync. Old private chat history, and groups and notes someone else owns, are not transferred.',
                );
              }
            } catch (e) {
              if (mounted) {
                setState(
                  () => status =
                      'Device added. Retry sharing drive history from Files: $e',
                );
              }
            }
          }
        } else {
          setState(() {});
        }
      });
    } catch (e) {
      if (mounted) setState(() => status = 'Could not start pairing: $e');
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    session?.close();
    discovery?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Add device')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              'Bring your profile with you',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 12),
            Text(status),
            const SizedBox(height: 20),
            if (session?.available == true) ...[
              Center(
                child: QrImageView(
                  data: session!.invitation,
                  size: 280,
                  backgroundColor: Colors.white,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Expires in ${session!.expires.difference(DateTime.now()).inSeconds.clamp(0, 300)} seconds',
                textAlign: TextAlign.center,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Share inbox and drive history'),
                subtitle: const Text(
                  'Your new device can access your inbox and previous file revisions. Old private chats are not transferred.',
                ),
                value: shareHistory,
                onChanged: (value) => setState(() => shareHistory = value),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: session!.invitation),
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Pairing invitation copied'),
                      ),
                    );
                  }
                },
                icon: const Icon(Icons.copy),
                label: const Text('Copy invitation'),
              ),
              const Text(
                'Keep this screen open. You’ll approve the new device here after comparing the code.',
              ),
            ] else
              FilledButton(
                onPressed: start,
                child: const Text('Create a new invitation'),
              ),
          ],
        ),
      ),
    ),
  );
}
