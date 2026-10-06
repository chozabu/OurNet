part of 'map_page.dart';

/// The menu behind the hamburger button.
void _showMapMenu(BuildContext context, _MapPageState map) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.people_alt_outlined),
            title: const Text('Location sharing'),
            subtitle: Text(
              map.share.sharing
                  ? 'Your friends can see where you are'
                  : 'Paused: nobody can see where you are',
            ),
            onTap: () {
              Navigator.pop(sheet);
              _openSharing(context, map);
            },
          ),
          ListTile(
            leading: const Icon(Icons.download_for_offline_outlined),
            title: const Text('Offline maps'),
            subtitle: Text(
              map.widget.tiles.online
                  ? 'Save areas to use without a connection'
                  : 'Internet use for maps is off',
            ),
            onTap: () {
              Navigator.pop(sheet);
              _openOfflineMaps(context, map);
            },
          ),
          ListTile(
            leading: const Icon(Icons.layers_outlined),
            title: const Text('Map details'),
            onTap: () {
              Navigator.pop(sheet);
              _showMapDetails(context, map);
            },
          ),
        ],
      ),
    ),
  );
}

/// Map type and what is drawn on it.
void _showMapDetails(BuildContext context, _MapPageState map) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => StatefulBuilder(
      builder: (context, set) {
        final store = map.node.store;
        final style = store.setting('mapStyle') as String? ?? 'auto';
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Map type', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'auto',
                      label: Text('Auto'),
                      icon: Icon(Icons.brightness_auto_outlined),
                    ),
                    ButtonSegment(
                      value: 'light',
                      label: Text('Light'),
                      icon: Icon(Icons.light_mode_outlined),
                    ),
                    ButtonSegment(
                      value: 'dark',
                      label: Text('Dark'),
                      icon: Icon(Icons.dark_mode_outlined),
                    ),
                  ],
                  selected: {style},
                  onSelectionChanged: (v) {
                    store.set('mapStyle', v.first);
                    set(() {});
                    map.refresh();
                  },
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Friends'),
                  subtitle: const Text('Show where friends last were'),
                  value: store.setting('mapFriends') != false,
                  onChanged: (v) {
                    store.set('mapFriends', v);
                    set(() {});
                    map.refresh();
                  },
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

void _openSharing(BuildContext context, _MapPageState state) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => LocationSharingPage(
        node: state.node,
        share: state.share,
        nameOf: state.widget.nameOf,
      ),
    ),
  );
}

void _openOfflineMaps(BuildContext context, _MapPageState map) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => OfflineMapsPage(
        tiles: map.widget.tiles,
        node: map.node,
        view: () {
          if (!map.ready) return null;
          final b = map.mapController.camera.visibleBounds;
          return (
            bounds: MapBounds(b.south, b.west, b.north, b.east),
            label: '${b.center.latitude.toStringAsFixed(2)}, ${b.center.longitude.toStringAsFixed(2)}',
          );
        },
      ),
    ),
  );
}

/// Saves what the map currently shows, after asking how much detail.
Future<void> _saveVisibleArea(BuildContext context, _MapPageState map) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => OfflineMapsPage(
          tiles: map.widget.tiles,
          node: map.node,
          startAdding: true,
          view: () {
            if (!map.ready) return null;
            final b = map.mapController.camera.visibleBounds;
            return (
              bounds: MapBounds(b.south, b.west, b.north, b.east),
              label: '${b.center.latitude.toStringAsFixed(2)}, ${b.center.longitude.toStringAsFixed(2)}',
            );
          },
        ),
      ),
    );

String bytesText(int bytes) => bytes < 1024 * 1024
    ? '${(bytes / 1024).round()} KB'
    : bytes < 1024 * 1024 * 1024
    ? '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB'
    : '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';

/// Who sees where you are, and the switch.
class LocationSharingPage extends StatefulWidget {
  final Node node;
  final LocationShare share;
  final String Function(String person) nameOf;
  const LocationSharingPage({
    super.key,
    required this.node,
    required this.share,
    required this.nameOf,
  });
  @override
  State<LocationSharingPage> createState() => _LocationSharingPageState();
}

class _LocationSharingPageState extends State<LocationSharingPage> {
  StreamSubscription<void>? _sub;
  @override
  void initState() {
    super.initState();
    widget.share.addListener(_changed);
    _sub = widget.node.locations.changes.listen((_) => _changed());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.share.removeListener(_changed);
    _sub?.cancel();
    super.dispose();
  }

  String get _problem => switch (widget.share.access) {
    LocationAccess.granted => '',
    LocationAccess.denied =>
      'OurNet does not have permission to read this device’s location yet.',
    LocationAccess.deniedForever =>
      'Location is blocked for OurNet in system settings.',
    LocationAccess.serviceOff => 'Location services are turned off on this device.',
    LocationAccess.unsupported =>
      'This device cannot report its own position. It still shows where your other devices are.',
  };

