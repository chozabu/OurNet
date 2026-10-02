part of 'app.dart';

/// A private group's conversation, laid out like a direct message with the
/// sender's name on each run of messages.
///
/// What it shows is [RoomFeed]'s window: the newest messages first, with
/// earlier ones read as the reader scrolls back, so opening a group costs
/// what is on screen rather than the group's age.
extension _GroupChat on _OurNetAppState {
  /// Whether a feed item is a chat message (as opposed to a pin record, or a
  /// list item from before lists were replaced).
  bool _isChatMessage(EverydayItem i) =>
      i.data['type'] != 'pin' &&
      i.data['type'] != 'check' &&
      i.data['deleted'] != true;

  List<EverydayItem> groupMessages(RoomFeed feed) =>
      memo('groupMessages', () => feed.items.where(_isChatMessage).toList());

  Set<dynamic> groupPins(RoomFeed feed) => memo(
    'groupPins',
    () => {
      for (final i in feed.items)
        if (i.data['type'] == 'pin' && i.data['pinned'] == true)
          i.data['target'],
    },
  );

  Set<String> _groupPeople(RoomFeed feed) =>
      (feed.room.data['members'] as List).cast<String>().toSet();

  /// Takes in what arrived since the last look. Cheap when nothing did.
  Future<void> refreshGroupChat() async {
    final feed = roomFeed;
    if (feed == null) return;
    if (activeRoom == null) {
      roomFeed = null;
      return;
    }
    try {
      await feed.refresh();
    } catch (_) {
      // No longer a member, or the group was closed: the list shows that.
      roomFeed = null;
    }
  }

