import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ournet_core/ournet_core.dart';

class WorldMap extends StatelessWidget {
  final Node node;
  const WorldMap({super.key, required this.node});
  static final _land = rootBundle
      .loadString('assets/maps/world_land.geojson')
      .then((text) {
        final rings = <List<Offset>>[];
        for (final feature in jsonDecode(text)['features']) {
          final geometry = feature['geometry'];
          final polygons = geometry['type'] == 'Polygon'
              ? [geometry['coordinates']]
              : geometry['coordinates'];
          if (polygons is! List) continue;
          for (final polygon in polygons) {
            for (final ring in polygon) {
              rings.add(
                (ring as List)
                    .map(
                      (p) => Offset(
                        (p[0] as num).toDouble(),
                        (p[1] as num).toDouble(),
                      ),
                    )
                    .toList(),
              );
            }
          }
        }
        return rings;
      });
  Future<List<Offset>> _points() async {
    final seen = <String>{}, points = <Offset>[];
    for (final object
        in node.store.objects(kind: 'location').where(node.visible)) {
      if (!seen.add(object.author)) continue;
      final p = await node.content(object);
      if (p != null) {
        points.add(Offset(double.parse(p['lng']), double.parse(p['lat'])));
      }
    }
    return points;
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<dynamic>>(
    future: Future.wait<dynamic>([_land, _points()]),
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return const SizedBox(
          height: 180,
          child: Center(
            child: Text(
              'Map unavailable. Shared coordinates are listed below.',
            ),
          ),
        );
      }
      if (!snapshot.hasData) {
        return const SizedBox(
          height: 180,
          child: Center(child: CircularProgressIndicator()),
        );
      }
      return AspectRatio(
        aspectRatio: 2,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: CustomPaint(
            painter: _MapPainter(
              snapshot.data![0],
              snapshot.data![1],
              Theme.of(context).colorScheme,
            ),
          ),
        ),
      );
    },
  );
}

class _MapPainter extends CustomPainter {
  final List<List<Offset>> land;
  final List<Offset> points;
  final ColorScheme colors;
  _MapPainter(this.land, this.points, this.colors);
  @override
  void paint(Canvas canvas, Size size) {
    Offset project(Offset p) => Offset(
      (p.dx + 180) / 360 * size.width,
      (90 - p.dy) / 180 * size.height,
    );
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = colors.surfaceContainerHighest,
    );
    final fill = Paint()..color = colors.primary.withValues(alpha: .2);
    for (final ring in land) {
      if (ring.isEmpty) continue;
      final path = Path();
      final first = project(ring.first);
      path.moveTo(first.dx, first.dy);
      for (final point in ring.skip(1)) {
        final p = project(point);
        path.lineTo(p.dx, p.dy);
      }
      path.close();
      canvas.drawPath(path, fill);
    }
    for (final p in points) {
      canvas.drawCircle(project(p), 6, Paint()..color = colors.primary);
      canvas.drawCircle(project(p), 2, Paint()..color = colors.onPrimary);
    }
  }

  @override
  bool shouldRepaint(covariant _MapPainter old) => true;
}
