part of 'app.dart';

const notesFilters = {
  'All': 'All notes',
  'Text': 'Text notes',
  'Lists': 'Lists',
  'Links': 'Links',
  'Files': 'Files & photos',
  'Removed': 'Removed',
};

extension _NotesHome on _OurNetAppState {
  Widget noteEditor({String? id, bool checklist = false}) => NoteEditor(
    key: ValueKey('editor/${id ?? 'new'}'),
    notes: notes,
    id: id,
    checklist: checklist,
    drafts: draftStore,
    network: network,
    friends: {for (final person in people) person: name(person)},
    personName: name,
    addFriend: () async {
      final context = noteNavigator.currentContext;
      if (context != null) await addFriend(context);
      return {for (final person in people) person: name(person)};
    },
    onRemoved: noteRemoved,
    notice: notice,
  );

  Future<void> openNote(String? id, {bool checklist = false}) async {
    if (!mounted) return;
    await noteNavigator.currentState!.push(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 260),
        reverseTransitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (_, _, _) => noteEditor(id: id, checklist: checklist),
        transitionsBuilder: (_, animation, secondary, child) =>
            FadeThroughTransition(
              animation: animation,
              secondaryAnimation: secondary,
              child: child,
            ),
      ),
    );
  }

  void noteRemoved(String id) {
    update(() => hiddenNotes.add(id));
    messenger.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('Note removed'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => unawaited(setNoteRemoved(id, false)),
          ),
        ),
      );
  }

  Future<void> setNoteRemoved(String id, bool removed) async {
    update(() => removed ? hiddenNotes.add(id) : hiddenNotes.remove(id));
    try {
      final note = await notes.get(id, includeUnavailable: true);
      if (note == null) throw StateError('This note is unavailable.');
      await notes.edit(
        id,
        note.epoch,
        'deleted',
        removed,
        note.parents('deleted'),
      );
      if (removed) noteRemoved(id);
    } catch (e) {
      update(() => removed ? hiddenNotes.remove(id) : hiddenNotes.add(id));
      notice('$e');
    }
  }

  /// Shows the check at once; the summary catches up after publication.
  Future<void> checkNoteItem(EverydayItem item, String check, bool done) async {
    final p = item.data;
    final row = (p['checks'] as List).cast<Map>().firstWhere(
      (r) => r['id'] == check,
    );
    update(() => (noteChecks[p['entry']] ??= {})[check] = done);
    try {
      await notes.edit(
        p['entry'],
        p['epoch'],
        'check:$check:done',
        done,
        (row['parents'] as List).cast<String>(),
      );
    } catch (e) {
      update(() => noteChecks[p['entry']]?.remove(check));
      notice('$e');
    }
  }

  Future<void> noteMenu(
    BuildContext context,
    EverydayItem item,
    Set<dynamic> pins,
    Offset? position,
  ) async {
    final p = item.data;
    final shared = p['type'] == 'shared_note';
    final pinned = pins.contains(p['entry']);
    final actions = <String, (IconData, String)>{
      'pin': (
        pinned ? Icons.push_pin : Icons.push_pin_outlined,
        pinned ? 'Unpin' : 'Pin',
      ),
      if (shared && p['available'] == true && p['removed'] != true)
        'color': (Icons.palette_outlined, 'Colour'),
      if (p['type'] != 'file') 'copy': (Icons.copy, 'Copy text'),
      if (p['type'] == 'file') 'save': (Icons.download, 'Save original'),
      if (p['type'] == 'file' &&
          RegExp(
            r'\.(png|jpe?g|webp|gif)$',
            caseSensitive: false,
          ).hasMatch(p['name'] ?? ''))
        'preview': (Icons.image_outlined, 'Preview photo'),
      if (!shared || (p['available'] == true && p['removed'] != true))
        'delete': (Icons.delete_outline, 'Remove'),
      if (shared && p['removed'] == true && p['available'] == true)
        'restore': (Icons.restore_from_trash, 'Restore'),
    };
    final String? chosen;
    if (position != null) {
      chosen = await showMenu<String>(
        context: context,
        position: RelativeRect.fromLTRB(
          position.dx,
          position.dy,
          position.dx,
          position.dy,
        ),
        items: [
          for (final entry in actions.entries)
            PopupMenuItem(
              value: entry.key,
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(entry.value.$1),
                title: Text(entry.value.$2),
              ),
            ),
        ],
      );
    } else {
      chosen = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final entry in actions.entries)
                ListTile(
                  leading: Icon(entry.value.$1),
                  title: Text(entry.value.$2),
                  onTap: () => Navigator.pop(context, entry.key),
                ),
            ],
          ),
        ),
      );
    }
    if (chosen == null || !context.mounted) return;
    if (!shared) {
      everydayItemAction(context, item, chosen, pins);
      return;
    }
    switch (chosen) {
      case 'pin':
        notes.pin(p['entry'], !pinned);
      case 'color':
        final color = await pickNoteColor(context, p['color']);
        if (color == null) return;
        try {
          final note = await notes.get(p['entry']);
          if (note == null) throw StateError('This note is unavailable.');
          await notes.edit(
            note.id,
            note.epoch,
            'color',
            color,
            note.parents('color'),
          );
        } catch (e) {
          notice('$e');
        }
      case 'copy':
        final note = await notes.get(p['entry'], includeUnavailable: true);
        if (note == null) return;
        await Clipboard.setData(
          ClipboardData(
            text: [
              if (note.rawTitle.isNotEmpty) note.rawTitle,
              if (note.text.isNotEmpty) note.text,
              for (final c in note.checks)
                '${note.done(c) ? '☑' : '☐'} ${note.itemText(c)}',
            ].join('\n'),
          ),
        );
        notice('Copied');
      case 'delete':
        await setNoteRemoved(p['entry'], true);
      case 'restore':
        await setNoteRemoved(p['entry'], false);
    }
  }

  bool notesMatch(EverydayItem item, Set<dynamic> pins, String query) {
    final p = item.data;
    final type = p['type'];
    if (type == 'pin') return false;
    final removedView = notesFilter == 'Removed';
    if (removedView) {
      if (type != 'shared_note' || p['deleted'] != true) return false;
    } else if (p['deleted'] == true || hiddenNotes.contains(p['entry'])) {
      return false;
    }
    final text = (p['text'] ?? '').toString();
    final link = text.startsWith('http');
    final passes = switch (notesFilter) {
      'Text' =>
        type == 'shared_note' && p['checklist'] != true ||
            type == 'note' && !link,
      'Lists' =>
        type == 'shared_note' && p['checklist'] == true || type == 'check',
      'Links' => (type == 'note' || type == 'shared_note') && link,
      'Files' => type == 'file',
      _ => true,
    };
    if (!passes) return false;
    if (query.isEmpty) return true;
    return '${p['title'] ?? ''}\n$text\n${p['name'] ?? ''}\n${p['list'] ?? ''}'
        .toLowerCase()
        .contains(query);
  }

  Widget legacyCard(BuildContext context, EverydayItem item, Set pins) {
    final p = item.data, o = item.object;
    final theme = Theme.of(context);
    final attachment = p['type'] == 'file', check = p['type'] == 'check';
    final text = (p['text'] ?? '').toString();
    final local = !attachment || files.cached(p);
    final status = local
        ? 'Available offline'
        : everydaySync.errors[o.id] != null
        ? 'Transfer delayed · will retry'
        : 'Waiting for source device';
    return Material(
      color: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: InkWell(
        // The photo clips itself; a second rounded clip here costs raster time.
        customBorder: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        onTap: attachment
            ? () => isImagePayload(p) && local
                  ? previewImage(context, o)
                  : saveFile(context, o, p)
            : () => readEverydayItem(context, item),
        onLongPress: () => noteMenu(context, item, pins, null),
        onSecondaryTapUp: (d) =>
            noteMenu(context, item, pins, d.globalPosition),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (attachment && isImagePayload(p))
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 6, 6, 0),
                child: InlineImage(
                  key: ValueKey(o.id),
                  files: files,
                  object: o,
                  payload: p,
                  online: network.running,
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (check)
                        Icon(
                          p['done'] == true
                              ? Icons.check_box_outlined
                              : Icons.check_box_outline_blank,
                          size: 20,
                        )
                      else if (attachment || text.startsWith('http'))
                        Icon(
                          attachment
                              ? Icons.insert_drive_file_outlined
                              : Icons.link,
                          size: 20,
                        ),
                      if (check || attachment || text.startsWith('http'))
                        const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          attachment ? p['name'] : text,
                          maxLines: attachment ? 2 : 10,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (pins.contains(p['entry']))
                        const Icon(Icons.push_pin, size: 16),
                    ],
                  ),
                  if (attachment || check)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        check ? '${p['list']}' : status,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget noteTile(BuildContext context, EverydayItem item, Set pins) {
    final p = item.data;
    if (p['type'] != 'shared_note') return legacyCard(context, item, pins);
    final colors = Theme.of(context).colorScheme;
    final overrides = noteChecks[p['entry']] ?? const <String, bool>{};
    final card = OpenContainer<void>(
      tappable: false,
      closedElevation: 0,
      openElevation: 0,
      transitionDuration: const Duration(milliseconds: 320),
      closedColor: noteColor(context, p['color']) ?? colors.surface,
      openColor: noteColor(context, p['color']) ?? colors.surface,
      middleColor: noteColor(context, p['color']) ?? colors.surface,
      closedShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      openBuilder: (_, _) => noteEditor(id: p['entry']),
      closedBuilder: (context, open) => NoteCard(
        item: item,
        pinned: pins.contains(p['entry']),
        overrides: overrides,
        personName: name,
        onOpen: open,
        onCheck: (check, done) => checkNoteItem(item, check, done),
        onMenu: (position) => noteMenu(context, item, pins, position),
      ),
    );
    if (notesFilter == 'Removed' || p['available'] != true) return card;
    return Dismissible(
      key: ValueKey('dismiss/${p['entry']}'),
      onDismissed: (_) => unawaited(setNoteRemoved(p['entry'], true)),
      child: card,
    );
  }

  Widget captureBar(BuildContext context, {required bool top}) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(28),
      clipBehavior: Clip.antiAlias,
      child: Row(
        children: [
          Expanded(
            child: OpenContainer<void>(
              tappable: false,
              closedElevation: 0,
              openElevation: 0,
              closedColor: colors.surfaceContainerHigh,
              openColor: colors.surface,
              middleColor: colors.surface,
              closedShape: const RoundedRectangleBorder(),
              openBuilder: (_, _) => noteEditor(),
              closedBuilder: (context, open) => InkWell(
                onTap: open,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 16,
                  ),
                  child: Text(
                    'Take a note…',
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'New list',
            onPressed: () => openNote(null, checklist: true),
            icon: const Icon(Icons.check_box_outlined),
          ),
          IconButton(
            tooltip: 'Add original file',
            onPressed: addingAttachment
                ? null
                : () => attachmentAct(() async {
                    final picker = widget.pickAttachment;
                    if (picker != null) {
                      final file = await picker();
                      if (file != null) {
                        await addEverydayFile(file.path, name: file.name);
                      }
                      return;
                    }
                    final selected = await FilePicker.pickFile();
                    if (selected?.path != null) {
                      await addEverydayFile(
                        selected!.path!,
                        name: selected.name,
                      );
                    }
                  }),
            icon: const Icon(Icons.image_outlined),
          ),
          IconButton(
            tooltip: 'Paste text or screenshot',
            onPressed: addingAttachment
                ? null
                : () => attachmentAct(pasteInbox),
            icon: const Icon(Icons.content_paste),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget notesHome(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final query = notesSearch.text.trim().toLowerCase();
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 600;
        final columns = notesGrid
            ? (constraints.maxWidth / 250).floor().clamp(2, 5)
            : 1;
        final search = Row(
          children: [
            Expanded(
              child: TextField(
                controller: notesSearch,
                // Presentation only: no data reload or saved destination.
                onChanged: (_) => redraw(),
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Search your notes',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear search',
                          onPressed: () {
                            notesSearch.clear();
                            redraw();
                          },
                          icon: const Icon(Icons.close),
                        ),
                  filled: true,
                  fillColor: colors.surfaceContainerHigh,
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(28),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            PopupMenuButton<String>(
              tooltip: 'Show',
              icon: Badge(
                isLabelVisible: notesFilter != 'All',
                smallSize: 8,
                child: const Icon(Icons.filter_list),
              ),
              initialValue: notesFilter,
              onSelected: (value) async {
                if (value != 'widget') {
                  update(() => notesFilter = value);
                  return;
                }
                final placed = await noteWidgets?.pinBoard().catchError(
                  (Object _) => false,
                );
                if (placed != true) {
                  notice(
                    'Long-press your home screen, choose Widgets, then OurNet · Notes.',
                  );
                }
              },
              itemBuilder: (_) => [
                for (final entry in notesFilters.entries)
                  CheckedPopupMenuItem(
                    value: entry.key,
                    checked: notesFilter == entry.key,
                    child: Text(entry.value),
                  ),
                if (noteWidgets != null) ...[
                  const PopupMenuDivider(),
                  const PopupMenuItem(
                    value: 'widget',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.widgets_outlined),
                      title: Text('Add Notes widget'),
                    ),
                  ),
                ],
              ],
            ),
            IconButton(
              tooltip: notesGrid ? 'List view' : 'Grid view',
              onPressed: () {
                update(() => notesGrid = !notesGrid);
                node.store.set('notesGrid', notesGrid);
              },
              icon: Icon(
                notesGrid ? Icons.view_agenda_outlined : Icons.grid_view,
              ),
            ),
          ],
        );
        final content = FutureBuilder<List<EverydayItem>>(
          future: everydayView ??= noteItems(),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                child: Text('Could not load notes: ${snapshot.error}'),
              );
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final all = snapshot.data!;
            final pins = <dynamic>{
              for (final i in all)
                if (i.data['type'] == 'pin' && i.data['pinned'] == true)
                  i.data['target'],
              ...node.store.trueSettings('notePin/'),
            };
            // Removals the summaries now reflect no longer need hiding.
            for (final i in all) {
              if (i.data['type'] == 'shared_note' &&
                  i.data['deleted'] == true) {
                hiddenNotes.remove(i.data['entry']);
              }
            }
            int time(EverydayItem i) =>
                i.data['updated'] as int? ?? i.object.created;
            final visible =
                all.where((i) => notesMatch(i, pins, query)).toList()
                  ..sort((a, b) => time(b).compareTo(time(a)));
            // Drop optimistic checks the summaries now reflect.
            for (final item in visible) {
              final overrides = noteChecks[item.data['entry']];
              if (overrides == null) continue;
              final unchecked = {
                for (final c in (item.data['checks'] as List? ?? const []))
                  c['id'],
              };
              overrides.removeWhere(
                (id, done) => done != unchecked.contains(id),
              );
            }
            final pinned = notesFilter == 'Removed'
                ? <EverydayItem>[]
                : visible.where((i) => pins.contains(i.data['entry'])).toList();
            final others = visible.where((i) => !pinned.contains(i)).toList();
            if (visible.isEmpty) {
              return empty(
                query.isNotEmpty
                    ? 'No matching notes'
                    : notesFilter == 'Removed'
                    ? 'Nothing removed'
                    : 'Your next small habit starts here',
                query.isNotEmpty
                    ? 'Try other words, or show all notes.'
                    : notesFilter == 'Removed'
                    ? 'Removed notes stay here, and can be restored.'
                    : 'Take a note or start a list. Drop a file, or paste a screenshot.',
                query.isNotEmpty ? Icons.search_off : Icons.lightbulb_outline,
              );
            }
            Widget header(String text) => SliverPadding(
              padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
              sliver: SliverToBoxAdapter(
                child: Text(
                  text.toUpperCase(),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    letterSpacing: 1.1,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            );
            Widget grid(List<EverydayItem> items) => SliverMasonryGrid.count(
              crossAxisCount: columns,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childCount: items.length,
              itemBuilder: (context, index) => KeyedSubtree(
                key: ValueKey(items[index].data['entry']),
                child: noteTile(context, items[index], pins),
              ),
            );
            return Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: notesGrid ? double.infinity : 640,
                ),
                child: CustomScrollView(
                  key: PageStorageKey('everyday/self/$notesFilter'),
                  slivers: [
                    if (pinned.isNotEmpty) ...[
                      header('Pinned'),
                      grid(pinned),
                      if (others.isNotEmpty) header('Others'),
                    ] else
                      const SliverToBoxAdapter(child: SizedBox(height: 8)),
                    grid(others),
                    const SliverToBoxAdapter(child: SizedBox(height: 16)),
                  ],
                ),
              ),
            );
          },
        );
        return DropTarget(
          enable: widget.enablePlatform && !addingAttachment,
          onDragEntered: (_) => update(() => inboxDragging = true),
          onDragExited: (_) => update(() => inboxDragging = false),
          onDragDone: (details) {
            update(() => inboxDragging = false);
            attachmentAct(() async {
              for (final file in details.files) {
                await addEverydayFile(file.path, name: file.name);
              }
            });
          },
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  search,
                  if (notesFilter != 'All')
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: InputChip(
                          label: Text(notesFilters[notesFilter]!),
                          onDeleted: () => update(() => notesFilter = 'All'),
                        ),
                      ),
                    ),
                  if (wide) ...[
                    const SizedBox(height: 12),
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 600),
                        child: captureBar(context, top: true),
                      ),
                    ),
                  ],
                  const SizedBox(height: 4),
                  Expanded(child: content),
                  if (!wide)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: captureBar(context, top: false),
                    ),
                ],
              ),
              if (inboxDragging)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        color: colors.tertiaryContainer.withValues(alpha: .85),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      alignment: Alignment.center,
                      child: const Text(
                        'Drop to save here',
                        style: TextStyle(fontSize: 22),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
