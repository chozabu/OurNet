part of 'app.dart';

/// A message shown at once while it is saved and sent; [error] is set when
/// saving failed, until it is retried or discarded.
class OutgoingMessage {
  final String text;
  final String? reply;
  String? error;
  OutgoingMessage(this.text, this.reply);
}

const _quickReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏'];
const _moreReactions = [
  '👍', '👎', '❤️', '🧡', '💛', '💚', '💙', '💜', //
  '😂', '🤣', '😊', '😍', '🥰', '😘', '😎', '🤔', //
  '😮', '😢', '😭', '😡', '🙄', '😴', '🤯', '🥳', //
  '🙏', '👏', '🙌', '💪', '🤝', '👋', '✌️', '👌', //
  '🔥', '✨', '🎉', '💯', '✅', '❌', '⭐', '👀', //
];

/// Chat-style rendering for private conversations: bubbles, day separators
/// and compact delivery ticks. Objects are newest first; the list is reversed
/// so offset 0 is the latest message at the bottom.
extension _ConversationPages on _OurNetAppState {
  Widget conversationAvatar(String person, {double radius = 18}) {
    final label = name(person).trim();
    return CircleAvatar(
      radius: radius,
      child: Text(label.isEmpty ? '?' : label.substring(0, 1).toUpperCase()),
    );
  }

  /// Latest message per conversation, read once per build.
  Map<String, ({String id, int created})> recentChats() => memo(
    'recentChats',
    () => {
      for (final r in node.store.recentConversations(node.person))
        r.peer: (id: r.id, created: r.created),
    },
  );

  /// Friends in chat-list order: pinned, then most recent message, then
  /// name. Archived chats stay apart until a newer message arrives.
  ({List<String> active, List<String> archived}) chatOrder() =>
      memo('chatOrder', () {
        final recent = recentChats();
        int latest(String p) => recent[p]?.created ?? 0;
        bool pinned(String p) => node.store.setting('chatPinned/$p') == true;
        final sorted = people.toList()
          ..sort((a, b) {
            final pin = (pinned(b) ? 1 : 0) - (pinned(a) ? 1 : 0);
            if (pin != 0) return pin;
            final time = latest(b).compareTo(latest(a));
            return time != 0 ? time : name(a).compareTo(name(b));
          });
        bool archived(String p) {
          final at = node.store.setting('chatArchived/$p');
          return at is int && latest(p) <= at;
        }

        return (
          active: sorted.where((p) => !archived(p)).toList(),
          archived: sorted.where(archived).toList(),
        );
      });

