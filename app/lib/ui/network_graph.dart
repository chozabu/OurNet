import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';

import 'sync_health.dart' show NetworkHealthBuilder;

/// How recently a device must have synced or reached this one to be drawn
/// as connected.
const connectedWithin = Duration(minutes: 15);

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

/// This person's devices inside a ring, with a line from the ring to each
/// friend; the people and devices this device is in touch with are named
/// and highlighted. Tapping one reports it.
class NetworkGraph extends StatelessWidget {
  final PeerNetwork network;
  final String Function(String person) name;

  /// What a device is called; its certificate's name when not given.
  final String Function(DeviceCertificate device)? deviceLabel;
  final void Function(String person) onPerson;
  final void Function(DeviceCertificate device) onDevice;
  final double height;

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
    this.connected,
  });

  @override
  Widget build(BuildContext context) => NetworkHealthBuilder(
    network: network,
    builder: (context) => LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, height);
        final layout = _layout(size);
        final connected = layout.spots.where((s) => s.connected).length;
        return Semantics(
          label:
              'Network: ${layout.spots.where((s) => s.own).length} of your '
              'devices, ${layout.spots.where((s) => !s.own).length} friends, '
              '$connected connected',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) {
              final spot = layout.hit(details.localPosition);
              if (spot == null) return;
              if (spot.device case final device?) {
                onDevice(device);
              } else {
                onPerson(spot.person);
              }
            },
            child: CustomPaint(
              size: size,
              painter: _GraphPainter(
                layout,
                Theme.of(context).colorScheme,
                Theme.of(context).textTheme.bodySmall ?? const TextStyle(),
              ),
            ),
          ),
        );
      },
    ),
  );

  _Layout _layout(Size size) {
    final node = network.node;
    final now = DateTime.now();
    bool live(String device) =>
        connected?.call(device) ?? recentlyConnected(network, device, now: now);
    final own = [
      node.identity.certificate,
      for (final c in node.contacts.values)
        if (c.person == node.person &&
            c.device != node.identity.device &&
            !node.revoked.contains(c.device))
          c,
    ];
    final friends = <String, List<DeviceCertificate>>{};
    for (final c in node.contacts.values) {
      if (c.person == node.person || node.revoked.contains(c.device)) continue;
      (friends[c.person] ??= []).add(c);
    }
    final people = friends.keys.toList()
      ..sort((a, b) => name(a).toLowerCase().compareTo(name(b).toLowerCase()));

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
          label: deviceLabel?.call(c) ?? c.label,
          person: c.person,
          device: c,
          own: true,
          self: self,
          connected: self || live(c.device),
        ),
      );
    }
    final rx = math.max(size.width / 2 - 48, ring + 40);
    final ry = math.max(size.height / 2 - 28, ring + 30);
    for (var i = 0; i < people.length; i++) {
      final person = people[i];
      final angle = -math.pi / 2 + 2 * math.pi * (i + .5) / people.length;
      spots.add(
        _Spot(
          at: centre + Offset(math.cos(angle) * rx, math.sin(angle) * ry),
          radius: 12,
          label: name(person),
          person: person,
          blocked: node.blocked.contains(person),
          connected: friends[person]!.any((c) => live(c.device)),
        ),
      );
    }
    return _Layout(
      centre: centre,
      ring: ring,
      title: name(node.person),
      spots: spots,
      // Names stay legible only while there is room for them all.
      labelAll: people.length <= 14,
    );
  }
}

class _Spot {
  final Offset at;
  final double radius;
  final String label;
  final String person;
  final DeviceCertificate? device;
  final bool own, self, connected, blocked;
  const _Spot({
    required this.at,
    required this.radius,
    required this.label,
    required this.person,
    required this.connected,
    this.device,
    this.own = false,
    this.self = false,
    this.blocked = false,
  });
}

class _Layout {
  final Offset centre;
  final double ring;
  final String title;
  final List<_Spot> spots;
  final bool labelAll;
  const _Layout({
    required this.centre,
    required this.ring,
    required this.title,
    required this.spots,
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

  @override
  void paint(Canvas canvas, Size size) {
    final centre = layout.centre;
    final live = scheme.primary;
    final idle = scheme.outline.withValues(alpha: .4);

    for (final s in layout.spots.where((s) => !s.own)) {
      final direction = s.at - centre;
      final unit = direction / direction.distance;
      canvas.drawLine(
        centre + unit * layout.ring,
        s.at - unit * s.radius,
        Paint()
          ..color = s.connected ? live : idle
          ..strokeWidth = s.connected ? 2.5 : 1.2,
      );
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

    for (final s in layout.spots) {
      final colour = s.blocked
          ? scheme.error
          : s.connected
          ? live
          : scheme.outline;
      canvas.drawCircle(s.at, s.radius, Paint()..color = colour);
      if (s.self) {
        canvas.drawCircle(
          s.at,
          s.radius + 3,
          Paint()
            ..color = live
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }
      if (!s.own) {
        _text(
          canvas,
          s.label.isEmpty ? '?' : s.label.characters.first.toUpperCase(),
          s.at,
          colour: s.connected || s.blocked ? scheme.onPrimary : scheme.surface,
          size: 11,
          bold: true,
        );
      }
      if (layout.labelAll || s.connected || s.own) {
        _text(
          canvas,
          s.label,
          s.at + Offset(0, s.radius + (s.own ? 7 : 9)),
          colour: s.connected ? scheme.onSurface : scheme.onSurfaceVariant,
          size: s.own ? 9 : 11,
          bold: s.connected && !s.own,
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
