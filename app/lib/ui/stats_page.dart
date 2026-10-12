import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ournet_transport/ournet_transport.dart';

import 'stats_widgets.dart';
import 'sync_status.dart' show syncAge;

/// Live bandwidth, totals and the health of the connections, from the
/// counters in [PeerNetwork.traffic].
class StatsPage extends StatefulWidget {
  final PeerNetwork network;

  /// Who a device belongs to, as the app names it.
  final String Function(String device) deviceName;
  const StatsPage({super.key, required this.network, required this.deviceName});

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  StreamSubscription<void>? _ticks;
  void Function()? _release;
  bool lifetime = false;

  TrafficStats get traffic => widget.network.traffic;

  @override
  void initState() {
    super.initState();
    _release = traffic.watch();
    _ticks = traffic.ticks.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    unawaited(_ticks?.cancel());
    _release?.call();
    super.dispose();
  }

  static const _typeNames = {
    'pull': 'Sync: fetch changes',
    'push': 'Sync: send changes',
    'delta': 'Sync: catch up',
    'blob': 'File chunk',
    'blobs': 'File chunks',
    'typing': 'Typing hints',
    'position': 'Shared locations',
    'groupcall': 'Group calls',
    'signal': 'Calls',
    'friend': 'Friend invitations',
    'pair': 'Device pairing',
    'other': 'Other',
  };

