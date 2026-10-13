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
};

/// Settings › Plugins: what is installed, what ships with the app, and
/// installing from a file. On desktop, a developer folder whose packages hot
/// reload as they are rebuilt.
class PluginsPage extends StatefulWidget {
  final Plugins plugins;

  /// Picks a `.ournet-plugin` file and returns its bytes.
  final Future<Uint8List?> Function() pickPackage;
  final void Function(String message) notice;
  const PluginsPage({
    super.key,
    required this.plugins,
    required this.pickPackage,
    required this.notice,
  });

  @override
  State<PluginsPage> createState() => _PluginsPageState();
}

class _PluginsPageState extends State<PluginsPage> {
  StreamSubscription<String>? _changes;
  List<PluginPackage> bundled = const [];
  final devFolder = TextEditingController();
  bool watching = false;

  Plugins get plugins => widget.plugins;

  @override
  void initState() {
    super.initState();
    _changes = plugins.changes.listen((_) {
      if (mounted) setState(() {});
    });
    devFolder.text =
        plugins.node.store.setting('pluginDevFolder') as String? ?? '';
    unawaited(_loadBundled());
  }

  @override
  void dispose() {
    _changes?.cancel();
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

  Future<void> _install(PluginPackage package) async {
    final m = package.manifest;
    final existing = plugins[m.id];
    final added = m.grants.difference(existing?.granted ?? const {});
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          existing == null ? 'Install ${m.name}?' : 'Update ${m.name}?',
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Version ${m.version}'),
              if (m.description.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(m.description),
              ],
              const SizedBox(height: 16),
              Text(
                m.grants.isEmpty
                    ? 'It runs sandboxed and asks for nothing more.'
                    : 'It runs sandboxed. It may:',
              ),
              for (final g in m.grants)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    added.contains(g)
                        ? Icons.new_releases_outlined
                        : Icons.check,
                  ),
                  title: Text(grantMeanings[g] ?? g),
                  subtitle: added.contains(g) && existing != null
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
            child: Text(existing == null ? 'Install' : 'Update'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await plugins.install(package, grants: m.grants);
      widget.notice('${m.name} installed');
    } catch (e) {
      widget.notice('Could not install ${m.name}: $e');
    }
    if (mounted) setState(() {});
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
              _status(p),
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
                    _ => _uninstall(p),
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'restart', child: Text('Restart')),
                    PopupMenuItem(value: 'remove', child: Text('Remove')),
                  ],
                ),
              ],
            ),
          ),
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
