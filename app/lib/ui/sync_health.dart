import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ournet_transport/ournet_transport.dart';

import 'sync_status.dart' show syncAge;

enum HealthLevel { ok, syncing, waiting, warning, error, offline }

/// What the app can say about one device, or about sync as a whole.
typedef Health = ({HealthLevel level, String headline, List<String> details});

/// A sync that fails for this long, or that never succeeded, is an error
/// rather than a passing delay.
const _stale = Duration(hours: 12);

/// Turns transport failures into something a person can act on. [order]
/// compares the other device's release with this one's, when both are known.
String friendlySyncError(String error, {int? order}) {
  if (error.contains('TimeoutException')) {
    return 'No response. It may be closed, asleep or offline.';
  }
  if (error.contains('Device not admitted')) {
    return 'It does not recognise this device yet. Add this device there too.';
  }
  if (error.contains('Network is stopped')) return 'Networking is off here.';
  if (error.contains('Unsupported protocol') ||
      error.contains('Unknown request')) {
    return switch (order) {
      final o? when o > 0 =>
        'It runs a newer OurNet that this one can’t sync with. Update OurNet here.',
      final o? when o < 0 =>
        'It runs an older OurNet that can’t sync with this one. Update OurNet there.',
      _ => 'It runs an incompatible version. Update both devices.',
    };
  }
  if (error.contains('SocketException') ||
      error.contains('Network is unreachable')) {
    return 'This device has no network connection.';
  }
  final text = error
      .replaceFirst(
        RegExp(r'^(Bad state|Exception|StateError|IrohAcceptException): '),
        '',
      )
      .trim();
  return text.length > 120 ? '${text.substring(0, 117)}…' : text;
}

String _label(PeerNetwork network, String device) =>
    network.node.contacts[device]?.label ?? 'Device';

String _ago(DateTime time, DateTime now) => syncAge(now.difference(time));

/// Health of the exchange with one contact device.
Health deviceHealth(PeerNetwork network, String device, {DateTime? now}) {
  now ??= DateTime.now();
  final label = _label(network, device);
  final synced = network.lastSync[device];
  final error = network.syncErrors[device];
  final inbound = network.lastInbound[device];
  final details = <String>[
    if (synced != null) 'Last synced ${_ago(synced, now)}' else 'Never synced',
    if (inbound != null) 'Last reached this device ${_ago(inbound, now)}',
    ?buildNote(network, device),
  ];
  if (!network.running) {
    return (
      level: HealthLevel.offline,
      headline: 'Networking is off',
      details: details,
    );
  }
  if (network.syncing.containsKey(device)) {
    final items = network.syncing[device] ?? 0;
    return (
      level: HealthLevel.syncing,
      headline: items > 0 ? 'Syncing · $items exchanged' : 'Syncing…',
      details: details,
    );
  }
  if (error != null) {
    final failing = synced == null || now.difference(synced) > _stale;
    return (
      level: failing ? HealthLevel.error : HealthLevel.warning,
      headline: 'Can’t reach $label',
      details: [
        friendlySyncError(error, order: releaseOrder(network, device)),
        ...details,
        'Retrying automatically',
      ],
    );
  }
  if (synced == null) {
    return (
      level: HealthLevel.waiting,
      headline: 'Waiting to sync',
      details: details,
    );
  }
  return (
    level: HealthLevel.ok,
    headline: 'Synced ${_ago(synced, now)}',
    details: details.skip(1).toList(),
  );
}

/// Compares x.y.z release versions; null when either is not one.
int? compareReleases(String a, String b) {
  List<int>? parse(String v) {
    final parts = v.split('.').map(int.tryParse).toList();
    return parts.length == 3 && !parts.contains(null)
        ? parts.cast<int>()
        : null;
  }

  final (x, y) = (parse(a), parse(b));
  if (x == null || y == null) return null;
  for (var i = 0; i < 3; i++) {
    if (x[i] != y[i]) return x[i].compareTo(y[i]);
  }
  return 0;
}

/// Whether a device runs a newer (positive) or older (negative) release
/// than this one; null when it has not said.
int? releaseOrder(PeerNetwork network, String device) {
  final theirs = network.peerVersions[device];
  return theirs == null ? null : compareReleases(theirs, network.version);
}

/// A note when a device runs a different release from this one. Builds of
/// one release differ per platform, so they are compared only when a device
/// predates version reporting.
String? buildNote(PeerNetwork network, String device) {
  final order = releaseOrder(network, device);
  if (order != null) {
    if (order == 0) return null;
    return 'Runs OurNet ${network.peerVersions[device]}, '
        '${order > 0 ? 'newer' : 'older'} than this one';
  }
  final theirs = network.peerBuilds[device];
  if (theirs == null || network.build.isEmpty) return null;
  if (theirs == network.build) return null;
  final newer = theirs.compareTo(network.build) > 0;
  return 'Runs build $theirs, ${newer ? 'newer' : 'older'} than this one';
}

