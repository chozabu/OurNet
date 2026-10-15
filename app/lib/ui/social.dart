part of 'app.dart';

extension _SocialPages on _OurNetAppState {
  /// Starts or joins the public forum a name, address or link points at. A
  /// forum's name is its address, so one that exists is joined and one that
  /// does not is started. [typed] is words already entered, such as from
  /// Browse.
  Future<void> joinForum(BuildContext context, {String? typed}) async {
    final value =
        typed ??
        await ask(
          context,
          'Start or join a forum',
          hint: 'Forum name, or paste an address or link',
        );
    if (value == null || value.trim().isEmpty) return;
    final text = value.trim();
    final linked = Links.parse(text);
    final listed = listings.found().map((l) => l.space).toSet();
    // An address as it stands (a forum from before names, or one a friend
    // follows), else the name as it is turned into one.
    final id = linked != null && linked.type == 'forum'
        ? linked.space
        : node.subscriptions.contains(text) || listed.contains(text)
        ? text
        : PublicNames.forumFrom(text);
    if (id == null) {
      throw StateError(
        'Choose a forum name with letters or digits, other than files.',
      );
    }
    final known = node.subscriptions.contains(id) || listed.contains(id);
    var description = '';
    if (!known && PublicNames.forum2Owner(id) == null) {
      if (!context.mounted) return;
      final entered = await ask(
        context,
        'Start "$id"',
        hint: 'Optional: what is this forum for?',
        lines: 3,
      );
      if (entered == null) return;
      description = entered.trim();
    }
    await notes.state.subscribe(id, true);
    await listings.advertise(id, description: description);
    openForum(id);
    if (network.running) unawaited(network.syncAll());
    if (!known) {
      notice('Joined "$id". Friends will see it under Friends follow.');
    }
  }

  /// A subscribed space that is a public forum: not personal state, the
  /// public files or a public chat.
  /// Followed spaces that are forums: not a public chat, the shared files,
  /// a plugin's space (such as a friend's microblog) or an internal one.
  bool isForumSpace(String s) =>
      !s.startsWith('_') &&
      s != 'files' &&
      !PublicChats.isChat(s) &&
      !PublicNames.isPluginSpace(s);

