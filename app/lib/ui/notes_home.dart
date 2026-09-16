part of 'app.dart';

const _removedDaysText = '7 days';

const notesFilters = {
  'All': 'All notes',
  'Text': 'Text notes',
  'Lists': 'Lists',
  'Links': 'Links',
  'Files': 'Files & photos',
  'Voice': 'Voice notes',
  'Reminders': 'Reminders',
  'Archive': 'Archive',
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
    files: files,
    speech: speech,
    friends: {for (final person in people) person: name(person)},
    personName: name,
    addFriend: () async {
      final context = noteNavigator.currentContext;
      if (context != null) await addFriend(context);
      return {for (final person in people) person: name(person)};
    },
    onRemoved: noteRemoved,
    onArchived: (id, pinned) => noteArchived([id], pinned: {if (pinned) id}),
    onOpenNote: (id) => unawaited(openNote(id)),
    onReminderSet: () async => reminders?.requestPermission(),
    pickImage: widget.pickImage,
    notice: notice,
  );

  Future<void> openNote(String? id, {bool checklist = false}) async {
    if (!mounted) return;
    await noteNavigator.currentState!.push(noteRoute(id, checklist: checklist));
  }

  Route<void> noteRoute(String? id, {bool checklist = false}) =>
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
      );

  /// Keep's microphone button: record at once; on stop, the recorder turns
  /// into the new note holding the audio and, with live system speech, its
  /// transcript. Otherwise transcription starts once the note is open.
  Future<void> captureVoice() async {
    final context = noteNavigator.currentContext;
    if (context == null) return;
    await recordVoice(
      context,
      speech: speech,
      save: (recording) async {
        final file = File(recording.path);
        try {
          final note = await notes.create();
          final attached = await notes.attach(
            note.id,
            note.epoch,
            file.openRead(),
            name: recording.name,
            meta: {
              'kind': 'audio',
              'mime': recording.mime,
              'duration': recording.duration,
            },
          );
          if (recording.transcript case final text?) {
            await speech.saveTranscript(note.id, attached, text);
          } else {
            // After the note opens, so a model download can be offered.
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => unawaited(
                transcribeRecording(
                  noteNavigator.currentContext,
                  speech,
                  note.id,
                  attached,
                ),
              ),
            );
          }
          return noteRoute(note.id);
        } finally {
          // The note opens without waiting for the temporary file to go.
          unawaited(file.delete().then<void>((_) {}, onError: (Object _) {}));
        }
      },
    );
  }

  /// Keep's drawing button: a new note holding one drawing.
  Future<void> captureDrawing() async {
    final context = noteNavigator.currentContext;
    if (context == null) return;
    final result = await editDrawing(context);
    if (result == null || !mounted) return;
    try {
      final note = await notes.create();
      final file = await notes.attach(
        note.id,
        note.epoch,
        Stream.value(result.png),
        name: 'Drawing.png',
        meta: {
          'kind': 'drawing',
          'mime': 'image/png',
          'width': result.width,
          'height': result.height,
        },
      );
      await notes.attach(
        note.id,
        note.epoch,
        Stream.value(result.strokes),
        name: 'Drawing.json',
        fileId: file,
        field: 'strokes',
        meta: {'version': 1},
      );
      await openNote(note.id);
    } catch (e) {
      notice('Could not save the drawing: $e');
    }
  }

  /// Keep's image button: a new note holding the chosen photo.
  Future<void> captureImage() async {
    final XFile? picked;
    try {
      picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    } catch (e) {
      notice('Images are unavailable: $e');
      return;
    }
    if (picked == null || !mounted) return;
    try {
      final note = await notes.create();
      final extension = picked.name.split('.').last.toLowerCase();
      await notes.attach(
        note.id,
        note.epoch,
        picked.openRead(),
        name: picked.name,
        meta: {
          'kind': 'image',
          'mime': switch (extension) {
            'png' => 'image/png',
            'webp' => 'image/webp',
            'gif' => 'image/gif',
            _ => 'image/jpeg',
          },
        },
      );
      await openNote(note.id);
    } catch (e) {
      notice('Could not add the image: $e');
    }
  }

  void noteRemoved(String id) => notesRemoved([id]);

  /// One Undo snackbar for a whole removal, however many notes it covers.
  void notesRemoved(List<String> ids) {
    if (ids.isEmpty) return;
    update(() => hiddenNotes.addAll(ids));
    messenger.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          // Action snackbars persist by default; this one should time out.
          persist: false,
          content: Text(
            ids.length == 1 ? 'Note removed' : '${ids.length} notes removed',
          ),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => unawaited(setNotesRemoved(ids, false)),
          ),
        ),
      );
  }

  Future<void> setNoteRemoved(String id, bool removed) =>
      setNotesRemoved([id], removed);

  Future<void> setNotesRemoved(List<String> ids, bool removed) async {
    update(() {
      for (final id in ids) {
        removed ? hiddenNotes.add(id) : hiddenNotes.remove(id);
      }
    });
    final done = <String>[];
    Object? error;
    for (final id in ids) {
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
        done.add(id);
      } catch (e) {
        error ??= e;
        update(() => removed ? hiddenNotes.remove(id) : hiddenNotes.add(id));
      }
    }
    if (removed) notesRemoved(done);
    if (error != null) notice('$error');
  }

  /// Offers Undo for an archive, restoring any pins archiving cleared.
  void noteArchived(List<String> ids, {Set<String> pinned = const {}}) {
    update(() {});
    messenger.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          persist: false,
          content: Text(
            ids.length == 1 ? 'Note archived' : '${ids.length} notes archived',
          ),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => unawaited(
              notes.state
                  .setAll([
                    for (final id in ids) ('archive', id, false),
                    for (final id in pinned) ('pin', id, true),
                  ])
                  .then((_) => update(() {}))
                  .catchError((Object e) => notice('$e')),
            ),
          ),
        ),
      );
  }

  Future<void> setArchived(List<String> ids, bool archived) async {
    final pinned = {
      for (final id in ids)
        if (notes.pinned(id)) id,
    };
    try {
      await notes.state.archive(ids, archived);
      if (archived) {
        noteArchived(ids, pinned: pinned);
      } else {
        update(() {});
        messenger.currentState
          ?..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                ids.length == 1
                    ? 'Note unarchived'
                    : '${ids.length} notes unarchived',
              ),
            ),
          );
      }
    } catch (e) {
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

  Future<void> setNoteColor(Iterable<String> ids, String chosen) async {
    try {
      for (final id in ids) {
        final note = await notes.get(id);
        if (note == null) continue;
        final field = chosen.startsWith('background:') ? 'background' : 'color';
        final value = chosen.startsWith('background:')
            ? chosen.substring('background:'.length)
            : chosen;
        await notes.edit(
          note.id,
          note.epoch,
          field,
          value,
          note.parents(field),
        );
      }
    } catch (e) {
      notice('$e');
    }
  }

  Future<void> remindNotes(BuildContext context, List<String> ids) async {
    final existing = ids.length == 1 ? notes.state.reminder(ids.single) : null;
    final chosen = await pickReminder(context, existing);
    if (chosen == null) return;
    try {
      if (chosen.at != null) await reminders?.requestPermission();
      await notes.state.setAll([
        for (final id in ids)
          (
            'reminder',
            id,
            chosen.at == null
                ? const <String, Object>{}
                : {
                    'at': chosen.at!.millisecondsSinceEpoch,
                    'repeat': chosen.repeat,
                  },
          ),
      ]);
      update(() {});
    } catch (e) {
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
    final live = shared && p['available'] == true && p['removed'] != true;
    final archived = shared && notes.state.archived(p['entry']);
    final actions = <String, (IconData, String)>{
      if (!shared || live)
        'pin': (
          pinned ? Icons.push_pin : Icons.push_pin_outlined,
          pinned ? 'Unpin' : 'Pin',
        ),
      if (live) 'select': (Icons.check_circle_outline, 'Select'),
      if (live)
        'archive': (
          archived ? Icons.unarchive_outlined : Icons.archive_outlined,
          archived ? 'Unarchive' : 'Archive',
        ),
      if (live) 'reminder': (Icons.notification_add_outlined, 'Remind me'),
      if (live) 'labels': (Icons.label_outline, 'Labels'),
      if (live) 'color': (Icons.palette_outlined, 'Colour and background'),
      if (live) 'copy note': (Icons.control_point_duplicate, 'Make a copy'),
      if (p['type'] != 'file') 'copy': (Icons.copy, 'Copy text'),
      if (p['type'] == 'file') 'save': (Icons.download, 'Save original'),
      if (p['type'] == 'file' &&
          RegExp(
            r'\.(png|jpe?g|webp|gif)$',
            caseSensitive: false,
          ).hasMatch(p['name'] ?? ''))
        'preview': (Icons.image_outlined, 'Preview photo'),
      if (!shared || live) 'delete': (Icons.delete_outline, 'Remove'),
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
        isScrollControlled: true,
        builder: (context) => SafeArea(
          child: SingleChildScrollView(
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
        ),
      );
    }
    if (chosen == null || !context.mounted) return;
    if (!shared) {
      everydayItemAction(context, item, chosen, pins);
      return;
    }
    final id = p['entry'] as String;
    switch (chosen) {
      case 'pin':
        await notes.pin(id, !pinned);
        update(() {});
      case 'select':
        update(() => selectedNotes.add(id));
      case 'archive':
        await setArchived([id], !archived);
      case 'reminder':
        await remindNotes(context, [id]);
      case 'labels':
        await editNoteLabels(context, notes.state, [id], notice: notice);
        update(() {});
      case 'color':
        final color = await pickNoteColor(
          context,
          p['color'],
          background: p['background'],
          backgrounds: true,
        );
        if (color != null) await setNoteColor([id], color);
      case 'copy note':
        try {
          final copy = await notes.copy(id);
          await openNote(copy.id);
        } catch (e) {
          notice('$e');
        }
      case 'copy':
        final note = await notes.get(id, includeUnavailable: true);
        if (note == null) return;
        await Clipboard.setData(ClipboardData(text: plainNote(note)));
        notice('Copied');
      case 'delete':
        await setNoteRemoved(id, true);
      case 'restore':
        await setNoteRemoved(id, false);
    }
  }

  String plainNote(NoteDocument note) => [
    if (note.rawTitle.isNotEmpty) note.rawTitle,
    if (note.text.isNotEmpty)
      note.format == 'markup' ? NoteMarkup.plain(note.text) : note.text,
    for (final c in note.checks)
      '${'    ' * note.indent(c)}${note.done(c) ? '☑' : '☐'} ${note.itemText(c)}',
    for (final f in note.files)
      if (note.transcript(f).isNotEmpty) note.transcript(f),
  ].join('\n');

  /// Removed notes leave Removed after [removedDays] days, or when emptied.
  /// Their encrypted history stays on the device; Recovery is not offered.
  static const removedDays = 7;
  bool emptied(Json p) {
    final at = p['removedAt'] as int?;
    return notes.state.purged(p['entry'], p['removal'] as String?) ||
        (at != null &&
            DateTime.now().millisecondsSinceEpoch - at >
                removedDays * Duration.millisecondsPerDay);
  }

  Future<void> emptyRemoved(List<EverydayItem> all) async {
    final removed = [
      for (final i in all)
        if (i.data['type'] == 'shared_note' &&
            i.data['removed'] == true &&
            i.data['removal'] != null &&
            !emptied(i.data))
          i,
    ];
    if (removed.isEmpty) return;
    try {
      await notes.state.setAll([
        for (final i in removed)
          ('purged', i.data['entry'] as String, i.data['removal'] as String),
      ]);
      update(() {});
    } catch (e) {
      notice('$e');
    }
  }

  bool notesMatch(EverydayItem item, Set<dynamic> pins, String query) {
    final p = item.data;
    final type = p['type'];
    if (type == 'pin') return false;
    final shared = type == 'shared_note';
    final id = p['entry'] as String? ?? '';
    final state = notes.state;
    final removedView = notesFilter == 'Removed';
    if (removedView) {
      if (!shared || p['deleted'] != true) return false;
      if (emptied(p)) return false;
    } else if (p['deleted'] == true || hiddenNotes.contains(id)) {
      return false;
    }
    final archived = shared && state.archived(id);
    if (notesFilter == 'Archive') {
      if (!archived) return false;
    } else if (archived && !removedView && notesFilter != 'Reminders') {
      return false;
    }
    final text = (p['text'] ?? '').toString();
    final link = text.startsWith('http');
    final files = (p['files'] as List? ?? const []).cast<Map>();
    final passes = switch (notesFilter) {
      'Text' => shared && p['checklist'] != true || type == 'note' && !link,
      'Lists' => shared && p['checklist'] == true || type == 'check',
      'Links' => (type == 'note' || shared) && link,
      'Files' =>
        type == 'file' ||
            files.any((f) => f['kind'] == 'image' || f['kind'] == 'drawing'),
      'Voice' => files.any((f) => f['kind'] == 'audio'),
      'Reminders' => shared && state.reminder(id) != null,
      _ when notesFilter.startsWith('label:') =>
        shared && state.labelsOf(id).contains(notesFilter.substring(6)),
      _ => true,
    };
    if (!passes) return false;
    if (query.isEmpty) return true;
    final labelNames = shared
        ? state.labelsOf(id).map((l) => state.labels[l]).join(' ')
        : '';
    return '${p['title'] ?? ''}\n$text\n${p['transcript'] ?? ''}\n${p['name'] ?? ''}\n${p['list'] ?? ''}\n$labelNames'
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

  /// Signed objects are immutable, so lookups for card previews are cached.
  SignedObject? cachedObject(String id) =>
      noteObjects[id] ??= node.store.get(id);

  void toggleSelected(String id) => update(
    () => selectedNotes.contains(id)
        ? selectedNotes.remove(id)
        : selectedNotes.add(id),
  );

  Widget noteTile(
    BuildContext context,
    EverydayItem item,
    Set pins, {
    List<EverydayItem> section = const [],
    double width = 240,
  }) {
    final p = item.data;
    if (p['type'] != 'shared_note') return legacyCard(context, item, pins);
    final id = p['entry'] as String;
    final colors = Theme.of(context).colorScheme;
    final overrides = noteChecks[id] ?? const <String, bool>{};
    final state = notes.state;
    final live = p['available'] == true && p['removed'] != true;
    final labelNames = state.labels;
    Widget card(VoidCallback open) => NoteCard(
      item: item,
      pinned: pins.contains(id),
      overrides: overrides,
      personName: name,
      onOpen: open,
      onCheck: (check, done) => checkNoteItem(item, check, done),
      onMenu: (position) => noteMenu(context, item, pins, position),
      labels: [for (final l in state.labelsOf(id)) labelNames[l]!],
      reminder: state.reminder(id),
      selected: selectedNotes.contains(id),
      selecting: selectedNotes.isNotEmpty,
      onSelect: live ? () => toggleSelected(id) : null,
      files: files,
      objectOf: cachedObject,
      online: network.running,
    );
    final container = OpenContainer<void>(
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
      openBuilder: (_, _) => noteEditor(id: id),
      closedBuilder: (context, open) => card(open),
    );
    if (notesFilter == 'Removed' || !live) return container;
    final draggable = notesSearch.text.trim().isEmpty && section.length > 1;
    final dismissible = Dismissible(
      key: ValueKey('dismiss/$id'),
      onDismissed: (_) => unawaited(setArchived([id], !state.archived(id))),
      child: container,
    );
    if (!draggable) return dismissible;
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) =>
          details.data != id &&
          section.any((s) => s.data['entry'] == details.data),
      onAcceptWithDetails: (details) =>
          unawaited(moveNote(details.data, id, section)),
      builder: (context, candidates, _) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            width: 2,
            color: candidates.isEmpty ? Colors.transparent : colors.primary,
          ),
        ),
        child: LongPressDraggable<String>(
          data: id,
          hapticFeedbackOnStart: true,
          onDragStarted: () => update(() => selectedNotes.add(id)),
          feedback: Material(
            color: Colors.transparent,
            elevation: 8,
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
              width: width,
              child: Opacity(opacity: .92, child: card(() {})),
            ),
          ),
          childWhenDragging: Opacity(opacity: .3, child: container),
          child: dismissible,
        ),
      ),
    );
  }

  /// Places [moved] just before [target] in the shown order of [section].
  /// Notes keep a personal position once moved; the first move gives every
  /// note in the section a position so the order stays as shown.
  Future<void> moveNote(
    String moved,
    String target,
    List<EverydayItem> section,
  ) async {
    final state = notes.state;
    final order = [for (final s in section) s.data['entry'] as String];
    order.remove(moved);
    final at = order.indexOf(target);
    if (at < 0) return;
    order.insert(at, moved);
    try {
      final before = at > 0 ? state.order(order[at - 1]) : null;
      final after = state.order(target);
      final keyed = order.every((id) => state.order(id) != null);
      if (keyed &&
          (at == 0 || before != null) &&
          after != null &&
          (before == null || before.compareTo(after) < 0)) {
        await state.set('order', moved, orderBetween(before, after));
      } else {
        final keys = orderSequence(order.length);
        await state.setAll([
          for (var i = 0; i < order.length; i++)
            if (state.order(order[i]) != keys[i]) ('order', order[i], keys[i]),
        ]);
      }
      update(() {});
    } catch (e) {
      notice('$e');
    }
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
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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
            tooltip: 'New voice note',
            onPressed: captureVoice,
            icon: const Icon(Icons.mic_none),
          ),
          IconButton(
            tooltip: 'New drawing',
            onPressed: captureDrawing,
            icon: const Icon(Icons.brush_outlined),
          ),
          PopupMenuButton<String>(
            tooltip: 'Add original file',
            enabled: !addingAttachment,
            icon: const Icon(Icons.image_outlined),
            onSelected: (value) => switch (value) {
              'image' => captureImage(),
              'paste' => attachmentAct(pasteInbox),
              _ => attachmentAct(() async {
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
                  await addEverydayFile(selected!.path!, name: selected.name);
                }
              }),
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'image',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.image_outlined),
                  title: Text('New note with image'),
                ),
              ),
              PopupMenuItem(
                value: 'file',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.attach_file),
                  title: Text('Save an original file'),
                ),
              ),
              PopupMenuItem(
                value: 'paste',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.content_paste),
                  title: Text('Paste text or screenshot'),
                ),
              ),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget selectionBar(BuildContext context, List<EverydayItem> all) {
    final ids = selectedNotes.toList();
    final state = notes.state;
    final allPinned = ids.every(notes.pinned);
    final allArchived = ids.every(state.archived);
    Future<void> run(Future<void> Function() action) async {
      try {
        await action();
      } catch (e) {
        notice('$e');
      }
      update(() {});
    }

    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      borderRadius: BorderRadius.circular(28),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Clear selection',
              onPressed: () => update(selectedNotes.clear),
              icon: const Icon(Icons.close),
            ),
            Expanded(
              child: Text(
                '${ids.length} selected',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              tooltip: allPinned ? 'Unpin' : 'Pin',
              onPressed: () => run(
                () => state.setAll([
                  for (final id in ids) ('pin', id, !allPinned),
                ]),
              ),
              icon: Icon(allPinned ? Icons.push_pin : Icons.push_pin_outlined),
            ),
            IconButton(
              tooltip: 'Remind me',
              onPressed: () => remindNotes(context, ids),
              icon: const Icon(Icons.notification_add_outlined),
            ),
            IconButton(
              tooltip: 'Colour and background',
              onPressed: () async {
                final chosen = await pickNoteColor(
                  context,
                  null,
                  backgrounds: true,
                );
                if (chosen != null) await run(() => setNoteColor(ids, chosen));
              },
              icon: const Icon(Icons.palette_outlined),
            ),
            IconButton(
              tooltip: allArchived ? 'Unarchive' : 'Archive',
              onPressed: () async {
                update(selectedNotes.clear);
                await setArchived(ids, !allArchived);
              },
              icon: Icon(
                allArchived ? Icons.unarchive_outlined : Icons.archive_outlined,
              ),
            ),
            PopupMenuButton<String>(
              tooltip: 'More actions',
              onSelected: (value) async {
                switch (value) {
                  case 'labels':
                    await editNoteLabels(context, state, ids, notice: notice);
                    update(() {});
                  case 'all':
                    update(() {
                      for (final item in all) {
                        if (item.data['type'] == 'shared_note' &&
                            item.data['available'] == true &&
                            item.data['removed'] != true) {
                          selectedNotes.add(item.data['entry']);
                        }
                      }
                    });
                  case 'copy':
                    await run(() async {
                      for (final id in ids) {
                        await notes.copy(id);
                      }
                    });
                    update(selectedNotes.clear);
                  case 'remove':
                    update(selectedNotes.clear);
                    await setNotesRemoved(ids, true);
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'labels', child: Text('Labels')),
                const PopupMenuItem(value: 'all', child: Text('Select all')),
                const PopupMenuItem(value: 'copy', child: Text('Make a copy')),
                const PopupMenuItem(value: 'remove', child: Text('Remove')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget filterChips(BuildContext context) {
    final labels = notes.state.labels;
    final chips = <(String, String, IconData)>[
      ('All', 'Notes', Icons.lightbulb_outline),
      ('Reminders', 'Reminders', Icons.notifications_none),
      for (final entry in labels.entries)
        ('label:${entry.key}', entry.value, Icons.label_outline),
      ('Archive', 'Archive', Icons.archive_outlined),
      ('Removed', 'Removed', Icons.delete_outline),
    ];
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final (value, label, icon) in chips)
            Padding(
              padding: const EdgeInsets.only(right: 6, top: 6),
              child: ChoiceChip(
                avatar: Icon(icon, size: 18),
                label: Text(label),
                selected: notesFilter == value,
                showCheckmark: false,
                onSelected: (_) => update(() {
                  notesFilter = value;
                  selectedNotes.clear();
                }),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: ActionChip(
              avatar: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('Edit labels'),
              onPressed: () async {
                await manageLabels(context, notes.state, notice: notice);
                if (notesFilter.startsWith('label:') &&
                    !notes.state.labels.containsKey(notesFilter.substring(6))) {
                  notesFilter = 'All';
                }
                update(() {});
              },
            ),
          ),
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
        final tileWidth = notesGrid
            ? (constraints.maxWidth - 10 * (columns - 1)) / columns
            : constraints.maxWidth.clamp(0, 640).toDouble();
        final search = Row(
          children: [
            Expanded(
              child: TextField(
                controller: notesSearch,
                focusNode: notesSearchFocus,
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
                  update(() {
                    notesFilter = value;
                    selectedNotes.clear();
                  });
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
        List<EverydayItem> loaded = const [];
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
            final all = loaded = snapshot.data!;
            final state = notes.state;
            final pins = <dynamic>{
              for (final i in all)
                if (i.data['type'] == 'pin' && i.data['pinned'] == true)
                  i.data['target'],
              for (final i in all)
                if (i.data['type'] == 'shared_note' &&
                    state.pinned(i.data['entry']))
                  i.data['entry'],
            };
            // Removals the summaries now reflect no longer need hiding.
            for (final i in all) {
              if (i.data['type'] == 'shared_note' &&
                  i.data['deleted'] == true) {
                hiddenNotes.remove(i.data['entry']);
              }
            }
            selectedNotes.removeWhere(
              (id) => !all.any(
                (i) =>
                    i.data['entry'] == id &&
                    i.data['type'] == 'shared_note' &&
                    i.data['deleted'] != true,
              ),
            );
            int time(EverydayItem i) =>
                i.data['updated'] as int? ?? i.object.created;
            String? position(EverydayItem i) => i.data['type'] == 'shared_note'
                ? state.order(i.data['entry'])
                : null;
            final visible =
                all.where((i) => notesMatch(i, pins, query)).toList()
                  ..sort((a, b) {
                    if (notesFilter == 'Reminders') {
                      final at =
                          state.reminder(a.data['entry'])?['at'] as int? ?? 0;
                      final bt =
                          state.reminder(b.data['entry'])?['at'] as int? ?? 0;
                      return at.compareTo(bt);
                    }
                    // Notes never moved come first, newest edit first; moved
                    // notes keep their personal position.
                    final pa = position(a), pb = position(b);
                    if (pa == null && pb == null) {
                      return time(b).compareTo(time(a));
                    }
                    if (pa == null) return -1;
                    if (pb == null) return 1;
                    return pa.compareTo(pb);
                  });
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
            final pinned = ['Removed', 'Archive'].contains(notesFilter)
                ? <EverydayItem>[]
                : visible.where((i) => pins.contains(i.data['entry'])).toList();
            final others = visible.where((i) => !pinned.contains(i)).toList();
            if (visible.isEmpty) {
              return empty(
                query.isNotEmpty
                    ? 'No matching notes'
                    : switch (notesFilter) {
                        'Removed' => 'Nothing removed',
                        'Archive' => 'Nothing archived',
                        'Reminders' => 'No upcoming reminders',
                        _ when notesFilter.startsWith('label:') =>
                          'No notes with this label',
                        _ => 'Your next small habit starts here',
                      },
                query.isNotEmpty
                    ? 'Try other words, or show all notes.'
                    : switch (notesFilter) {
                        'Removed' =>
                          'Removed notes stay here, and can be restored.',
                        'Archive' =>
                          'Archived notes stay searchable. Swipe a note to archive it.',
                        'Reminders' =>
                          'Notes with a reminder appear here, soonest first.',
                        _ when notesFilter.startsWith('label:') =>
                          'Add labels from a note\'s menu.',
                        _ =>
                          'Take a note, start a list, record your voice or draw. Drop a file, or paste a screenshot.',
                      },
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
                child: noteTile(
                  context,
                  items[index],
                  pins,
                  section: items,
                  width: tileWidth,
                ),
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
        final addDisabled = notesFilter == 'Removed';
        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyC): () {
              if (!addDisabled) unawaited(openNote(null));
            },
            const SingleActivator(LogicalKeyboardKey.keyL): () {
              if (!addDisabled) unawaited(openNote(null, checklist: true));
            },
            const SingleActivator(LogicalKeyboardKey.keyV): () {
              if (!addDisabled) unawaited(captureVoice());
            },
            const SingleActivator(LogicalKeyboardKey.slash): () =>
                notesSearchFocus.requestFocus(),
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                update(selectedNotes.clear),
            const SingleActivator(LogicalKeyboardKey.keyE): () {
              if (selectedNotes.isEmpty) return;
              final ids = selectedNotes.toList();
              update(selectedNotes.clear);
              unawaited(setArchived(ids, !ids.every(notes.state.archived)));
            },
            const SingleActivator(LogicalKeyboardKey.keyF): () {
              if (selectedNotes.isEmpty) return;
              final ids = selectedNotes.toList();
              final value = !ids.every(notes.pinned);
              unawaited(
                notes.state
                    .setAll([for (final id in ids) ('pin', id, value)])
                    .then((_) => update(() {})),
              );
            },
            const SingleActivator(LogicalKeyboardKey.delete): () {
              final ids = selectedNotes.toList();
              update(selectedNotes.clear);
              unawaited(setNotesRemoved(ids, true));
            },
            const SingleActivator(LogicalKeyboardKey.keyA, control: true): () =>
                update(() {
                  for (final item in loaded) {
                    if (item.data['type'] == 'shared_note' &&
                        item.data['available'] == true &&
                        item.data['removed'] != true &&
                        notesMatch(item, const {}, query)) {
                      selectedNotes.add(item.data['entry']);
                    }
                  }
                }),
          },
          child: Focus(
            autofocus: true,
            child: DropTarget(
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
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 150),
                        child: selectedNotes.isEmpty
                            ? search
                            : selectionBar(context, loaded),
                      ),
                      filterChips(context),
                      if (notesFilter == 'Removed')
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Row(
                            children: [
                              const Expanded(
                                child: Text(
                                  'Removed notes leave this list after $_removedDaysText. Collaborators keep their own copies.',
                                ),
                              ),
                              TextButton(
                                onPressed: () => emptyRemoved(loaded),
                                child: const Text('Empty Removed'),
                              ),
                            ],
                          ),
                        ),
                      if (![
                            'All',
                            'Reminders',
                            'Archive',
                            'Removed',
                          ].contains(notesFilter) &&
                          !notesFilter.startsWith('label:'))
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: InputChip(
                              label: Text(notesFilters[notesFilter]!),
                              onDeleted: () =>
                                  update(() => notesFilter = 'All'),
                            ),
                          ),
                        ),
                      if (wide && !addDisabled) ...[
                        const SizedBox(height: 12),
                        Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 640),
                            child: captureBar(context, top: true),
                          ),
                        ),
                      ],
                      const SizedBox(height: 4),
                      Expanded(child: content),
                      if (!wide && !addDisabled)
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
                            color: colors.tertiaryContainer.withValues(
                              alpha: .85,
                            ),
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
            ),
          ),
        );
      },
    );
  }
}
