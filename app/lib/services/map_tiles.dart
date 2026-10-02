import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:ournet_core/ournet_core.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart' as vmt;
import 'package:vector_tile_renderer/vector_tile_renderer.dart' as vtr;

/// Where the map's vector tiles come from, and keeping them.
///
/// Tiles come from OpenFreeMap's public OpenMapTiles-schema planet, which asks
/// for no key and no sign-up. Every tile seen is kept in a [TileStore], whole
/// regions can be saved for offline use, and with "Use the internet for maps"
/// off nothing is fetched at all. A tile request tells that server roughly
/// where you are looking, which is why it can be switched off; the styles,
/// icons and fonts are bundled and need no network.
class MapTiles extends ChangeNotifier {
  static const tileJson = 'https://tiles.openfreemap.org/planet';
  static const maxZoom = 14;

  /// Largest region taken in one go, and an average tile for estimating size.
  static const maxRegionTiles = 40000;
  static const averageTileBytes = 24 * 1024;

  final TileStore store;
  final bool Function() allowed;
  final http.Client Function() newClient;
  MapTiles(
    this.store, {
    required this.allowed,
    http.Client Function()? client,
  }) : newClient = client ?? http.Client.new;

  /// Whether tiles may be fetched.
  bool get online => allowed();

  /// Tells listeners that a setting behind [allowed] changed.
  void changed() => notifyListeners();

  String? get _template => store.meta('template');

  Future<String?>? _refreshing;

  /// The URL template for the current tile version. The version in it changes
  /// every week or so, so it is refreshed daily and when a tile is gone.
  Future<String?> template({bool force = false}) {
    final at = int.tryParse(store.meta('templateAt') ?? '') ?? 0;
    final stale =
        DateTime.now().millisecondsSinceEpoch - at > 24 * 3600 * 1000;
    if (_template != null && !stale && !force) return Future.value(_template);
    if (!online) return Future.value(_template);
    return _refreshing ??= _fetchTemplate().whenComplete(
      () => _refreshing = null,
    );
  }

  Future<String?> _fetchTemplate() async {
    final client = newClient();
    try {
      final response = await client
          .get(Uri.parse(tileJson))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final tiles = (jsonDecode(response.body) as Map)['tiles'];
        if (tiles is List && tiles.isNotEmpty && tiles.first is String) {
          store.setMeta('template', tiles.first as String);
          store.setMeta(
            'templateAt',
            '${DateTime.now().millisecondsSinceEpoch}',
          );
        }
      }
    } catch (_) {
      // Offline: carry on with the last known version.
    } finally {
      client.close();
    }
    return _template;
  }

  static Uri _url(String template, int z, int x, int y) => Uri.parse(
    template
        .replaceAll('{z}', '$z')
        .replaceAll('{x}', '$x')
        .replaceAll('{y}', '$y'),
  );

  int _inFlight = 0;
  final _waiting = <Completer<void>>[];
  Future<void> _slot() async {
    if (_inFlight >= 6) {
      final c = Completer<void>();
      _waiting.add(c);
      await c.future;
    } else {
      _inFlight++;
    }
  }

  void _release() {
    if (_waiting.isEmpty) {
      _inFlight--;
    } else {
      _waiting.removeAt(0).complete();
    }
  }

  /// A tile from the network, or null when it does not exist (an empty
  /// area). Throws when the network fails.
  Future<Uint8List?> fetch(int z, int x, int y) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final template = await this.template(force: attempt > 0);
      if (template == null) throw StateError('No tile source known yet');
      await _slot();
      final client = newClient();
      try {
        final response = await client
            .get(_url(template, z, x, y))
            .timeout(const Duration(seconds: 20));
        if (response.statusCode == 200) return response.bodyBytes;
        if (response.statusCode == 204) return null;
        // The versioned path rotates away; ask for the new one once.
        if (response.statusCode != 404 || attempt > 0) {
          if (response.statusCode == 404) return null;
          throw StateError('Tile server answered ${response.statusCode}');
        }
      } finally {
        client.close();
        _release();
      }
    }
    return null;
  }

  /// A tile for the map: kept, else fetched and kept.
  Future<Uint8List> tile(int z, int x, int y) async {
    final held = store.get(z, x, y);
    if (held != null) return held;
    if (!online) {
      throw vmt.ProviderException(
        message: 'Offline',
        statusCode: 503,
        retryable: vmt.Retryable.none,
      );
    }
    try {
      final bytes = await fetch(z, x, y) ?? Uint8List(0);
      store.put(z, x, y, bytes);
      return bytes;
    } catch (e) {
      throw vmt.ProviderException(
        message: '$e',
        retryable: vmt.Retryable.retry,
      );
    }
  }

  late final vmt.VectorTileProvider provider = _Provider(this);

  // Styles.

  vmt.Style? _light, _dark;
  Future<vmt.Style> style({required bool dark}) async {
    final held = dark ? _dark : _light;
    if (held != null) return held;
    final json =
        jsonDecode(
              await rootBundle.loadString(
                'assets/maps/style_${dark ? 'dark' : 'light'}.json',
              ),
            )
            as Map<String, dynamic>;
    final sprites = jsonDecode(
      await rootBundle.loadString('assets/maps/sprite.json'),
    );
    final built = vmt.Style(
      name: dark ? 'OurNet dark' : 'OurNet',
      theme: vtr.ThemeReader().read(json),
      providers: vmt.TileProviders({'openmaptiles': provider}),
      sprites: vmt.SpriteStyle(
        atlasProvider: () async => (await rootBundle.load(
          'assets/maps/sprite.png',
        )).buffer.asUint8List(),
        index: vtr.SpriteIndexReader().read(sprites as Map<String, dynamic>),
      ),
    );
    if (dark) {
      _dark = built;
    } else {
      _light = built;
    }
    return built;
  }

  // Offline regions.

  final downloads = <int, RegionDownload>{};

  /// Starts (or resumes) saving a region. Progress is on the returned object
  /// and through this notifier.
  RegionDownload download(int regionId) {
    final running = downloads[regionId];
    if (running != null && !running.finished) return running;
    final job = RegionDownload(this, regionId)..addListener(notifyListeners);
    downloads[regionId] = job;
    unawaited(job.run());
    notifyListeners();
    return job;
  }

  /// Adds a region and starts saving it. Throws if it is too large.
  RegionDownload addRegion(
    String name,
    MapBounds bounds,
    int minZoom,
    int maxZoom,
  ) {
    if (bounds.count(minZoom, maxZoom) > maxRegionTiles) {
      throw StateError('That area is too large to save in one go');
    }
    return download(store.addRegion(name, bounds, minZoom, maxZoom));
  }

  void deleteRegion(int id) {
    downloads.remove(id)?.cancel();
    store.deleteRegion(id);
    notifyListeners();
  }

  @override
  void dispose() {
    for (final job in downloads.values) {
      job.cancel();
    }
    super.dispose();
  }
}

