import 'dart:math' as math;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:ournet_core/ournet_core.dart';

/// Grid clusters for the current viewport. Called outside a frame after
/// camera movement settles, never reads storage or decodes content.
List<List<SavedMapEntry>> clusterPlaces(
  List<SavedMapEntry> places,
  MapCamera camera,
) {
  final visible = places
      .where((p) => camera.visibleBounds.contains(LatLng(p.lat, p.lng)))
      .toList();
  final scale = 256 * math.pow(2, camera.zoom);
  var cell = 64.0;
  while (true) {
    final groups = <(int, int), List<SavedMapEntry>>{};
    for (final p in visible) {
      final sin = math.sin(p.lat.clamp(-85.0511, 85.0511) * math.pi / 180);
      final x = (p.lng + 180) / 360 * scale;
      final y = (.5 - math.log((1 + sin) / (1 - sin)) / (4 * math.pi)) * scale;
      (groups[((x / cell).floor(), (y / cell).floor())] ??= []).add(p);
    }
    if (groups.length <= 200) return groups.values.toList();
    cell *= 2;
  }
}
