// Builds the app's map styles: OpenFreeMap's "Liberty" (OpenMapTiles schema,
// BSD-licensed styles over ODbL data) recoloured to a familiar light and dark
// road-map palette. The result is committed under app/assets/maps so the map
// draws with no network; rerun only to change the look:
//
//   dart run tool/map_style.dart            # downloads Liberty
//   dart run tool/map_style.dart liberty.json
import 'dart:convert';
import 'dart:io';

typedef Paint = Map<String, Object>;

/// Rules are tried in order and every match applies, so later rules refine
/// earlier ones. Keys are regular expressions over the layer id.
class Palette {
  final String land, water, park, building, label, halo, waterLabel;
  final Map<String, Paint> rules;
  Palette({
    required this.land,
    required this.water,
    required this.park,
    required this.building,
    required this.label,
    required this.halo,
    required this.waterLabel,
    required this.rules,
  });
}

Paint line(String color) => {'line-color': color};
Paint fill(String color) => {'fill-color': color};

Palette light() => Palette(
  land: '#f1f0ec',
  water: '#a8d3f7',
  park: '#c8e6c0',
  building: '#e3e0d9',
  label: '#5f6368',
  halo: '#ffffff',
  waterLabel: '#4879b6',
  rules: {
    r'^background$': {'background-color': '#f1f0ec'},
    r'^landuse_residential$': fill('#ece9e3'),
    r'^landcover_wood$': fill('#c4e1b4'),
    r'^landcover_grass$': fill('#d4e9c6'),
    r'^landcover_ice$': fill('#fafcfd'),
    r'^landcover_wetland$': fill('#cfe6dc'),
    r'^landcover_sand$': fill('#f2ead7'),
    r'^landuse_pitch$': fill('#c4e4be'),
    r'^landuse_track$': fill('#c4e4be'),
    r'^landuse_cemetery$': fill('#cfe3d0'),
    r'^landuse_hospital$': fill('#f6d9d5'),
    r'^landuse_school$': fill('#ece6dc'),
    r'^aeroway_fill$': fill('#e4e5e8'),
    r'^aeroway_(runway|taxiway)$': line('#d3d6da'),
    r'^waterway_': line('#a8d3f7'),
    r'^water$': fill('#a8d3f7'),
    // Roads: local streets white, main roads yellow, motorways orange.
    r'casing$': line('#d5d8dc'),
    r'(minor|street|service_track|path_pedestrian)$': line('#ffffff'),
    r'(secondary_tertiary)$': line('#ffffff'),
    r'secondary_tertiary_casing$': line('#c9ccd1'),
    r'trunk_primary$': line('#fde9a6'),
    r'trunk_primary_casing$': line('#e6c566'),
    r'motorway$|motorway_link$': line('#f9c46c'),
    r'motorway_casing$|motorway_link_casing$': line('#e0a43d'),
    r'^(road|bridge)_link$': line('#ffffff'),
    r'^tunnel_': {'line-opacity': 0.55},
    r'_rail$|_rail_hatching$': line('#c2c5ca'),
    r'^road_area_pattern$': {'fill-opacity': 0.0},
    r'^building$': {
      'fill-color': '#e3e0d9',
      'fill-outline-color': '#d4d0c7',
    },
    r'^boundary_': line('#a1a6ad'),
  },
);