  /// Which of this person's devices friends see, and where the others are.
  List<Widget> _devices(BuildContext context) {
    final share = widget.share, node = widget.node;
    final self = node.identity.device;
    final others = share.otherDevices;
    final names = node.deviceNames();
    final primary = share.primary;
    String when(String device) {
      final fix = node.locations.ofDevice(device);
      return fix == null ? 'No position yet' : 'Updated ${ago(fix.at)}';
    }

    Widget tile(String id, String label, String detail, {required bool me}) =>
        ListTile(
          leading: Icon(
            primary == id ? Icons.share_location : Icons.devices_other,
            color: primary == id ? _googleBlue : null,
          ),
          title: Text(me ? '$label (this device)' : label),
          subtitle: Text(
            [if (primary == id) 'Friends see this device', detail].join(' · '),
          ),
          trailing: primary == id
              ? null
              : TextButton(
                  onPressed: () => share.makePrimary(id),
                  child: const Text('Use for friends'),
                ),
        );

    return [
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          'Your devices',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        child: Text(
          primary == null
              ? 'Every device that can read its position tells your friends '
                    'where you are. Choose one, usually your phone, so a '
                    'laptop left at home does not.'
              : 'Only the device chosen here tells your friends where you '
                    'are. Your own devices always see each other.',
        ),
      ),
      tile(
        self,
        names[self] ?? node.identity.certificate.label,
        when(self),
        me: true,
      ),
      for (final c in others)
        tile(c.device, names[c.device] ?? c.label, when(c.device), me: false),
      SwitchListTile(
        title: const Text('Show this device to my other devices'),
        subtitle: const Text(
          'Turn off on a spare phone to save its battery. Friends are not '
          'affected.',
        ),
        value: share.sendsToOwnDevices,
        onChanged: share.setShowToOwnDevices,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final share = widget.share, node = widget.node;
    final friends =
        node.contacts.values
            .map((c) => c.person)
            .where((p) => p != node.person && !node.blocked.contains(p))
            .toSet()
            .toList()
          ..sort((a, b) => widget.nameOf(a).compareTo(widget.nameOf(b)));
    final problem = _problem;
    return Scaffold(
      appBar: AppBar(title: const Text('Location sharing')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('Share my location with friends'),
            subtitle: Text(
              share.sharing
                  ? 'Live, with everyone listed below. Turn off to pause.'
                  : 'Paused. Friends see where you were when you stopped.',
            ),
            value: share.sharing,
            onChanged: (v) => share.setSharing(v),
          ),
          if (share.sharing && problem.isNotEmpty)
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(problem),
                    if (share.access == LocationAccess.denied ||
                        share.access == LocationAccess.serviceOff)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: FilledButton(
                          onPressed: () => share.start(request: true),
                          child: const Text('Allow location'),
                        ),
                      ),
                    if (share.access == LocationAccess.deniedForever)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: FilledButton(
                          onPressed: share.openSystemSettings,
                          child: const Text('Open settings'),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'OurNet keeps only the last place each person was. There is no '
              'trail and no history, and it stays until a newer position '
              'replaces it. Positions go straight to your friends’ devices '
              'and your own, never through a server. A friend who is offline '
              'sees where you were when they last connected.',
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              'Who can see where you are',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          if (friends.isEmpty)
            const ListTile(
              title: Text('Nobody yet'),
              subtitle: Text('Friends you connect with are added here.'),
            ),
          for (final person in friends)
            ListTile(
              leading: _Avatar(
                name: widget.nameOf(person),
                color: personColor(person, dark: Theme.of(context).brightness == Brightness.dark),
                size: 36,
              ),
              title: Text(widget.nameOf(person)),
              subtitle: Text(
                node.locations.of(person) == null
                    ? 'Not sharing with you yet'
                    : 'Sharing with you · ${ago(node.locations.of(person)!.at)}',
              ),
              trailing: Icon(
                share.sharing ? Icons.visibility_outlined : Icons.visibility_off_outlined,
              ),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'Everyone you have added can see you. To stop sharing with '
              'someone, remove them as a friend or block them on this device.',
            ),
          ),
          ..._devices(context),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Forget saved positions'),
            subtitle: const Text(
              'Removes the last known places stored on this device',
            ),
            onTap: () {
              for (final person in node.locations.all.keys.toList()) {
                node.locations.forget(person);
              }
            },
          ),
        ],
      ),
    );
  }
}

/// Saved areas, and the choice of whether maps may use the internet.
class OfflineMapsPage extends StatefulWidget {
  final MapTiles tiles;
  final Node node;