  /// Opens a private group's conversation at its newest message, as a
  /// notification does.
  Future<void> openGroup(String space) async {
    final room = (await Everyday(
      node,
    ).rooms()).where((r) => r.object.space == space && r.data['note'] != true);
    if (!mounted || room.isEmpty) return;
    update(() {
      tab = Destination.groups;
      activeRoom = room.first;
      everydaySection = 'Conversation';
    });
    markRoomSeen(space);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (groupChatScroll.hasClients) groupChatScroll.jumpTo(0);
    });
  }

  /// Marks everything in a group read and clears its notification. What
  /// opening the group, or reading its newest messages, does.
  void markRoomSeen(String space) {
    unawaited(
      node.markRoomRead(space).catchError((Object e) {
        notice('Could not mark read: $e');
      }),
    );
    redraw();
    if (widget.enablePlatform) {
      unawaited(
        notifications.dismiss('group:$space').catchError((Object _) {}),
      );
    }
  }

  /// Stops or resumes notifications for a group.
  void toggleGroupMute(String space) {
    final muted = chatMuted(node, space);
    update(() => node.store.set('chatMuted/$space', muted ? null : true));
    if (!muted && widget.enablePlatform) {
      unawaited(
        notifications.dismiss('group:$space').catchError((Object _) {}),
      );
    }
  }

  /// Whether a newest message the reader can see is unread: the app is in
  /// front and the list is at its newest end.
  bool _readingNewestGroupMessages(RoomFeed feed) {
    if (widget.enablePlatform && !foreground) return false;
    final c = groupChatScroll;
    if (c.hasClients && c.positions.length == 1 && c.offset > 16) return false;
    return feed.items
        .take(20)
        .any(
          (i) =>
              i.object.author != node.person &&
              node.store.setting('seen/${i.object.id}') != true,
        );
  }

  void groupChatScrolled() {
    final c = groupChatScroll;
    if (!c.hasClients || c.positions.length != 1) return;
    if (c.position.maxScrollExtent - c.offset < 600) {
      unawaited(loadOlderGroupChat());
    }
  }

  Future<void> loadOlderGroupChat() async {
    final feed = roomFeed;
    if (feed == null ||
        !feed.hasOlder ||
        roomFeedLoadingOlder ||
        !roomFeedReady) {
      return;
    }
    update(() => roomFeedLoadingOlder = true);
    try {
      await feed.loadOlder();
    } catch (e) {
      notice('Could not load earlier messages: $e');
      if (mounted) update(() => roomFeedLoadingOlder = false);
      return;
    }
    if (!mounted) return;
    update(() => roomFeedLoadingOlder = false);
    // A short list never scrolls, so keep reading until it does.
    WidgetsBinding.instance.addPostFrameCallback((_) => groupChatScrolled());
  }

  Widget groupChatView(BuildContext context, EverydayItem room) {
    var feed = roomFeed;
    if (feed == null || feed.space != room.object.space) {
      final started = feed = roomFeed = RoomFeed(node, room);
      roomFeedReady = false;
      roomFeedLoadingOlder = false;
      roomFeedError = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (groupChatScroll.hasClients) groupChatScroll.jumpTo(0);
      });
      unawaited(() async {
        try {
          await started.loadOlder();
        } catch (e) {
          if (roomFeed == started) roomFeedError = e;
        }
        if (mounted && roomFeed == started) {
          update(() => roomFeedReady = true);
        }
      }());
    }
    if (roomFeedError != null) {
      return Center(child: Text('Could not load messages: $roomFeedError'));
    }
    if (!roomFeedReady) {
      return const Center(child: CircularProgressIndicator());
    }
    final messages = groupMessages(feed);
    final pins = groupPins(feed);
    if (messages.isEmpty) {
      if (feed.hasOlder) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => unawaited(loadOlderGroupChat()),
        );
        return const Center(child: CircularProgressIndicator());
      }
      return empty(
        'Make yourselves at home',
        'Send a message or add the first file.',
        Icons.favorite_border,
      );
    }
    if (_readingNewestGroupMessages(feed)) {
      final space = feed.space;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && activeRoom?.object.space == space) markRoomSeen(space);
      });
    }
    final byId = {for (final i in messages) i.object.id: i};
    final history = ConversationHistory(
      peer: 'group/${room.object.id}',
      objects: [for (final i in messages) i.object],
      controller: groupChatScroll,
      keyFor: (id) => groupKeys.putIfAbsent(id, GlobalKey.new),
      earlier: feed.hasOlder
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: roomFeedLoadingOlder
                    ? const SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : TextButton(
                        onPressed: () => unawaited(loadOlderGroupChat()),
                        child: const Text('Load earlier messages'),
                      ),
              ),
            )
          : null,
      bubble: (context, object, groupStart) => groupBubble(
        context,
        byId[object.id]!,
        feed!,
        pins,
        groupStart: groupStart,
      ),
    );
    return ChatBackdrop(
      children: [
        Positioned.fill(child: history),
        Positioned(
          right: 12,
          bottom: 12,
          child: JumpToLatest(
            controller: groupChatScroll,
            pending: false,
            unread: 0,
            onPressed: () => unawaited(
              groupChatScroll.animateTo(
                0,
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOut,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// One group message as a chat bubble. The sender's name shows on other
  /// people's messages (history shared with a new member keeps its original
  /// author). Swipe or use the menu to reply, react, edit or remove.
  Widget groupBubble(
    BuildContext context,
    EverydayItem item,
    RoomFeed feed,
    Set<dynamic> pins, {
    required bool groupStart,
  }) {
    final p = item.data, o = item.object;
    final author = (p['originalAuthor'] ?? o.author) as String;
    final mine = author == node.person;
    final attachment = p['type'] == 'file';
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final clock = messageClock(Everyday.sentOf(item));
    final body = attachment ? '' : (p['text'] ?? '').toString();
    final reactions = messageUpdates.reactionsFor(
      Everyday.reactionTarget(item),
      _groupPeople(feed),
    );
    final highlighted = highlightedMessage == o.id;
    final bubble = AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      constraints: const BoxConstraints(minWidth: 72),
      padding: const EdgeInsets.fromLTRB(10, 6, 8, 5),
      decoration: bubbleDecoration(
        scheme,
        mine: mine,
        groupStart: groupStart,
        highlighted: highlighted,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!mine && groupStart) senderLabel(context, author),
          if (pins.contains(p['entry']))
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Icon(
                Icons.push_pin,
                size: 14,
                color: scheme.onSurfaceVariant,
              ),
            ),
          if (p['reply'] case final String reply)
            groupReplyQuote(context, feed, reply),
          if (attachment && isImagePayload(p))
            Padding(
              padding: const EdgeInsets.only(bottom: 4, top: 2),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: InlineImage(
                  key: ValueKey(o.id),
                  files: files,
                  object: o,
                  payload: p,
                  online: network.running,
                ),
              ),
            ),
          if (attachment)
            TextButton.icon(
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              onPressed: () => saveFile(context, o, p),
              icon: Icon(
                isImagePayload(p)
                    ? Icons.download
                    : Icons.insert_drive_file_outlined,
                size: 16,
              ),
              label: Text(
                isImagePayload(p) ? 'Save original' : (p['name'] ?? 'File'),
              ),
            ),
          Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.end,
            spacing: 8,
            children: [
              if (body.isNotEmpty) MessageText(body, style: text.bodyLarge),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  p['edited'] == true ? 'edited · $clock' : clock,
                  style: text.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    return Padding(
      padding: EdgeInsets.only(top: groupStart ? 6 : 2),
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: (MediaQuery.sizeOf(context).width * 0.8).clamp(120, 560),
          ),
          child: SwipeToReply(
            onReply: () => startGroupReply(item),
            child: GestureDetector(
              onLongPressStart: (d) =>
                  unawaited(groupMenu(context, item, pins, d.globalPosition)),
              onSecondaryTapUp: (d) =>
                  unawaited(groupMenu(context, item, pins, d.globalPosition)),
              child: Column(
                crossAxisAlignment: mine
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  bubble,
                  if (reactions.isNotEmpty)
                    reactionRow(
                      context,
                      o,
                      reactions,
                      onReact: (emoji) => reactGroup(item, emoji),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The message a reply answers, if it is within what has been loaded.
  Widget groupReplyQuote(BuildContext context, RoomFeed feed, String entry) {
    final target = feed.entry(entry);
    final removed = target != null && target.data['deleted'] == true;
    final who = target == null
        ? ''
        : name((target.data['originalAuthor'] ?? target.object.author));
    final preview = removed
        ? 'Message deleted'
        : target == null
        ? 'Earlier message'
        : target.data['type'] == 'file'
        ? '${target.data['name'] ?? 'File'}'
        : MessageText.plain('${target.data['text'] ?? ''}');
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: QuoteFrame(
        author: who,
        preview: preview.isEmpty ? '…' : preview,
        onTap: () => unawaited(jumpToGroupMessage(entry)),
      ),
    );
  }

  Future<void> groupMenu(
    BuildContext context,
    EverydayItem item,
    Set<dynamic> pins,
    Offset at,
  ) async {
    final p = item.data;
    final mine = ((p['originalAuthor'] ?? item.object.author)) == node.person;
    final attachment = p['type'] == 'file';
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        at & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        const _QuickReactions(),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'reply', child: Text('Reply')),
        if (!attachment)
          const PopupMenuItem(value: 'copy', child: Text('Copy text')),
        if (mine && !attachment)
          const PopupMenuItem(value: 'edit', child: Text('Edit')),
        if (attachment)
          const PopupMenuItem(value: 'save', child: Text('Save original')),
        PopupMenuItem(
          value: 'pin',
          child: Text(pins.contains(p['entry']) ? 'Unpin' : 'Pin'),
        ),
        if (mine) const PopupMenuItem(value: 'delete', child: Text('Remove')),
      ],
    );
    if (!context.mounted || action == null) return;
    if (action.startsWith('react:')) {
      var emoji = action.substring(6);
      if (emoji == 'more') {
        final chosen = await pickReaction(context);
        if (chosen == null) return;
        emoji = chosen;
      }
      reactGroup(item, emoji);
      return;
    }
    switch (action) {
      case 'reply':
        startGroupReply(item);
      case 'edit':
        startGroupEdit(item);
      default:
        everydayItemAction(context, item, action, pins);
    }
  }

  /// Sets this person's reaction to [emoji], or withdraws it if it is theirs.
  /// Filed under the entry, so editing or re-sharing it keeps the reactions.
  void reactGroup(EverydayItem item, String emoji) {
    final feed = roomFeed;
    if (feed == null) return;
    final people = _groupPeople(feed);
    final target = Everyday.reactionTarget(item);
    final current = messageUpdates.reactionsFor(target, people)[node.person];
    unawaited(
      messageUpdates
          .reactToTarget(
            target,
            people.where((p) => p != node.person).toList(),
            current == emoji ? '' : emoji,
          )
          .then<void>(
            (_) {},
            onError: (Object e) => notice('Could not react: $e'),
          ),
    );
  }

  void startGroupReply(EverydayItem item) {
    final room = activeRoom;
    if (room == null) return;
    update(() {
      cancelGroupEdit(room);
      groupReply[room.object.id] = item.data['entry'] as String;
    });
  }

  void startGroupEdit(EverydayItem item) {
    final room = activeRoom;
    if (room == null) return;
    final body = (item.data['text'] ?? '').toString();
    update(() {
      groupReply.remove(room.object.id);
      if (!groupEdit.containsKey(room.object.id)) {
        groupDraftBeforeEdit[room.object.id] = inboxComposer.value;
      }
      groupEdit[room.object.id] = item.data['entry'] as String;
    });
    inboxComposer.value = TextEditingValue(
      text: body,
      selection: TextSelection.collapsed(offset: body.length),
    );
  }

  /// Leaves edit mode, bringing back the draft set aside for it.
  void cancelGroupEdit(EverydayItem room) {
    if (groupEdit.remove(room.object.id) == null) return;
    inboxComposer.value =
        groupDraftBeforeEdit.remove(room.object.id) ?? TextEditingValue.empty;
  }

  /// Esc: leaves edit or reply. False if there was neither.
  bool cancelGroupMode(EverydayItem room) {
    final id = room.object.id;
    if (groupEdit.containsKey(id)) {
      update(() => cancelGroupEdit(room));
    } else if (groupReply.containsKey(id)) {
      update(() => groupReply.remove(id));
    } else {
      return false;
    }
    return true;
  }

  /// Up arrow in an empty composer edits this person's latest text message.  Newest first.
  bool editLastGroupMessage() {
    final feed = roomFeed;
    if (feed == null) return false;
    for (final item in groupMessages(feed)) {
      final author = (item.data['originalAuthor'] ?? item.object.author);
      if (author != node.person || item.data['type'] == 'file') continue;
      if (item.data['deleted'] == true) continue;
      startGroupEdit(item);
      return true;
    }
    return false;
  }

  /// Above the composer: what is being replied to, or that a message is
  /// being edited.
  Widget groupComposerBar(BuildContext context, EverydayItem room) {
    final feed = roomFeed;
    final editing = groupEdit[room.object.id];
    final reply = groupReply[room.object.id];
    if (feed == null || (editing == null && reply == null)) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: editing != null
              ? Text('Editing message', style: TextStyle(color: scheme.primary))
              : groupReplyQuote(context, feed, reply!),
        ),
        IconButton(
          tooltip: editing != null ? 'Cancel editing' : 'Cancel reply',
          onPressed: () => update(() {
            if (editing != null) {
              cancelGroupEdit(room);
            } else {
              groupReply.remove(room.object.id);
            }
          }),
          icon: const Icon(Icons.close),
        ),
      ],
    );
  }

  /// Sends the composer's text to the group: a new message, a reply, or the
  /// replacement for the one being edited.
  Future<void> sendGroupMessage(EverydayItem room, String draftKey) async {
    final feed = roomFeed;
    final submitted = inboxComposer.text;
    final text = submitted.trim();
    if (text.isEmpty) return;
    final id = room.object.id;
    final editing = groupEdit[id];
    if (editing != null) {
      final item = feed?.entry(editing);
      update(() => cancelGroupEdit(room));
      if (item == null || (item.data['text'] ?? '') == text) return;
      await Everyday(
        node,
      ).write({...item.data, 'text': text, 'edited': true}, room: room);
    } else {
      await Everyday(node).write({
        'type': 'note',
        'text': text,
        'sent': DateTime.now().millisecondsSinceEpoch,
        'reply': ?groupReply[id],
      }, room: room);
      update(() => groupReply.remove(id));
      await finishDraft(draftKey, submitted, notes: true);
    }
    await refreshGroupChat();
    if (mounted) update(() {});
    if (groupChatScroll.hasClients && groupChatScroll.offset > 0) {
      unawaited(
        groupChatScroll.animateTo(
          0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        ),
      );
    }
  }

  /// Scrolls to the message with entry ID [entry], reading back as far as it
  /// takes to find it.
  Future<void> jumpToGroupMessage(String entry) async {
    final feed = roomFeed;
    if (feed == null) return;
    var target = feed.entry(entry);
    for (var i = 0; target == null && feed.hasOlder && i < 50; i++) {
      await feed.loadOlder();
      target = feed.entry(entry);
    }
    if (target == null || target.data['deleted'] == true || !mounted) {
      notice('The original message is not available');
      return;
    }
    final id = target.object.id;
    update(() => highlightedMessage = id);
    final key = groupKeys.putIfAbsent(id, GlobalKey.new);
    for (var i = 0; i < 100 && mounted; i++) {
      await WidgetsBinding.instance.endOfFrame;
      final context = key.currentContext;
      if (context != null && context.mounted) {
        await Scrollable.ensureVisible(
          context,
          alignment: 0.5,
          duration: const Duration(milliseconds: 250),
        );
        break;
      }
      if (!groupChatScroll.hasClients) break;
      final position = groupChatScroll.position;
      if (position.pixels >= position.maxScrollExtent) break;
      groupChatScroll.jumpTo(
        (position.pixels + position.viewportDimension * 0.8).clamp(
          0,
          position.maxScrollExtent,
        ),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    if (highlightedMessage == id && mounted) {
      update(() => highlightedMessage = null);
    }
  }
}
