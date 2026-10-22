import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';

import 'sync_health.dart' show NetworkHealthBuilder;

/// How recently a device must have synced or reached this one to be drawn
/// as connected.
const connectedWithin = Duration(minutes: 15);

/// Lists older than this are drawn faded: they may no longer be true.
const staleListAfter = Duration(days: 90);

/// Whether this device is in touch with [device] now: syncing, or heard
/// from within [connectedWithin] without a failure since.
bool recentlyConnected(PeerNetwork network, String device, {DateTime? now}) {
  if (!network.running) return false;
  if (network.syncing.containsKey(device)) return true;
  now ??= DateTime.now();
  bool recent(DateTime? t) => t != null && now!.difference(t) < connectedWithin;
  return (recent(network.lastSync[device]) &&
          network.syncErrors[device] == null) ||
      recent(network.lastInbound[device]);
}

/// Where each person in [graph] goes, this person at the origin and about
/// one unit per link: a Fruchterman-Reingold layout that starts from rings
/// by distance and runs a fixed number of steps, so the same graph always
/// lands the same way.
@visibleForTesting
List<Offset> placeGraph(FriendGraph graph) {
  final n = graph.people.length;
  if (n == 1) return const [Offset.zero];
  final x = Float64List(n), y = Float64List(n);
  final ringSize = <int, int>{}, ringAt = <int, int>{};
  for (final p in graph.people) {
    ringSize[p.hops] = (ringSize[p.hops] ?? 0) + 1;
  }
  for (var i = 1; i < n; i++) {
    final hops = graph.people[i].hops;
    final at = ringAt[hops] = (ringAt[hops] ?? -1) + 1;
    final angle =
        -math.pi / 2 + 2 * math.pi * (at + .5) / ringSize[hops]! + hops * .7;
    x[i] = math.cos(angle) * hops;
    y[i] = math.sin(angle) * hops;
  }
  // Bounded work, however many people there are.
  final steps = (3e6 / (n * n)).round().clamp(40, 300);
  const k = .6;
  final dx = Float64List(n), dy = Float64List(n);
  for (var step = 0; step < steps; step++) {
    final heat = .4 * (1 - step / steps) + .01;
    dx.fillRange(0, n, 0);
    dy.fillRange(0, n, 0);
    for (var i = 0; i < n; i++) {
      for (var j = i + 1; j < n; j++) {
        var ox = x[i] - x[j], oy = y[i] - y[j];
        var d2 = ox * ox + oy * oy;
        if (d2 < 1e-6) (ox, oy, d2) = (.01 * (i - j), .01, 1e-4);
        final f = k * k / d2;
        dx[i] += ox * f;
        dy[i] += oy * f;
        dx[j] -= ox * f;
        dy[j] -= oy * f;
      }
    }
    for (final (i, j) in graph.links) {
      final ox = x[i] - x[j], oy = y[i] - y[j];
      final f = math.sqrt(ox * ox + oy * oy) / k;
      dx[i] -= ox * f;
      dy[i] -= oy * f;
      dx[j] += ox * f;
      dy[j] += oy * f;
    }
    for (var i = 1; i < n; i++) {
      // A pull back to its ring keeps distance readable.
      final r = math.sqrt(x[i] * x[i] + y[i] * y[i]);
      if (r > 1e-6) {
        final pull = (graph.people[i].hops - r) * .5 / r;
        dx[i] += x[i] * pull;
        dy[i] += y[i] * pull;
      }
      final d = math.sqrt(dx[i] * dx[i] + dy[i] * dy[i]);
      if (d < 1e-9) continue;
      final move = math.min(d, heat) / d;
      x[i] += dx[i] * move;
      y[i] += dy[i] * move;
    }
  }
  return [for (var i = 0; i < n; i++) Offset(x[i], y[i])];
}

/// This person's devices inside a ring, and the people around them as far
/// as [depth] links, laid out by how they are linked. Friends, the people
/// and devices this device is in touch with, and whoever is selected are
/// named and highlighted. Tapping a person selects them, shows the chain of
/// friends to them and reports them; tapping a device reports it.
class NetworkGraph extends StatefulWidget {
  final PeerNetwork network;
  final String Function(String person) name;

  /// What a device is called; its certificate's name when not given.
  final String Function(DeviceCertificate device)? deviceLabel;
  final void Function(String person) onPerson;
  final void Function(DeviceCertificate device) onDevice;
  final double height;

  /// Links out to start with.
  final int depth;

  /// Fills the page and pans and zooms, without the full-screen button.
  final bool fullScreen;

  /// Overrides [recentlyConnected], for tests without a running network.
  @visibleForTesting
  final bool Function(String device)? connected;

