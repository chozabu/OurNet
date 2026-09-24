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
    await notes.state.subscribe(id, true);
    openForum(id);
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
                    onTap: () => openForum(forum),
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
    contact = people.contains(contact)
        ? contact
        : chatOrder().active.firstOrNull ?? people.firstOrNull;
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
                : Builder(
                    builder: (context) {
                      final order = chatOrder();
                      return ListView(
                        children: [
                          for (final person in order.active)
                            chatTile(context, person),
                          if (order.archived.isNotEmpty)
                            ListTile(
                              leading: const Icon(Icons.archive_outlined),
                              title: Text(
                                showArchivedChats
                                    ? 'Hide archived'
                                    : 'Archived (${order.archived.length})',
                              ),
                              onTap: () => update(
                                () => showArchivedChats = !showArchivedChats,
                              ),
                            ),
                          if (showArchivedChats)
                            for (final person in order.archived)
                              chatTile(context, person),
                        ],
                      );
                    },
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
                act(() => notes.state.subscribe(space, false));
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

  /// Shows the message at once and saves it in the background, so typing
  /// can go on; see [deliverOutgoing]. In edit mode, saves the edit instead.
  Future<void> sendConversationMessage() async {
    final recipient = contact;
    if (recipient == null) return;
    final draftKey = composerContext;
    final submitted = composer.text;
    if (messageEdit[recipient] case final id?) {
      await finishEdit(recipient, id, submitted);
      return;
    }
    if (submitted.trim().isEmpty) return;
    final item = OutgoingMessage(
      submitted.trim(),
      messageReply.remove(recipient),
    );
    update(() {
      (outgoing[recipient] ??= []).add(item);
      if (unreadMarkerPeer == recipient) unreadMarker = null;
      if (conversations.hasPending(recipient)) {
        conversations.showLatest(recipient);
      }
    });
    typing.sent(recipient);
    final scroll = conversations.scrollFor(recipient);
    if (scroll.hasClients) scroll.jumpTo(0);
    deliverOutgoing(recipient, item);
    // A draft persistence failure must never offer to publish this message twice.
    try {
      await finishDraft(draftKey, submitted);
    } catch (error) {
      notice('Message saved; could not update draft: $error');
    }
  }

  /// Records a voice message and sends it with its transcript: the live one,
  /// or one made on this device before sending. Without transcription set
  /// up, the audio is sent alone.
  Future<void> sendVoiceMessage(BuildContext context) async {
    final recipient = contact;
    if (recipient == null || voiceProgress.containsKey(recipient)) return;
    final recording = await recordVoice(context, speech: speech, message: true);
    if (recording == null) return;
    update(() {
      voiceProgress[recipient] = 'Preparing voice message…';
      messageErrors.remove(recipient);
    });
    try {
      var transcript = recording.transcript?.trim();
      if (transcript == null || transcript.isEmpty) {
        transcript = null;
        if (await speech.canTranscribe()) {
          update(() => voiceProgress[recipient] = 'Transcribing…');
          try {
            transcript = await speech.transcribeFile(
              recording.path,
              onProgress: (p) =>
                  update(() => voiceProgress[recipient] = 'Transcribing… $p%'),
            );
          } catch (e) {
            // The recording matters more than its text; send it anyway.
            notice('Sending without a transcript: $e');
          }
        }
      }
      update(() => voiceProgress[recipient] = 'Sending voice message…');
      final extension = recording.mime == 'audio/wav' ? 'wav' : 'm4a';
      await files.publish(
        recording.path,
        name: 'Voice message.$extension',
        audience: [recipient],
        via: messageHelpers(node, recipient),
        extra: {
          'audio': {'mime': recording.mime, 'duration': recording.duration},
          if (transcript != null && transcript.isNotEmpty)
            'transcript': transcript,
        },
      );
    } catch (error) {
      update(
        () => messageErrors[recipient] = 'Could not send voice message: $error',
      );
    } finally {
      update(() => voiceProgress.remove(recipient));
      unawaited(
        File(
          recording.path,
        ).delete().then<void>((_) {}, onError: (Object _) {}),
      );
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
    final peer = contact!;
    final scheme = Theme.of(context).colorScheme;
    final scroll = conversations.scrollFor(peer);
    final objects = conversations.messages(peer);
    final helpers = messageHelpers(node, peer);
    final unreadCount = node.store.conversationUnread(node.person, peer: peer);
    // Where reading resumes, fixed while the chat stays open.
    if (unreadMarkerPeer != peer) {
      unreadMarkerPeer = peer;
      unreadMarker = unreadCount == 0
          ? null
          : node.store
                .unreadMessages(node.person, peer, limit: 200)
                .lastOrNull
                ?.id;
    }
    final muted = chatMuted(node, peer);
    final desktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    final header = selectedMessages.isNotEmpty
        ? messageSelectionBar(context)
        : searchingConversation
        ? ConversationSearch(
            key: ValueKey('search/$peer'),
            node: node,
            updates: messageUpdates,
            peer: peer,
            name: name,
            onClose: () => update(() => searchingConversation = false),
            onOpen: (o) {
              update(() => searchingConversation = false);
              unawaited(jumpToMessage(o.id));
            },
          )
        : Material(
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
                  conversationAvatar(peer),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          name(peer),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        if (typing.isTyping(peer))
                          Text(
                            'typing…',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: scheme.primary,
                                  fontStyle: FontStyle.italic,
                                ),
                          )
                        else
                          ConversationDelivery(
                            key: ValueKey('delivery/$peer'),
                            network: network,
                            person: peer,
                            helpers: helpers,
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Search this chat',
                    onPressed: () => update(() => searchingConversation = true),
                    icon: const Icon(Icons.search),
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
                          unawaited(markChatRead(peer));
                        case 'mute':
                          toggleMute(peer);
                        case 'helper':
                          chooseMessageHelper(context);
                        case 'places':
                          update(() => tab = Destination.locations);
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'read',
                        enabled: unreadCount > 0,
                        child: const ListTile(
                          leading: Icon(Icons.done_all),
                          title: Text('Mark all read'),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'mute',
                        child: ListTile(
                          leading: Icon(
                            muted
                                ? Icons.volume_up_outlined
                                : Icons.volume_off_outlined,
                          ),
                          title: Text(
                            muted
                                ? 'Unmute notifications'
                                : 'Mute notifications',
                          ),
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
          );
    Widget history = ColoredBox(
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
          if (objects.isNotEmpty && conversations.hasOlder(peer))
            Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: ActionChip(
                  avatar: const Icon(Icons.history, size: 18),
                  label: const Text('Load older messages'),
                  onPressed: () => update(() => conversations.loadOlder(peer)),
                ),
              ),
            ),
          Positioned(
            right: 12,
            bottom: 12,
            child: JumpToLatest(
              controller: scroll,
              pending: conversations.hasPending(peer),
              unread: unreadCount,
              onPressed: () {
                if (conversations.hasPending(peer)) {
                  update(() => conversations.showLatest(peer));
                }
                if (!scroll.hasClients) return;
                if (scroll.offset > 3000) {
                  scroll.jumpTo(0);
                } else {
                  unawaited(
                    scroll.animateTo(
                      0,
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOut,
                    ),
                  );
                }
              },
            ),
          ),
          if (chatDragging)
            Positioned.fill(
              child: ColoredBox(
                color: scheme.primary.withValues(alpha: 0.12),
                child: Center(
                  child: Text(
                    'Drop to send to ${name(peer)}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    if (desktop) {
      history = DropTarget(
        onDragEntered: (_) => update(() => chatDragging = true),
        onDragExited: (_) => update(() => chatDragging = false),
        onDragDone: (details) {
          update(() => chatDragging = false);
          unawaited(
            sendAttachments(peer, [
              for (final f in details.files) (path: f.path, name: f.name),
            ]),
          );
        },
        child: history,
      );
    }
    Widget progressBar(String text) => Material(
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(text)),
          ],
        ),
      ),
    );
    return Column(
      children: [
        header,
        Expanded(child: history),
        if (voiceProgress[peer] case final progress?) progressBar(progress),
        if (attachProgress[peer] case final progress?) progressBar(progress),
        if (messageErrors[peer] case final error?)
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
                    onPressed: () => update(() => messageErrors.remove(peer)),
                    child: const Text('Dismiss'),
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
              attach: attachProgress.containsKey(peer)
                  ? null
                  : () => unawaited(pickConversationFiles()),
              voice: voiceProgress.containsKey(peer)
                  ? null
                  : () => unawaited(sendVoiceMessage(context)),
            ),
          ),
        ),
      ],
    );
  }

  void startCall(bool video) => callAct(() async {
    if (!network.running) await network.start();
    await calls.callPerson(contact!, video: video);
  });
  Widget compose(
    BuildContext context,
    VoidCallback send, {
    VoidCallback? attach,
    VoidCallback? voice,
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
          if (chat) ?composerContextBar(context),
          if (!chat && replyTo != null)
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
                    if (chat && event is KeyDownEvent) {
                      if (event.logicalKey == LogicalKeyboardKey.escape &&
                          cancelComposerMode()) {
                        return KeyEventResult.handled;
                      }
                      if (event.logicalKey == LogicalKeyboardKey.arrowUp &&
                          composer.text.isEmpty &&
                          editLastMessage()) {
                        return KeyEventResult.handled;
                      }
                    }
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
                            hintText:
                                contact != null &&
                                    messageEdit.containsKey(contact)
                                ? 'Edit message'
                                : 'Message',
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
              if (chat) ...[
                const SizedBox(width: 2),
                IconButton(
                  tooltip: 'Record voice message',
                  onPressed: voice,
                  icon: const Icon(Icons.mic_none),
                ),
              ],
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