  Widget communities(BuildContext context) {
    final forums = node.subscriptions.where(isForumSpace).toList()..sort();
    return browsePane(
      context,
      selected: showForum,
      back: () => update(() => showForum = false),
      list: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            onPressed: busy ? null : () => act(() => joinForum(context)),
            icon: const Icon(Icons.add),
            label: const Text('Start or join a forum'),
          ),
          TextButton.icon(
            onPressed: busy
                ? null
                : () => act(() => browseSpaces(context, 'forum')),
            icon: const Icon(Icons.travel_explore),
            label: const Text('Browse forums'),
          ),
          Text(
            scope == null
                ? 'Public forums and private group discussions'
                : 'Public discussions · visible to others',
          ),
          Expanded(
            child: ListView(
              children: [
                if (forums.isNotEmpty || scope == null)
                  ListTile(
                    leading: const Icon(Icons.dynamic_feed_outlined),
                    title: const Text('All forums'),
                    subtitle: const Text('Latest discussions from every forum'),
                    trailing: scope == null
                        ? countBadge(forumsUnread())
                        : unreadBadge(
                            unreadObjects(
                              'post',
                            ).where((o) => forums.contains(o.space)),
                          ),
                    selected: space == _OurNetAppState.allForums,
                    onTap: () => openForum(_OurNetAppState.allForums),
                  ),
                for (final forum in forums)
                  ListTile(
                    leading: const Icon(Icons.forum_outlined),
                    title: Text(forumName(forum)),
                    subtitle: recentActivity(
                      latestShownIn('post', forum, where: (o) => o.isPublic),
                      'No discussions yet',
                    ),
                    trailing: unreadBadge(
                      unreadObjects('post').where((o) => o.space == forum),
                    ),
                    selected: forum == space,
                    onTap: () => openForum(forum),
                  ),
                suggestedSpaces(context, 'forum'),
                // All lists the groups' private forums after the public ones.
                scopedRooms(
                  (context, rooms) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (rooms.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                          child: Text(
                            'In your groups · private',
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                        ),
                      for (final room in rooms)
                        ListTile(
                          leading: const Icon(Icons.lock_outline),
                          title: Text(room.data['name']),
                          subtitle: const Text('Group forum'),
                          trailing: countBadge(groupForumUnreadOf(room)),
                          selected: listRoom?.object.space == room.object.space,
                          onTap: () =>
                              openGroupInList(room, Destination.forums),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      detail: listRoom != null
          ? groupListDetail(context)
          : forums.contains(space) || space == _OurNetAppState.allForums
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
          // One main action, and the rest in a menu, so the list keeps
          // the room on a phone.
          Row(
            children: [
              Expanded(
                child: scope == ScopeKind.public
                    ? FilledButton.icon(
                        onPressed: busy
                            ? null
                            : () => act(() => startPublicChat(context)),
                        icon: const Icon(Icons.add_comment_outlined),
                        label: const Text('Start or join a public chat'),
                      )
                    : FilledButton.icon(
                        onPressed: () =>
                            addFriend(context, offerSharedNote: true),
                        icon: const Icon(Icons.person_add_alt),
                        label: const Text('Add friend'),
                      ),
              ),
              if (scope != ScopeKind.personal)
                PopupMenuButton<String>(
                  tooltip: 'More ways to chat',
                  enabled: !busy,
                  icon: const Icon(Icons.more_vert),
                  onSelected: (choice) => act(
                    () => switch (choice) {
                      'group' => createPrivateGroup(context),
                      'start' => startPublicChat(context),
                      _ => browseSpaces(context, 'chat'),
                    },
                  ),
                  itemBuilder: (_) => [
                    if (scope == null) ...[
                      const PopupMenuItem(
                        value: 'group',
                        child: ListTile(
                          leading: Icon(Icons.group_add_outlined),
                          title: Text('Create group'),
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'start',
                        child: ListTile(
                          leading: Icon(Icons.add_comment_outlined),
                          title: Text('Start or join a public chat'),
                        ),
                      ),
                    ],
                    const PopupMenuItem(
                      value: 'join',
                      child: ListTile(
                        leading: Icon(Icons.login),
                        title: Text('Browse public chats'),
                      ),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            // All lists group and public chats among conversations; Public
            // lists only public chats, Personal only direct messages.
            child: scopedRooms((context, rooms) {
              final chats = scope == ScopeKind.personal
                  ? const <String>[]
                  : publicChats.joined;
              final friends = scope != ScopeKind.public;
              if ((!friends || people.isEmpty) &&
                  rooms.isEmpty &&
                  chats.isEmpty) {
                return friends
                    ? empty(
                        'Start a conversation',
                        'Add a friend by QR code, on the same Wi-Fi, or with an invitation.',
                        Icons.chat_bubble_outline,
                      )
                    : ListView(
                        children: [
                          SizedBox(
                            height: 240,
                            child: empty(
                              'No public chats yet',
                              'Start one by its name, or join one friends follow.',
                              Icons.forum_outlined,
                            ),
                          ),
                          suggestedSpaces(context, 'chat'),
                        ],
                      );
              }
              final order = friends
                  ? chatOrder()
                  : (active: const <String>[], archived: const <String>[]);
              return ListView(
                children: [
                  for (final entry in chatEntries(order, rooms, chats: chats))
                    switch (entry) {
                      final String person => chatTile(context, person),
                      final EverydayItem room => groupChatTile(context, room),
                      (chat: final String chat) => publicChatTile(
                        context,
                        chat,
                      ),
                      _ => const SizedBox.shrink(),
                    },
                  if (order.archived.isNotEmpty)
                    ListTile(
                      leading: const Icon(Icons.archive_outlined),
                      title: Text(
                        showArchivedChats
                            ? 'Hide archived'
                            : 'Archived (${order.archived.length})',
                      ),
                      onTap: () =>
                          update(() => showArchivedChats = !showArchivedChats),
                    ),
                  if (showArchivedChats)
                    for (final person in order.archived)
                      chatTile(context, person),
                  if (scope == ScopeKind.public)
                    suggestedSpaces(context, 'chat'),
                ],
              );
            }),
          ),
        ],
      ),
      detail: chatDetail(context),
      detailBuilder: (back) => chatDetail(context, back: back),
    );
  }

  /// The open public chat, or else the direct conversation.
  Widget chatDetail(BuildContext context, {VoidCallback? back}) {
    if (listRoom != null) return groupListDetail(context, back: back);
    final chat = publicChat;
    if (chat != null && publicChats.joined.contains(chat)) {
      return publicChatView(context, chat, back: back);
    }
    if (scope == ScopeKind.public) {
      return empty(
        'Public chats',
        'Pick a chat, or start one: anyone with its address can join.',
        Icons.forum_outlined,
      );
    }
    return messageDetail(context, back: back);
  }

  Widget forumDetail(BuildContext context) {
    final all = space == _OurNetAppState.allForums;
    // Open is read, as for a chat: every post in the forum (or, for All
    // forums, in each joined one), including any its owner removed, or the
    // badge could never clear.
    final spaces = all
        ? node.subscriptions.where(isForumSpace).toSet()
        : {space};
    if (unreadObjects('post').any((o) => spaces.contains(o.space))) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || tab != Destination.forums) return;
        for (final forum in spaces) {
          node.store.markSpaceSeen('post', forum, node.person);
        }
        unreadCounts.clear();
        redraw();
      });
    }
    return _forumDetail(context, all);
  }

  Widget _forumDetail(BuildContext context, bool all) => Column(
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              all ? 'All forums' : forumName(space),
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          if (!all)
            PopupMenuButton<String>(
              tooltip: 'Forum options',
              onSelected: (action) {
                if (action == 'copy') {
                  Clipboard.setData(ClipboardData(text: Links.forum(space)));
                  notice('Forum link copied. Anyone you send it to can join.');
                }
                if (action == 'advert') {
                  act(
                    () => listings.setAdvertised(
                      space,
                      !listings.advertises(space),
                    ),
                  );
                }
                if (action == 'edit') act(() => forumSettings(context));
                if (action == 'leave') {
                  act(() => notes.state.subscribe(space, false));
                  update(() {
                    space =
                        node.subscriptions.where(isForumSpace).firstOrNull ??
                        'general';
                    showForum = false;
                  });
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'copy',
                  child: Text('Copy forum link'),
                ),
                CheckedPopupMenuItem(
                  value: 'advert',
                  checked: listings.advertises(space),
                  child: const Text('Show to friends in Browse'),
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
      if (!all && forumDescription(space) != null)
        Align(
          alignment: Alignment.centerLeft,
          child: Text(forumDescription(space)!),
        ),
      if (selectedThread == null && !all)
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
          if (selectedThread == null) forumSortMenu(),
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
              if (all && scope == null) {
                for (final group in allGroupForums.values) {
                  markGroupForumRead(group.space);
                }
              }
              unreadCounts.clear();
              refresh();
            },
            child: const Text('Mark read'),
          ),
        ],
      ),
      Expanded(
        child: all && scope == null
            ? allForumList(context)
            : objectList(
                context,
                discussionObjects(),
                inline:
                    selectedThread == null ||
                        (replyTo == null &&
                            submittedForumThreads.contains(
                              'community/$space/$selectedThread',
                            ))
                    ? null
                    : InlineReply(replyTo ?? selectedThread!, publicReplyBox),
              ),
      ),
    ],
  );

  Widget publicReplyBox(BuildContext context) {
    final root = replyTo == null || replyTo == selectedThread;
    return compose(
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
        update(() {
          replyTo = null;
          if (draftKey != null &&
              draftKey == composerContext &&
              composer.text.isEmpty) {
            submittedForumThreads.add(draftKey);
            composerFocus.unfocus();
          }
        });
      }),
      attach: () => pickFile(
        [],
        postSpace: space,
        postData: {
          'parent': replyTo ?? selectedThread,
          'text': composer.text.trim(),
        },
      ),
      inline: true,
      hint: root ? 'Add a comment…' : 'Write a reply…',
      cancelReply: root ? null : () => update(() => replyTo = null),
    );
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
    final all = space == _OurNetAppState.allForums;
    final joined = node.subscriptions.toSet();
    final posts = node.store
        .objects(kind: 'post', limit: 10000)
        .where(
          (o) =>
              (all
                  ? isForumSpace(o.space) && joined.contains(o.space)
                  : o.space == space) &&
              o.isPublic &&
              contentVisible(o),
        )
        .toList();
    final ids = posts.map((o) => o.id).toSet();
    if (selectedThread == null) {
      final roots = posts
          .where((o) => !ids.contains(o.data['payload']['parent']))
          .toList();
      return rankTopics(roots, (o) => o.created);
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
      // The best replies first, as on Reddit; equal scores oldest first.
      final replies = (children[id] ?? []).toList()
        ..sort((a, b) {
          final score = postVotes(b).score.compareTo(postVotes(a).score);
          return score != 0 ? score : a.created.compareTo(b.created);
        });
      pending.addAll(replies.reversed.map((r) => r.id));
    }

    return ordered;
  }