/// The newest release any contact's device runs, if newer than this one.
String? newerRelease(PeerNetwork network) {
  String? newest;
  for (final v in network.peerVersions.values) {
    if ((compareReleases(v, newest ?? network.version) ?? 0) > 0) newest = v;
  }
  return newest;
}

/// Devices whose health reaches the status bar: this person's other
/// devices. Friends' phones are often offline; their rows say so instead.
Iterable<String> _watched(PeerNetwork network) => network.node.contacts.values
    .where((c) => c.person == network.node.person)
    .map((c) => c.device)
    .where(network.node.allowedPeer);

/// One line for the whole app: the worst device, relay trouble, or all good.
Health overallHealth(PeerNetwork network, {DateTime? now}) {
  now ??= DateTime.now();
  if (!network.running) {
    return (
      level: HealthLevel.offline,
      headline: network.error == null
          ? 'Offline · local data available'
          : 'Network unavailable · local data available',
      details: [?network.error],
    );
  }
  final devices = _watched(network).toList();
  final health = {
    for (final d in devices) d: deviceHealth(network, d, now: now),
  };
  final syncing = health.values
      .where((h) => h.level == HealthLevel.syncing)
      .length;
  if (syncing > 0) {
    return (
      level: HealthLevel.syncing,
      headline: 'Syncing with $syncing device${syncing == 1 ? '' : 's'}…',
      details: const [],
    );
  }
  for (final level in [HealthLevel.error, HealthLevel.warning]) {
    final failing = [
      for (final MapEntry(:key, :value) in health.entries)
        if (value.level == level) _label(network, key),
    ];
    if (failing.isNotEmpty) {
      return (
        level: level,
        headline: failing.length == 1
            ? 'Can’t reach ${failing.single}'
            : 'Can’t reach ${failing.length} devices',
        details: failing,
      );
    }
  }
  final relays = network.relays;
  if (!network.local && relays.isNotEmpty && !relays.any((r) => r.connected)) {
    return (
      level: HealthLevel.warning,
      headline: 'No relay · only devices on this network can connect',
      details: [for (final r in relays) ?r.error],
    );
  }
  if (devices.isEmpty) {
    return (
      level: HealthLevel.ok,
      headline: 'Connected · no other devices of yours',
      details: const [],
    );
  }
  DateTime? latest;
  for (final d in devices) {
    final synced = network.lastSync[d];
    if (synced != null && (latest == null || synced.isAfter(latest))) {
      latest = synced;
    }
  }
  final waiting = health.values
      .where((h) => h.level == HealthLevel.waiting)
      .length;
  if (latest == null) {
    return (
      level: HealthLevel.waiting,
      headline: 'Connected · waiting to sync',
      details: const [],
    );
  }
  return (
    level: waiting > 0 ? HealthLevel.waiting : HealthLevel.ok,
    headline: waiting > 0
        ? 'Synced ${_ago(latest, now)} · $waiting waiting'
        : 'Synced ${_ago(latest, now)}',
    details: const [],
  );
}

Color healthColor(BuildContext context, HealthLevel level) {
  final scheme = Theme.of(context).colorScheme;
  return switch (level) {
    HealthLevel.ok => Colors.teal,
    HealthLevel.syncing => scheme.primary,
    HealthLevel.waiting => scheme.outline,
    HealthLevel.warning => Colors.amber.shade800,
    HealthLevel.error => scheme.error,
    HealthLevel.offline => Colors.grey,
  };
}

IconData healthIcon(HealthLevel level) => switch (level) {
  HealthLevel.ok => Icons.check_circle_outline,
  HealthLevel.syncing => Icons.sync,
  HealthLevel.waiting => Icons.schedule,
  HealthLevel.warning => Icons.warning_amber_rounded,
  HealthLevel.error => Icons.error_outline,
  HealthLevel.offline => Icons.cloud_off_outlined,
};

/// Rebuilds on network changes, sync progress and the passing of time.
class NetworkHealthBuilder extends StatefulWidget {
  final PeerNetwork network;
  final Widget Function(BuildContext context) builder;
  const NetworkHealthBuilder({
    super.key,
    required this.network,
    required this.builder,
  });
  @override
  State<NetworkHealthBuilder> createState() => _NetworkHealthBuilderState();
}

class _NetworkHealthBuilderState extends State<NetworkHealthBuilder> {
  final _subscriptions = <StreamSubscription<void>>[];
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    void refresh(_) {
      if (mounted) setState(() {});
    }