  /// The area the map shows now, to save.
  final ({MapBounds bounds, String label})? Function() view;
  final bool startAdding;
  const OfflineMapsPage({
    super.key,
    required this.tiles,
    required this.node,
    required this.view,
    this.startAdding = false,
  });
  @override
  State<OfflineMapsPage> createState() => _OfflineMapsPageState();
}

class _OfflineMapsPageState extends State<OfflineMapsPage> {
  MapTiles get tiles => widget.tiles;

  @override
  void initState() {
    super.initState();
    tiles.addListener(_changed);
    if (widget.startAdding) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _add());
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    tiles.removeListener(_changed);
    super.dispose();
  }

  Future<void> _add() async {
    final view = widget.view();
    if (view == null) return;
    final choice = await showDialog<({String name, int maxZoom})>(
      context: context,
      builder: (_) => _AddRegionDialog(view: view),
    );
    if (choice == null || !mounted) return;
    try {
      tiles.addRegion(choice.name, view.bounds, 0, choice.maxZoom);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final regions = tiles.store.regions();
    final online = tiles.online;
    return Scaffold(
      appBar: AppBar(title: const Text('Offline maps')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.download_for_offline_outlined),
        label: const Text('Save visible area'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          SwitchListTile(
            title: const Text('Use the internet for maps'),
            subtitle: const Text(
              'Maps load from OpenFreeMap, which learns roughly where you '
              'look. Off: only saved areas and what was already seen show.',
            ),
            value: online,
            onChanged: (v) {
              widget.node.store.set('mapOnline', v);
              tiles.changed();
            },
          ),
          const Divider(),
          if (regions.isEmpty)
            const ListTile(
              title: Text('No saved areas'),
              subtitle: Text(
                'Move the map to a place you will need without signal, then '
                'save it here. A city takes a few megabytes.',
              ),
            ),
          for (final r in regions) _region(context, r),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.storage_outlined),
            title: const Text('Seen recently'),
            subtitle: Text(
              '${bytesText(tiles.store.cacheBytes)} kept so places you look at '
              'again load fast, up to ${bytesText(tiles.store.cacheLimit)}.',
            ),
            trailing: TextButton(
              onPressed: () {
                tiles.store.clearCache();
                setState(() {});
              },
              child: const Text('Clear'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _region(BuildContext context, OfflineRegion r) {
    final job = tiles.downloads[r.id];
    final running = job != null && !job.finished;
    final failed = job?.error;
    return ListTile(
      leading: Icon(
        r.complete
            ? Icons.offline_pin_outlined
            : running
            ? Icons.downloading
            : Icons.error_outline,
      ),
      title: Text(r.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            r.complete
                ? '${bytesText(r.bytes)} · ${r.tiles} tiles · to detail ${r.maxZoom}'
                : running
                ? '${job.done} of ${job.total} tiles'
                : failed != null
                ? 'Stopped: ${failed.toString().replaceFirst('Bad state: ', '')}'
                : '${bytesText(r.bytes)} saved so far',
          ),
          if (running)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: LinearProgressIndicator(value: job.progress),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!r.complete && !running)
            IconButton(
              tooltip: 'Resume',
              icon: const Icon(Icons.play_arrow),
              onPressed: () => tiles.download(r.id),
            ),
          IconButton(
            tooltip: running ? 'Cancel and delete' : 'Delete',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => tiles.deleteRegion(r.id),
          ),
        ],
      ),
    );
  }
}

class _AddRegionDialog extends StatefulWidget {
  final ({MapBounds bounds, String label}) view;
  const _AddRegionDialog({required this.view});
  @override
  State<_AddRegionDialog> createState() => _AddRegionDialogState();
}

class _AddRegionDialogState extends State<_AddRegionDialog> {
  late final _name = TextEditingController(text: 'Area near ${widget.view.label}');
  double _zoom = 14;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tiles = widget.view.bounds.count(0, _zoom.round());
    final tooLarge = tiles > MapTiles.maxRegionTiles;
    return AlertDialog(
      title: const Text('Save this area'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          const SizedBox(height: 16),
          Text('Detail: ${_zoom < 11 ? 'regions' : _zoom < 13 ? 'towns' : 'streets'}'),
          Slider(
            value: _zoom,
            min: 8,
            max: 14,
            divisions: 6,
            onChanged: (v) => setState(() => _zoom = v),
          ),
          Text(
            tooLarge
                ? 'Too large: zoom the map in, or choose less detail.'
                : 'About ${bytesText(tiles * MapTiles.averageTileBytes)} ($tiles tiles)',
            style: tooLarge
                ? TextStyle(color: Theme.of(context).colorScheme.error)
                : null,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: tooLarge || _name.text.trim().isEmpty
              ? null
              : () => Navigator.pop(context, (
                  name: _name.text.trim(),
                  maxZoom: _zoom.round(),
                )),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
