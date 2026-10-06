import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:ournet_core/ournet_core.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart' as vmt;
import '../services/location_share.dart';
import '../services/map_tiles.dart';
import 'avatar.dart';

part 'map_settings.dart';

/// How long ago, in the shortest words that read well.
String ago(int millis, {DateTime? now}) {
  final t = now ?? DateTime.now();
  final d = t.difference(DateTime.fromMillisecondsSinceEpoch(millis));
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  if (d.inDays < 7) return '${d.inDays} d ago';
  final at = DateTime.fromMillisecondsSinceEpoch(millis);
  return '${at.year}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')}';
}

String distanceText(double metres) => metres < 950
    ? '${(metres / 10).round() * 10} m'
    : metres < 10000
    ? '${(metres / 1000).toStringAsFixed(1)} km'
    : '${(metres / 1000).round()} km';

/// "51.5, -0.12" and common variants, as a point.
LatLng? parseCoordinates(String text) {
  final m = RegExp(
    r'^\s*(-?\d{1,2}(?:\.\d+)?)\s*[,;\s]\s*(-?\d{1,3}(?:\.\d+)?)\s*$',
  ).firstMatch(text);
  if (m == null) return null;
  final lat = double.parse(m[1]!), lng = double.parse(m[2]!);
  return lat.abs() <= 90 && lng.abs() <= 180 ? LatLng(lat, lng) : null;
}

Color personColor(String person, {required bool dark}) {
  final hue = person.codeUnits.fold<int>(7, (h, c) => (h * 31 + c) % 360);
  return HSLColor.fromAHSL(1, hue.toDouble(), .6, dark ? .5 : .42).toColor();
}

const _googleBlue = Color(0xff1a73e8);

/// The map: full-bleed, with a floating search bar, people along the top, a
/// layers button, a compass and "my location" at the corner, and a card for
/// whatever is selected. Friends appear where they last said they were.
class MapPage extends StatefulWidget {
  final Node node;
  final MapTiles tiles;
  final LocationShare share;
  final String Function(String person) nameOf;

  /// Opens the chat with a friend.
  final void Function(String person)? onMessage;
  const MapPage({
    super.key,
    required this.node,
    required this.tiles,
    required this.share,
    required this.nameOf,
    this.onMessage,
  });
  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> with TickerProviderStateMixin {
  final _controller = MapController();
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  late final AnimationController _fly;
  StreamSubscription<void>? _positions;
  Timer? _saveCamera, _refreshAges;
  Future<vmt.Style>? _style;
  bool? _styleDark;
  String? _selected;
  LatLng? _pin;
  bool _follow = false;
  double _rotation = 0;
  bool _ready = false;

  Node get node => widget.node;
  LocationShare get share => widget.share;

  @override
  void initState() {
    super.initState();
    _fly = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _positions = node.locations.changes.listen((_) {
      if (!mounted) return;
      setState(() {});
      final me = share.own;
      if (_follow && me != null) _moveTo(LatLng(me.lat, me.lng));
    });
    share.addListener(_changed);
    widget.tiles.addListener(_changed);
    _search.addListener(() => setState(() {}));
    // Ages tick over without any new data.
    _refreshAges = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _offerLocation());
  }

