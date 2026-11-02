import 'dart:io';

import 'package:flutter/material.dart';
import 'package:ournet_transport/ournet_transport.dart';
import 'package:url_launcher/url_launcher.dart';

import 'sync_health.dart';

/// Public store listings. The Microsoft Store page is the same URL whether
/// the product is search-visible or link-only; that is set in Partner Center.
const playListing =
    'https://play.google.com/store/apps/details?id=org.chozabu.ournet';
const microsoftStoreId = '9N6P4X13QG9M';
const microsoftListing = 'https://apps.microsoft.com/detail/$microsoftStoreId';

/// Where to check for an update on [os] (`Platform.operatingSystem`), best
/// first: the store app itself, then its web page. Empty when there is no
/// store for this platform.
List<Uri> updateLinks([String? os]) => switch (os ?? Platform.operatingSystem) {
  'android' => [
    Uri.parse('market://details?id=org.chozabu.ournet'),
    Uri.parse(playListing),
  ],
  'windows' => [
    Uri.parse('ms-windows-store://pdp/?ProductId=$microsoftStoreId'),
    Uri.parse(microsoftListing),
  ],
  _ => const [],
};

/// Opens the first of [links] that launches.
Future<bool> openUpdateLink(List<Uri> links) async {
  for (final link in links) {
    final ok = await launchUrl(
      link,
      mode: LaunchMode.externalApplication,
    ).catchError((Object _) => false);
    if (ok) return true;
  }
  return false;
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
      final links = updateLinks();
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
          if (links.isNotEmpty)
            FilledButton.tonal(
              onPressed: () => openUpdateLink(links),
              child: const Text('Check for update'),
            ),
        ],
      );
    },
  );
}
