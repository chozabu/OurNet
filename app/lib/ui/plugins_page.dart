import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ournet_core/ournet_core.dart';

/// What each grant lets a plugin do, as the install prompt says it.
const grantMeanings = {
  'objects': 'Save and sync its own data, signed by you',
  'identity': "See your friends' and groups' names and who is in each group",
  'live': "Exchange live messages with friends' devices that run it",
  'tun':
      'Run a network interface (a VPN) for traffic to your devices and '
      'friends; the system asks too',
};

/// Settings › Plugins: what is installed, what friends offer (shared
/// plugins and updates from publishers), what ships with the app, and
/// installing from a file. On desktop, publishing and a developer folder
/// whose packages hot reload as they are rebuilt.
class PluginsPage extends StatefulWidget {
  final Plugins plugins;

  /// Picks a `.ournet-plugin` file and returns its bytes.
  final Future<Uint8List?> Function() pickPackage;
  /// Saves a signed package the person just published.
  final Future<void> Function(String name, Uint8List bytes) savePackage;

  /// A person's display name.
  final String Function(String person) nameOf;
  final void Function(String message) notice;
  const PluginsPage({
    super.key,
    required this.plugins,
    required this.pickPackage,
    required this.savePackage,
    required this.nameOf,
    required this.notice,
  });

  @override
  State<PluginsPage> createState() => _PluginsPageState();
}

class _PluginsPageState extends State<PluginsPage> {
  StreamSubscription<String>? _changes;
  StreamSubscription<Set<String>>? _offerChanges;
  Timer? _offerRefresh;
  List<PluginPackage> bundled = const [];
  List<PluginOffer> offers = const [];
  final devFolder = TextEditingController();
  bool watching = false;

  Plugins get plugins => widget.plugins;

  @override
  void initState() {
    super.initState();
    _changes = plugins.changes.listen((_) {
      if (mounted) setState(() {});
      _refreshOffers();
    });
    _offerChanges = plugins.node.onChangesTo({
      PluginRelease.packageKind,
    }, _refreshOffers);
    _refreshOffers();
    devFolder.text =
        plugins.node.store.setting('pluginDevFolder') as String? ?? '';
    unawaited(_loadBundled());
  }

  @override
  void dispose() {
    _changes?.cancel();
    _offerChanges?.cancel();
    _offerRefresh?.cancel();
    devFolder.dispose();
    super.dispose();
  }

