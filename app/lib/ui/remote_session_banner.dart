import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ournet_core/ournet_core.dart';

/// Shown on every page while another of this person's devices is watching
/// or controlling this one through a plugin (Device Dashboard, Remote
/// Input), with the local session log and a way to stop it here.
class RemoteSessionBanner extends StatefulWidget {
  final Plugins plugins;
  const RemoteSessionBanner({super.key, required this.plugins});

  @override
  State<RemoteSessionBanner> createState() => _RemoteSessionBannerState();
}

class _RemoteSessionBannerState extends State<RemoteSessionBanner> {
  StreamSubscription<void>? _changes;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(RemoteSessionBanner old) {
    super.didUpdateWidget(old);
    if (old.plugins != widget.plugins) {
      _changes?.cancel();
      _listen();
    }
  }

  void _listen() => _changes = widget.plugins.remoteChanges.listen((_) {
    if (mounted) setState(() {});
  });

  @override
  void dispose() {
    _changes?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sessions = widget.plugins.remoteSessions;
    if (sessions.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final controlling = sessions.any((s) => s.controlling);
    final names = {
      for (final s in sessions) widget.plugins.deviceName(s.device),
    }.join(', ');
    final what = {
      for (final s in sessions)
        widget.plugins[s.plugin]?.manifest.name ?? s.plugin,
    }.join(', ');
    return Material(
      color: controlling ? scheme.errorContainer : scheme.tertiaryContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
          child: Row(
            children: [
              Icon(
                controlling ? Icons.mouse_outlined : Icons.visibility_outlined,
                color: controlling
                    ? scheme.onErrorContainer
                    : scheme.onTertiaryContainer,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${controlling ? 'Being controlled' : 'Being viewed'} by $names',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Text(what, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              TextButton(
                onPressed: () => showRemoteLog(context, widget.plugins),
                child: const Text('Log'),
              ),
              FilledButton.tonal(
                onPressed: () => widget.plugins.stopRemoteSessions(),
                child: const Text('Stop'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The local log of remote sessions and remote process ends: kept in
/// memory on this device, never in shared history.
Future<void> showRemoteLog(BuildContext context, Plugins plugins) =>
    showDialog<void>(
      context: context,
      builder: (context) {
        final log = plugins.remoteLog;
        String time(DateTime t) =>
            '${t.hour.toString().padLeft(2, '0')}:'
            '${t.minute.toString().padLeft(2, '0')}:'
            '${t.second.toString().padLeft(2, '0')}';
        return AlertDialog(
          title: const Text('Remote sessions'),
          content: SizedBox(
            width: 420,
            height: 360,
            child: log.isEmpty
                ? const Center(
                    child: Text('No remote sessions since OurNet started'),
                  )
                : ListView.builder(
                    itemCount: log.length,
                    itemBuilder: (context, i) {
                      final e = log[i];
                      return ListTile(
                        dense: true,
                        leading: Text(time(e.at)),
                        title: Text(e.text),
                        subtitle: Text(
                          '${plugins.deviceName(e.device)} · '
                          '${plugins[e.plugin]?.manifest.name ?? e.plugin}',
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            Text(
              'Kept on this device only, until OurNet closes.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
