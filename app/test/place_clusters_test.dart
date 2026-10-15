import 'dart:math';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:ournet/services/place_clusters.dart';
import 'package:ournet_core/ournet_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'large visible lists stay bounded, and every pin remains selectable',
    () async {
      final node = Node(await LocalIdentity.create(), Store());
      addTearDown(node.close);
      final pin = await Places(node).save(lat: 0, lng: 0, name: 'A');
      final camera = MapCamera(
        crs: const Epsg3857(),
        center: const LatLng(0, 0),
        zoom: 6,
        rotation: 0,
        nonRotatedSize: const Point<double>(2400, 1600),
      );
      final bounds = camera.visibleBounds;
      final pins = [
        for (var i = 0; i < 2000; i++)
          SavedMapEntry(pin.object, {
            ...pin.data,
            'id': '${node.person}:$i',
            'lat':
                ((bounds.south +
                            (bounds.north - bounds.south) *
                                (i % 50 + .5) /
                                50) *
                        1e7)
                    .round(),
            'lng':
                ((bounds.west +
                            (bounds.east - bounds.west) * (i ~/ 50 + .5) / 40) *
                        1e7)
                    .round(),
          }),
      ];
      final groups = clusterPlaces(pins, camera);
      expect(groups.length, lessThanOrEqualTo(200));
      expect(groups.expand((g) => g).map((p) => p.id).toSet().length, 2000);
      expect(
        clusterPlaces([
          SavedMapEntry(pin.object, {...pin.data, 'lat': 850000000}),
        ], camera),
        isEmpty,
      );
      final overlapping = clusterPlaces([pin, pin, pin], camera);
      expect(overlapping.single.length, 3);
    },
  );
}
