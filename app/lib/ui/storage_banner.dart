import 'package:flutter/material.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';

import 'map_page.dart' show bytesText;
import 'sync_health.dart';

const _gib = 1024 * 1024 * 1024;

/// What the storage line in Settings says.
String storageSummary(Store store) =>
    '${bytesText(store.storedBytes)} used · warns at '
    '${bytesText(store.storageWarning)} · limit ${bytesText(store.storageLimit)}';

/// A size in GB as typed, or null when it is not a positive number.
int? gigabytes(String text) {
  final value = double.tryParse(text.trim());
  return value == null || value <= 0 ? null : (value * _gib).round();
}

/// The size [bytes] as it is typed into the GB prompts.
String gigabytesText(int bytes) {
  final value = bytes / _gib;
  return value == value.roundToDouble()
      ? value.round().toString()
      : value.toStringAsFixed(2);
}

/// Shown when this device stores more than its storage warning, and
/// whenever it has reached the storage limit, past which friends' messages,
/// posts and files are refused.
class StorageBanner extends StatefulWidget {
  final PeerNetwork network;
  final VoidCallback openSettings;
  const StorageBanner({
    super.key,
    required this.network,
    required this.openSettings,
  });

  @override
  State<StorageBanner> createState() => _StorageBannerState();
}

class _StorageBannerState extends State<StorageBanner> {
  /// Storage in use when the warning was put off. It returns once another
  /// GB has been stored.
  static const _dismissed = 'storageWarningDismissed';

  @override
  Widget build(BuildContext context) => NetworkHealthBuilder(
    network: widget.network,
    builder: (context) {
      final store = widget.network.node.store;
      // Two counters kept by trigger: no scan, however much is stored.
      final used = store.storedBytes;
      final limit = store.storageLimit;
      final full = used >= limit;
      final dismissed = store.setting(_dismissed);
      if (!full &&
          (used < store.storageWarning ||
              (dismissed is int && used < dismissed + _gib))) {
        return const SizedBox.shrink();
      }
      return MaterialBanner(
        key: const Key('storage-banner'),
        leading: Icon(full ? Icons.error_outline : Icons.storage),
        content: Text(
          full
              ? 'OurNet has reached its storage limit of ${bytesText(limit)} '
                    'on this device. New messages, posts and files from '
                    'friends are not being received.'
              : 'OurNet is storing ${bytesText(used)} on this device. It '
                    'stops receiving from friends at ${bytesText(limit)}.',
        ),
        actions: [
          if (!full)
            TextButton(
              onPressed: () => setState(() => store.set(_dismissed, used)),
              child: const Text('Not now'),
            ),
          FilledButton.tonal(
            onPressed: widget.openSettings,
            child: const Text('Storage settings'),
          ),
        ],
      );
    },
  );
}