  /// Packages shipped in `assets/plugins/`.
  Future<void> _loadBundled() async {
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final found = <PluginPackage>[];
      for (final asset in manifest.listAssets()) {
        if (!asset.startsWith('assets/plugins/') ||
            !asset.endsWith('.ournet-plugin')) {
          continue;
        }
        final data = await rootBundle.load(asset);
        found.add(PluginPackage.read(data.buffer.asUint8List()));
      }
      if (mounted) setState(() => bundled = found);
    } catch (e) {
      widget.notice('Could not list bundled plugins: $e');
    }
  }

  /// Coalesced: settings and objects change in bursts.
  void _refreshOffers() {
    _offerRefresh?.cancel();
    _offerRefresh = Timer(const Duration(milliseconds: 300), () async {
      final found = await plugins.offers();
      if (mounted) setState(() => offers = found);
    });
  }

  /// Asks before installing: what it is, who signed it, what it may do.
  Future<bool> _confirm({
    required String id,
    required String name,
    required String version,
    required String description,
    required Set<String> grants,
    required String? publisher,
    String changes = '',
  }) async {
    final existing = plugins[id];
    final replaces =
        existing?.publisher != null && existing!.publisher != publisher;
    final update = existing != null && !replaces;
    final added = grants.difference(update ? existing.granted : const {});
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(update ? 'Update $name?' : 'Install $name?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                publisher == null
                    ? 'Version $version, unsigned'
                    : 'Version $version, published by '
                          '${publisher == plugins.node.person ? 'you' : widget.nameOf(publisher)}',
              ),
              if (replaces)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'It replaces ${existing.manifest.name} from '
                    '${widget.nameOf(existing.publisher!)}, and what that '
                    'kept here goes. Both read data of the same kinds.',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (description.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(description),
              ],
              if (changes.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('What changed: $changes'),
              ],
              const SizedBox(height: 16),
              Text(
                grants.isEmpty
                    ? 'It runs sandboxed and asks for nothing more.'
                    : 'It runs sandboxed. It may:',
              ),
              for (final g in grants)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    added.contains(g)
                        ? Icons.new_releases_outlined
                        : Icons.check,
                  ),
                  title: Text(grantMeanings[g] ?? g),
                  subtitle: added.contains(g) && update
                      ? const Text('New in this version')
                      : null,
                ),
              const SizedBox(height: 8),
              const Text(
                'It never holds your keys, and reaches nothing else of yours.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(update ? 'Update' : 'Install'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _install(PluginPackage package) async {
    final m = package.manifest;
    final PluginRelease? release;
    try {
      release = await plugins.releaseOf(package);
    } on FormatException catch (e) {
      widget.notice('Not installed: ${e.message}');
      return;
    }
    if (!await _confirm(
      id: m.id,
      name: m.name,
      version: m.version,
      description: m.description,
      grants: m.grants,
      publisher: release?.publisher,
      changes: release?.changes ?? '',
    )) {
      return;
    }
    try {
      await plugins.install(package, grants: m.grants, release: release);
      widget.notice('${m.name} installed');
    } catch (e) {
      widget.notice('Could not install ${m.name}: $e');
    }
    if (mounted) setState(() {});
  }

  Future<void> _installOffer(PluginOffer offer) async {
    final r = offer.release;
    if (!await _confirm(
      id: r.plugin,
      name: r.name,
      version: r.version,
      description: r.summary,
      grants: r.grants,
      publisher: r.publisher,
      changes: r.changes,
    )) {
      return;
    }
    widget.notice('Fetching ${r.name} ${r.version}…');
    try {
      await plugins.installOffer(offer, grants: r.grants);
      widget.notice('${r.name} ${r.version} installed');
    } catch (e) {
      widget.notice('Could not install ${r.name}: $e');
    }
  }

  /// Signs a package as this person's release, for everyone who follows
  /// them, and offers to save the signed file.
  Future<void> _publish() async {
    final bytes = await widget.pickPackage();
    if (bytes == null) return;
    final PluginPackage package;
    try {
      package = await PluginPackage.decode(bytes);
    } on FormatException catch (e) {
      widget.notice('Not a plugin package: ${e.message}');
      return;
    }
    if (!mounted) return;
    final m = package.manifest;
    final changes = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Publish ${m.name} ${m.version}?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Signed by you. Friends who follow you, and anyone they pass '
              'it to, can install it and are offered it as an update.',
            ),
            TextField(
              controller: changes,
              maxLength: 4096,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'What changed'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Publish'),
          ),
        ],
      ),
    );
    final text = changes.text;
    changes.dispose();
    if (ok != true) return;
    try {
      final signed = await plugins.publish(package, changes: text);
      widget.notice('${m.name} ${m.version} published');
      await widget.savePackage('${m.id}-${m.version}.ournet-plugin', signed);
    } catch (e) {
      widget.notice('Not published: ${e is StateError ? e.message : e}');
    }
  }

  /// Shares an installed, signed plugin with chosen friends.
  Future<void> _share(InstalledPlugin plugin) async {
    final node = plugins.node;
    final friends = {
      for (final c in node.contacts.values)
        if (c.person != node.person && !node.blocked.contains(c.person))
          c.person,
    }.toList()..sort((a, b) => widget.nameOf(a).compareTo(widget.nameOf(b)));
    final chosen = <String>{};
    final people = await showDialog<Set<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, change) => AlertDialog(
          title: Text('Share ${plugin.manifest.name} with'),
          content: SizedBox(
            width: 360,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final person in friends)
                  CheckboxListTile(
                    value: chosen.contains(person),
                    title: Text(widget.nameOf(person)),
                    onChanged: (on) => change(
                      () => on == true
                          ? chosen.add(person)
                          : chosen.remove(person),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, chosen),
              child: const Text('Share'),
            ),
          ],
        ),
      ),
    );
    if (people == null || people.isEmpty) return;
    try {
      await plugins.share(plugin.id, people.toList());
      widget.notice('${plugin.manifest.name} shared');
    } catch (e) {
      widget.notice('Not shared: ${e is StateError ? e.message : e}');
    }
  }

  Future<void> _installFile() async {
    final bytes = await widget.pickPackage();
    if (bytes == null) return;
    try {
      await _install(PluginPackage.read(bytes));
    } on FormatException catch (e) {
      widget.notice('Not a plugin this app can install: ${e.message}');
    }
  }

  Future<void> _uninstall(InstalledPlugin plugin) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${plugin.manifest.name}?'),
        content: const Text(
          'What it kept on this device goes with it. What it published '
          'stays, signed by you.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) await plugins.uninstall(plugin.id);
  }

  void _watch(bool on) {
    final folder = devFolder.text.trim();
    plugins.node.store.set('pluginDevFolder', folder.isEmpty ? null : folder);
    if (!on) {
      plugins.unwatch();
      setState(() => watching = false);
      return;
    }
    final ok = plugins.watch(folder);
    if (!ok) widget.notice('Cannot watch $folder');
    setState(() => watching = ok);
  }

  String _status(InstalledPlugin p) => switch (p.status) {
    PluginStatus.running => 'Running',
    PluginStatus.starting => 'Starting…',
    PluginStatus.stopped => 'Off',
    PluginStatus.failed => 'Stopped: ${p.error ?? 'unknown error'}',
  };

  @override
  Widget build(BuildContext context) {
    final installed = plugins.installed;
    final available = [
      for (final p in bundled)
        if (plugins[p.manifest.id]?.manifest.version != p.manifest.version) p,
    ];
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        if (!plugins.available)
          const ListTile(
            leading: Icon(Icons.extension_off_outlined),
            title: Text('Plugins do not run on this device'),
          ),
        const ListTile(
          title: Text(
            'Installed',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        if (installed.isEmpty)
          const ListTile(
            leading: Icon(Icons.extension_outlined),
            title: Text('No plugins yet'),
            subtitle: Text('Plugins add games, wikis and more, sandboxed.'),
          ),
        for (final p in installed)
          ListTile(
            leading: const Icon(Icons.extension),
            title: Text('${p.manifest.name} ${p.manifest.version}'),
            subtitle: Text(
              [
                _status(p),
                if (p.publisher != null)
                  'by ${p.publisher == plugins.node.person ? 'you' : widget.nameOf(p.publisher!)}',
              ].join(' · '),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  value: p.enabled,
                  onChanged: (on) => plugins.setEnabled(p.id, on),
                ),
                PopupMenuButton<String>(
                  onSelected: (choice) => switch (choice) {
                    'restart' => plugins.restart(p.id),
                    'share' => _share(p),
                    _ => _uninstall(p),
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'restart',
                      child: Text('Restart'),
                    ),
                    if (p.publisher != null)
                      const PopupMenuItem(
                        value: 'share',
                        child: Text('Share with friends'),
                      ),
                    const PopupMenuItem(value: 'remove', child: Text('Remove')),
                  ],
                ),
              ],
            ),
          ),
        if (offers.isNotEmpty) ...[
          const Divider(),
          const ListTile(
            title: Text(
              'Offered to you',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          for (final o in offers)
            ListTile(
              leading: const Icon(Icons.extension_outlined),
              title: Text('${o.release.name} ${o.release.version}'),
              subtitle: Text(
                [
                  'by ${widget.nameOf(o.release.publisher)}',
                  if (o.distribution.author != o.release.publisher)
                    'shared by ${widget.nameOf(o.distribution.author)}',
                  if (o.release.changes.isNotEmpty) o.release.changes,
                ].join(' · '),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: FilledButton.tonal(
                onPressed: plugins.available ? () => _installOffer(o) : null,
                child: Text(
                  plugins[o.release.plugin] != null && !o.replaces
                      ? 'Update'
                      : 'Install',
                ),
              ),
            ),
        ],
        if (available.isNotEmpty) ...[
          const Divider(),
          const ListTile(
            title: Text(
              'Comes with OurNet',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          for (final p in available)
            ListTile(
              leading: const Icon(Icons.extension_outlined),
              title: Text('${p.manifest.name} ${p.manifest.version}'),
              subtitle: Text(p.manifest.description),
              trailing: FilledButton.tonal(
                onPressed: plugins.available ? () => _install(p) : null,
                child: Text(
                  plugins[p.manifest.id] == null ? 'Install' : 'Update',
                ),
              ),
            ),
        ],
        const Divider(),
        ListTile(
          leading: const Icon(Icons.file_open_outlined),
          title: const Text('Install from a file'),
          subtitle: const Text('A .ournet-plugin package'),
          enabled: plugins.available,
          onTap: _installFile,
        ),
        if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) ...[
          const Divider(),
          ListTile(
            leading: const Icon(Icons.publish_outlined),
            title: const Text('Publish a package'),
            subtitle: const Text(
              'Sign it as yours and offer it to friends who follow you',
            ),
            onTap: _publish,
          ),
          ListTile(
            title: const Text('Developer folder'),
            subtitle: TextField(
              controller: devFolder,
              decoration: const InputDecoration(
                hintText: r'D:\git\OurNetAS\plugins\dist',
              ),
            ),
            trailing: Switch(value: watching, onChanged: _watch),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Installed plugins reload, keeping their state, when their '
              'package there changes (plugins/pack --watch).',
            ),
          ),
        ],
      ],
    );
  }
}