  const NetworkGraph({
    super.key,
    required this.network,
    required this.name,
    this.deviceLabel,
    required this.onPerson,
    required this.onDevice,
    this.height = 300,
    this.depth = 2,
    this.fullScreen = false,
    this.connected,
  });

  /// The depths offered, the last as far as chains are looked for.
  static const depths = [
    (1, '1'),
    (2, '2'),
    (3, '3'),
    (Connections.maxLinks, 'All'),
  ];

  @override
  State<NetworkGraph> createState() => NetworkGraphState();
}

class NetworkGraphState extends State<NetworkGraph> {
  late int depth = widget.depth;
  String? selected;
  final _canvas = GlobalKey();
  FriendGraph? _placedFor;
  List<Offset> _places = const [];
  (FriendGraph, String)? _chainFor;
  Set<(String, String)> _path = const {};
  _Layout? _layout;

  /// Where [person] (or, for this person, this device) is drawn, in global
  /// coordinates.
  @visibleForTesting
  Offset? spotOf(String person) {
    final box = _canvas.currentContext?.findRenderObject() as RenderBox?;
    final spot = _layout?.spots.where((s) => s.person == person).firstOrNull;
    if (box == null || spot == null) return null;
    return box.localToGlobal(spot.at);
  }

  FriendGraph _graph() {
    final graph = widget.network.node.connections.graph(depth: depth);
    if (!identical(graph, _placedFor)) {
      _places = placeGraph(graph);
      _placedFor = graph;
    }
    final chosen = selected;
    if (chosen != null && graph.people.every((p) => p.id != chosen)) {
      selected = null;
    }
    if (selected case final s? when _chainFor != (graph, s)) {
      final chain = widget.network.node.connections.chain(s) ?? const [];
      _path = {
        for (var i = 1; i < chain.length; i++) (chain[i - 1], chain[i]),
        for (var i = 1; i < chain.length; i++) (chain[i], chain[i - 1]),
      };
      _chainFor = (graph, s);
    } else if (selected == null) {
      _path = const {};
      _chainFor = null;
    }
    return graph;
  }