  int replyDepth(SignedObject object) {
    var depth = 0;
    final seen = <String>{object.id};
    var parent = object.data['payload']['parent'];
    while (parent is String && seen.add(parent) && depth < 64) {
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
                  Expanded(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => unawaited(showPersonDetails(context, peer)),
                      child: Row(
                        children: [
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
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
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
                                else if (reachText(peer) case final reach?)
                                  // Nothing sent here arrives until one of
                                  // their devices is back.
                                  Text(
                                    reach,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(color: scheme.error),
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
                        ],
                      ),
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
                          update(() => tab = Destination.maps);
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
                          title: Text('Open Maps'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
    Widget history = ChatBackdrop(
      children: [
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

    /// For a composer that is not the DM or public forum one: its draft key,
    /// the post being replied to, and how to stop replying.
    String? draftKey,
    String? replying,
    VoidCallback? cancelReply,

    /// The reply box that opens under a post in a discussion.
    bool inline = false,
    String? hint,
  }) {
    final chat = tab == Destination.messages;
    final desktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    const sendHint = 'Enter sends · Shift+Enter adds a line';
    final sendDisabled = chat ? sending : busy;
    void sendKeepingFocus() {
      send();
      composerFocus.requestFocus();
    }

    Future<void> pasteImage([Uint8List? given, String? mime]) async {
      final draftKey = composerContext;
      final submitted = composer.text;
      final recipient = contact!;
      final image = given ?? await clipboardImage();
      if (image == null) {
        throw StateError('Clipboard has no image');
      }
      if (image.length > 8 * 1024 * 1024) {
        throw StateError('Clipboard image limit is 8 MiB');
      }
      final extension = switch (mime) {
        'image/jpeg' => 'jpg',
        'image/gif' => 'gif',
        'image/webp' => 'webp',
        _ => 'png',
      };
      final temp = File(
        '${(await getTemporaryDirectory()).path}/${randomId()}.$extension',
      );
      try {
        await temp.writeAsBytes(image);
        await files.publish(temp.path, audience: [recipient], text: submitted);
        await finishDraft(draftKey, submitted);
      } finally {
        if (await temp.exists()) await temp.delete();
      }
    }

    final key =
        draftKey ??
        (tab == Destination.messages
            ? 'message/$contact'
            : 'community/$space/$selectedThread');
    if (composerContext != key) {
      if (composerContext != null) drafts[composerContext!] = composer.value;
      composerContext = key;
      switchingDraft = true;
      composer.value = drafts[key] ?? TextEditingValue.empty;
      switchingDraft = false;
    }
    if (chat) {
      final peer = contact!;
      return ChatComposer(
        controller: composer,
        focusNode: composerFocus,
        hint: messageEdit.containsKey(peer) ? 'Edit message' : 'Message',
        onSend: sendDisabled ? null : send,
        contextBar: composerContextBar(context),
        onAttach: attach == null || busy ? null : attach,
        onPasteButton: attach == null || busy ? null : () => act(pasteImage),
        onPasteShortcut: attach == null
            ? null
            : () {
                if (!busy) {
                  unawaited(pasteIntoComposer(composer, () => act(pasteImage)));
                }
              },
        onImageInserted: attach == null
            ? null
            : (bytes, mime) {
                if (!busy) unawaited(act(() => pasteImage(bytes, mime)));
              },
        hasVoice: true,
        onVoice: voice,
        onEvent: () => unawaited(insertEventLink(context, composer)),
        onEscape: cancelComposerMode,
        onEditLast: editLastMessage,
      );
    }
    if (inline) {
      return ListenableBuilder(
        listenable: Listenable.merge([composerFocus, composer]),
        builder: (context, _) {
          final expanded = composerFocus.hasFocus || composer.text.isNotEmpty;
          return Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Focus(
                  onKeyEvent: (_, event) {
                    if (event is KeyDownEvent &&
                        event.logicalKey == LogicalKeyboardKey.escape &&
                        cancelReply != null) {
                      cancelReply();
                      return KeyEventResult.handled;
                    }
                    return enterSends(composer, event, busy ? null : send);
                  },
                  child: TextField(
                    controller: composer,
                    focusNode: composerFocus,
                    minLines: expanded ? 2 : 1,
                    maxLines: expanded ? 8 : 1,
                    decoration: InputDecoration(
                      hintText: hint ?? 'Write a reply…',
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
                if (expanded) const SizedBox(height: 4),
                if (expanded)
                  Row(
                    children: [
                      if (attach != null)
                        IconButton(
                          tooltip: 'Attach file',
                          visualDensity: VisualDensity.compact,
                          onPressed: busy ? null : attach,
                          icon: const Icon(Icons.attach_file),
                        ),
                      IconButton(
                        tooltip: 'Mention a calendar event',
                        visualDensity: VisualDensity.compact,
                        onPressed: busy
                            ? null
                            : () =>
                                  unawaited(insertEventLink(context, composer)),
                        icon: const Icon(Icons.event_outlined),
                      ),
                      if (desktop)
                        Expanded(
                          child: Text(
                            sendHint,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        )
                      else
                        const Spacer(),
                      if (cancelReply != null)
                        TextButton(
                          onPressed: cancelReply,
                          child: const Text('Cancel'),
                        ),
                      const SizedBox(width: 4),
                      FilledButton(
                        onPressed: busy ? null : send,
                        child: const Text('Comment'),
                      ),
                    ],
                  ),
              ],
            ),
          );
        },
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        children: [
          if ((replying ?? replyTo) != null)
            Row(
              children: [
                Expanded(
                  child: Text('Replying to ${short((replying ?? replyTo)!)}'),
                ),
                IconButton(
                  tooltip: 'Cancel reply',
                  onPressed: cancelReply ?? () => update(() => replyTo = null),
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
              IconButton(
                tooltip: 'Mention a calendar event',
                onPressed: busy
                    ? null
                    : () => unawaited(insertEventLink(context, composer)),
                icon: const Icon(Icons.event_outlined),
              ),
              Expanded(
                child: Focus(
                  onKeyEvent: (_, event) =>
                      enterSends(composer, event, busy ? null : send),
                  child: TextField(
                    controller: composer,
                    focusNode: composerFocus,
                    minLines: 1,
                    maxLines: 5,
                    decoration: InputDecoration(
                      helperText: desktop ? sendHint : null,
                      hintText: 'Start a discussion in this forum…',
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              FilledButton(
                onPressed: busy ? null : sendKeepingFocus,
                child: const Icon(Icons.send),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
