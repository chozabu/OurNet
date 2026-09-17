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
            onPressed: () => addFriend(context, offerSharedNote: true),
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
                          leading: conversationAvatar(person, radius: 20),
                          title: Text(name(person)),
                          subtitle: recentActivity(
                            node.store.conversation(
                              node.person,
                              person,
                              limit: 1,
                            ),
                            'Private conversation',
                          ),
                          selected: contact == person,
                          trailing: conversationUnreadBadge(person),
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
      detailBuilder: (back) => messageDetail(context, back: back),
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

  Widget conversationUnreadBadge(String person) {
    final count = node.store.conversationUnread(
      node.person,
      peer: person,
      blocked: node.blocked,
    );
    return Badge.count(count: count, isLabelVisible: count > 0);
  }

  Widget unreadBadge(Iterable<SignedObject> unread) {
    final count = unread.length;
    return Badge.count(count: count, isLabelVisible: count > 0);
  }

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

  int compareMessages(SignedObject a, SignedObject b) {
    final time = b.created.compareTo(a.created);
    return time == 0 ? a.id.compareTo(b.id) : time;
  }

  Future<void> refreshConversations() async {
    final end = node.store.insertionCursor;
    while (conversationCursor < end) {
      final page = node.store.insertedAfter(conversationCursor, ['message']);
      if (page.isEmpty) break;
      for (final (cursor, object) in page) {
        conversationCursor = cursor;
        final peers = object.author == node.person
            ? object.audience
            : object.audience.contains(node.person)
            ? [object.author]
            : <String>[];
        for (final peer in peers) {
          final loaded = conversationOlder[peer];
          if (loaded == null) continue;
          final scroll = conversationScroll[peer];
          if (loaded.isNotEmpty &&
              (conversationPending.contains(peer) ||
                  scroll == null ||
                  !scroll.hasClients ||
                  scroll.offset > 16)) {
            // Do not move the reader's visible messages under background sync.
            // Keep only a dirty flag, not an unbounded queue of unseen arrivals.
            conversationPending.add(peer);
            continue;
          }
          // Ignore arrivals older than the loaded range until that page opens.
          if (loaded.isNotEmpty &&
              !conversationEnd.contains(peer) &&
              compareMessages(object, loaded.last) > 0) {
            continue;
          }
          var low = 0, high = loaded.length;
          while (low < high) {
            final mid = (low + high) ~/ 2;
            if (compareMessages(loaded[mid], object) < 0) {
              low = mid + 1;
            } else {
              high = mid;
            }
          }
          if (low == loaded.length || loaded[low].id != object.id) {
            loaded.insert(low, object);
          }
        }
      }
      await Future<void>.delayed(Duration.zero);
    }
    if (conversationCursor < end) conversationCursor = end;
  }

  List<String> messageHelpers(String recipient) {
    final helper = node.store.setting('messageHelper/$recipient');
    return helper is String &&
            people.contains(helper) &&
            helper != recipient &&
            !node.blocked.contains(helper)
        ? [helper]
        : const [];
  }

  Future<void> chooseMessageHelper(BuildContext context) async {
    final recipient = contact;
    if (recipient == null) return;
    final chosen = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Optional text forwarding'),
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'A chosen contact can retain encrypted text messages while you are offline. '
              'Both people must connect to that helper, and it must remain available. '
              'It cannot read message text, but can see routing metadata. '
              'This does not forward attachment originals or wake sleeping phones. '
              'Changes apply to new text messages only. Your own linked devices can also hold messages.',
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, ''),
            child: const Text('Direct and my linked devices only'),
          ),
          for (final person in people.where(
            (p) => p != recipient && p != node.person,
          ))
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, person),
              child: Text(name(person)),
            ),
        ],
      ),
    );
    if (chosen != null) {
      update(
        () => node.store.set(
          'messageHelper/$recipient',
          chosen.isEmpty ? null : chosen,
        ),
      );
    }
  }

  Future<void> sendConversationMessage() async {
    final recipient = contact;
    if (recipient == null || sendingMessages.contains(recipient)) return;
    final draftKey = composerContext;
    final submitted = composer.text;
    if (submitted.trim().isEmpty) return;
    update(() {
      sendingMessages.add(recipient);
      messageErrors.remove(recipient);
    });
    try {
      await node.publish(
        'message',
        {'text': submitted.trim()},
        space: '_messages',
        audience: [recipient],
        via: messageHelpers(recipient),
      );
    } catch (error) {
      update(() => messageErrors[recipient] = 'Could not save message: $error');
      return;
    } finally {
      update(() => sendingMessages.remove(recipient));
    }
    // A draft persistence failure must never offer to publish this message twice.
    try {
      await finishDraft(draftKey, submitted);
    } catch (error) {
      notice('Message saved; could not update draft: $error');
    }
  }

  Widget messageDetail(BuildContext context, {VoidCallback? back}) {
    if (contact == null || !people.contains(contact)) {
      return empty(
        'Choose a conversation',
        'Select a friend to send a private message.',
        Icons.chat_bubble_outline,
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final scroll = conversationScroll.putIfAbsent(
      contact!,
      ScrollController.new,
    );
    final objects = conversationOlder.putIfAbsent(contact!, () {
      final page = node.store.conversation(node.person, contact!);
      if (page.length < 50) conversationEnd.add(contact!);
      return page;
    });
    final helpers = messageHelpers(contact!);
    final unreadLoaded = objects
        .where(
          (o) =>
              o.author != node.person &&
              node.store.setting('read/${o.id}') != true,
        )
        .toList();
    return Column(
      children: [
        Material(
          color: scheme.surfaceContainer,
          borderRadius: back == null
              ? const BorderRadius.vertical(top: Radius.circular(12))
              : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
            child: Row(
              children: [
                if (back != null)
                  IconButton(
                    tooltip: 'Back to list',
                    onPressed: back,
                    icon: const Icon(Icons.arrow_back),
                  )
                else
                  const SizedBox(width: 8),
                conversationAvatar(contact!),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        name(contact!),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      ConversationDelivery(
                        key: ValueKey('delivery/$contact'),
                        network: network,
                        person: contact!,
                        helpers: helpers,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Video call',
                  onPressed: () => startCall(true),
                  icon: const Icon(Icons.videocam_outlined),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Voice call',
                  onPressed: () => startCall(false),
                  icon: const Icon(Icons.call_outlined),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Conversation options',
                  onSelected: (action) {
                    switch (action) {
                      case 'read':
                        act(() async {
                          for (final object in unreadLoaded) {
                            await node.markRead(object.id);
                          }
                          refresh();
                        });
                      case 'helper':
                        chooseMessageHelper(context);
                      case 'places':
                        update(() => tab = Destination.locations);
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'read',
                      enabled: !busy && unreadLoaded.isNotEmpty,
                      child: const ListTile(
                        leading: Icon(Icons.done_all),
                        title: Text('Mark loaded messages read'),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'helper',
                      child: ListTile(
                        leading: Icon(
                          helpers.isEmpty
                              ? Icons.cloud_outlined
                              : Icons.cloud_done_outlined,
                        ),
                        title: Text(
                          helpers.isEmpty
                              ? 'Optional text forwarding'
                              : 'Text forwarding · ${name(helpers.first)}',
                        ),
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'places',
                      child: ListTile(
                        leading: Icon(Icons.place_outlined),
                        title: Text('Shared places'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: ColoredBox(
            color: Color.alphaBlend(
              scheme.primary.withValues(alpha: 0.05),
              scheme.surfaceContainerLow,
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: ChatWallpaper(
                        scheme.onSurface.withValues(alpha: 0.05),
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: conversationList(context, objects, controller: scroll),
                ),
                if (objects.isNotEmpty && !conversationEnd.contains(contact))
                  Align(
                    alignment: Alignment.topCenter,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: ActionChip(
                        avatar: const Icon(Icons.history, size: 18),
                        label: const Text('Load older messages'),
                        onPressed: () => update(() {
                          final page = node.store.conversation(
                            node.person,
                            contact!,
                            before: objects.last,
                          );
                          conversationOlder[contact!] = [...objects, ...page];
                          if (page.length < 50) conversationEnd.add(contact!);
                        }),
                      ),
                    ),
                  ),
                if (conversationPending.contains(contact))
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: FilledButton.tonalIcon(
                        icon: const Icon(Icons.keyboard_double_arrow_down),
                        label: const Text('Show latest messages'),
                        onPressed: () {
                          update(() {
                            final page = node.store.conversation(
                              node.person,
                              contact!,
                            );
                            conversationOlder[contact!] = page;
                            conversationPending.remove(contact);
                            if (page.length < 50) {
                              conversationEnd.add(contact!);
                            } else {
                              conversationEnd.remove(contact);
                            }
                          });
                          if (scroll.hasClients) scroll.jumpTo(0);
                        },
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (messageErrors[contact] case final error?)
          Material(
            color: scheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      error,
                      style: TextStyle(color: scheme.onErrorContainer),
                    ),
                  ),
                  TextButton(
                    onPressed: sendConversationMessage,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
        ColoredBox(
          color: scheme.surfaceContainer,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
            child: compose(
              context,
              sendConversationMessage,
              sending: sendingMessages.contains(contact),
              attach: () => pickFile([contact!]),
            ),
          ),
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
    bool sending = false,
  }) {
    final chat = tab == Destination.messages;
    final desktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    const sendHint = 'Enter sends · Shift+Enter adds a line';
    final sendDisabled = chat ? sending : busy;
    final key = tab == Destination.messages
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
      padding: EdgeInsets.only(top: chat ? 6 : 12),
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
                    if (event is KeyDownEvent && !sendDisabled) send();
                    return KeyEventResult.handled;
                  },
                  child: TextField(
                    controller: composer,
                    minLines: 1,
                    maxLines: 5,
                    decoration: chat
                        ? InputDecoration(
                            hintText: 'Message',
                            filled: true,
                            fillColor: Theme.of(context).colorScheme.surface,
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(24),
                              borderSide: BorderSide.none,
                            ),
                          )
                        : InputDecoration(
                            helperText: desktop ? sendHint : null,
                            hintText: 'Start a discussion in this forum…',
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              chat
                  ? IconButton.filled(
                      tooltip: desktop ? 'Send · $sendHint' : 'Send',
                      style: IconButton.styleFrom(
                        minimumSize: const Size.square(46),
                      ),
                      onPressed: sendDisabled ? null : send,
                      icon: const Icon(Icons.send),
                    )
                  : FilledButton(
                      onPressed: sendDisabled ? null : send,
                      child: const Icon(Icons.send),
                    ),
            ],
          ),
        ],
      ),
    );
  }
}