  String chatTime(int created) {
    final t = DateTime.fromMillisecondsSinceEpoch(created).toLocal();
    final now = DateTime.now();
    final days = DateTime(
      now.year,
      now.month,
      now.day,
    ).difference(DateTime(t.year, t.month, t.day)).inDays;
    if (days <= 0) {
      return '${t.hour.toString().padLeft(2, '0')}:'
          '${t.minute.toString().padLeft(2, '0')}';
    }
    if (days == 1) return 'Yesterday';
    if (days < 7) {
      return const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][t.weekday -
          1];
    }
    return '${t.day}/${t.month}/${t.year % 100}';
  }

  Widget chatTile(BuildContext context, String person) {
    final theme = Theme.of(context);
    final latest = recentChats()[person];
    final muted = chatMuted(node, person);
    final pinned = node.store.setting('chatPinned/$person') == true;
    final count = node.store.conversationUnread(
      node.person,
      peer: person,
      blocked: node.blocked,
    );
    final markedUnread = node.store.setting('chatUnread/$person') == true;
    final object = latest == null ? null : node.store.get(latest.id);
    final Widget subtitle = typing.isTyping(person)
        ? Text(
            'typing…',
            style: TextStyle(
              color: theme.colorScheme.primary,
              fontStyle: FontStyle.italic,
            ),
          )
        : object == null
        ? const Text('Private conversation')
        : FutureBuilder<Json?>(
            future: node.content(object),
            builder: (context, snapshot) {
              final payload = snapshot.data;
              final current = payload == null
                  ? null
                  : messageUpdates.current(object, payload);
              final text = messageUpdates.hidden(object)
                  ? ''
                  : payload != null && current == null
                  ? 'Message deleted'
                  : MessageText.plain(contentPreview(current));
              return Text(
                text.isEmpty
                    ? ''
                    : object.author == node.person
                    ? 'You: $text'
                    : text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              );
            },
          );
    void menu(Offset at) => unawaited(chatMenu(context, person, at));
    return GestureDetector(
      onLongPressStart: (d) => menu(d.globalPosition),
      onSecondaryTapUp: (d) => menu(d.globalPosition),
      child: ListTile(
        leading: conversationAvatar(person, radius: 20),
        title: Row(
          children: [
            Flexible(
              child: Text(
                name(person),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (muted)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Icon(
                  Icons.volume_off,
                  size: 14,
                  color: theme.colorScheme.outline,
                ),
              ),
          ],
        ),
        subtitle: subtitle,
        selected: contact == person,
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (latest != null)
              Text(
                chatTime(latest.created),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: count > 0
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (pinned)
                  Icon(
                    Icons.push_pin,
                    size: 14,
                    color: theme.colorScheme.outline,
                  ),
                if (count > 0 || markedUnread)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Badge(
                      backgroundColor: muted
                          ? theme.colorScheme.outline
                          : theme.colorScheme.primary,
                      label: count > 0 ? Text('$count') : null,
                      smallSize: 10,
                    ),
                  ),
              ],
            ),
          ],
        ),
        onTap: () => openConversation(person),
      ),
    );
  }

  Future<void> chatMenu(BuildContext context, String person, Offset at) async {
    final pinned = node.store.setting('chatPinned/$person') == true;
    final muted = chatMuted(node, person);
    final archived = chatOrder().archived.contains(person);
    final unread =
        node.store.conversationUnread(node.person, peer: person) > 0 ||
        node.store.setting('chatUnread/$person') == true;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        at & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          value: 'pin',
          child: Text(pinned ? 'Unpin chat' : 'Pin chat'),
        ),
        PopupMenuItem(
          value: 'mute',
          child: Text(muted ? 'Unmute notifications' : 'Mute notifications'),
        ),
        PopupMenuItem(
          value: 'archive',
          child: Text(archived ? 'Unarchive chat' : 'Archive chat'),
        ),
        PopupMenuItem(
          value: 'unread',
          child: Text(unread ? 'Mark as read' : 'Mark as unread'),
        ),
      ],
    );
    switch (action) {
      case 'pin':
        update(
          () => node.store.set('chatPinned/$person', pinned ? null : true),
        );
      case 'mute':
        toggleMute(person);
      case 'archive':
        update(
          () => node.store.set(
            'chatArchived/$person',
            archived ? null : DateTime.now().millisecondsSinceEpoch,
          ),
        );
        if (!archived) notice('Chat archived; a new message brings it back');
      case 'unread':
        if (unread) {
          node.store.set('chatUnread/$person', null);
          await markChatRead(person);
          redraw();
        } else {
          update(() {
            node.store.set('chatUnread/$person', true);
            if (contact == person) showConversation = false;
          });
        }
    }
  }

  void toggleMute(String person) {
    final muted = chatMuted(node, person);
    update(() => node.store.set('chatMuted/$person', muted ? null : true));
    if (!muted && widget.enablePlatform) {
      unawaited(
        notifications.dismiss('chat:$person').catchError((Object _) {}),
      );
    }
  }

  Future<void> markChatRead(String person) async {
    try {
      await node.markConversationRead(person);
    } catch (e) {
      notice('Could not mark read: $e');
    }
  }

  Widget conversationList(
    BuildContext context,
    List<SignedObject> objects, {
    required ScrollController controller,
  }) {
    objects = objects.where(contentVisible).toList();
    final peer = contact!;
    final footer = <Widget>[
      for (final item in outgoing[peer] ?? const <OutgoingMessage>[])
        outgoingBubble(context, peer, item),
      if (typing.isTyping(peer)) typingBubble(context),
    ];
    if (objects.isEmpty && footer.isEmpty) {
      return empty(
        'No messages yet',
        'Say hello — messages are end-to-end encrypted.',
        Icons.lock_outline,
      );
    }
    return ConversationHistory(
      peer: peer,
      objects: objects,
      controller: controller,
      footer: footer,
      unreadMarker: unreadMarkerPeer == peer ? unreadMarker : null,
      keyFor: conversations.keyFor,
      bubble: (context, object, groupStart) =>
          messageBubble(context, object, groupStart: groupStart),
    );
  }

  Widget typingBubble(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          'typing…',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
            fontStyle: FontStyle.italic,
          ),
        ),
      ),
    );
  }

  /// A message being saved and sent: shown at once with a clock, or with
  /// its error and what can be done about it.
  Widget outgoingBubble(
    BuildContext context,
    String peer,
    OutgoingMessage item,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final failed = item.error != null;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Align(
        alignment: Alignment.centerRight,
        child: GestureDetector(
          onTapUp: failed
              ? (d) =>
                    unawaited(failedMenu(context, peer, item, d.globalPosition))
              : null,
          child: Tooltip(
            message: failed ? 'Not sent: ${item.error}' : 'Sending…',
            child: Container(
              constraints: const BoxConstraints(minWidth: 72, maxWidth: 560),
              padding: const EdgeInsets.fromLTRB(10, 6, 8, 5),
              decoration: BoxDecoration(
                color: failed
                    ? scheme.errorContainer
                    : scheme.primaryContainer.withValues(alpha: 0.75),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.end,
                spacing: 8,
                children: [
                  MessageText(
                    item.text,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: failed
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'Not sent · tap',
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(color: scheme.error),
                              ),
                              const SizedBox(width: 3),
                              Icon(
                                Icons.error_outline,
                                size: 16,
                                color: scheme.error,
                              ),
                            ],
                          )
                        : Icon(
                            Icons.schedule,
                            size: 14,
                            color: scheme.onSurfaceVariant,
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> failedMenu(
    BuildContext context,
    String peer,
    OutgoingMessage item,
    Offset at,
  ) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        at & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem(value: 'retry', child: Text('Try again')),
        PopupMenuItem(value: 'edit', child: Text('Edit and resend')),
        PopupMenuItem(value: 'discard', child: Text('Discard')),
      ],
    );
    switch (action) {
      case 'retry':
        update(() => item.error = null);
        deliverOutgoing(peer, item);
      case 'edit':
        update(() {
          outgoing[peer]?.remove(item);
          if (item.reply != null) messageReply[peer] = item.reply!;
        });
        composer.value = TextEditingValue(
          text: item.text,
          selection: TextSelection.collapsed(offset: item.text.length),
        );
      case 'discard':
        update(() => outgoing[peer]?.remove(item));
    }
  }

  /// Queues saving [item] after this conversation's earlier messages, so
  /// messages typed quickly arrive in the order they were written.
  void deliverOutgoing(String recipient, OutgoingMessage item) {
    final previous = _sendChains[recipient] ?? Future<void>.value();
    final next = previous.then((_) async {
      try {
        final sent = await sendMessage(
          node,
          recipient,
          item.text,
          reply: item.reply,
        );
        update(() {
          outgoing[recipient]?.remove(item);
          conversations.sent(recipient, sent);
        });
      } catch (error) {
        update(() => item.error = '$error');
      }
    });
    _sendChains[recipient] = next;
    unawaited(
      next.whenComplete(() {
        if (identical(_sendChains[recipient], next)) {
          _sendChains.remove(recipient);
        }
      }),
    );
  }

  /// Marks messages read as they are shown, a few at a time. Only while the
  /// app is in front: a chat left open behind other windows is not read.
  void queueRead(SignedObject o) {
    if (widget.enablePlatform && !foreground) return;
    if (!_pendingReads.add(o.id)) return;
    _readTimer ??= Timer(const Duration(milliseconds: 300), () {
      _readTimer = null;
      final ids = _pendingReads.toList();
      _pendingReads.clear();
      unawaited(
        node
            .markManyRead(ids)
            .catchError((Object e) => notice('Could not mark read: $e')),
      );
    });
  }

  /// Compact tick for an outgoing message; the full wording is the tooltip.
  Widget deliveryTick(BuildContext context, SignedObject o, Json p) {
    final scheme = Theme.of(context).colorScheme;
    final detail = delivery(o, attachment: p['chunks'] is List);
    final read = node.store.setting('readBy/${o.id}') != null;
    final delivered =
        read || detail.startsWith('Delivered') || detail.startsWith('Shared');
    final forwarded =
        detail.startsWith('Stored') || detail.startsWith('Attachment details');
    return Tooltip(
      message: read ? 'Read · $detail' : detail,
      child: Icon(
        delivered || forwarded ? Icons.done_all : Icons.done,
        size: 16,
        color: read
            ? Colors.lightBlue
            : forwarded
            ? scheme.outline.withValues(alpha: 0.6)
            : scheme.onSurfaceVariant,
      ),
    );
  }

  /// A message this device holds but cannot decrypt: it was encrypted to the
  /// devices this person had when it was sent, and this one was added later
  /// without being handed its key (see [Node.shareKeys]).
  Widget unreadableBubble(
    BuildContext context,
    SignedObject o, {
    required bool mine,
  }) => noticeBubble(
    context,
    mine: mine,
    icon: Icons.lock_outline,
    text:
        'Sent before this device was added. To read it, choose Share history for this device in Network on one of your other devices.',
  );

  Widget noticeBubble(
    BuildContext context, {
    required bool mine,
    required IconData icon,
    required String text,
    String? time,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
      fontStyle: FontStyle.italic,
    );
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Flexible(child: Text(text, style: style)),
            if (time != null) ...[
              const SizedBox(width: 8),
              Text(time, style: Theme.of(context).textTheme.labelSmall),
            ],
          ],
        ),
      ),
    );
  }

  /// The quoted message a reply answers; tapping it goes there.
  Widget replyQuote(BuildContext context, String id, {required bool mine}) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final target = node.store.get(id);
    Widget frame(String author, String preview) => Material(
      color: scheme.onSurface.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: target == null ? null : () => unawaited(jumpToMessage(id)),
        child: Container(
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: scheme.primary, width: 3)),
          ),
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (author.isNotEmpty)
                Text(
                  author,
                  style: text.labelMedium?.copyWith(color: scheme.primary),
                ),
              Text(
                preview,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
    if (target == null || !contentVisible(target)) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: frame('', 'Original message unavailable'),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: FutureBuilder<Json?>(
        future: node.content(target),
        builder: (context, snapshot) {
          final payload = snapshot.data;
          final current = payload == null
              ? null
              : messageUpdates.current(target, payload);
          final preview = payload != null && current == null
              ? 'Message deleted'
              : MessageText.plain(contentPreview(current));
          return frame(
            target.author == node.person ? 'You' : name(target.author),
            preview.isEmpty ? '…' : preview,
          );
        },
      ),
    );
  }

  /// Reactions under a message, one chip per emoji; tapping one adds or
  /// withdraws this person's.
  Widget reactionRow(
    BuildContext context,
    SignedObject o,
    Map<String, String> reactions,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final counts = <String, int>{};
    for (final emoji in reactions.values) {
      counts[emoji] = (counts[emoji] ?? 0) + 1;
    }
    final mine = reactions[node.person];
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Wrap(
        spacing: 4,
        children: [
          for (final MapEntry(key: emoji, value: count) in counts.entries)
            Tooltip(
              message: reactions.entries
                  .where((e) => e.value == emoji)
                  .map((e) => e.key == node.person ? 'You' : name(e.key))
                  .join(', '),
              child: Material(
                color: emoji == mine
                    ? scheme.primaryContainer
                    : scheme.surfaceContainerHighest,
                shape: StadiumBorder(
                  side: BorderSide(color: scheme.surface, width: 1.5),
                ),
                child: InkWell(
                  customBorder: const StadiumBorder(),
                  onTap: () => react(o, emoji),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1,
                    ),
                    child: Text(
                      count > 1 ? '$emoji $count' : emoji,
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Sets this person's reaction to [emoji], or withdraws it if it is theirs.
  void react(SignedObject o, String emoji) {
    final current = messageUpdates.reactions(o)[node.person];
    unawaited(
      messageUpdates
          .react(o, current == emoji ? '' : emoji)
          .then<void>(
            (_) {},
            onError: (Object e) => notice('Could not react: $e'),
          ),
    );
  }

  Widget messageBubble(
    BuildContext context,
    SignedObject o, {
    required bool groupStart,
  }) {
    final mine = o.author == node.person;
    if (!mine && node.store.setting('read/${o.id}') != true) queueRead(o);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final time = DateTime.fromMillisecondsSinceEpoch(o.created).toLocal();
    final clock =
        '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}';
    final selecting = selectedMessages.isNotEmpty;
    final selected = selectedMessages.contains(o.id);
    void toggleSelected() => update(() {
      if (!selectedMessages.remove(o.id)) selectedMessages.add(o.id);
    });
    const round = Radius.circular(16);
    const tail = Radius.circular(4);
    return FutureBuilder<Json?>(
      future: node.content(o),
      builder: (context, snapshot) {
        final p = snapshot.data;
        if (p == null) {
          // Blocked or expired messages are simply not shown. One that is
          // still visible but unreadable was encrypted before this device
          // was added, so say so rather than leaving a silent gap.
          return node.visible(o) && !snapshot.hasError && snapshot.hasData
              ? unreadableBubble(context, o, mine: mine)
              : const SizedBox.shrink();
        }
        if (messageUpdates.deleted(o)) {
          return GestureDetector(
            onTap: selecting ? toggleSelected : null,
            onLongPress: toggleSelected,
            child: Container(
              color: selected ? scheme.primary.withValues(alpha: .12) : null,
              padding: EdgeInsets.only(top: groupStart ? 6 : 2),
              child: noticeBubble(
                context,
                mine: mine,
                icon: Icons.block,
                text: mine
                    ? 'You deleted this message'
                    : 'This message was deleted',
                time: clock,
              ),
            ),
          );
        }
        final edited = messageUpdates.editedText(o);
        final body = edited ?? (p['text'] ?? '').toString();
        final reactions = messageUpdates.reactions(o);
        final highlighted = highlightedMessage == o.id;
        final meta = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              edited != null ? 'edited · $clock' : clock,
              style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (mine) ...[
              const SizedBox(width: 3),
              deliveryTick(context, o, p),
            ],
          ],
        );
        final base = mine ? scheme.primaryContainer : scheme.surface;
        final bubble = AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          constraints: const BoxConstraints(minWidth: 72),
          decoration: BoxDecoration(
            color: highlighted
                ? Color.alphaBlend(scheme.primary.withValues(alpha: .25), base)
                : base,
            borderRadius: BorderRadius.only(
              topLeft: !mine && groupStart ? tail : round,
              topRight: mine && groupStart ? tail : round,
              bottomLeft: round,
              bottomRight: round,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 1,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(10, 6, 8, 5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (p['forwarded'] == true)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.shortcut,
                        size: 14,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Forwarded',
                        style: text.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                  ),
                ),
              if (p['reply'] case final String reply)
                replyQuote(context, reply, mine: mine),
              if (isImagePayload(p))
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
              if (p['audio'] case final Map<String, dynamic> audio
                  when p['chunks'] != null)
                voiceClip(context, o, p, audio)
              else if (p['chunks'] != null && !isImagePayload(p))
                attachmentChip(context, o, p),
              if (p['chunks'] != null && isImagePayload(p))
                TextButton.icon(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: fileProgress.containsKey(o.id)
                      ? null
                      : () => saveFile(context, o, p),
                  icon: const Icon(Icons.download, size: 16),
                  label: Text(
                    fileProgress.containsKey(o.id)
                        ? 'Preparing ${(fileProgress[o.id]! * 100).round()}%'
                        : 'Save original',
                  ),
                ),
              if (fileErrors[o.id] case final error?)
                Text(
                  '$error · Verified chunks are kept for retry.',
                  style: text.bodySmall?.copyWith(color: scheme.error),
                ),
              // Like WhatsApp: the time shares the last line when it fits,
              // otherwise it wraps below, right-aligned.
              Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.end,
                spacing: 8,
                children: [
                  if (body.isNotEmpty) MessageText(body, style: text.bodyLarge),
                  Padding(padding: const EdgeInsets.only(top: 4), child: meta),
                ],
              ),
            ],
          ),
        );
        return Container(
          color: selected ? scheme.primary.withValues(alpha: .12) : null,
          padding: EdgeInsets.only(top: groupStart ? 6 : 2),
          child: Row(
            mainAxisAlignment: mine
                ? MainAxisAlignment.end
                : MainAxisAlignment.start,
            children: [
              if (selecting)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(
                    selected
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    size: 20,
                    color: selected ? scheme.primary : scheme.outline,
                  ),
                ),
              Flexible(
                child: LayoutBuilder(
                  builder: (context, constraints) => Align(
                    alignment: mine
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: (constraints.maxWidth * 0.8).clamp(120, 560),
                      ),
                      child: SwipeToReply(
                        enabled: !selecting,
                        onReply: () => startReply(o),
                        child: GestureDetector(
                          onTap: selecting ? toggleSelected : null,
                          onLongPressStart: (d) => selecting
                              ? toggleSelected()
                              : unawaited(
                                  messageMenu(
                                    context,
                                    o,
                                    p,
                                    body,
                                    d.globalPosition,
                                  ),
                                ),
                          onSecondaryTapUp: (d) => unawaited(
                            messageMenu(context, o, p, body, d.globalPosition),
                          ),
                          child: Column(
                            crossAxisAlignment: mine
                                ? CrossAxisAlignment.end
                                : CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              bubble,
                              if (reactions.isNotEmpty)
                                reactionRow(context, o, reactions),
                            ],
                          ),
                        ),
                      ),
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

  /// A voice message: the notes player with its transcript beneath.
  Widget voiceClip(BuildContext context, SignedObject o, Json p, Json audio) {
    final transcript = (p['transcript'] as String? ?? '').trim();
    final style = Theme.of(context).textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 4),
      child: SizedBox(
        width: 320,
        child: AudioClip(
          key: ValueKey('voice/${o.id}'),
          files: files,
          object: o,
          payload: p,
          meta: audio,
          editable: false,
          transcript: Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: transcript.isEmpty
                ? Text(
                    'No transcript',
                    style: style?.copyWith(fontStyle: FontStyle.italic),
                  )
                : SelectableText(transcript, style: style),
          ),
        ),
      ),
    );
  }

  Widget attachmentChip(BuildContext context, SignedObject o, Json p) {
    final scheme = Theme.of(context).colorScheme;
    final progress = fileProgress[o.id];
    final size = (p['size'] as num?)?.toInt() ?? 0;
    final readable = size >= 1 << 20
        ? '${(size / (1 << 20)).toStringAsFixed(1)} MB'
        : size >= 1 << 10
        ? '${(size / (1 << 10)).toStringAsFixed(0)} KB'
        : '$size bytes';
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 6),
      child: Material(
        color: scheme.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: progress != null ? null : () => saveFile(context, o, p),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.insert_drive_file_outlined),
                const SizedBox(width: 8),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${p['name']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        progress != null
                            ? 'Preparing ${(progress * 100).round()}%'
                            : fileErrors.containsKey(o.id)
                            ? 'Tap to retry download'
                            : readable,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                progress != null
                    ? SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          value: progress,
                        ),
                      )
                    : const Icon(Icons.download, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> messageMenu(
    BuildContext context,
    SignedObject o,
    Json p,
    String body,
    Offset at,
  ) async {
    final mine = o.author == node.person;
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
        if (body.isNotEmpty)
          const PopupMenuItem(value: 'copy', child: Text('Copy text')),
        const PopupMenuItem(value: 'forward', child: Text('Forward')),
        if (mine && p['chunks'] == null)
          const PopupMenuItem(value: 'edit', child: Text('Edit')),
        const PopupMenuItem(value: 'select', child: Text('Select')),
        const PopupMenuItem(value: 'info', child: Text('Message info')),
        const PopupMenuItem(value: 'delete', child: Text('Delete…')),
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
      react(o, emoji);
      return;
    }
    switch (action) {
      case 'reply':
        startReply(o);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: body));
        notice('Copied');
      case 'forward':
        await forwardMessages(context, [o]);
      case 'edit':
        startEdit(o, body);
      case 'select':
        update(() => selectedMessages.add(o.id));
      case 'info':
        await provenance(context, o);
      case 'delete':
        await deleteMessages(context, [o]);
    }
  }

  Future<String?> pickReaction(BuildContext context) => showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('React'),
      content: SizedBox(
        width: 320,
        child: Wrap(
          children: [
            for (final emoji in _moreReactions)
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => Navigator.pop(context, emoji),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Text(emoji, style: const TextStyle(fontSize: 26)),
                ),
              ),
          ],
        ),
      ),
    ),
  );

  void startReply(SignedObject o) {
    final peer = contact;
    if (peer == null) return;
    update(() {
      messageReply[peer] = o.id;
      cancelEdit(peer);
    });
  }

  void startEdit(SignedObject o, String body) {
    final peer = contact;
    if (peer == null) return;
    update(() {
      messageReply.remove(peer);
      if (!messageEdit.containsKey(peer)) {
        _draftBeforeEdit[peer] = composer.value;
      }
      messageEdit[peer] = o.id;
    });
    composer.value = TextEditingValue(
      text: body,
      selection: TextSelection.collapsed(offset: body.length),
    );
  }

  /// Leaves edit mode, bringing back the draft set aside for it.
  void cancelEdit(String peer) {
    if (messageEdit.remove(peer) == null) return;
    composer.value = _draftBeforeEdit.remove(peer) ?? TextEditingValue.empty;
  }

  /// Esc: leaves selection, edit or reply, in that order. False if none.
  bool cancelComposerMode() {
    final peer = contact;
    if (peer == null) return false;
    if (selectedMessages.isNotEmpty) {
      update(selectedMessages.clear);
    } else if (messageEdit.containsKey(peer)) {
      update(() => cancelEdit(peer));
    } else if (messageReply.containsKey(peer)) {
      update(() => messageReply.remove(peer));
    } else if (searchingConversation) {
      update(() => searchingConversation = false);
    } else {
      return false;
    }
    return true;
  }

  /// Up arrow in an empty composer edits this person's latest text message.
  bool editLastMessage() {
    final peer = contact;
    if (peer == null) return false;
    for (final o in conversations.messages(peer).take(50)) {
      if (o.author != node.person) continue;
      if (messageUpdates.deleted(o) || !contentVisible(o)) continue;
      unawaited(
        node.content(o).then((p) {
          if (p == null || p['chunks'] != null || contact != peer) return;
          startEdit(o, messageUpdates.editedText(o) ?? '${p['text'] ?? ''}');
        }),
      );
      return true;
    }
    return false;
  }

  Future<void> finishEdit(String peer, String id, String text) async {
    final o = node.store.get(id);
    final trimmed = text.trim();
    if (o == null) {
      update(() => cancelEdit(peer));
      return;
    }
    final payload = await node.content(o);
    final before = messageUpdates.editedText(o) ?? '${payload?['text'] ?? ''}';
    update(() => cancelEdit(peer));
    if (trimmed.isEmpty || trimmed == before.trim()) return;
    try {
      await messageUpdates.edit(o, trimmed);
    } catch (e) {
      notice('Could not edit: $e');
    }
  }

  /// Scrolls to [id] in the open conversation, loading older pages as
  /// needed, and highlights it briefly.
  Future<void> jumpToMessage(String id) async {
    final peer = contact;
    if (peer == null) return;
    if (!conversations.loadUntil(peer, id)) {
      notice('The original message is not available');
      return;
    }
    update(() => highlightedMessage = id);
    final scroll = conversations.scrollFor(peer);
    for (var i = 0; i < 100 && mounted; i++) {
      await WidgetsBinding.instance.endOfFrame;
      final target = conversations.keyFor(id).currentContext;
      if (target != null && target.mounted) {
        await Scrollable.ensureVisible(
          target,
          alignment: 0.5,
          duration: const Duration(milliseconds: 250),
        );
        break;
      }
      if (!scroll.hasClients) break;
      final position = scroll.position;
      if (position.pixels >= position.maxScrollExtent) break;
      scroll.jumpTo(
        (position.pixels + position.viewportDimension * 0.8).clamp(
          0,
          position.maxScrollExtent,
        ),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    if (highlightedMessage == id) update(() => highlightedMessage = null);
  }

  /// Delete for me hides messages here; delete for everyone is offered when
  /// all of them are this person's own.
  Future<void> deleteMessages(
    BuildContext context,
    List<SignedObject> messages,
  ) async {
    final everyone = messages.every(
      (o) => o.author == node.person && !messageUpdates.deleted(o),
    );
    final count = messages.length;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(count == 1 ? 'Delete message?' : 'Delete $count messages?'),
        content: Text(
          everyone
              ? 'Delete for everyone removes it for both of you. Friends on '
                    'an older OurNet version will still see it until they '
                    'update.'
              : 'This removes it from this device only.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'me'),
            child: const Text('Delete for me'),
          ),
          if (everyone)
            FilledButton(
              onPressed: () => Navigator.pop(context, 'everyone'),
              child: const Text('Delete for everyone'),
            ),
        ],
      ),
    );
    if (choice == null) return;
    update(selectedMessages.clear);
    try {
      for (final o in messages) {
        if (choice == 'everyone') {
          await messageUpdates.deleteForEveryone(o);
        } else {
          await messageUpdates.hide(o);
        }
      }
    } catch (e) {
      notice('Could not delete: $e');
    }
  }

  /// Sends copies of [messages] to chosen friends, oldest first. Attachments
  /// go only when this device holds all of their chunks to pass on.
  Future<void> forwardMessages(
    BuildContext context,
    List<SignedObject> messages,
  ) async {
    final chosen = <String>{};
    final recipients = await showDialog<Set<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, change) => AlertDialog(
          title: const Text('Forward to'),
          content: SizedBox(
            width: 360,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final person in chatOrder().active)
                  CheckboxListTile(
                    value: chosen.contains(person),
                    secondary: conversationAvatar(person),
                    title: Text(name(person)),
                    onChanged: (on) => change(() {
                      if (on == true) {
                        chosen.add(person);
                      } else {
                        chosen.remove(person);
                      }
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: chosen.isEmpty
                  ? null
                  : () => Navigator.pop(context, chosen),
              child: const Text('Forward'),
            ),
          ],
        ),
      ),
    );
    if (recipients == null || recipients.isEmpty) return;
    update(selectedMessages.clear);
    final ordered = messages.toList()
      ..sort((a, b) => a.created.compareTo(b.created));
    var sent = 0, skipped = 0;
    try {
      for (final o in ordered) {
        final payload = await node.content(o);
        final current = payload == null
            ? null
            : messageUpdates.current(o, payload);
        if (current == null) {
          skipped++;
          continue;
        }
        if (current['chunks'] case final List chunks
            when !node.store.hasBlobs(chunks.cast<String>())) {
          skipped++;
          continue;
        }
        for (final person in recipients) {
          await forwardMessage(node, person, current);
        }
        sent++;
      }
    } catch (e) {
      notice('Could not forward: $e');
      return;
    }
    final to = recipients.length == 1
        ? name(recipients.single)
        : '${recipients.length} friends';
    notice(
      skipped == 0
          ? 'Forwarded to $to'
          : 'Forwarded $sent to $to · $skipped not forwarded: '
                'download attachments first',
    );
  }

  /// The bar shown instead of the header while messages are selected.
  Widget messageSelectionBar(BuildContext context) {
    final peer = contact!;
    final loaded = {for (final o in conversations.messages(peer)) o.id: o};
    final chosen = [for (final id in selectedMessages) ?loaded[id]];
    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Cancel selection',
              onPressed: () => update(selectedMessages.clear),
              icon: const Icon(Icons.close),
            ),
            Expanded(
              child: Text(
                '${chosen.length} selected',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              tooltip: 'Copy text',
              onPressed: () async {
                final ordered = chosen.toList()
                  ..sort((a, b) => a.created.compareTo(b.created));
                final lines = <String>[];
                for (final o in ordered) {
                  final p = await node.content(o);
                  final current = p == null
                      ? null
                      : messageUpdates.current(o, p);
                  final text = contentPreview(current);
                  if (text.isNotEmpty) {
                    lines.add(
                      '[${chatTime(o.created)}] '
                      '${o.author == node.person ? 'You' : name(o.author)}: $text',
                    );
                  }
                }
                await Clipboard.setData(ClipboardData(text: lines.join('\n')));
                update(selectedMessages.clear);
                notice('Copied');
              },
              icon: const Icon(Icons.copy),
            ),
            IconButton(
              tooltip: 'Forward',
              onPressed: () => unawaited(forwardMessages(context, chosen)),
              icon: const Icon(Icons.shortcut),
            ),
            IconButton(
              tooltip: 'Delete',
              onPressed: () => unawaited(deleteMessages(context, chosen)),
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ),
    );
  }

  /// Above the composer: the message being replied to or edited.
  Widget? composerContextBar(BuildContext context) {
    final peer = contact;
    if (peer == null) return null;
    final editing = messageEdit[peer];
    final reply = messageReply[peer];
    if (editing == null && reply == null) return null;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 0, 0),
      child: Row(
        children: [
          Icon(
            editing != null ? Icons.edit_outlined : Icons.reply,
            size: 20,
            color: scheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: editing != null
                ? Text(
                    'Editing message',
                    style: TextStyle(color: scheme.primary),
                  )
                : replyQuote(context, reply!, mine: false),
          ),
          IconButton(
            tooltip: editing != null ? 'Cancel editing' : 'Cancel reply',
            onPressed: () => update(() {
              if (editing != null) {
                cancelEdit(peer);
              } else {
                messageReply.remove(peer);
              }
            }),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }

  /// Tells the friend in the open chat that this person is typing.
  void composerTyped() {
    final text = composer.text;
    if (text == _typedText) return;
    _typedText = text;
    final peer = contact;
    if (switchingDraft ||
        text.isEmpty ||
        peer == null ||
        tab != Destination.messages ||
        messageEdit.containsKey(peer)) {
      return;
    }
    typing.typed(peer);
  }

  /// Attaches files to the open chat, one after another, with progress in
  /// the chat rather than the app-wide busy state. The composer text goes
  /// with the first as its caption.
  Future<void> sendAttachments(
    String recipient,
    List<({String path, String name})> items,
  ) async {
    if (items.isEmpty || attachProgress.containsKey(recipient)) return;
    final draftKey = composerContext;
    final caption = composerContext == 'message/$recipient'
        ? composer.text
        : '';
    final failures = <String>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      update(
        () => attachProgress[recipient] = items.length == 1
            ? 'Adding ${item.name}…'
            : 'Adding ${i + 1} of ${items.length} · ${item.name}',
      );
      try {
        if (await File(item.path).length() > Files.maxSize) {
          throw StateError('Larger than 64 MiB');
        }
        await files.publish(
          item.path,
          name: item.name,
          audience: [recipient],
          text: i == 0 ? caption : '',
          via: messageHelpers(node, recipient),
        );
        if (i == 0 && caption.isNotEmpty) {
          await finishDraft(draftKey, caption);
        }
      } catch (e) {
        failures.add('${item.name}: $e');
      }
    }
    update(() => attachProgress.remove(recipient));
    if (failures.isNotEmpty) {
      notice('Not added · ${failures.join(' · ')}');
    }
  }

  Future<void> pickConversationFiles() async {
    final recipient = contact;
    if (recipient == null) return;
    final picked = await FilePicker.pickFiles();
    if (picked.isEmpty) return;
    final staged = <({String path, String name})>[];
    final temps = <File>[];
    try {
      for (final file in picked) {
        if (file.path case final path?) {
          staged.add((path: path, name: file.name));
          continue;
        }
        // Content without a file path (Android providers): copy it out.
        final temp = File(
          '${(await getTemporaryDirectory()).path}/${randomId()}.upload',
        );
        temps.add(temp);
        final output = temp.openWrite();
        try {
          var size = 0;
          await for (final bytes in file.readAsByteStream()) {
            size += bytes.length;
            if (size > Files.maxSize) {
              throw StateError('${file.name} is larger than 64 MiB');
            }
            output.add(bytes);
          }
        } finally {
          await output.close();
        }
        staged.add((path: temp.path, name: file.name));
      }
      await sendAttachments(recipient, staged);
    } catch (e) {
      notice('$e');
    } finally {
      for (final temp in temps) {
        if (await temp.exists()) await temp.delete();
      }
    }
  }
}

