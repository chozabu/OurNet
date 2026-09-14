part of 'app.dart';

extension _SocialPages on _OurNetAppState {
  Future<void> joinForum(BuildContext context, {bool create = false}) async {
    final value = await ask(
      context,
      create ? 'Start a forum' : 'Join forum',
      hint: create
          ? 'Name your public forum'
          : 'Paste a forum address, or enter a legacy forum name',
    );
    if (value == null || value.isEmpty) return;
    if (value.startsWith('_') || value == 'files') {
      throw StateError('Choose a public forum name other than files.');
    }
    final id = create ? 'forum2:${node.person}:${randomId()}' : value;
    if (create) {
      if (!context.mounted) return;
      final description = await ask(
        context,
        'Forum description',
        hint: 'What is this forum for?',
        lines: 3,
      );
      if (description == null) return;
      await node.publish('forum', {
        'name': value,
        'description': description,
      }, space: id);
    }
    node.subscribe(id, true);
    update(() {
      space = id;
      selectedThread = null;
      replyTo = null;
      showForum = true;
    });
    if (create) {
      notice(
        'Forum created. Start a discussion, then copy the forum address to invite people.',
      );
    }
  }

  Widget communities(BuildContext context) {
    final forums =
        node.subscriptions
            .where((s) => !s.startsWith('_') && s != 'files')
            .toList()
          ..sort();
    return browsePane(
      context,
      selected: showForum,
      back: () => update(() => showForum = false),
      list: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            onPressed: busy
                ? null
                : () => act(() => joinForum(context, create: true)),
            icon: const Icon(Icons.add),
            label: const Text('Start a forum'),
          ),
          TextButton.icon(
            onPressed: busy ? null : () => act(() => joinForum(context)),
            icon: const Icon(Icons.login),
            label: const Text('Join forum'),
          ),
          const Text('Public discussions · visible to others'),
          Expanded(
            child: ListView(
              children: [
                for (final forum in forums)
                  ListTile(
                    leading: const Icon(Icons.forum_outlined),
                    title: Text(forumName(forum)),
                    subtitle: recentActivity(
                      (objectsBySpace('post')[forum] ?? const [])
                          .where((o) => o.isPublic)
                          .toList(),
                      'No discussions yet',
                    ),
                    trailing: unreadBadge(
                      unreadObjects('post').where((o) => o.space == forum),
                    ),
                    selected: forum == space,
                    onTap: () => update(() {
                      space = forum;
                      selectedThread = null;
                      replyTo = null;
                      showForum = true;
                    }),
                  ),
              ],
            ),
          ),
        ],
      ),
      detail: forums.contains(space)
          ? forumDetail(context)
          : empty(
              'Find your discussions',
              'Join a forum or start one.',
              Icons.forum_outlined,
            ),
    );
  }

  Widget messages(BuildContext context) {
    contact = people.contains(contact) ? contact : people.firstOrNull;
    return browsePane(
      context,
      selected: showConversation,
      back: () => update(() => showConversation = false),
      list: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            onPressed: busy ? null : () => act(() => addFriend(context)),
            icon: const Icon(Icons.person_add_alt),
            label: const Text('Add friend'),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: people.isEmpty
                ? empty(
                    'Start a conversation',
                    'Add a friend using their contact card.',
                    Icons.chat_bubble_outline,
                  )
                : ListView(
                    children: [
                      for (final person in people)
                        ListTile(
                          leading: const Icon(Icons.person_outline),
                          title: Text(name(person)),
                          subtitle: recentActivity(
                            messageObjects()
                                .where(
                                  (o) =>
                                      !o.isPublic &&
                                      ((o.author == person &&
                                              o.audience.contains(
                                                node.person,
                                              )) ||
                                          (o.author == node.person &&
                                              o.audience.contains(person))),
                                )
                                .toList(),
                            'Private conversation',
                          ),
                          selected: contact == person,
                          trailing: unreadBadge(
                            unreadObjects('message').where(
                              (o) =>
                                  o.author == person &&
                                  o.audience.contains(node.person),
                            ),
                          ),
                          onTap: () => update(() {
                            contact = person;
                            showConversation = true;
                            replyTo = null;
                          }),
                        ),
                    ],
                  ),
          ),
        ],
      ),
      detail: messageDetail(context),
    );
  }

  Widget forumDetail(BuildContext context) => Column(
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              forumName(space),
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'Forum options',
            onSelected: (action) {
              if (action == 'copy') {
                Clipboard.setData(ClipboardData(text: space));
                notice('Forum address copied');
              }
              if (action == 'edit') act(() => forumSettings(context));
              if (action == 'leave') {
                node.subscribe(space, false);
                update(() {
                  space =
                      node.subscriptions
                          .where((s) => !s.startsWith('_') && s != 'files')
                          .firstOrNull ??
                      'general';
                  showForum = false;
                });
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'copy',
                child: Text('Copy forum address'),
              ),
              if (ownsForum(space))
                const PopupMenuItem(
                  value: 'edit',
                  child: Text('Edit description'),
                ),
              const PopupMenuItem(value: 'leave', child: Text('Leave forum')),
            ],
          ),
        ],
      ),
      if (forumInfo(space)?['description'] != null)
        Align(
          alignment: Alignment.centerLeft,
          child: Text(forumInfo(space)!['description']),
        ),
      if (selectedThread == null)
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: busy ? null : () => act(() => newDiscussion(context)),
            icon: const Icon(Icons.add_comment_outlined),
            label: const Text('New discussion'),
          ),
        ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: Text(
              selectedThread == null
                  ? 'Forum discussions'
                  : (node.store
                            .get(selectedThread!)
                            ?.data['payload']['title'] ??
                        'Discussion'),
            ),
          ),
          if (selectedThread != null)
            IconButton(
              tooltip: 'All discussions',
              icon: const Icon(Icons.arrow_back),
              onPressed: () => update(() {
                selectedThread = null;
                replyTo = null;
              }),
            ),
          TextButton(
            onPressed: () {
              for (final o in discussionObjects()) {
                node.store.set('seen/${o.id}', true);
              }
              refresh();
            },
            child: const Text('Mark read'),
          ),
        ],
      ),
      Expanded(child: objectList(context, discussionObjects())),
      if (selectedThread != null)
        compose(
          context,
          () => act(() async {
            final draftKey = composerContext;
            final submitted = composer.text;
            if (submitted.trim().isEmpty) return;
            await node.publish('post', {
              'text': submitted.trim(),
              'parent': replyTo ?? selectedThread,
            }, space: space);
            await finishDraft(draftKey, submitted);
            update(() => replyTo = null);
          }),
          attach: () => pickFile(
            [],
            postSpace: space,
            postData: {
              'parent': replyTo ?? selectedThread,
              'text': composer.text.trim(),
            },
          ),
        ),
    ],
  );

  Widget unreadBadge(Iterable<SignedObject> unread) {
    final count = unread.length;
    return Badge.count(count: count, isLabelVisible: count > 0);
  }

  List<SignedObject> messageObjects() =>
      memo('messages', () => node.store.objects(kind: 'message'));

  /// Direct reply counts for every post, computed once per build.
  Map<String, int> replyCounts() => memo('replies', () {
    final counts = <String, int>{};
    for (final o in node.store.objects(kind: 'post', limit: 10000)) {
      final parent = o.data['payload']['parent'];
      if (parent is String) counts[parent] = (counts[parent] ?? 0) + 1;
    }
    return counts;
  });

  List<SignedObject> discussionObjects() =>
      memo('discussion/$space/$selectedThread', _discussionObjects);

  List<SignedObject> _discussionObjects() {
    final posts = node.store
        .objects(kind: 'post', limit: 10000)
        .where((o) => o.space == space && o.isPublic && contentVisible(o))
        .toList();
    final ids = posts.map((o) => o.id).toSet();
    if (selectedThread == null) {
      return posts
          .where((o) => !ids.contains(o.data['payload']['parent']))
          .toList();
    }
    final children = <String, List<SignedObject>>{};
    for (final o in posts) {
      final parent = o.data['payload']['parent'];
      if (parent is String) (children[parent] ??= []).add(o);
    }
    final ordered = <SignedObject>[];
    final visited = <String>{};
    final byId = {for (final post in posts) post.id: post};
    final pending = [selectedThread!];
    while (pending.isNotEmpty) {
      final id = pending.removeLast();
      if (!visited.add(id)) continue;
      final found = byId[id];
      if (found != null) ordered.add(found);
      final replies = (children[id] ?? []).toList()
        ..sort((a, b) => a.created.compareTo(b.created));
      pending.addAll(replies.reversed.map((r) => r.id));
    }

    return ordered;
  }

  int replyDepth(SignedObject object) {
    var depth = 0;
    final seen = <String>{object.id};
    var parent = object.data['payload']['parent'];
    while (parent is String && seen.add(parent) && depth < 8) {
      depth++;
      parent = node.store.get(parent)?.data['payload']['parent'];
    }
    return depth;
  }

  Widget messageDetail(BuildContext context) {
    if (contact == null || !people.contains(contact)) {
      return empty(
        'Choose a conversation',
        'Select a friend to send a private message.',
        Icons.chat_bubble_outline,
      );
    }
    final objects = messageObjects()
        .where(
          (o) =>
              !o.isPublic &&
              ((o.author == node.person && o.audience.contains(contact)) ||
                  (o.author == contact && o.audience.contains(node.person))),
        )
        .toList();
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                name(contact!),
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            IconButton(
              tooltip: 'Shared places',
              onPressed: () => update(() => tab = 5),
              icon: const Icon(Icons.place_outlined),
            ),
            IconButton(
              tooltip: 'Voice call',
              onPressed: () => startCall(false),
              icon: const Icon(Icons.call_outlined),
            ),
            IconButton(
              tooltip: 'Video call',
              onPressed: () => startCall(true),
              icon: const Icon(Icons.videocam_outlined),
            ),
          ],
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: busy
                ? null
                : () => act(() async {
                    for (final object in objects.where(
                      (o) =>
                          o.author != node.person &&
                          node.store.setting('read/${o.id}') != true,
                    )) {
                      await node.markRead(object.id);
                    }
                    refresh();
                  }),
            icon: const Icon(Icons.done_all),
            label: const Text('Mark conversation read'),
          ),
        ),
        Expanded(child: objectList(context, objects)),
        compose(
          context,
          () => act(() async {
            final draftKey = composerContext;
            final submitted = composer.text;
            if (submitted.trim().isEmpty) return;
            await node.publish(
              'message',
              {'text': submitted.trim()},
              space: '_messages',
              audience: [contact!],
            );
            await finishDraft(draftKey, submitted);
          }),
          attach: () => pickFile([contact!]),
        ),
      ],
    );
  }

  void startCall(bool video) => act(() async {
    final device = node.contacts.values.firstWhere(
      (c) => c.person == contact && !node.revoked.contains(c.device),
    );
    if (!network.running) await network.start();
    await calls.call(device.device, video: video);
  });
  Widget compose(
    BuildContext context,
    VoidCallback send, {
    VoidCallback? attach,
  }) {
    final key = tab == 2
        ? 'message/$contact'
        : 'community/$space/$selectedThread';
    if (composerContext != key) {
      if (composerContext != null) drafts[composerContext!] = composer.value;
      composerContext = key;
      switchingDraft = true;
      composer.value = drafts[key] ?? TextEditingValue.empty;
      switchingDraft = false;
    }
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        children: [
          if (replyTo != null)
            Row(
              children: [
                Expanded(child: Text('Replying to ${short(replyTo!)}')),
                IconButton(
                  onPressed: () => update(() => replyTo = null),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (attach != null)
                IconButton(
                  tooltip: 'Attach file',
                  onPressed: busy ? null : attach,
                  icon: const Icon(Icons.attach_file),
                ),
              if (attach != null)
                IconButton(
                  tooltip: 'Paste image',
                  onPressed: busy
                      ? null
                      : () => act(() async {
                          final draftKey = composerContext;
                          final submitted = composer.text;
                          final recipient = contact!;
                          final image = await Pasteboard.image;
                          if (image == null) {
                            throw StateError('Clipboard has no image');
                          }
                          if (image.length > 8 * 1024 * 1024) {
                            throw StateError('Clipboard image limit is 8 MiB');
                          }
                          final temp = File(
                            '${(await getTemporaryDirectory()).path}/${randomId()}.png',
                          );
                          try {
                            await temp.writeAsBytes(image);
                            await files.publish(
                              temp.path,
                              audience: [recipient],
                              text: submitted,
                            );
                            await finishDraft(draftKey, submitted);
                          } finally {
                            if (await temp.exists()) await temp.delete();
                          }
                        }),
                  icon: const Icon(Icons.content_paste),
                ),
              Expanded(
                child: Focus(
                  onKeyEvent: (_, event) {
                    if (event.logicalKey != LogicalKeyboardKey.enter ||
                        (composer.value.composing.isValid &&
                            !composer.value.composing.isCollapsed)) {
                      return KeyEventResult.ignored;
                    }
                    if (HardwareKeyboard.instance.isShiftPressed) {
                      if (event is KeyDownEvent) {
                        final selection = composer.selection;
                        final start = selection.isValid
                            ? selection.start
                            : composer.text.length;
                        final end = selection.isValid ? selection.end : start;
                        composer.value = TextEditingValue(
                          text: composer.text.replaceRange(start, end, '\n'),
                          selection: TextSelection.collapsed(offset: start + 1),
                        );
                      }
                      return KeyEventResult.handled;
                    }
                    if (event is KeyDownEvent && !busy) send();
                    return KeyEventResult.handled;
                  },
                  child: TextField(
                    controller: composer,
                    minLines: 1,
                    maxLines: 5,
                    decoration: InputDecoration(
                      helperText:
                          Platform.isWindows ||
                              Platform.isLinux ||
                              Platform.isMacOS
                          ? 'Enter sends · Shift+Enter adds a line'
                          : null,
                      hintText: tab == 2
                          ? 'Write a private message…'
                          : 'Start a discussion in this forum…',
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: busy ? null : send,
                child: const Icon(Icons.send),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