    _subscriptions
      ..add(widget.network.updates.stream.listen(refresh))
      ..add(widget.network.syncActivity.stream.listen(refresh));
    // Keeps "n min ago" current.
    _clock = Timer.periodic(const Duration(seconds: 30), refresh);
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    _clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

/// The app-wide status line: a coloured dot and the most important fact.
class SyncHealthLine extends StatelessWidget {
  final PeerNetwork network;
  const SyncHealthLine({super.key, required this.network});

  @override
  Widget build(BuildContext context) => NetworkHealthBuilder(
    network: network,
    builder: (context) {
      final health = overallHealth(network);
      final colour = healthColor(context, health.level);
      return Row(
        children: [
          Icon(
            health.level == HealthLevel.offline
                ? Icons.circle_outlined
                : Icons.circle,
            size: 10,
            color: colour,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              health.headline,
              key: const Key('sync-health-line'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color:
                    health.level == HealthLevel.error ||
                        health.level == HealthLevel.warning
                    ? colour
                    : null,
              ),
            ),
          ),
        ],
      );
    },
  );
}

/// Status and details for one device, for use as a list tile subtitle.
class DeviceHealthText extends StatelessWidget {
  final PeerNetwork network;
  final String device;

  /// Shown before the status, e.g. a shortened device ID.
  final String? prefix;
  const DeviceHealthText({
    super.key,
    required this.network,
    required this.device,
    this.prefix,
  });

  @override
  Widget build(BuildContext context) => NetworkHealthBuilder(
    network: network,
    builder: (context) {
      final health = deviceHealth(network, device);
      final colour = healthColor(context, health.level);
      final style = Theme.of(context).textTheme.bodySmall;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(healthIcon(health.level), size: 14, color: colour),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  [?prefix, health.headline].join(' · '),
                  style: style?.copyWith(
                    color: health.level == HealthLevel.ok ? null : colour,
                  ),
                ),
              ),
            ],
          ),
          for (final line in health.details) Text(line, style: style),
        ],
      );
    },
  );
}

/// This device's side of connectivity: mode, relays and inbound connections.
class ConnectionHealthCard extends StatelessWidget {
  final PeerNetwork network;
  final Future<void> Function() onRestart;
  const ConnectionHealthCard({
    super.key,
    required this.network,
    required this.onRestart,
  });

  @override
  Widget build(BuildContext context) => NetworkHealthBuilder(
    network: network,
    builder: (context) {
      final overall = overallHealth(network);
      final colour = healthColor(context, overall.level);
      final style = Theme.of(context).textTheme.bodySmall;
      final relays = network.relays;
      final connectedRelays = relays.where((r) => r.connected).length;
      final lines = <String>[
        if (!network.running)
          network.error ?? 'Networking is off'
        else if (network.local)
          'Local mode · only devices on this network can connect'
        else if (relays.isEmpty)
          'Internet mode · connecting to a relay…'
        else
          'Internet mode · relay ${connectedRelays > 0 ? 'connected' : 'unavailable'}',
        for (final r in relays)
          if (!r.connected && r.error != null) 'Relay: ${r.error}',
        if (network.running && network.acceptFailures > 0)
          '${network.acceptFailures} incoming connection'
              '${network.acceptFailures == 1 ? '' : 's'} failed'
              '${network.lastAcceptError == null ? '' : ' · ${friendlySyncError(network.lastAcceptError!)}'}',
        if (network.build.isNotEmpty) 'This device runs build ${network.build}',
        if (newerRelease(network) case final v?)
          'A contact runs OurNet $v, newer than this one',
      ];
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(healthIcon(overall.level), color: colour),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      overall.headline,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    for (final line in lines) Text(line, style: style),
                  ],
                ),
              ),
              TextButton(
                onPressed: onRestart,
                child: Text(network.running ? 'Reconnect' : 'Connect'),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Sync health for diagnostics; device IDs are shortened, nothing secret.
Map<String, Object?> syncDiagnostics(PeerNetwork network) => {
  'mode': network.local ? 'local' : 'internet',
  'relays': [
    for (final r in network.relays)
      {'url': r.url, 'connected': r.connected, 'error': r.error},
  ],
  'acceptFailures': network.acceptFailures,
  'lastAcceptError': network.lastAcceptError,
  'devices': [
    for (final device in network.node.contacts.keys)
      {
        'device': device.substring(0, 8),
        'label': _label(network, device),
        'lastSync': network.lastSync[device]?.toIso8601String(),
        'lastAttempt': network.lastAttempt[device]?.toIso8601String(),
        'lastInbound': network.lastInbound[device]?.toIso8601String(),
        'error': network.syncErrors[device],
        'build': network.peerBuilds[device],
        'version': network.peerVersions[device],
      },
  ],
};