  void _openFullScreen() {
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => Scaffold(
            appBar: AppBar(title: const Text('Friend graph')),
            body: Padding(
              padding: const EdgeInsets.all(8),
              child: NetworkGraph(
                network: widget.network,
                name: widget.name,
                deviceLabel: widget.deviceLabel,
                onPerson: widget.onPerson,
                onDevice: widget.onDevice,
                depth: depth,
                fullScreen: true,
                connected: widget.connected,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => NetworkHealthBuilder(
    network: widget.network,
    builder: (context) {
      final graph = _graph();
      final toolbar = Row(
        children: [
          Expanded(
            child: Wrap(
              spacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('Reach', style: Theme.of(context).textTheme.labelMedium),
                for (final (value, label) in NetworkGraph.depths)
                  ChoiceChip(
                    label: Text(label),
                    selected: depth == value,
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) => setState(() => depth = value),
                  ),
              ],
            ),
          ),
          if (graph.omitted > 0)
            Text(
              '+${graph.omitted} more',
              style: Theme.of(context).textTheme.labelMedium,
            ),
          if (!widget.fullScreen)
            IconButton(
              tooltip: 'Full screen',
              icon: const Icon(Icons.fullscreen),
              onPressed: _openFullScreen,
            ),
        ],
      );
      return Column(
        mainAxisSize: widget.fullScreen ? MainAxisSize.max : MainAxisSize.min,
        children: [
          toolbar,
          if (widget.fullScreen)
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // Room for everyone to be told apart once zoomed in.
                  final side = math.sqrt(graph.people.length) * 90;
                  final size = Size(
                    math.max(constraints.maxWidth, side),
                    math.max(constraints.maxHeight, side),
                  );
                  return InteractiveViewer(
                    constrained: false,
                    minScale: .2,
                    maxScale: 5,
                    boundaryMargin: const EdgeInsets.all(200),
                    child: _picture(context, graph, size),
                  );
                },
              ),
            )
          else
            LayoutBuilder(
              builder: (context, constraints) => _picture(
                context,
                graph,
                Size(constraints.maxWidth, widget.height),
              ),
            ),
        ],
      );
    },
  );

  Widget _picture(BuildContext context, FriendGraph graph, Size size) {
    final layout = _layout = _place(graph, size);
    final people = layout.spots.where((s) => !s.own);
    final connected = layout.spots.where((s) => s.connected).length;
    final counts = [
      for (final (hops, what) in [(1, 'friends'), (2, 'friends of friends')])
        '${graph.count(hops)} $what',
      if (people.where((s) => s.hops > 2).length case final far when far > 0)
        '$far further away',
    ];
    return Semantics(
      label:
          'Network: ${layout.spots.where((s) => s.own).length} of your '
          'devices, ${counts.join(', ')}, $connected connected'
          '${graph.omitted > 0 ? ', ${graph.omitted} more not shown' : ''}',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) {
          final spot = layout.hit(details.localPosition);
          if (spot == null) {
            if (selected != null) setState(() => selected = null);
            return;
          }
          if (spot.device case final device?) {
            widget.onDevice(device);
          } else {
            setState(() => selected = spot.person);
            widget.onPerson(spot.person);
          }
        },
        child: CustomPaint(
          key: _canvas,
          size: size,
          painter: _GraphPainter(
            layout,
            Theme.of(context).colorScheme,
            Theme.of(context).textTheme.bodySmall ?? const TextStyle(),
          ),
        ),
      ),
    );
  }

  _Layout _place(FriendGraph graph, Size size) {
    final node = widget.network.node;
    final now = DateTime.now();
    bool live(String device) =>
        widget.connected?.call(device) ??
        recentlyConnected(widget.network, device, now: now);
    final own = [
      node.identity.certificate,
      for (final c in node.contacts.values)
        if (c.person == node.person &&
            c.device != node.identity.device &&
            !node.revoked.contains(c.device))
          c,
    ];
    final friendDevices = <String, List<DeviceCertificate>>{};
    for (final c in node.contacts.values) {
      if (c.person == node.person || node.revoked.contains(c.device)) continue;
      (friendDevices[c.person] ??= []).add(c);
    }

    final centre = Offset(size.width / 2, size.height / 2);
    final ring = own.length == 1
        ? 30.0
        : (24 + 10.0 * own.length).clamp(44.0, 72.0);
    final spots = <_Spot>[];
    for (var i = 0; i < own.length; i++) {
      final c = own[i];
      final self = c.device == node.identity.device;
      final angle = -math.pi / 2 + 2 * math.pi * i / own.length;
      spots.add(
        _Spot(
          at: own.length == 1
              ? centre
              : centre + Offset.fromDirection(angle, ring * .55),
          radius: self ? 9 : 7,
          label: widget.deviceLabel?.call(c) ?? c.label,
          person: c.person,
          hops: 0,
          device: c,
          own: true,
          self: self,
          connected: self || live(c.device),
        ),
      );
    }

    // Spread from just outside the ring to the edges of an ellipse filling
    // the space, so friends stand clear of the ring and the furthest
    // people reach the edge.
    var reach = 1e-6;
    for (final p in _places) {
      reach = math.max(reach, p.distance);
    }
    final rx = math.max(size.width / 2 - 48, ring + 40);
    final ry = math.max(size.height / 2 - 28, ring + 30);
    final clear = ring + 30;
    final staleBefore = now.subtract(staleListAfter).millisecondsSinceEpoch;
    final at = <String, Offset>{node.person: centre};
    for (var i = 1; i < graph.people.length; i++) {
      final p = graph.people[i];
      final place = _places[i];
      final r = place.distance;
      final unit = r < 1e-6 ? const Offset(0, -1) : place / r;
      final edge =
          1 / math.sqrt(math.pow(unit.dx / rx, 2) + math.pow(unit.dy / ry, 2));
      final offset = unit * (clear + r / reach * math.max(edge - clear, 0));
      at[p.id] = centre + offset;
      spots.add(
        _Spot(
          at: centre + offset,
          radius: switch (p.hops) {
            1 => 12,
            2 => 8,
            _ => 6,
          },
          label: widget.name(p.id),
          person: p.id,
          hops: p.hops,
          stale: p.hops > 1 && p.listed != null && p.listed! < staleBefore,
          selected: p.id == selected,
          connected: friendDevices[p.id]?.any((c) => live(c.device)) ?? false,
        ),
      );
    }
    final lines = <_Line>[];
    for (final (i, j) in graph.links) {
      final a = graph.people[i].id, b = graph.people[j].id;
      lines.add(
        _Line(
          at[a]!,
          at[b]!,
          fromRing: i == 0,
          path: _path.contains((a, b)),
          connected:
              i == 0 && (friendDevices[b]?.any((c) => live(c.device)) ?? false),
        ),
      );
    }
    return _Layout(
      centre: centre,
      ring: ring,
      title: widget.name(node.person),
      spots: spots,
      lines: lines,
      // Names stay legible only while there is room for them all.
      labelAll: graph.people.length <= 15,
    );
  }
}

class _Spot {
  final Offset at;
  final double radius;
  final String label;
  final String person;
  final int hops;
  final DeviceCertificate? device;
  final bool own, self, connected, stale, selected;
  const _Spot({
    required this.at,
    required this.radius,
    required this.label,
    required this.person,
    required this.hops,
    required this.connected,
    this.device,
    this.own = false,
    this.self = false,
    this.stale = false,
    this.selected = false,
  });
}