  /// The first time the map opens: starts reading the position if it may,
  /// and otherwise explains what sharing is and asks once.
  Future<void> _offerLocation() async {
    await share.start();
    if (!mounted ||
        !share.sharing ||
        share.access != LocationAccess.denied ||
        node.store.setting('locationAsked') == true) {
      return;
    }
    node.store.set('locationAsked', true);
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Share your location with friends?'),
        content: const Text(
          'OurNet shows where your friends are and lets them see where you '
          'are, live. Only people you have added can see it. It goes straight '
          'to their devices, nothing is kept on a server, and only your last '
          'place is remembered, never a trail.\n\n'
          'You can pause this at any time in the map menu under Location '
          'sharing.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Turn on'),
          ),
        ],
      ),
    );
    if (yes == true) await share.start(request: true);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _positions?.cancel();
    share.removeListener(_changed);
    widget.tiles.removeListener(_changed);
    _saveCamera?.cancel();
    _refreshAges?.cancel();
    _fly.dispose();
    _search.dispose();
    _searchFocus.dispose();
    _controller.dispose();
    super.dispose();
  }

  bool get _dark {
    final choice = node.store.setting('mapStyle');
    return choice == 'dark' ||
        choice != 'light' && Theme.of(context).brightness == Brightness.dark;
  }

  // Camera.

  ({LatLng center, double zoom}) get _start {
    final saved = node.store.setting('mapCamera');
    if (saved is List && saved.length == 3) {
      return (
        center: LatLng(
          (saved[0] as num).toDouble(),
          (saved[1] as num).toDouble(),
        ),
        zoom: (saved[2] as num).toDouble(),
      );
    }
    final here = share.own ?? node.locations.of(node.person);
    if (here != null) return (center: LatLng(here.lat, here.lng), zoom: 14);
    final newest = _people.fold<Fix?>(
      null,
      (a, b) => a == null || b.$2.at > a.at ? b.$2 : a,
    );
    if (newest != null) {
      return (center: LatLng(newest.lat, newest.lng), zoom: 12);
    }
    return (center: const LatLng(30, 10), zoom: 2);
  }

  void _moveTo(LatLng to, {double? zoom, bool animate = true}) {
    if (!_ready) return;
    final from = _controller.camera;
    final target = zoom ?? math.max(from.zoom, 14);
    if (!animate) {
      _controller.move(to, target);
      return;
    }
    // A short glide, shorter when the places are far apart: crossing the
    // world slowly is not nicer.
    final lat = Tween(begin: from.center.latitude, end: to.latitude);
    final lng = Tween(begin: from.center.longitude, end: to.longitude);
    final z = Tween(begin: from.zoom, end: target);
    _fly
      ..stop()
      ..reset();
    void tick() {
      final t = Curves.easeInOutCubic.transform(_fly.value);
      _controller.move(
        LatLng(lat.transform(t), lng.transform(t)),
        z.transform(t),
      );
    }

    _fly.removeListener(tick);
    _fly
      ..addListener(tick)
      ..forward().whenComplete(() => _fly.removeListener(tick));
  }

  void _onCamera(MapCamera camera, bool gesture) {
    if (gesture) {
      _follow = false;
      if (_fly.isAnimating) _fly.stop();
    }
    if ((camera.rotation - _rotation).abs() > .5) {
      setState(() => _rotation = camera.rotation);
    }
    _saveCamera?.cancel();
    _saveCamera = Timer(const Duration(seconds: 2), () {
      node.store.set('mapCamera', [
        camera.center.latitude,
        camera.center.longitude,
        camera.zoom,
      ]);
    });
  }

  // People.

  /// Everyone with a position, nearest first is not wanted: freshest first.
  List<(String, Fix)> get _people {
    final known = node.contacts.values.map((c) => c.person).toSet();
    final list = [
      for (final e in node.locations.all.entries)
        if (e.key != node.person &&
            known.contains(e.key) &&
            !node.blocked.contains(e.key))
          (e.key, e.value),
    ]..sort((a, b) => b.$2.at.compareTo(a.$2.at));
    return list;
  }

  Fix? get _me => share.own ?? node.locations.of(node.person);

  /// This person's other devices that have reported a position, still
  /// admitted, as (device ID, fix).
  List<(String, Fix)> get _otherDevices => [
    for (final c in share.otherDevices)
      if (node.locations.ofDevice(c.device) case final fix?) (c.device, fix),
  ];

  void _select(String? person) {
    setState(() {
      _selected = person;
      if (person != null) _pin = null;
    });
    final fix = person == null ? null : node.locations.of(person);
    if (fix != null) _moveTo(LatLng(fix.lat, fix.lng), zoom: 15);
  }

  Future<void> _goToMe() async {
    if (share.own == null && share.access != LocationAccess.granted) {
      await share.start(request: true);
    }
    if (!mounted) return;
    final me = _me;
    if (me == null) {
      _say(switch (share.access) {
        LocationAccess.deniedForever =>
          'Location is blocked for OurNet. Allow it in system settings.',
        LocationAccess.serviceOff => 'Turn on location services first.',
        LocationAccess.unsupported =>
          'This device cannot report its position. Your other devices can.',
        _ => 'Waiting for a position fix…',
      });
      return;
    }
    setState(() {
      _follow = share.own != null;
      _selected = null;
    });
    _moveTo(LatLng(me.lat, me.lng), zoom: 16);
  }

  MapController get mapController => _controller;
  bool get ready => _ready;
  void refresh() => _changed();

  void _say(String text) => ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(text)));

  // Build.

  @override
  Widget build(BuildContext context) {
    final dark = _dark;
    if (_style == null || _styleDark != dark) {
      _styleDark = dark;
      _style = widget.tiles.style(dark: dark);
    }
    final start = _start;
    final here = share.own;
    final showFriends = node.store.setting('mapFriends') != false;
    final people = showFriends ? _people : <(String, Fix)>[];
    final scheme = Theme.of(context).colorScheme;
    final land = dark ? const Color(0xff242f3e) : const Color(0xfff1f0ec);
    final card = _card(context);
    return Material(
      color: land,
      child: Stack(
        children: [
          FlutterMap(
            mapController: _controller,
            options: MapOptions(
              initialCenter: start.center,
              initialZoom: start.zoom,
              minZoom: 2,
              maxZoom: 19,
              backgroundColor: land,
              onMapReady: () => _ready = true,
              onPositionChanged: (camera, gesture) => _onCamera(camera, gesture),
              onTap: (_, _) {
                _searchFocus.unfocus();
                setState(() {
                  _selected = null;
                  _pin = null;
                });
              },
              onLongPress: (_, point) => setState(() {
                _pin = point;
                _selected = null;
              }),
            ),
            children: [
              FutureBuilder<vmt.Style>(
                future: _style,
                builder: (context, snapshot) {
                  final style = snapshot.data;
                  if (style == null) return const SizedBox.shrink();
                  return vmt.VectorTileLayer(
                    key: ValueKey(dark),
                    theme: style.theme,
                    sprites: style.sprites,
                    tileProviders: style.providers,
                    layerMode: vmt.VectorTileLayerMode.raster,
                    maximumZoom: 19,
                    // Tiles are kept by the tile store; this is only the
                    // library's own scratch.
                    fileCacheMaximumSizeInBytes: 4 * 1024 * 1024,
                    fileCacheTtl: const Duration(hours: 1),
                  );
                },
              ),
              if (here != null && here.accuracy != null)
                CircleLayer(
                  circles: [
                    CircleMarker(
                      point: LatLng(here.lat, here.lng),
                      radius: here.accuracy!,
                      useRadiusInMeter: true,
                      color: _googleBlue.withValues(alpha: .15),
                      borderColor: _googleBlue.withValues(alpha: .4),
                      borderStrokeWidth: 1,
                    ),
                  ],
                ),
              MarkerLayer(
                rotate: true,
                markers: [
                  if (_pin != null)
                    Marker(
                      point: _pin!,
                      width: 40,
                      height: 48,
                      alignment: Alignment.topCenter,
                      child: const Icon(
                        Icons.location_on,
                        size: 44,
                        color: Color(0xffea4335),
                      ),
                    ),
                  for (final (person, fix) in people)
                    Marker(
                      point: LatLng(fix.lat, fix.lng),
                      width: 120,
                      height: 84,
                      alignment: Alignment.topCenter,
                      child: _FriendMarker(
                        name: widget.nameOf(person),
                        avatar: node.avatars.of(person),
                        color: personColor(person, dark: dark),
                        stale: _stale(fix),
                        selected: _selected == person,
                        onTap: () => _select(person),
                      ),
                    ),
                  for (final (device, fix) in _otherDevices)
                    Marker(
                      point: LatLng(fix.lat, fix.lng),
                      width: 110,
                      height: 52,
                      alignment: Alignment.topCenter,
                      child: _DeviceMarker(
                        label: fix.device.isEmpty ? 'Your device' : fix.device,
                        stale: _stale(fix),
                        primary: share.primary == device,
                      ),
                    ),
                  if (here != null)
                    Marker(
                      point: LatLng(here.lat, here.lng),
                      width: 40,
                      height: 40,
                      child: _MyDot(
                        heading: here.heading,
                        moving: (here.speed ?? 0) > 1,
                      ),
                    ),
                ],
              ),
              RichAttributionWidget(
                alignment: AttributionAlignment.bottomLeft,
                showFlutterMapAttribution: false,
                attributions: [
                  TextSourceAttribution(
                    '© OpenStreetMap contributors',
                    onTap: () => launchUrl(
                      Uri.parse('https://www.openstreetmap.org/copyright'),
                    ),
                  ),
                  TextSourceAttribution(
                    'OpenFreeMap © OpenMapTiles',
                    onTap: () => launchUrl(Uri.parse('https://openfreemap.org')),
                  ),
                ],
              ),
            ],
          ),
          // Controls.
          SafeArea(
            minimum: const EdgeInsets.all(12),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _searchBar(context),
                    if (_search.text.trim().isNotEmpty)
                      _results(context)
                    else
                      _peopleChips(context, people),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            right: 12,
            bottom: 12,
            child: SafeArea(child: _fabs(context, scheme, cardUp: card != null)),
          ),
          if (card != null) Align(alignment: Alignment.bottomCenter, child: card),
        ],
      ),
    );
  }

  bool _stale(Fix fix) =>
      DateTime.now().millisecondsSinceEpoch - fix.at > 3 * 3600 * 1000;

  Widget _pill({required Widget child, EdgeInsets? padding}) => Material(
    elevation: 3,
    shadowColor: Colors.black54,
    borderRadius: BorderRadius.circular(28),
    color: Theme.of(context).colorScheme.surface,
    child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
  );

  Widget _searchBar(BuildContext context) => _pill(
    child: SizedBox(
      height: 52,
      child: Row(
        children: [
          IconButton(
            tooltip: 'Menu',
            icon: const Icon(Icons.menu),
            onPressed: () => _showMapMenu(context, this),
          ),
          Expanded(
            child: TextField(
              controller: _search,
              focusNode: _searchFocus,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                hintText: 'Search friends or coordinates',
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                isDense: true,
              ),
              onSubmitted: (_) => _submit(),
            ),
          ),
          if (_search.text.isNotEmpty)
            IconButton(
              tooltip: 'Clear',
              icon: const Icon(Icons.close),
              onPressed: _search.clear,
            )
          else
            IconButton(
              tooltip: 'Location sharing',
              icon: Icon(
                share.sharing ? Icons.people_alt : Icons.people_alt_outlined,
                color: share.sharing ? _googleBlue : null,
              ),
              onPressed: () => _openSharing(context, this),
            ),
        ],
      ),
    ),
  );

  List<(String, Fix)> get _matches {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return const [];
    return [
      for (final p in _people)
        if (widget.nameOf(p.$1).toLowerCase().contains(q)) p,
    ];
  }

  void _submit() {
    final point = parseCoordinates(_search.text);
    if (point != null) {
      _goToPoint(point);
    } else if (_matches.isNotEmpty) {
      _pickPerson(_matches.first.$1);
    }
  }

  void _goToPoint(LatLng point) {
    _search.clear();
    _searchFocus.unfocus();
    setState(() {
      _pin = point;
      _selected = null;
    });
    _moveTo(point, zoom: 15);
  }

  void _pickPerson(String person) {
    _search.clear();
    _searchFocus.unfocus();
    _select(person);
  }

  Widget _results(BuildContext context) {
    final point = parseCoordinates(_search.text);
    final matches = _matches;
    final shared = node.contacts.values
        .map((c) => c.person)
        .where((p) => p != node.person)
        .toSet();
    final unlocated = [
      for (final p in shared)
        if (node.locations.of(p) == null &&
            widget.nameOf(p).toLowerCase().contains(
              _search.text.trim().toLowerCase(),
            ))
          p,
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: _pill(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 6),
            children: [
              if (point != null)
                ListTile(
                  leading: const Icon(Icons.place_outlined),
                  title: Text(
                    '${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)}',
                  ),
                  subtitle: const Text('Go to these coordinates'),
                  onTap: () => _goToPoint(point),
                ),
              for (final (person, fix) in matches)
                ListTile(
                  leading: _Avatar(
                    name: widget.nameOf(person),
                    color: personColor(person, dark: _dark),
                    avatar: node.avatars.of(person),
                  ),
                  title: Text(widget.nameOf(person)),
                  subtitle: Text(ago(fix.at)),
                  onTap: () => _pickPerson(person),
                ),
              for (final person in unlocated)
                ListTile(
                  leading: _Avatar(
                    name: widget.nameOf(person),
                    color: Colors.grey,
                    avatar: node.avatars.of(person),
                  ),
                  title: Text(widget.nameOf(person)),
                  subtitle: const Text('Has not shared a location yet'),
                  enabled: false,
                ),
              if (point == null && matches.isEmpty && unlocated.isEmpty)
                const ListTile(
                  leading: Icon(Icons.search_off),
                  title: Text('No friends match'),
                  subtitle: Text(
                    'Place search is not available yet. Try coordinates like 51.5, -0.12',
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _peopleChips(BuildContext context, List<(String, Fix)> people) {
    if (people.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: SizedBox(
        height: 40,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            for (final (person, fix) in people)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Material(
                  elevation: 2,
                  shape: const StadiumBorder(),
                  color: _selected == person
                      ? _googleBlue.withValues(alpha: .15)
                      : Theme.of(context).colorScheme.surface,
                  child: InkWell(
                    customBorder: const StadiumBorder(),
                    onTap: () => _select(person),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(6, 4, 14, 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _Avatar(
                            name: widget.nameOf(person),
                            color: personColor(person, dark: _dark),
                            size: 28,
                            faded: _stale(fix),
                            avatar: node.avatars.of(person),
                          ),
                          const SizedBox(width: 8),
                          Text(widget.nameOf(person)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _fabs(BuildContext context, ColorScheme scheme, {required bool cardUp}) {
    Widget round(Widget icon, String tip, VoidCallback onTap) => Tooltip(
      message: tip,
      child: Material(
        elevation: 3,
        shape: const CircleBorder(),
        color: scheme.surface,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(width: 48, height: 48, child: Center(child: icon)),
        ),
      ),
    );
    return Padding(
      padding: EdgeInsets.only(bottom: cardUp ? 168 : 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_rotation.abs() > 1) ...[
            round(
              Transform.rotate(
                angle: -_rotation * math.pi / 180,
                child: const Icon(Icons.navigation, color: Color(0xffea4335)),
              ),
              'Face north',
              () => _controller.rotate(0),
            ),
            const SizedBox(height: 12),
          ],
          round(const Icon(Icons.layers_outlined), 'Map details', () {
            _showMapDetails(context, this);
          }),
          const SizedBox(height: 12),
          round(
            Icon(
              _follow ? Icons.my_location : Icons.location_searching,
              color: _me == null ? null : _googleBlue,
            ),
            'Your location',
            _goToMe,
          ),
        ],
      ),
    );
  }

  Widget? _card(BuildContext context) {
    final person = _selected;
    final pin = _pin;
    if (person != null) {
      final fix = node.locations.of(person);
      if (fix == null) return null;
      return _InfoCard(
        key: ValueKey(person),
        leading: _Avatar(
          name: widget.nameOf(person),
          color: personColor(person, dark: _dark),
          size: 44,
          faded: _stale(fix),
          avatar: node.avatars.of(person),
        ),
        title: widget.nameOf(person),
        subtitle: [
          'Updated ${ago(fix.at)}',
          if (fix.device.isNotEmpty) fix.device,
          if (_me case final me?)
            '${distanceText(me.distanceTo(fix.lat, fix.lng))} from you',
        ].join(' · '),
        actions: [
          if (widget.onMessage != null)
            _Action(Icons.chat_bubble_outline, 'Message', () {
              widget.onMessage!(person);
            }),
          _Action(Icons.directions_outlined, 'Directions', () {
            openDirections(LatLng(fix.lat, fix.lng));
          }),
          _Action(Icons.copy, 'Copy', () {
            Clipboard.setData(
              ClipboardData(text: '${fix.lat.toStringAsFixed(6)}, ${fix.lng.toStringAsFixed(6)}'),
            );
            _say('Coordinates copied');
          }),
        ],
        onClose: () => setState(() => _selected = null),
      );
    }
    if (pin != null) {
      return _InfoCard(
        key: const ValueKey('pin'),
        leading: const Icon(Icons.location_on, size: 40, color: Color(0xffea4335)),
        title: 'Dropped pin',
        subtitle:
            '${pin.latitude.toStringAsFixed(5)}, ${pin.longitude.toStringAsFixed(5)}'
            '${_me == null ? '' : ' · ${distanceText(Distance().as(LengthUnit.Meter, LatLng(_me!.lat, _me!.lng), pin).toDouble())} from you'}',
        actions: [
          _Action(Icons.directions_outlined, 'Directions', () {
            openDirections(pin);
          }),
          _Action(Icons.download_for_offline_outlined, 'Save area', () {
            _saveVisibleArea(context, this);
          }),
          _Action(Icons.copy, 'Copy', () {
            Clipboard.setData(
              ClipboardData(text: '${pin.latitude.toStringAsFixed(6)}, ${pin.longitude.toStringAsFixed(6)}'),
            );
            _say('Coordinates copied');
          }),
        ],
        onClose: () => setState(() => _pin = null),
      );
    }
    return null;
  }

  /// Hands a destination to the system: any maps app on a phone, the
  /// OpenStreetMap route planner in a browser elsewhere. Routing inside the
  /// app is not built yet.
  Future<void> openDirections(LatLng to) async {
    final uri = Theme.of(context).platform == TargetPlatform.android
        ? Uri.parse('geo:${to.latitude},${to.longitude}?q=${to.latitude},${to.longitude}')
        : Uri.parse(
            'https://www.openstreetmap.org/directions?to=${to.latitude}%2C${to.longitude}',
          );
    if (!await launchUrl(uri) && mounted) _say('No app could show directions');
  }
}

class _Avatar extends StatelessWidget {
  final String name;
  final Color color;
  final double size;
  final bool faded;

  /// Their profile picture, drawn over the initial once decoded.
  final Avatar? avatar;
  const _Avatar({
    required this.name,
    required this.color,
    this.size = 40,
    this.faded = false,
    this.avatar,
  });
  @override
  Widget build(BuildContext context) {
    final letter = ProfileAvatar.initial(name);
    final image = AvatarImage.sized(context, avatar, size);
    final initial = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: faded ? Color.alphaBlend(Colors.white70, color) : color,
      ),
      child: Text(
        letter,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: size * .45,
        ),
      ),
    );
    if (image == null) return initial;
    return ClipOval(
      child: Stack(
        children: [
          initial,
          Positioned.fill(
            child: Opacity(
              opacity: faded ? .45 : 1,
              child: Image(
                image: image,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A friend on the map: a coloured disc with their initial and a point, and
/// their name underneath. Faded when the position is old.
class _FriendMarker extends StatelessWidget {
  final String name;
  final Avatar? avatar;
  final Color color;
  final bool stale, selected;
  final VoidCallback onTap;
  const _FriendMarker({
    required this.name,
    this.avatar,
    required this.color,
    required this.stale,
    required this.selected,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final size = selected ? 46.0 : 40.0;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2.5),
              boxShadow: const [
                BoxShadow(blurRadius: 4, color: Colors.black38, offset: Offset(0, 1)),
              ],
            ),
            child: _Avatar(
              name: name,
              color: color,
              size: size,
              faded: stale,
              avatar: avatar,
            ),
          ),
          CustomPaint(size: const Size(14, 8), painter: _Point(Colors.white)),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(0xff202124),
              shadows: [
                Shadow(color: Colors.white, blurRadius: 3),
                Shadow(color: Colors.white, blurRadius: 3),
                Shadow(color: Colors.white, blurRadius: 3),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Point extends CustomPainter {
  final Color color;
  _Point(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      Path()
        ..moveTo(0, 0)
        ..lineTo(size.width, 0)
        ..lineTo(size.width / 2, size.height)
        ..close(),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_Point old) => old.color != color;
}

/// One of this person's other devices: a small blue badge with its name, and a
/// filled one for the primary device, which is what friends see.
class _DeviceMarker extends StatelessWidget {
  final String label;
  final bool stale, primary;
  const _DeviceMarker({
    required this.label,
    required this.stale,
    required this.primary,
  });
  @override
  Widget build(BuildContext context) => Tooltip(
    message: primary ? '$label (what friends see)' : label,
    child: Column(
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: stale ? _googleBlue.withValues(alpha: .5) : _googleBlue,
            border: Border.all(color: Colors.white, width: 2.5),
            boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black38)],
          ),
          child: Icon(
            primary ? Icons.share_location : Icons.devices_other,
            size: 15,
            color: Colors.white,
          ),
        ),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: Color(0xff202124),
            shadows: [
              Shadow(color: Colors.white, blurRadius: 3),
              Shadow(color: Colors.white, blurRadius: 3),
              Shadow(color: Colors.white, blurRadius: 3),
            ],
          ),
        ),
      ],
    ),
  );
}

/// The blue dot for where this device is.
class _MyDot extends StatelessWidget {
  final double? heading;
  final bool moving;
  const _MyDot({this.heading, this.moving = false});
  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'You',
    child: Stack(
      alignment: Alignment.center,
      children: [
        if (heading != null && moving)
          Transform.rotate(
            angle: heading! * math.pi / 180,
            child: const Align(
              alignment: Alignment.topCenter,
              child: Icon(Icons.arrow_drop_up, size: 30, color: _googleBlue),
            ),
          ),
        Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: _googleBlue,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: const [BoxShadow(blurRadius: 5, color: Colors.black38)],
          ),
        ),
      ],
    ),
  );
}

class _Action {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _Action(this.icon, this.label, this.onTap);
}

/// The card at the foot of the map for a selected friend or dropped pin.
class _InfoCard extends StatelessWidget {
  final Widget leading;
  final String title, subtitle;
  final List<_Action> actions;
  final VoidCallback onClose;
  const _InfoCard({
    super.key,
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.actions,
    required this.onClose,
  });
  @override
  Widget build(BuildContext context) => SafeArea(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Material(
          elevation: 6,
          borderRadius: BorderRadius.circular(20),
          color: Theme.of(context).colorScheme.surface,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    leading,
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Text(
                            subtitle,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      icon: const Icon(Icons.close),
                      onPressed: onClose,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final a in actions)
                        OutlinedButton.icon(
                          onPressed: a.onTap,
                          icon: Icon(a.icon, size: 18),
                          label: Text(a.label),
                          style: OutlinedButton.styleFrom(
                            shape: const StadiumBorder(),
                            foregroundColor: _googleBlue,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