Palette dark() => Palette(
  land: '#242f3e',
  water: '#17263c',
  park: '#263c3f',
  building: '#2c3a4d',
  label: '#9ca5b3',
  halo: '#242f3e',
  waterLabel: '#515c6d',
  rules: {
    r'^background$': {'background-color': '#242f3e'},
    r'^landuse_residential$': fill('#28344a'),
    r'^landcover_wood$': fill('#263c3f'),
    r'^landcover_grass$': fill('#26393f'),
    r'^landcover_ice$': fill('#2c3a4d'),
    r'^landcover_wetland$': fill('#23374a'),
    r'^landcover_sand$': fill('#2c3a4d'),
    r'^landuse_pitch$': fill('#263c3f'),
    r'^landuse_track$': fill('#263c3f'),
    r'^landuse_cemetery$': fill('#263c3f'),
    r'^landuse_hospital$': fill('#3b2f3f'),
    r'^landuse_school$': fill('#2b3849'),
    r'^aeroway_fill$': fill('#2c3a4d'),
    r'^aeroway_(runway|taxiway)$': line('#3a4658'),
    r'^waterway_': line('#17263c'),
    r'^water$': fill('#17263c'),
    r'casing$': line('#212a37'),
    r'(minor|street|service_track|path_pedestrian)$': line('#38414e'),
    r'(secondary_tertiary)$': line('#46515f'),
    r'secondary_tertiary_casing$': line('#212a37'),
    r'trunk_primary$': line('#746855'),
    r'trunk_primary_casing$': line('#1f2835'),
    r'motorway$|motorway_link$': line('#9a8a6a'),
    r'motorway_casing$|motorway_link_casing$': line('#1f2835'),
    r'^(road|bridge)_link$': line('#46515f'),
    r'^tunnel_': {'line-opacity': 0.55},
    r'_rail$|_rail_hatching$': line('#3f4a5a'),
    r'^road_area_pattern$': {'fill-opacity': 0.0},
    r'^building$': {
      'fill-color': '#2c3a4d',
      'fill-outline-color': '#323f52',
    },
    r'^boundary_': line('#4b5870'),
  },
);

Map<String, dynamic> build(Map<String, dynamic> liberty, Palette p) {
  final style = jsonDecode(jsonEncode(liberty)) as Map<String, dynamic>;
  // One vector source; the raster Natural Earth shading and 3D extrusions
  // are dropped, as are sprite and glyph URLs (assets and system fonts).
  (style['sources'] as Map).removeWhere((k, _) => k != 'openmaptiles');
  (style['sources'] as Map)['openmaptiles'] = {'type': 'vector'};
  style
    ..remove('sprite')
    ..remove('glyphs')
    ..['name'] = 'OurNet';
  final layers = <Map<String, dynamic>>[];
  for (final layer in (style['layers'] as List).cast<Map<String, dynamic>>()) {
    final id = layer['id'] as String;
    if (layer['type'] == 'raster' ||
        layer['type'] == 'fill-extrusion' ||
        id == 'park_outline' ||
        id.startsWith('road_one_way_arrow')) {
      continue;
    }
    final paint = (layer['paint'] as Map<String, dynamic>?) ?? {};
    final layout = (layer['layout'] as Map<String, dynamic>?) ?? {};
    for (final rule in p.rules.entries) {
      if (RegExp(rule.key).hasMatch(id)) {
        for (final e in rule.value.entries) {
          // A colour rule must not land on a layer of another type.
          if (e.key.startsWith('fill') && layer['type'] != 'fill') continue;
          if (e.key.startsWith('line') && layer['type'] != 'line') continue;
          if (e.key.startsWith('background') && layer['type'] != 'background') {
            continue;
          }
          paint[e.key] = e.value;
        }
      }
    }
    if (layer['type'] == 'symbol') {
      final water = id.contains('water') || id.contains('waterway');
      final place = id.startsWith('label_') || id == 'airport';
      paint['text-color'] = water
          ? p.waterLabel
          : place
          ? (identical(p, _darkPalette) ? '#e8eaed' : '#202124')
          : p.label;
      paint['text-halo-color'] = p.halo;
      paint['text-halo-width'] = 1.4;
      paint['text-halo-blur'] = 0.5;
      layout.remove('text-font');
    }
    if (paint.isNotEmpty) layer['paint'] = paint;
    if (layout.isNotEmpty) layer['layout'] = layout;
    layers.add(layer);
  }
  style['layers'] = layers;
  return style;
}

late final Palette _darkPalette;

Future<void> main(List<String> args) async {
  final String text;
  if (args.isNotEmpty) {
    text = File(args.first).readAsStringSync();
  } else {
    final client = HttpClient();
    final request = await client.getUrl(
      Uri.parse('https://tiles.openfreemap.org/styles/liberty'),
    );
    final response = await request.close();
    text = await utf8.decodeStream(response);
    client.close();
  }
  final liberty = jsonDecode(text) as Map<String, dynamic>;
  _darkPalette = dark();
  final out = Directory('app/assets/maps');
  File('${out.path}/style_light.json').writeAsStringSync(
    const JsonEncoder().convert(build(liberty, light())),
  );
  File('${out.path}/style_dark.json').writeAsStringSync(
    const JsonEncoder().convert(build(liberty, _darkPalette)),
  );
  stdout.writeln('Wrote styles to ${out.path}');
}