class _Line {
  final Offset a, b;
  final bool fromRing, path, connected;
  const _Line(
    this.a,
    this.b, {
    required this.fromRing,
    required this.path,
    required this.connected,
  });
}

class _Layout {
  final Offset centre;
  final double ring;
  final String title;
  final List<_Spot> spots;
  final List<_Line> lines;
  final bool labelAll;
  const _Layout({
    required this.centre,
    required this.ring,
    required this.title,
    required this.spots,
    required this.lines,
    required this.labelAll,
  });

  /// The nearest spot within easy reach of a finger.
  _Spot? hit(Offset point) {
    _Spot? best;
    var distance = double.infinity;
    for (final s in spots) {
      final d = (s.at - point).distance;
      if (d <= s.radius + 14 && d < distance) (best, distance) = (s, d);
    }
    return best;
  }
}

class _GraphPainter extends CustomPainter {
  final _Layout layout;
  final ColorScheme scheme;
  final TextStyle style;
  _GraphPainter(this.layout, this.scheme, this.style);

  Color _colour(_Spot s) {
    final base = switch (s.hops) {
      1 => s.connected ? scheme.primary : scheme.outline,
      2 => scheme.tertiary,
      _ => scheme.tertiary.withValues(alpha: .6),
    };
    return s.stale ? base.withValues(alpha: base.a * .4) : base;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final centre = layout.centre;
    final live = scheme.primary;
    final idle = scheme.outline.withValues(alpha: .4);
    final faint = scheme.outline.withValues(alpha: .22);

    // The chain to whoever is selected goes on top.
    for (final path in [false, true]) {
      for (final l in layout.lines.where((l) => l.path == path)) {
        var a = l.a;
        final direction = l.b - a;
        if (direction.distance < 1e-6) continue;
        final unit = direction / direction.distance;
        if (l.fromRing) a = centre + unit * layout.ring;
        canvas.drawLine(
          a,
          l.b,
          Paint()
            ..color = l.path
                ? scheme.secondary
                : l.connected
                ? live
                : l.fromRing
                ? idle
                : faint
            ..strokeWidth = l.path
                ? 3
                : l.connected
                ? 2.5
                : l.fromRing
                ? 1.2
                : .8,
        );
      }
    }

    canvas.drawCircle(
      centre,
      layout.ring,
      Paint()..color = live.withValues(alpha: .08),
    );
    canvas.drawCircle(
      centre,
      layout.ring,
      Paint()
        ..color = live.withValues(alpha: .7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    _text(
      canvas,
      layout.title,
      centre - Offset(0, layout.ring + 9),
      bold: true,
      colour: scheme.onSurface,
      maxWidth: 160,
    );

    final ownCount = layout.spots.where((o) => o.own).length;
    // Further people first, so friends and their names sit on top.
    final order = [...layout.spots]
      ..sort((a, b) {
        int rank(_Spot s) => s.selected ? -1 : s.hops;
        return rank(b).compareTo(rank(a));
      });
    for (final s in order) {
      final colour = s.own ? (s.connected ? live : scheme.outline) : _colour(s);
      canvas.drawCircle(s.at, s.radius, Paint()..color = colour);
      if (s.self || s.selected) {
        canvas.drawCircle(
          s.at,
          s.radius + 3,
          Paint()
            ..color = s.selected ? scheme.secondary : live
            ..style = PaintingStyle.stroke
            ..strokeWidth = s.selected ? 2.5 : 1.5,
        );
      }
      if (!s.own && s.radius >= 10) {
        _text(
          canvas,
          s.label.isEmpty ? '?' : s.label.characters.first.toUpperCase(),
          s.at,
          colour: s.connected ? scheme.onPrimary : scheme.surface,
          size: 11,
          bold: true,
        );
      }
      // A lone device is the ring itself, which is already named.
      final lone = s.own && ownCount == 1;
      if (!lone &&
          (layout.labelAll ||
              s.connected ||
              s.own ||
              s.hops == 1 ||
              s.selected)) {
        _text(
          canvas,
          s.label,
          s.at + Offset(0, s.radius + (s.own ? 7 : 9)),
          colour: s.connected || s.selected
              ? scheme.onSurface
              : scheme.onSurfaceVariant,
          size: s.own ? 9 : (s.hops > 1 && !s.selected ? 10 : 11),
          bold: (s.connected && !s.own) || s.selected,
          maxWidth: s.own ? 64 : 96,
        );
      }
    }
  }

  void _text(
    Canvas canvas,
    String text,
    Offset centre, {
    required Color colour,
    double size = 12,
    bool bold = false,
    double maxWidth = 120,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: style.copyWith(
          color: colour,
          fontSize: size,
          fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);
    painter.paint(
      canvas,
      centre - Offset(painter.width / 2, painter.height / 2),
    );
  }

  @override
  bool shouldRepaint(_GraphPainter old) => true;
}