class _Provider extends vmt.VectorTileProvider {
  final MapTiles tiles;
  _Provider(this.tiles);

  @override
  int get maximumZoom => MapTiles.maxZoom;

  @override
  int get minimumZoom => 0;

  @override
  Future<Uint8List> provide(vmt.TileIdentity tile) =>
      tiles.tile(tile.z, tile.x, tile.y);
}

/// Saves the tiles of one region, a few at a time, and can be resumed after
/// an interruption because only tiles not yet held are fetched.
class RegionDownload extends ChangeNotifier {
  final MapTiles tiles;
  final int regionId;
  RegionDownload(this.tiles, this.regionId);

  int done = 0;
  int total = 0;
  Object? error;
  bool finished = false;
  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
  }

  double get progress => total == 0 ? 0 : done / total;

  Future<void> run() async {
    final store = tiles.store;
    try {
      final region = store.region(regionId);
      if (region == null) return;
      total = region.tiles;
      // Found a slice at a time, so a large region never holds up a frame.
      final pending = <(int, int, int)>[];
      var checked = 0;
      for (final tile in store.missing(regionId)) {
        pending.add(tile);
        if (++checked % 400 == 0) {
          await Future<void>.delayed(Duration.zero);
          if (_cancelled) return;
        }
      }
      done = total - pending.length;
      notifyListeners();
      var next = 0;
      var lastNotify = DateTime.now();

      Future<void> worker() async {
        while (!_cancelled && error == null) {
          if (next >= pending.length) return;
          final (z, x, y) = pending[next++];
          Uint8List? bytes;
          for (var attempt = 0; ; attempt++) {
            try {
              bytes = await tiles.fetch(z, x, y);
              break;
            } catch (e) {
              if (attempt >= 2 || _cancelled) {
                error ??= e;
                return;
              }
              await Future<void>.delayed(Duration(seconds: 1 << attempt));
            }
          }
          store.put(z, x, y, bytes ?? Uint8List(0), region: regionId);
          done++;
          final now = DateTime.now();
          if (now.difference(lastNotify).inMilliseconds > 250) {
            lastNotify = now;
            notifyListeners();
          }
        }
      }

      await Future.wait([for (var i = 0; i < 4; i++) worker()]);
      if (!_cancelled && error == null && done >= total) {
        store.completeRegion(regionId);
      }
    } catch (e) {
      error ??= e;
    } finally {
      finished = true;
      notifyListeners();
    }
  }
}
