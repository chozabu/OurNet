import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';
import '../services/pairing_discovery.dart';

/// Returned when a friendship completes and the person chose a next step.
class FriendAdded {
  final String person;
  final bool shareNote;
  const FriendAdded(this.person, {this.shareNote = false});
}

/// One screen for both people: one shows an invitation (QR, copied text and
/// same-Wi-Fi discovery), the other finds, scans or pastes it. The inviting
/// device approves after comparing a code. An open invitation keeps working if
/// this screen is left: approval appears over whatever is open.
class FriendInvitePage extends StatefulWidget {
  final PeerNetwork network;
  final bool enablePlatform;
  final String Function(String person)? personName;

  /// Offer "Start a shared note" once connected.
  final bool offerSharedNote;
  const FriendInvitePage({
    super.key,
    required this.network,
    this.enablePlatform = true,
    this.personName,
    this.offerSharedNote = false,
  });
  @override
  State<FriendInvitePage> createState() => _FriendInvitePageState();
}

/// Beacon for the open invitation; outlives the page with the invitation.
RawDatagramSocket? _friendBeacon;

class _FriendInvitePageState extends State<FriendInvitePage> {
  final input = TextEditingController();
  FriendSession? invitation;
  Timer? timer;
  String mode = 'show';
  String? error, joining, code;
  String? friend;
  bool busy = false, searching = false;
  List<String> nearby = [];
  int searchGeneration = 0;
  PeerNetwork get network => widget.network;

  @override
  void initState() {
    super.initState();
    final open = network.friendInvitation;
    if (open != null && open.available) invitation = open;
    timer = Timer.periodic(const Duration(seconds: 1), (_) => tick());
    if (widget.enablePlatform && invitation == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => act(create));
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    searchGeneration++;
    input.dispose();
    super.dispose();
  }

  void tick() {
    if (!mounted) return;
    final session = invitation;
    if (session != null && !session.available) {
      final person = session.acceptedPeer == null
          ? null
          : network.node.contacts[session.acceptedPeer]?.person;
      _friendBeacon?.close();
      _friendBeacon = null;
      if (person != null) {
        setState(() {
          friend = person;
          invitation = null;
        });
        return;
      }
      // Expired while visible: quietly offer a fresh one.
      invitation = null;
      if (mode == 'show' && !busy && widget.enablePlatform) {
        unawaited(act(create));
      }
    }
    setState(() {});
  }

  Future<void> act(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => error = '$e'.replaceFirst('Bad state: ', ''));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String nameOf(String person, [String? fallback]) {
    final name = widget.personName?.call(person);
    return name == null || name.length > 14 && name.contains('…')
        ? fallback ?? name ?? 'your friend'
        : name;
  }