  static String _day(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = StatColors.of(context);
    final net = widget.network;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          children: [
            Row(
              children: [
                Expanded(child: Text('Network stats', style: theme.textTheme.headlineSmall)),
                _StatusChip(running: net.running, local: net.local),
              ],
            ),
            const SizedBox(height: 12),
            _live(context, colors),
            _totals(context, colors),
            _days(context, colors),
            _devices(context, colors),
            _types(context, colors),
            _health(context, colors),
            Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (c) => AlertDialog(
                        title: const Text('Reset network totals?'),
                        content: const Text(
                          'Clears the all-time counters, daily history and per-device figures. '
                          'Nothing else changes.',
                        ),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Reset')),
                        ],
                      ),
                    );
                    if (ok == true) setState(traffic.reset);
                  },
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('Reset totals'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _live(BuildContext context, StatColors colors) {
    final theme = Theme.of(context);
    final rate = traffic.rate;
    final down = [for (final r in traffic.history) r.rx];
    final up = [for (final r in traffic.history) r.tx];
    double peak(List<double> v) => v.isEmpty ? 0 : v.reduce((a, b) => a > b ? a : b);
    Widget big(String label, double value, Color color, IconData icon) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 4),
              Text(label, style: theme.textTheme.labelLarge?.copyWith(color: color)),
            ],
          ),
          Text(
            rateText(value),
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
    return StatSection(
      title: 'Live bandwidth',
      subtitle: 'Everything on the wire, last ${TrafficStats.historyLength ~/ 60} minutes',
      child: Column(
        children: [
          Row(
            children: [
              big('Download', rate.rx, colors.download, Icons.arrow_downward),
              big('Upload', rate.tx, colors.upload, Icons.arrow_upward),
            ],
          ),
          const SizedBox(height: 12),
          RateChart(
            down: down,
            up: up,
            length: TrafficStats.historyLength,
            downColor: colors.download,
            upColor: colors.upload,
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('2 min ago', style: theme.textTheme.labelSmall),
              Text(
                'peak ↓ ${rateText(peak(down))} · ↑ ${rateText(peak(up))}',
                style: theme.textTheme.labelSmall,
              ),
              Text('now', style: theme.textTheme.labelSmall),
            ],
          ),
        ],
      ),
    );
  }

  Widget _totals(BuildContext context, StatColors colors) {
    final theme = Theme.of(context);
    final wire = traffic.wireNow(session: !lifetime);
    final payload = lifetime ? traffic.payload : traffic.sessionPayload;
    final overhead = payload.total == 0 ? 0.0 : (wire.total - payload.total) / payload.total;
    return StatSection(
      title: 'Totals',
      subtitle: lifetime
          ? 'Since ${traffic.since.day}/${traffic.since.month}/${traffic.since.year}'
          : 'This session, ${durationText(DateTime.now().difference(traffic.started))}',
      trailing: SegmentedButton<bool>(
        showSelectedIcon: false,
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
        segments: const [
          ButtonSegment(value: false, label: Text('Session')),
          ButtonSegment(value: true, label: Text('All time')),
        ],
        selected: {lifetime},
        onSelectionChanged: (s) => setState(() => lifetime = s.first),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FigureGrid([
            Figure(value: sizeText(wire.rx), label: 'downloaded', color: colors.download, icon: Icons.arrow_downward),
            Figure(value: sizeText(wire.tx), label: 'uploaded', color: colors.upload, icon: Icons.arrow_upward),
            Figure(value: sizeText(wire.total), label: 'total on the wire', icon: Icons.swap_vert),
            Figure(value: countText(payload.n), label: 'requests', icon: Icons.sync_alt),
          ]),
          const SizedBox(height: 14),
          SegmentedBar(
            segments: [
              (value: wire.rx.toDouble(), color: colors.download),
              (value: wire.tx.toDouble(), color: colors.upload),
            ],
            height: 10,
          ),
          const SizedBox(height: 10),
          Text(
            'Content moved: ${sizeText(payload.rx)} in, ${sizeText(payload.tx)} out. '
            '${payload.total == 0 ? '' : overhead >= 0 ? 'Encryption and protocol add about ${percentText(overhead)}.' : ''}',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _days(BuildContext context, StatColors colors) {
    final now = DateTime.now();
    final bars = <({String label, double a, double b})>[];
    var total = 0;
    for (var i = 13; i >= 0; i--) {
      final d = DateTime(now.year, now.month, now.day - i);
      final day = traffic.days[_day(d)];
      // The wire is more complete; use content bytes where it has not been counted yet.
      final rx = day == null ? 0 : (day.wireRx > 0 ? day.wireRx : day.payloadRx);
      final tx = day == null ? 0 : (day.wireTx > 0 ? day.wireTx : day.payloadTx);
      total += rx + tx;
      bars.add((label: '${d.day}', a: tx.toDouble(), b: rx.toDouble()));
    }
    return StatSection(
      title: 'Last 14 days',
      subtitle: '${sizeText(total)} in two weeks · connections count once they close',
      child: Column(
        children: [
          StackedBars(bars: bars, aColor: colors.upload, bColor: colors.download),
          const SizedBox(height: 8),
          Wrap(
            spacing: 16,
            children: [
              LegendDot(color: colors.download, label: 'Download'),
              LegendDot(color: colors.upload, label: 'Upload'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _devices(BuildContext context, StatColors colors) {
    final net = widget.network;
    final entries = traffic.devices.entries.toList()
      ..sort((a, b) {
        final x = a.value.wire.total + a.value.payload.total;
        final y = b.value.wire.total + b.value.payload.total;
        return y.compareTo(x);
      });
    final peak = entries.isEmpty
        ? 1
        : entries.first.value.wire.total > 0
        ? entries.first.value.wire.total
        : entries.first.value.payload.total;
    return StatSection(
      title: 'By device',
      subtitle: 'All-time traffic with each device',
      child: entries.isEmpty
          ? const Text('Nothing exchanged yet.')
          : Column(
              children: [
                for (final (i, e) in entries.take(12).indexed)
                  () {
                    final d = e.value;
                    final w = d.wire.total > 0 ? d.wire : d.payload;
                    final latency = d.latencyMs;
                    final synced = net.lastSync[e.key];
                    return BarRow(
                      label: widget.deviceName(e.key),
                      value: sizeText(w.total),
                      fraction: peak == 0 ? 0 : w.total / peak,
                      color: colors.series[i % colors.series.length],
                      detail: '↓ ${sizeText(w.rx)} · ↑ ${sizeText(w.tx)} · '
                          '${countText(d.payload.n)} requests'
                          '${latency == null ? '' : ' · ${latency.round()} ms'}'
                          '${synced == null ? '' : ' · synced ${syncAge(DateTime.now().difference(synced))}'}',
                    );
                  }(),
              ],
            ),
    );
  }

  Widget _types(BuildContext context, StatColors colors) {
    Widget table(String title, Map<String, Flow> map) {
      final rows = map.entries.toList()..sort((a, b) => b.value.total.compareTo(a.value.total));
      final peak = rows.isEmpty ? 1 : rows.first.value.total;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.labelLarge),
          if (rows.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Text('–')),
          for (final (i, e) in rows.take(8).indexed)
            BarRow(
              label: _typeNames[e.key] ?? e.key,
              value: sizeText(e.value.total),
              fraction: peak == 0 ? 0 : e.value.total / peak,
              color: colors.series[i % colors.series.length],
              detail: '${countText(e.value.n)} × · ↓ ${sizeText(e.value.rx)} · ↑ ${sizeText(e.value.tx)}',
            ),
        ],
      );
    }

    return StatSection(
      title: 'By request',
      subtitle: 'Content bytes, before encryption overhead',
      child: Column(
        children: [
          table('You asked', traffic.requestsOut),
          const SizedBox(height: 14),
          table('Friends asked', traffic.requestsIn),
        ],
      ),
    );
  }

  Widget _health(BuildContext context, StatColors colors) {
    final net = widget.network;
    final now = DateTime.now();
    final recent = net.lastSync.values.where((t) => now.difference(t) < const Duration(hours: 1)).length;
    final theme = Theme.of(context);
    return StatSection(
      title: 'Connections',
      subtitle: 'This session',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FigureGrid([
            Figure(value: '${net.openConnections}', label: 'open now', icon: Icons.link),
            Figure(value: '${net.pooledConnections}', label: 'kept for reuse', icon: Icons.cached),
            Figure(value: '${net.servingNow}', label: 'answering friends', icon: Icons.call_received),
            Figure(value: countText(net.dialed), label: 'connections made', icon: Icons.call_made),
            Figure(value: countText(traffic.inboundConnections), label: 'received', icon: Icons.call_received),
            Figure(value: countText(traffic.dialFailures), label: 'could not connect', icon: Icons.link_off),
            Figure(value: countText(traffic.failed), label: 'requests failed', icon: Icons.error_outline),
            Figure(value: countText(traffic.refused), label: 'requests refused', icon: Icons.block),
            Figure(value: countText(net.acceptFailures), label: 'failed handshakes', icon: Icons.handshake_outlined),
            Figure(value: countText(net.watchdogRestarts), label: 'network restarts', icon: Icons.restart_alt),
            Figure(value: '${net.node.contacts.length}', label: 'devices known', icon: Icons.devices),
            Figure(value: '$recent', label: 'synced in the last hour', icon: Icons.sync),
          ]),
          if (net.relays.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Relays', style: theme.textTheme.labelLarge),
            for (final relay in net.relays)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    Icon(
                      relay.connected ? Icons.check_circle : Icons.error_outline,
                      size: 16,
                      color: relay.connected ? colors.download : theme.colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        relay.connected ? relay.url : '${relay.url} · ${relay.error ?? 'not connected'}',
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
          ],
          if (net.lastAcceptError != null) ...[
            const SizedBox(height: 12),
            Text(
              'Last handshake problem: ${net.lastAcceptError}',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final bool running, local;
  const _StatusChip({required this.running, required this.local});

  @override
  Widget build(BuildContext context) {
    final colors = StatColors.of(context);
    final color = running ? colors.download : Theme.of(context).colorScheme.error;
    return Chip(
      avatar: Icon(Icons.circle, size: 10, color: color),
      label: Text(!running ? 'Offline' : local ? 'Local network' : 'Online'),
      visualDensity: VisualDensity.compact,
    );
  }
}