/// A row of quick reactions at the top of a message's menu.
class _QuickReactions extends PopupMenuEntry<String> {
  const _QuickReactions();

  @override
  double get height => 48;

  @override
  bool represents(String? value) => false;

  @override
  State<_QuickReactions> createState() => _QuickReactionsState();
}

class _QuickReactionsState extends State<_QuickReactions> {
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 6),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final emoji in _quickReactions)
          InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => Navigator.pop(context, 'react:$emoji'),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Text(emoji, style: const TextStyle(fontSize: 22)),
            ),
          ),
        IconButton(
          tooltip: 'More reactions',
          visualDensity: VisualDensity.compact,
          onPressed: () => Navigator.pop(context, 'react:more'),
          icon: const Icon(Icons.add_reaction_outlined),
        ),
      ],
    ),
  );
}

/// Faint staggered dot pattern behind a conversation.
class ChatWallpaper extends CustomPainter {
  final Color color;
  const ChatWallpaper(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const step = 22.0;
    var row = 0;
    for (var y = step / 2; y < size.height; y += step, row++) {
      for (var x = row.isEven ? step / 2 : step; x < size.width; x += step) {
        canvas.drawCircle(Offset(x, y), 1.4, paint);
      }
    }
  }

  @override
  bool shouldRepaint(ChatWallpaper old) => old.color != color;
}
