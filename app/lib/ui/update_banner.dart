import 'dart:io';

import 'package:flutter/material.dart';
import 'package:ournet_transport/ournet_transport.dart';
import 'package:url_launcher/url_launcher.dart';

import 'sync_health.dart';

/// Where this platform's builds come from, or null when there is no store.
Uri? updateLink() {
  if (Platform.isAndroid) {
    return Uri.parse(
      'https://play.google.com/apps/internaltest/4701143104149213002',
    );
  }
  if (Platform.isWindows) {
    return Uri.parse('https://apps.microsoft.com/detail/9N6P4X13QG9M');
  }
  return null;
}

/// What the banner says about the device that showed a newer release exists.
String updateMessage({
  required String version,
  required String device,
  required String person,
  required bool own,
}) =>
    'OurNet $version is out: we heard from '
    '${own ? 'your device $device' : '$person on $device'}. '
    'Check for an update.';

/// Says an update exists once a contact's device reports a newer release.
/// There is no update server: friends' devices are how news arrives.
/// Dismissing hides that release until a newer one turns up.
class UpdateBanner extends StatefulWidget {
  final PeerNetwork network;
  final String Function(String person) nameOf;
  const UpdateBanner({super.key, required this.network, required this.nameOf});

  @override
  State<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends State<UpdateBanner> {
  static const _dismissed = 'updateDismissed';

  PeerNetwork get network => widget.network;

  @override
  Widget build(BuildContext context) => NetworkHealthBuilder(
    network: network,
    builder: (context) {
      final source = updateSource(network);
      if (source == null) return const SizedBox.shrink();
      final version = network.peerVersions[source.device]!;
      final dismissed = network.node.store.setting(_dismissed);
      if (dismissed is String &&
          (compareReleases(version, dismissed) ?? 1) <= 0) {
        return const SizedBox.shrink();
      }
      final link = updateLink();
      return MaterialBanner(
        key: const Key('update-banner'),
        leading: const Icon(Icons.system_update),
        content: Text(
          updateMessage(
            version: version,
            device: source.label,
            person: widget.nameOf(source.person),
            own: source.person == network.node.person,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () =>
                setState(() => network.node.store.set(_dismissed, version)),
            child: const Text('Not now'),
          ),
          if (link != null)
            FilledButton.tonal(
              onPressed: () => launchUrl(
                link,
                mode: LaunchMode.externalApplication,
              ).catchError((Object _) => false),
              child: const Text('Check for update'),
            ),
        ],
      );
    },
  );
}
