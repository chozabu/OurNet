part of 'app.dart';

extension _EverydayPages on _OurNetAppState {
  Future<void> openNote(String id) async {
    if (!mounted) return;
    await noteNavigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => NoteEditor(
          notes: notes,
          id: id,
          drafts: draftStore,
          network: network,
          friends: {for (final person in people) person: name(person)},
          personName: name,
        ),
      ),
    );
  }

  Future<List<EverydayItem>> noteItems() async => [
    ...await Everyday(node).items(),
    ...await notes.summaries(includeDeleted: true),
  ];

  Future<void> noteAction(Future<void> Function() action) async {
    if (savingNote) return;
    update(() => savingNote = true);
    try {
      await action();
    } catch (e) {
      notice('$e');
    } finally {
      if (mounted) update(() => savingNote = false);
    }
  }

  Future<void> savePersonalNote(String text, bool checklist) async {
    if (!checklist) {
      await notes.create(text: text);
      return;
    }
    final title = listName.text.trim().isEmpty
        ? 'Shopping'
        : listName.text.trim();
    final matching = (await notes.summaries())
        .where((n) => n.data['title'] == title && n.data['checklist'] == true)
        .firstOrNull;
    final note = matching == null
        ? await notes.create(title: title)
        : (await notes.get(matching.data['entry']))!;
    await notes.edit(note.id, note.epoch, 'check:${randomId()}:text', text, []);
  }

  Future<void> adoptNote(EverydayItem item) async {
    // Explicit one-time conversion, not a scan during widget/list refresh.
    final check = item.data['type'] == 'check';
    final entries = check
        ? (await Everyday(node).items())
              .where(
                (r) =>
                    r.data['type'] == 'check' &&
                    r.data['list'] == item.data['list'] &&
                    r.data['deleted'] != true,
              )
              .toList()
        : [item];
    final stable = entries.map((e) => e.data['entry'].toString()).toList()
      ..sort();
    final note = await notes.create(
      stableId: 'note-${stable.first}',
      title: check ? item.data['list'] : 'Note',
      text: check ? '' : item.data['text'],
    );
    for (final entry in entries) {
      if (check) {
        final field = 'check:${entry.data['entry']}';
        if (!note.heads.containsKey('$field:text')) {
          await notes.edit(
            note.id,
            note.epoch,
            '$field:text',
            entry.data['text'],
            [],
          );
          await notes.edit(
            note.id,
            note.epoch,
            '$field:done',
            entry.data['done'] == true,
            [],
          );
        }
      }
    }
    for (final entry in entries) {
      await Everyday(
        node,
      ).write({...entry.data, 'deleted': true, 'movedTo': note.id});
    }
    await openNote(note.id);
  }

  Future<void> loadDeliveryLabels() async {
    final labels = <String, String>{};
    final received = <String, Set<String>>{};
    for (final o in node.store.objects(
      kind: 'delivery',
      limit: Node.maxObjects,
    )) {
      final p = await node.content(o);
      if (p == null) continue;
      final original = node.store.get(p['object']);
      if (original == null ||
          o.certificate.device == node.identity.device ||
          !original.audience.contains(o.author)) {
        continue;
      }
      (received[p['object']] ??= <String>{}).add(o.certificate.device);
      labels[p['object']] =
          'Received on ${received[p['object']]!.length} other device(s)';
    }
    if (mounted && labels.toString() != deliveryLabels.toString()) {
      update(() {
        deliveryLabels
          ..clear()
          ..addAll(labels);
      });
    }
  }

  Future<void> addEverydayFile(
    String path, {
    String? name,
    EverydayItem? room,
  }) async {
    final job = Object();
    if (mounted) {
      imports.value = {...imports.value, job: (completed: 0, total: 0)};
    }
    try {
      if (room != null) {
        room = await Everyday(node).current(room);
        await Everyday(node).prepare(room);
      }
      final object = await files.publish(
        path,
        name: name,
        audience: room == null
            ? [node.person]
            : await Everyday(node).members(room),
        room: room?.data['room'],
        everyday: await Everyday(node).data({
          'type': 'file',
          if (room != null) 'epoch': Everyday(node).epoch(room),
        }),
        onProgress: (completed, total) {
          if (mounted) {
            imports.value = {
              ...imports.value,
              job: (completed: completed, total: total),
            };
          }
        },
      );
      // Prepare the list preview in the background so scrolling never needs
      // the original. Failures fall back to on-demand generation.
      if (isImagePayload({'chunks': const [], 'name': name ?? path})) {
        unawaited(Thumbnails.of(files).prepare(object).catchError((_) {}));
      }
    } finally {
      if (mounted) imports.value = {...imports.value}..remove(job);
    }
  }

  Future<void> pasteInbox() async {
    final room = activeRoom;
    final image = await Pasteboard.image;
    if (image != null) {
      final temp = File(
        '${(await getTemporaryDirectory()).path}/${randomId()}.png',
      );
      try {
        await temp.writeAsBytes(image);
        await addEverydayFile(temp.path, name: 'Screenshot.png', room: room);
      } finally {
        if (await temp.exists()) await temp.delete();
      }
    } else {
      final value = await Clipboard.getData(Clipboard.kTextPlain);
      if (value?.text?.trim().isNotEmpty == true) {
        await Everyday(
          node,
        ).write({'type': 'note', 'text': value!.text!}, room: room);
      }
    }
  }

  Future<void> createPrivateGroup(BuildContext context) async {
    final title = await ask(
      context,
      'Create a private group',
      hint: 'Family, Weekend trip…',
    );
    if (title == null || title.isEmpty || !context.mounted) return;
    final selected = <String>{};
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, change) => AlertDialog(
          title: const Text('Invite friends'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Only the people you choose can read this group. The owner can invite or remove members later.',
                  ),
                  if (people.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 16),
                      child: Text(
                        'Add a friend below, or create a group just for you.',
                      ),
                    ),
                  TextButton.icon(
                    onPressed: () async {
                      await addFriend(context);
                      change(() {});
                    },
                    icon: const Icon(Icons.person_add_alt),
                    label: const Text('Add friend'),
                  ),
                  for (final p in people)
                    CheckboxListTile(
                      title: Text(name(p)),
                      value: selected.contains(p),
                      onChanged: (v) => change(() {
                        v == true ? selected.add(p) : selected.remove(p);
                      }),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Create group'),
            ),
          ],
        ),
      ),
    );
    if (accepted == true) {
      final room = await Everyday(node).createRoom(title, selected.toList());
      update(() {
        activeRoom = room;
        everydaySection = 'Conversation';
        tab = 10;
      });
    }
  }

  Widget everydayPage(BuildContext context) {
    final room = activeRoom;
    final draftKey = 'notes/${room?.object.id ?? 'self'}';
    if (notesComposerContext != draftKey) {
      if (notesComposerContext != null) {
        drafts[notesComposerContext!] = inboxComposer.value;
      }
      notesComposerContext = draftKey;
      switchingDraft = true;
      inboxComposer.value = drafts[draftKey] ?? TextEditingValue.empty;
      switchingDraft = false;
    }
    final colors = Theme.of(context).colorScheme;
    final typing = MediaQuery.viewInsetsOf(context).bottom > 0;
    return DropTarget(
      enable: widget.enablePlatform && !addingAttachment,
      onDragEntered: (_) => update(() => inboxDragging = true),
      onDragExited: (_) => update(() => inboxDragging = false),
      onDragDone: (details) {
        update(() => inboxDragging = false);
        attachmentAct(() async {
          for (final file in details.files) {
            await addEverydayFile(file.path, name: file.name, room: room);
          }
        });
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(typing ? 12 : 24),
            decoration: BoxDecoration(
              color: inboxDragging
                  ? colors.tertiaryContainer
                  : colors.primaryContainer,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      room == null
                          ? Icons.note_alt_outlined
                          : Icons.people_outline,
                      size: 28,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        room?.data['name'] ?? 'Notes',
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -.8,
                        ),
                      ),
                    ),
                    if (room != null)
                      IconButton(
                        tooltip: 'Group members',
                        onPressed: busy
                            ? null
                            : () => act(() => manageGroup(context, room)),
                        icon: const Icon(Icons.manage_accounts_outlined),
                      ),
                  ],
                ),
                if (!typing) const SizedBox(height: 8),
                Text(
                  inboxDragging
                      ? 'Drop to save here'
                      : room == null
                      ? 'Your notes, checklists and notes shared with friends.'
                      : '${(room.data['members'] as List).length} members · Private group',
                ),
                if (!typing) const SizedBox(height: 12),
                SyncStatus(
                  network: network,
                  people: room == null
                      ? null
                      : (room.data['members'] as List).cast<String>(),
                  suffix: ' · originals stay intact',
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (room == null)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final filter in [
                    'All',
                    'Text',
                    'Links',
                    'Files',
                    'Lists',
                    'Pinned',
                    'Removed',
                  ])
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(filter),
                        selected: notesFilter == filter,
                        onSelected: (_) => update(() => notesFilter = filter),
                      ),
                    ),
                ],
              ),
            ),
          if (room != null)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final section in ['Conversation', 'Files', 'Lists'])
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(section),
                        selected: everydaySection == section,
                        onSelected: (_) =>
                            update(() => everydaySection = section),
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: FutureBuilder<List<EverydayItem>>(
              future: everydayView ??= room == null
                  ? noteItems()
                  : Everyday(node).items(room),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(
                    child: Text('Could not load items: ${snapshot.error}'),
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final all = snapshot.data!;
                final pins = all
                    .where(
                      (i) =>
                          i.data['type'] == 'pin' && i.data['pinned'] == true,
                    )
                    .map((i) => i.data['target'])
                    .toSet();
                pins.addAll(node.store.trueSettings('notePin/'));
                final visible = all
                    .where(
                      (i) =>
                          i.data['type'] != 'pin' &&
                          (notesFilter == 'Removed' && room == null
                              ? i.data['deleted'] == true &&
                                    i.data['type'] == 'shared_note'
                              : i.data['deleted'] != true) &&
                          (room == null &&
                                  (notesFilter == 'All' ||
                                      notesFilter == 'Removed' ||
                                      i.data['type'] == 'shared_note' &&
                                          (notesFilter == 'Text' &&
                                                  i.data['checklist'] != true ||
                                              notesFilter == 'Lists' &&
                                                  i.data['checklist'] ==
                                                      true) ||
                                      notesFilter == 'Text' &&
                                          i.data['type'] == 'note' &&
                                          !(i.data['text'] ?? '')
                                              .toString()
                                              .startsWith('http') ||
                                      notesFilter == 'Links' &&
                                          (i.data['text'] ?? '')
                                              .toString()
                                              .startsWith('http') ||
                                      notesFilter == 'Files' &&
                                          i.data['type'] == 'file' ||
                                      notesFilter == 'Lists' &&
                                          i.data['type'] == 'check' ||
                                      notesFilter == 'Pinned' &&
                                          pins.contains(i.data['entry'])) ||
                              room != null &&
                                  everydaySection == 'Conversation' &&
                                  i.data['type'] != 'check' ||
                              room != null &&
                                  everydaySection == 'Files' &&
                                  i.data['type'] == 'file' ||
                              (room != null && everydaySection == 'Lists' ||
                                      room == null && notesFilter == 'Lists') &&
                                  i.data['type'] == 'check'),
                    )
                    .toList();
                visible.sort((a, b) {
                  final pinned = (pins.contains(b.data['entry']) ? 1 : 0)
                      .compareTo(pins.contains(a.data['entry']) ? 1 : 0);
                  return pinned != 0
                      ? pinned
                      : b.object.created.compareTo(a.object.created);
                });
                if (visible.isEmpty) {
                  return empty(
                    room == null
                        ? 'Your next small habit starts here'
                        : everydaySection == 'Lists'
                        ? 'Less remembering. More doing.'
                        : 'Make yourselves at home',
                    room == null
                        ? 'Save a link or note below. Drop a file, or paste a screenshot.'
                        : everydaySection == 'Lists'
                        ? 'Create a shopping, packing, or household checklist below.'
                        : 'Send a message or add the first file.',
                    room == null ? Icons.devices : Icons.favorite_border,
                  );
                }
                return ListView.builder(
                  key: PageStorageKey(
                    'everyday/${room?.object.id ?? 'self'}/${room == null ? notesFilter : everydaySection}',
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  itemCount: visible.length,
                  itemBuilder: (context, index) => KeyedSubtree(
                    key: ValueKey(visible[index].data['entry']),
                    child: everydayRow(context, visible[index], pins),
                  ),
                );
              },
            ),
          ),
          if ((room != null && everydaySection == 'Lists' ||
              room == null && notesFilter == 'Lists'))
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TextField(
                controller: listName,
                decoration: const InputDecoration(
                  labelText: 'List name',
                  hintText: 'Shopping',
                  isDense: true,
                ),
              ),
            ),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              border: Border.all(color: colors.outlineVariant),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              children: [
                TextField(
                  controller: inboxComposer,
                  minLines: 1,
                  maxLines: 4,
                  decoration: InputDecoration(
                    hintText:
                        (room != null && everydaySection == 'Lists' ||
                            room == null && notesFilter == 'Lists')
                        ? 'Add an item…'
                        : 'A link, a thought, something to keep…',
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                  ),
                ),
                Row(
                  children: [
                    IconButton(
                      tooltip: 'Add original file',
                      onPressed: addingAttachment
                          ? null
                          : () => attachmentAct(() async {
                              final picker = widget.pickAttachment;
                              final selected = picker == null
                                  ? await FilePicker.pickFile()
                                  : null;
                              if (picker != null) {
                                final file = await picker();
                                if (file != null) {
                                  await addEverydayFile(
                                    file.path,
                                    name: file.name,
                                    room: room,
                                  );
                                }
                                return;
                              }
                              if (selected?.path != null) {
                                await addEverydayFile(
                                  selected!.path!,
                                  name: selected.name,
                                  room: room,
                                );
                              }
                            }),
                      icon: const Icon(Icons.attach_file),
                    ),
                    IconButton(
                      tooltip: 'Paste text or screenshot',
                      onPressed: addingAttachment
                          ? null
                          : () => attachmentAct(pasteInbox),
                      icon: const Icon(Icons.content_paste),
                    ),
                    const Spacer(),
                    FilledButton.icon(
                      onPressed: savingNote
                          ? null
                          : () => noteAction(() async {
                              final submitted = inboxComposer.text;
                              final text = submitted.trim();
                              if (text.isEmpty) return;
                              final check =
                                  (room != null && everydaySection == 'Lists' ||
                                  room == null && notesFilter == 'Lists');
                              if (room == null) {
                                await savePersonalNote(text, check);
                              } else {
                                await Everyday(node).write({
                                  'type': check ? 'check' : 'note',
                                  'text': text,
                                  if (check) 'done': false,
                                  if (check)
                                    'list': listName.text.trim().isEmpty
                                        ? 'Shopping'
                                        : listName.text.trim(),
                                }, room: room);
                              }
                              await finishDraft(
                                draftKey,
                                submitted,
                                notes: true,
                              );
                            }),
                      icon: const Icon(Icons.arrow_upward, size: 18),
                      label: Text(
                        room == null && notesFilter != 'Lists'
                            ? 'Save note'
                            : 'Add',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> readEverydayItem(BuildContext context, EverydayItem item) async {
    if (activeRoom == null && ['note', 'check'].contains(item.data['type'])) {
      await noteAction(() => adoptNote(item));
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(item.data['type'] == 'check' ? 'List item' : 'Note'),
        content: SizedBox(
          width: 600,
          child: SingleChildScrollView(
            child: SelectableText(item.data['text'] ?? ''),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(
                ClipboardData(text: item.data['text'] ?? ''),
              );
              notice('Copied');
            },
            child: const Text('Copy text'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget everydayRow(
    BuildContext context,
    EverydayItem item,
    Set<dynamic> pins,
  ) {
    final p = item.data, o = item.object;
    if (p['type'] == 'shared_note') {
      return Card(
        child: Column(
          children: [
            ListTile(
              leading: Icon(
                p['members'] > 1
                    ? Icons.people_outline
                    : p['checklist'] == true
                    ? Icons.checklist
                    : Icons.notes,
              ),
              title: Text(
                p['title'],
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${p['members'] > 1 ? '${p['members']} collaborators · ' : ''}${p['conflicts'] == true ? 'Competing edits to review\n' : ''}${p['checklist'] == true ? 'Checklist' : p['text']}',
                maxLines: 5,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => openNote(p['entry']),
              trailing: IconButton(
                tooltip: pins.contains(p['entry']) ? 'Unpin' : 'Pin',
                icon: Icon(
                  pins.contains(p['entry'])
                      ? Icons.push_pin
                      : Icons.push_pin_outlined,
                ),
                onPressed: () =>
                    notes.pin(p['entry'], !pins.contains(p['entry'])),
              ),
            ),
            if (p['checklist'] == true && p['deleted'] != true)
              for (final row in p['checks'] as List)
                CheckboxListTile(
                  value: row['done'] == true,
                  title: Text(
                    row['text'],
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onChanged: (value) async {
                    try {
                      await notes.edit(
                        p['entry'],
                        p['epoch'],
                        'check:${row['id']}:done',
                        value!,
                        (row['parents'] as List).cast<String>(),
                      );
                    } catch (e) {
                      notice('$e');
                    }
                  },
                ),
          ],
        ),
      );
    }
    final attachment = p['type'] == 'file', check = p['type'] == 'check';
    final local = !attachment || files.cached(p);
    final saved = Platform.isAndroid
        ? 'Saved on this phone'
        : 'Saved on this PC';
    final status = local
        ? '$saved · Available offline'
        : everydaySync.errors[o.id] != null
        ? 'Transfer delayed: ${everydaySync.errors[o.id]} · Will retry'
        : 'Waiting for source device · Will retry';
    return Card(
      child: Column(
        children: [
          if (attachment && isImagePayload(p))
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: InlineImage(
                key: ValueKey(o.id),
                files: files,
                object: o,
                payload: p,
                online: network.running,
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: ListTile(
              leading: check
                  ? Checkbox(
                      value: p['done'] == true,
                      onChanged: busy
                          ? null
                          : (v) => act(
                              () => Everyday(
                                node,
                              ).write({...p, 'done': v}, room: activeRoom),
                            ),
                    )
                  : CircleAvatar(
                      backgroundColor: Theme.of(
                        context,
                      ).colorScheme.secondaryContainer,
                      child: Icon(
                        attachment
                            ? Icons.insert_drive_file_outlined
                            : (p['text'] ?? '').toString().startsWith('http')
                            ? Icons.link
                            : Icons.notes,
                      ),
                    ),
              title: Text(
                attachment ? p['name'] : p['text'] ?? '',
                maxLines: 5,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  decoration: check && p['done'] == true
                      ? TextDecoration.lineThrough
                      : null,
                ),
              ),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '${pins.contains(p['entry']) ? 'Pinned · ' : ''}${check ? '${p['list']} · ' : ''}${p['history'] == true ? 'Shared history · ${name(p['originalAuthor'] ?? o.author)}' : o.certificate.label}\n$status${o.certificate.device == node.identity.device ? '\n${deliveryLabels[o.id] ?? (node.contacts.values.any((c) => c.person == node.person) || activeRoom != null ? 'Waiting for other devices · automatic retry' : 'Link another device to send it there')}' : ''}',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              isThreeLine: true,
              onTap: attachment
                  ? () => saveFile(context, o, p)
                  : () => readEverydayItem(context, item),
              trailing: PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'copy') {
                    act(() async {
                      await Clipboard.setData(
                        ClipboardData(text: p['text'] ?? ''),
                      );
                      notice('Copied');
                    });
                    return;
                  }
                  if (value == 'edit' || value == 'delete') {
                    final room = activeRoom;
                    act(() async {
                      final text = value == 'edit'
                          ? await ask(
                              context,
                              'Edit item',
                              initial: p['text'] ?? '',
                              lines: 3,
                            )
                          : null;
                      if (value == 'edit' && (text == null || text.isEmpty)) {
                        return;
                      }
                      await Everyday(node).write({
                        ...p,
                        'text': ?text,
                        if (value == 'delete') 'deleted': true,
                      }, room: room);
                      if (value == 'delete' && mounted) {
                        messenger.currentState?.showSnackBar(
                          SnackBar(
                            content: const Text('Item removed'),
                            action: SnackBarAction(
                              label: 'Undo',
                              onPressed: () => act(() async {
                                await Everyday(
                                  node,
                                ).write({...p, 'deleted': false}, room: room);
                              }),
                            ),
                          ),
                        );
                      }
                    });
                    return;
                  }
                  if (value == 'save') {
                    saveFile(context, o, p);
                    return;
                  }
                  if (value == 'preview') {
                    previewImage(context, o);
                    return;
                  }
                  act(
                    () => Everyday(node).write({
                      'type': 'pin',
                      'entry': 'pin:${p['entry']}',
                      'target': p['entry'],
                      'pinned': !pins.contains(p['entry']),
                    }, room: activeRoom),
                  );
                },
                itemBuilder: (_) => [
                  if (!attachment)
                    const PopupMenuItem(
                      value: 'copy',
                      child: Text('Copy text'),
                    ),
                  if (!attachment)
                    const PopupMenuItem(value: 'edit', child: Text('Edit')),
                  const PopupMenuItem(value: 'delete', child: Text('Remove')),
                  if (attachment)
                    const PopupMenuItem(
                      value: 'save',
                      child: Text('Save original'),
                    ),
                  if (attachment &&
                      RegExp(
                        r'\.(png|jpe?g|webp|gif)$',
                        caseSensitive: false,
                      ).hasMatch(p['name']))
                    const PopupMenuItem(
                      value: 'preview',
                      child: Text('Preview photo'),
                    ),
                  PopupMenuItem(
                    value: 'pin',
                    child: Text(pins.contains(p['entry']) ? 'Unpin' : 'Pin'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
