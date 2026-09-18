part of 'app.dart';

extension _DrivePages on _OurNetAppState {
  Future<void> connectFolder({DriveEntry? folder}) async {
    if (connectingFolder) return;
    setState(() => connectingFolder = true);
    try {
      final location = await pickSyncFolder();
      if (location == null || !mounted) return;
      final local = await folderBackend(location).scan();
      if (!mounted) return;
      final bytes = local.values.fold<int>(0, (n, item) => n + item.size);
      var remoteBytes = 0, remoteFiles = 0;
      if (folder != null) {
        final entries = await Drive(node).entries();
        final parents = {
          for (final e in entries) e.current.entry: e.current.data['folder'],
        };
        for (final entry in entries) {
          if (entry.current.deleted || entry.current.isFolder) continue;
          var parent = entry.current.data['folder'];
          final seen = <String>{};
          while (parent is String && seen.add(parent)) {
            if (parent == folder.current.entry) {
              remoteFiles++;
              remoteBytes += entry.current.data['size'] as int;
              break;
            }
            parent = parents[parent];
          }
        }
      }
      if (!mounted) return;
      final name =
          folder?.current.data['name'] as String? ??
          await ask(
            context,
            'Name in My drive',
            initial: Platform.isAndroid
                ? 'Phone folder'
                : Directory(
                    location,
                  ).uri.pathSegments.where((p) => p.isNotEmpty).last,
          );
      if (name == null || name.trim().isEmpty || !mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Connect $name?'),
          content: SingleChildScrollView(
            child: Text(
              '$location\n\n${local.length} local entries · $bytes bytes\n\n'
              'Changes and deletions sync both ways. Files in this folder are ordinary, decrypted files. '
              'Existing files with matching names are preserved as conflicts; nothing is silently overwritten. '
              '$remoteFiles drive files · up to $remoteBytes bytes to download.\n\n'
              'Sync runs while OurNet is running and resumes when you reopen it. '
              'Current limits: 64 MiB per file and 512 MiB of encrypted storage. '
              'Disconnecting leaves the files in place.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Connect folder'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      final id =
          folder?.current.entry ??
          (await node.content(
                await Drive(node).folder(name.trim(), parent: driveFolder),
              ))!['entry']
              as String;
      await folderSync.connect(id, location);
      if (mounted) {
        setState(() {
          driveFolder = id;
          driveView = null;
        });
      }
    } catch (e) {
      if (mounted) notice('Folder connection: $e');
    } finally {
      if (mounted) setState(() => connectingFolder = false);
    }
  }

  Widget filePage(BuildContext context) => Column(
    children: [
      Wrap(
        spacing: 8,
        children: [
          ChoiceChip(
            label: const Text('Private drive'),
            selected: !publicFiles && !attachmentFiles,
            onSelected: (_) => update(() {
              publicFiles = false;
              attachmentFiles = false;
            }),
          ),
          ChoiceChip(
            label: const Text('Attachments'),
            selected: attachmentFiles,
            onSelected: (_) => update(() => attachmentFiles = true),
          ),
          ChoiceChip(
            label: const Text('Public files'),
            selected: publicFiles && !attachmentFiles,
            onSelected: (_) => update(() {
              publicFiles = true;
              attachmentFiles = false;
            }),
          ),
        ],
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: fileSearch,
              decoration: const InputDecoration(
                labelText: 'Find files by name',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (value) =>
                  update(() => fileQuery = value.trim().toLowerCase()),
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'Sort files',
            onSelected: (value) => update(() => fileSort = value),
            itemBuilder: (_) => [
              for (final value in ['Newest', 'Name', 'Size'])
                PopupMenuItem(value: value, child: Text(value)),
            ],
            icon: const Icon(Icons.sort),
          ),
        ],
      ),
      const SizedBox(height: 12),
      Expanded(
        child: attachmentFiles
            ? attachmentsPage(context)
            : publicFiles
            ? publicFilePage(context)
            : privateDrive(context),
      ),
    ],
  );

  List<SignedObject> publicFileObjects() =>
      node.store
          .objects(kind: 'file')
          .where(
            (o) =>
                o.isPublic &&
                (o.data['payload']['name'] ?? '')
                    .toString()
                    .toLowerCase()
                    .contains(fileQuery),
          )
          .toList()
        ..sort(
          (a, b) => compareFiles(
            EverydayItem(a, a.data['payload']),
            EverydayItem(b, b.data['payload']),
          ),
        );

  int compareFiles(EverydayItem a, EverydayItem b) => switch (fileSort) {
    'Name' => (a.data['name'] ?? '').toString().toLowerCase().compareTo(
      (b.data['name'] ?? '').toString().toLowerCase(),
    ),
    'Size' => (b.data['size'] as int? ?? 0).compareTo(
      a.data['size'] as int? ?? 0,
    ),
    _ => b.object.created.compareTo(a.object.created),
  };

  Future<List<(EverydayItem, String)>> attachmentEntries() async {
    final result = <(EverydayItem, String)>[];
    final everyday = Everyday(node);
    for (final item in await everyday.items()) {
      if (item.data['type'] == 'file' &&
          item.data['deleted'] != true &&
          node.visible(item.object)) {
        result.add((item, 'Notes · Only you'));
      }
    }
    for (final room in await everyday.rooms()) {
      for (final item in await everyday.items(room)) {
        if (item.data['type'] == 'file' &&
            item.data['deleted'] != true &&
            node.visible(item.object)) {
          result.add((
            item,
            '${room.data['name']} · Private group · ${item.object.audience.length} members',
          ));
        }
      }
    }
    await for (final object in scanHistory(const ['message', 'post'])) {
      if (!node.visible(object)) continue;
      final payload = await node.content(object);
      if (payload == null ||
          payload['chunks'] is! List ||
          payload['drive'] != null ||
          object.space == '_drive') {
        continue;
      }
      result.add((
        EverydayItem(object, payload),
        object.kind == 'post'
            ? '${object.space} · Public forum'
            : 'Direct messages · ${{object.author, ...object.audience}.map(name).join(', ')}',
      ));
    }
    result.sort((a, b) => b.$1.object.created.compareTo(a.$1.object.created));
    return result;
  }

  Widget attachmentsPage(
    BuildContext context,
  ) => FutureBuilder<List<(EverydayItem, String)>>(
    future: attachmentsView ??= attachmentEntries(),
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return empty(
          'Attachments could not be loaded',
          'Try opening Attachments again.',
          Icons.error_outline,
        );
      }
      if (!snapshot.hasData) {
        return const Center(child: CircularProgressIndicator());
      }
      final entries =
          snapshot.data!
              .where(
                (e) => (e.$1.data['name'] ?? '')
                    .toString()
                    .toLowerCase()
                    .contains(fileQuery),
              )
              .toList()
            ..sort((a, b) => compareFiles(a.$1, b.$1));
      if (entries.isEmpty) {
        return empty(
          'Your shared files, in one place',
          'Files saved in Notes, private groups and direct sharing appear here.',
          Icons.attach_file,
        );
      }
      return ListView.builder(
        itemCount: entries.length,
        itemBuilder: (context, index) {
          final entry = entries[index];
          return ListTile(
            leading: isImagePayload(entry.$1.data)
                ? InlineImage(
                    key: ValueKey(entry.$1.object.id),
                    files: files,
                    object: entry.$1.object,
                    payload: entry.$1.data,
                    online: network.running,
                    thumbnail: true,
                  )
                : const Icon(Icons.insert_drive_file_outlined),
            title: Text(entry.$1.data['name'] ?? 'File'),
            subtitle: Text(entry.$2),
            onTap: () => openSource(entry.$1),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Open in source',
                  icon: const Icon(Icons.open_in_new),
                  onPressed: () => openSource(entry.$1),
                ),
                IconButton(
                  tooltip: 'Save original',
                  icon: const Icon(Icons.download),
                  onPressed: () =>
                      saveFile(context, entry.$1.object, entry.$1.data),
                ),
              ],
            ),
          );
        },
      );
    },
  );

  void uploadDrive({DriveEntry? replacing}) => pickFile(
    [node.person],
    driveData: {
      'entry': replacing?.current.entry ?? randomId(),
      'revision': randomId(),
      'folder': replacing?.current.data['folder'] ?? driveFolder,
      'type': 'file',
      'deleted': false,
      'parents': replacing?.heads.map((v) => v.data['revision']).toList() ?? [],
      if (replacing != null) 'name': replacing.current.data['name'],
    },
  );

  Widget privateDrive(BuildContext context) => FutureBuilder<List<DriveEntry>>(
    future: driveView ??= Drive(node).entries(),
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Text('Unable to load drive: ${snapshot.error}');
      }
      if (!snapshot.hasData) {
        return const Center(child: CircularProgressIndicator());
      }
      final entries = snapshot.data!;
      final connections = folderSync.connections;
      final connection = connections[driveFolder];
      final folder = entries
          .where((e) => e.current.entry == driveFolder)
          .firstOrNull;
      final visible =
          entries
              .where(
                (e) =>
                    e.current.data['folder'] == driveFolder &&
                    (e.current.data['name'] as String).toLowerCase().contains(
                      fileQuery,
                    ) &&
                    (!e.current.deleted || e.conflicted),
              )
              .toList()
            ..sort((a, b) {
              final type = (a.current.isFolder ? 0 : 1).compareTo(
                b.current.isFolder ? 0 : 1,
              );
              return type != 0
                  ? type
                  : compareFiles(
                      EverydayItem(a.current.object, a.current.data),
                      EverydayItem(b.current.object, b.current.data),
                    );
            });
      return CustomScrollView(
        key: PageStorageKey('drive/$driveFolder'),
        slivers: [
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Encrypted for your devices',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
                const Text(
                  'Add files here to sync their history between devices enrolled under your identity.',
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Keep files offline on this device'),
                  subtitle: Text(
                    driveSync.busy
                        ? 'Downloading encrypted copies…'
                        : driveSync.error ??
                              'Copies download automatically while connected.',
                  ),
                  value: driveSync.enabled,
                  onChanged: driveSync.setEnabled,
                ),
                if (connection != null)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.sync),
                    title: const Text('Connected local folder · two-way sync'),
                    subtitle: Text(
                      '${connection['location']}\n${folderSync.status[driveFolder] ?? 'Waiting to check local folder'}',
                    ),
                    trailing: PopupMenuButton<String>(
                      onSelected: (action) async {
                        if (action == 'sync') {
                          await folderSync.sync();
                        } else {
                          await folderSync.disconnect(driveFolder!);
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'sync', child: Text('Sync now')),
                        PopupMenuItem(
                          value: 'disconnect',
                          child: Text('Disconnect (keep files)'),
                        ),
                      ],
                    ),
                  ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (widget.enablePlatform &&
                        !Platform.isIOS &&
                        connection == null)
                      OutlinedButton.icon(
                        onPressed: connectingFolder
                            ? null
                            : () => connectFolder(folder: folder),
                        icon: const Icon(Icons.folder_copy_outlined),
                        label: Text(
                          connectingFolder
                              ? 'Checking folder…'
                              : folder == null
                              ? 'Sync a folder'
                              : 'Connect to local folder',
                        ),
                      ),
                    FilledButton.icon(
                      onPressed: busy ? null : () => uploadDrive(),
                      icon: const Icon(Icons.upload_file),
                      label: const Text('Add file'),
                    ),
                    OutlinedButton.icon(
                      onPressed: busy
                          ? null
                          : () => act(() async {
                              final value = await ask(context, 'New folder');
                              if (value != null && value.isNotEmpty) {
                                await Drive(
                                  node,
                                ).folder(value, parent: driveFolder);
                              }
                            }),
                      icon: const Icon(Icons.create_new_folder_outlined),
                      label: const Text('New folder'),
                    ),
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => act(() async {
                              final count = await Drive(node).shareHistory();
                              notice(
                                'Shared $count revisions with your enrolled devices',
                              );
                            }),
                      child: const Text('Share history with new devices'),
                    ),
                    TextButton(
                      onPressed: () => driveHistory(context, entries),
                      child: const Text('History & deleted items'),
                    ),
                  ],
                ),
                Row(
                  children: [
                    if (driveFolder != null)
                      IconButton(
                        tooltip: 'Parent folder',
                        onPressed: () => update(
                          () => driveFolder = folder?.current.data['folder'],
                        ),
                        icon: const Icon(Icons.arrow_upward),
                      ),
                    TextButton(
                      onPressed: () => update(() => driveFolder = null),
                      child: const Text('My drive'),
                    ),
                    if (folder != null)
                      Expanded(
                        child: Text(
                          '/ ${folder.current.data['name']}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (visible.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: empty(
                'This folder is empty',
                'Add a file or create a folder.',
                Icons.folder_open,
              ),
            )
          else
            SliverList.builder(
              itemCount: visible.length,
              itemBuilder: (context, index) {
                final entry = visible[index];
                return driveRow(
                  context,
                  entry,
                  entries,
                  connections.containsKey(entry.current.entry),
                );
              },
            ),
        ],
      );
    },
  );

  Widget driveRow(
    BuildContext context,
    DriveEntry entry,
    List<DriveEntry> entries,
    bool connected,
  ) {
    final v = entry.current, p = v.data;
    return Card(
      child: ListTile(
        leading: !v.isFolder && isImagePayload(p)
            ? InlineImage(
                key: ValueKey(v.object.id),
                files: files,
                object: v.object,
                payload: p,
                online: network.running,
                thumbnail: true,
              )
            : Icon(
                entry.conflicted
                    ? Icons.warning_amber
                    : v.isFolder
                    ? Icons.folder_outlined
                    : Icons.insert_drive_file_outlined,
              ),
        title: Text(p['name'], maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          entry.conflicted
              ? '${entry.heads.length} concurrent versions — choose in history'
              : v.deleted
              ? 'Deleted'
              : v.isFolder
              ? connected
                    ? 'Connected to a local folder'
                    : 'Folder · browse on demand'
              : '${p['size']} bytes · ${files.cached(p) ? 'Available offline' : 'Download on request'}',
        ),
        onTap: () => v.isFolder
            ? update(() => driveFolder = v.entry)
            : driveHistory(context, [entry]),
        trailing: PopupMenuButton<String>(
          onSelected: (action) {
            if (action == 'history') {
              driveHistory(context, [entry]);
              return;
            }
            if (action == 'export') {
              saveFile(context, v.object, p);
              return;
            }
            if (action == 'replace') {
              uploadDrive(replacing: entry);
              return;
            }
            act(() async {
              if (action == 'cache') {
                await files.cache(v.object);
                refresh();
                return;
              }
              if (action == 'rename') {
                final name = await ask(context, 'Rename', initial: p['name']);
                if (name != null) {
                  await Drive(node).revise(entry, {'name': name});
                }
              }
              if (action == 'delete') {
                if (v.isFolder &&
                    entries.any(
                      (e) =>
                          e.current.data['folder'] == v.entry &&
                          !e.current.deleted,
                    )) {
                  throw StateError(
                    'Move or delete the folder’s contents first',
                  );
                }
                await Drive(node).revise(entry, {'deleted': true});
              }
              if (action == 'move') {
                if (!context.mounted) return;
                final target = await showDialog<String>(
                  context: context,
                  builder: (context) => SimpleDialog(
                    title: const Text('Move to folder'),
                    children: [
                      SimpleDialogOption(
                        onPressed: () => Navigator.pop(context, ''),
                        child: const Text('My drive'),
                      ),
                      for (final f in entries.where(
                        (e) =>
                            e.current.isFolder &&
                            !e.current.deleted &&
                            e.current.entry != v.entry,
                      ))
                        SimpleDialogOption(
                          onPressed: () =>
                              Navigator.pop(context, f.current.entry),
                          child: Text(f.current.data['name']),
                        ),
                    ],
                  ),
                );
                if (target != null) {
                  var cursor = target;
                  final seen = <String>{v.entry};
                  while (cursor.isNotEmpty) {
                    if (!seen.add(cursor)) {
                      throw StateError('A folder cannot contain itself');
                    }
                    cursor =
                        entries
                            .where((e) => e.current.entry == cursor)
                            .firstOrNull
                            ?.current
                            .data['folder'] ??
                        '';
                  }
                  await Drive(
                    node,
                  ).revise(entry, {'folder': target.isEmpty ? null : target});
                }
              }
            });
          },
          itemBuilder: (_) => [
            if (!v.isFolder)
              const PopupMenuItem(value: 'export', child: Text('Export file')),
            if (!v.isFolder)
              const PopupMenuItem(
                value: 'cache',
                child: Text('Keep this file offline'),
              ),
            if (!v.isFolder)
              const PopupMenuItem(
                value: 'replace',
                child: Text('Upload new version'),
              ),
            const PopupMenuItem(value: 'rename', child: Text('Rename')),
            const PopupMenuItem(value: 'move', child: Text('Move')),
            const PopupMenuItem(
              value: 'history',
              child: Text('Version history'),
            ),
            const PopupMenuItem(
              value: 'delete',
              child: Text('Delete from drive'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> driveHistory(
    BuildContext context,
    List<DriveEntry> entries,
  ) => showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Drive history'),
      content: SizedBox(
        width: 620,
        height: 420,
        child: ListView(
          children: [
            for (final entry in entries)
              for (final v in entry.history)
                ListTile(
                  leading: !v.isFolder && isImagePayload(v.data)
                      ? InlineImage(
                          key: ValueKey(v.object.id),
                          files: files,
                          object: v.object,
                          payload: v.data,
                          online: network.running,
                          thumbnail: true,
                        )
                      : null,
                  title: Text(
                    '${v.data['name']}${v.deleted ? ' · deleted' : ''}',
                  ),
                  subtitle: Text(
                    '${v.object.certificate.label} · ${DateTime.fromMillisecondsSinceEpoch(v.object.created).toLocal()}${entry.heads.contains(v) ? ' · current' : ''}',
                  ),
                  trailing: Wrap(
                    children: [
                      if (!v.isFolder)
                        IconButton(
                          tooltip: 'Export this version',
                          icon: const Icon(Icons.download),
                          onPressed: () => saveFile(context, v.object, v.data),
                        ),
                      IconButton(
                        tooltip: 'Use this version',
                        icon: const Icon(Icons.restore),
                        onPressed: () => act(() async {
                          await Drive(
                            node,
                          ).revise(entry, {'deleted': false}, source: v);
                          if (dialogContext.mounted) {
                            Navigator.pop(dialogContext);
                          }
                          notice(
                            'Version restored; previous revisions remain in history',
                          );
                        }),
                      ),
                    ],
                  ),
                ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