  Future<void> create() async {
    if (!widget.enablePlatform) {
      throw StateError('Invitations require a network connection.');
    }
    await network.start();
    if (!mounted) return;
    // Approval shows over any screen, so leaving this page keeps it usable.
    final navigator = Navigator.of(context, rootNavigator: true).context;
    final messenger = ScaffoldMessenger.maybeOf(context);
    invitation?.close();
    final session = FriendSession(network, (cert, code) async {
      if (!navigator.mounted) return false;
      BuildContext? dialogContext;
      final expiry = Timer(const Duration(seconds: 80), () {
        if (dialogContext?.mounted == true) {
          Navigator.pop(dialogContext!, false);
        }
      });
      final approved = await showDialog<bool>(
        context: navigator,
        builder: (context) {
          dialogContext = context;
          return AlertDialog(
            title: Text('Connect with ${cert.label}?'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Check that your friend sees this same code:'),
                const SizedBox(height: 12),
                Center(child: CodeText(code)),
                const SizedBox(height: 12),
                const Text(
                  'This adds a friend. Your private notes and drive stay private.',
                ),
              ],
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
      if (approved == true && !mounted) {
        messenger?.showSnackBar(
          SnackBar(content: Text('You and ${cert.label} are now friends')),
        );
      }
      return approved == true;
    });
    _friendBeacon?.close();
    _friendBeacon = null;
    try {
      _friendBeacon = await FriendDiscovery.advertise(session);
    } catch (_) {
      // Another invitation window or a restricted network; QR still works.
    }
    if (!mounted) return;
    setState(() => invitation = session);
  }

  Future<void> accept(String text) async {
    final value = text.trim();
    final decoded = jsonDecode(value) as Json;
    if (decoded['friend'] == 1) {
      final data = FriendSession.parse(value);
      if (!widget.enablePlatform) {
        throw StateError('Invitations require a network connection.');
      }
      final owner = DeviceCertificate.fromJson(data['card']['certificate']);
      if (owner.person == network.node.person) {
        throw StateError('That invitation is from your own profile.');
      }
      await network.start();
      if (!mounted) return;
      setState(() {
        joining = owner.label;
        code = FriendSession.code(
          data['token'],
          network.node.identity.certificate,
        );
      });
      try {
        await FriendSession.join(network, value);
      } finally {
        if (mounted) setState(() => code = null);
      }
      if (!mounted) return;
      setState(() {
        friend = owner.person;
        joining = owner.label;
      });
      unawaited(network.syncAll());
    } else {
      await network.addCard(value);
      if (!mounted) return;
      await Clipboard.setData(ClipboardData(text: network.contactCard()));
      setState(
        () => error =
            'Contact added. Your return card is copied; send it to your friend to finish connecting.',
      );
    }
  }

  Future<void> pasteInvitation() async {
    final value = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    try {
      FriendSession.parse(value.trim());
    } catch (_) {
      throw StateError(
        'Copy the invitation your friend sent, then choose Paste again.',
      );
    }
    input.text = value.trim();
    await accept(value);
  }

  Future<void> search() async {
    final generation = ++searchGeneration;
    if (!widget.enablePlatform) return;
    setState(() => searching = true);
    while (mounted && generation == searchGeneration && mode == 'find') {
      try {
        final found = await FriendDiscovery.find(rounds: 2);
        if (!mounted || generation != searchGeneration) return;
        setState(() {
          nearby = found.where((text) {
            try {
              final device = FriendSession.parse(
                text,
              )['card']['certificate']['device'];
              return device != network.node.identity.device;
            } catch (_) {
              return false; // Expired between discovery and display.
            }
          }).toList();
        });
      } catch (_) {
        if (mounted) setState(() => nearby = []);
        return;
      } finally {
        if (mounted && generation == searchGeneration) {
          setState(() => searching = false);
        }
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  void setMode(String next) {
    setState(() {
      mode = next;
      error = null;
    });
    if (next == 'find') {
      unawaited(search());
    } else {
      searchGeneration++;
      if (invitation == null && widget.enablePlatform) unawaited(act(create));
    }
  }

  Widget connected(BuildContext context) {
    final person = friend!;
    final label = nameOf(person, joining);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 24),
        Icon(
          Icons.celebration_outlined,
          size: 56,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(height: 16),
        Text(
          'You and $label are now friends',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        const Text(
          'Your devices sync while both apps are open. Share notes, lists or a private group whenever you like.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        if (widget.offerSharedNote)
          FilledButton.icon(
            onPressed: () =>
                Navigator.pop(context, FriendAdded(person, shareNote: true)),
            icon: const Icon(Icons.note_add_outlined),
            label: const Text('Start a shared note'),
          ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: () => Navigator.pop(context, FriendAdded(person)),
          child: const Text('Done'),
        ),
      ],
    );
  }

  Widget showInvitation(BuildContext context) {
    final session = invitation;
    final remaining = session == null
        ? 0
        : session.expires.difference(DateTime.now()).inSeconds.clamp(0, 300);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Let your friend scan this, or both open Add friend on the same Wi-Fi and they choose Find theirs.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        Center(
          child: Container(
            width: 274,
            height: 274,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            padding: const EdgeInsets.all(12),
            child: session == null
                ? const Center(child: CircularProgressIndicator())
                : QrImageView(data: session.invitation, size: 250),
          ),
        ),
        const SizedBox(height: 8),
        if (session != null) ...[
          Text(
            'Waiting for your friend · ${remaining ~/ 60}:${(remaining % 60).toString().padLeft(2, '0')}',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            children: [
              TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: session.invitation),
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Invitation copied · send it in any message app',
                        ),
                      ),
                    );
                  }
                },
                icon: const Icon(Icons.copy),
                label: const Text('Copy invitation'),
              ),
              TextButton.icon(
                onPressed: busy ? null : () => act(create),
                icon: const Icon(Icons.refresh),
                label: const Text('New invitation'),
              ),
            ],
          ),
          const Text(
            'You can leave this screen. When your friend connects, OurNet asks you to compare a code.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12),
          ),
        ],
      ],
    );
  }

  Widget findInvitation(BuildContext context) {
    final theme = Theme.of(context);
    if (code != null) {
      return Column(
        children: [
          const SizedBox(height: 24),
          Text(
            'Ask ${joining ?? 'your friend'} to check this code',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 16),
          CodeText(code!),
          const SizedBox(height: 16),
          const LinearProgressIndicator(),
          const SizedBox(height: 8),
          const Text('Waiting for them to confirm…'),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('Nearby', style: theme.textTheme.titleSmall),
            const SizedBox(width: 8),
            if (searching)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        if (nearby.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'Looking for friends showing an invitation on this Wi-Fi…',
              style: theme.textTheme.bodySmall,
            ),
          ),
        for (final text in nearby)
          Card(
            child: ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person_outline)),
              title: Text(
                DeviceCertificate.fromJson(
                  jsonDecode(text)['card']['certificate'],
                ).label,
              ),
              subtitle: const Text('Tap to connect'),
              trailing: const Icon(Icons.chevron_right),
              onTap: busy ? null : () => act(() => accept(text)),
            ),
          ),
        const SizedBox(height: 16),
        if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS)
          FilledButton.icon(
            onPressed: busy
                ? null
                : () async {
                    final value = await Navigator.push<String>(
                      context,
                      MaterialPageRoute(builder: (_) => const ScanFriendPage()),
                    );
                    if (value != null && mounted) {
                      input.text = value;
                      await act(() => accept(value));
                    }
                  },
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Scan their QR code'),
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: busy ? null : () => act(pasteInvitation),
          icon: const Icon(Icons.content_paste),
          label: const Text('Paste invitation they sent'),
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Enter a contact card'),
          children: [
            TextField(
              controller: input,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Paste invitation or contact card',
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: busy ? null : () => act(() => accept(input.text)),
                child: const Text('Accept invitation'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Add friend')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (friend != null)
              connected(context)
            else ...[
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: 'show',
                    icon: Icon(Icons.qr_code),
                    label: Text('Show my invitation'),
                  ),
                  ButtonSegment(
                    value: 'find',
                    icon: Icon(Icons.person_search_outlined),
                    label: Text('Find theirs'),
                  ),
                ],
                selected: {mode},
                onSelectionChanged: code != null
                    ? null
                    : (value) => setMode(value.single),
              ),
              const SizedBox(height: 20),
              if (mode == 'show')
                showInvitation(context)
              else
                findInvitation(context),
              if (busy && code == null)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: LinearProgressIndicator(),
                ),
            ],
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: SelectableText(
                  error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

/// A comparison code in large, spaced, monospaced characters.
class CodeText extends StatelessWidget {
  final String code;
  const CodeText(this.code, {super.key});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.secondaryContainer,
      borderRadius: BorderRadius.circular(12),
    ),
    child: SelectableText(
      code.length == 8 ? '${code.substring(0, 4)} ${code.substring(4)}' : code,
      style: const TextStyle(
        fontSize: 30,
        fontFamily: 'monospace',
        letterSpacing: 4,
        fontWeight: FontWeight.w600,
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
