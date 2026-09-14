import 'dart:async';
import 'package:flutter/material.dart';
import 'package:ournet_transport/ournet_transport.dart';

/// Live sync line: progress while syncing, otherwise when sync last completed.
/// Listens to [PeerNetwork.syncActivity] so progress rebuilds only this text.
class SyncStatus extends StatefulWidget {
  final PeerNetwork network;

  /// People whose devices matter here; null means every contact device.
  final Iterable<String>? people;
  final String offline, prefix, suffix;
  final TextStyle? style;
  const SyncStatus({
    super.key,
    required this.network,
    this.people,
    this.offline = 'Saved locally · transfers resume when connected',
    this.prefix = '',
    this.suffix = '',
    this.style,
  });
  @override
  State<SyncStatus> createState() => _SyncStatusState();
}

String syncAge(Duration age) => age.inSeconds < 60
    ? 'just now'
    : age.inMinutes < 60
    ? '${age.inMinutes} min ago'
    : age.inHours < 24
    ? '${age.inHours} h ago'
    : '${age.inDays} d ago';

class _SyncStatusState extends State<SyncStatus> {
  StreamSubscription<void>? activity;
  Timer? clock;
  @override
  void initState() {
    super.initState();
    activity = widget.network.syncActivity.stream.listen((_) {
      if (mounted) setState(() {});
    });
    // Keeps "n min ago" current without touching the rest of the page.
    clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    activity?.cancel();
    clock?.cancel();
    super.dispose();
  }

  bool relevant(String device) {
    final people = widget.people;
    if (people == null) return true;
    final node = widget.network.node;
    final person = node.contacts[device]?.person;
    return person == node.person || people.contains(person);
  }

  String describe() {
    final network = widget.network;
    if (!network.running) return widget.offline;
    final syncing = network.syncing.entries.where((e) => relevant(e.key));
    if (syncing.isNotEmpty) {
      final devices = syncing.length;
      final items = syncing.fold(0, (sum, e) => sum + e.value);
      return 'Syncing with $devices device${devices == 1 ? '' : 's'}…'
          '${items > 0 ? ' · $items item${items == 1 ? '' : 's'} exchanged' : ''}';
    }
    DateTime? latest;
    for (final entry in network.lastSync.entries) {
      if (relevant(entry.key) &&
          (latest == null || entry.value.isAfter(latest))) {
        latest = entry.value;
      }
    }
    if (latest == null) return 'Not yet synced';
    return 'Last synced ${syncAge(DateTime.now().difference(latest))}';
  }

  @override
  Widget build(BuildContext context) => Text(
    widget.network.running
        ? '${widget.prefix}${describe()}${widget.suffix}'
        : widget.offline,
    style: widget.style,
  );
}
