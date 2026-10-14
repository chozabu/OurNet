part of 'app.dart';

/// Public chats in the Chat section: open conversations anyone can start and
/// anyone with the address can join. See [PublicChats] and docs/SCOPES.md.
extension _PublicChatPages on _OurNetAppState {
  /// The chat's name, once its record has arrived.
  String publicChatName(String space) => memo(
    'chatName/$space',
    () => publicChats.info(space)?.name ?? 'Public chat',
  );

  /// When the chat was named, to order a chat with no messages yet.
  int publicChatCreated(String space) =>
      node.store.latestIn(PublicChats.recordKind, space)?.created ?? 0;

  /// The name this person signs public messages with, if they have one.
  String? ownDisplayName() {
    final own = _plainName(node.person);
    return own == 'You' ? null : own;
  }

  /// Starts or joins the public chat a name, address or link points at. A
  /// chat's name is its address, so one that exists is joined and one that
  /// does not is started.
  Future<void> startPublicChat(BuildContext context, {String? typed}) async {
    final value =
        typed ??
        await ask(
          context,
          'Start or join a public chat',
          hint: 'Chat name, or paste an address or link',
        );
    if (value == null || value.trim().isEmpty) return;
    final text = value.trim();
    // Addresses and links, including chats from before names, are joined as
    // they are.
    if (PublicChats.parseLink(text) != null || PublicChats.isChat(text)) {
      final space = await publicChats.join(text);
      openPublicChat(space);
      if (network.running) unawaited(network.syncAll());
      unawaited(listings.refresh());
      return;
    }
    final space = PublicNames.chatSpace(text);
    if (space == null) {
      throw StateError('Choose a chat name with letters or digits.');
    }
    final known =
        publicChats.joined.contains(space) ||
        listings.found().any((l) => l.space == space);
    var description = '';
    if (!known) {
      if (!context.mounted) return;
      final entered = await ask(
        context,
        'Start "${PublicChats.slugOf(space)}"',
        hint: 'Optional: what is this chat for?',
        lines: 2,
      );
      if (entered == null) return;
      description = entered.trim();
    }
    await publicChats.startOrJoin(text);
    await listings.advertise(space, description: description);
    openPublicChat(space);
    if (network.running) unawaited(network.syncAll());
    if (!known) {
      notice('Joined the chat. Friends will see it under Friends follow.');
    }
  }

  Future<void> joinPublicChat(BuildContext context, {String? typed}) =>
      startPublicChat(context, typed: typed);

  /// A chat link was tapped: joins the chat if need be, then opens it.
  Future<void> followChatLink(String space) async {
    // Links can sit on pages above the app's own, such as a note.
    noteNavigator.currentState?.popUntil((route) => route.isFirst);
    if (!publicChats.joined.contains(space)) {
      try {
        await publicChats.join(space);
      } catch (e) {
        notice('Could not join: $e');
        return;
      }
      if (network.running) unawaited(network.syncAll());
    }
    openPublicChat(space);
  }

  /// Sends friends a link to [space] in a direct message each.
  Future<void> inviteToPublicChat(BuildContext context, String space) async {
    final chosen = <String>{};
    final friends = chatOrder().active;
    final send = await showDialog<bool>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, change) => AlertDialog(
          title: const Text('Invite friends'),
          content: SizedBox(
            width: 360,
            child: friends.isEmpty
                ? const Text('Add a friend first, then invite them here.')
                : ListView(
                    shrinkWrap: true,
                    children: [
                      for (final person in friends)
                        CheckboxListTile(
                          value: chosen.contains(person),
                          secondary: conversationAvatar(person),
                          title: Text(name(person)),
                          onChanged: (on) => change(
                            () => on == true
                                ? chosen.add(person)
                                : chosen.remove(person),
                          ),
                        ),
                    ],
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Send invitation'),
            ),
          ],
        ),
      ),
    );
    if (send != true || chosen.isEmpty) return;
    final text =
        'Join me in a public chat: '
        '${PublicChats.link(space, name: publicChatName(space))}';
    for (final person in chosen) {
      await sendMessage(node, person, text);
    }
    notice(
      chosen.length == 1
          ? 'Invitation sent to ${name(chosen.single)}'
          : 'Invitation sent to ${chosen.length} friends',
    );
  }

  void openPublicChat(String space) {
    update(() {
      tab = Destination.messages;
      reveal(ScopeKind.public);
      listRoom = null;
      publicChat = space;
      showConversation = true;
    });
    publicChats.markRead(space);
    dismissShownNotification();
  }

  /// The newest messages shown in [space], read once per change.
  List<ChatMessage> publicChatMessages(String space) {
    final limit = publicChatLimit[space] ?? 100;
    return publicMessages['$space/$limit'] ??= publicChats.latest(
      space,
      limit: limit,
    );
  }

  Widget publicChatTile(BuildContext context, String space) {
    final theme = Theme.of(context);
    final latest = latestIn(PublicChats.messageKind, space);
    final message = latest == null ? null : publicChats.message(latest);
    final count = memo('chatUnread/$space', () => publicChats.unread(space));
    return ListTile(
      leading: CircleAvatar(
        radius: 20,
        backgroundColor: theme.colorScheme.tertiaryContainer,
        child: const Icon(Icons.public),
      ),
      title: Text(
        publicChatName(space),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        message == null
            ? 'Public chat'
            : '${message.object.author == node.person ? 'You' : publicSender(message)}: '
                  '${MessageText.plain(message.text)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      selected: publicChat == space && listRoom == null,
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
          if (count > 0)
            Badge(
              backgroundColor: theme.colorScheme.primary,
              label: Text('$count'),
            ),
        ],
      ),
      onTap: () => openPublicChat(space),
    );
  }

  /// Who sent [m]: their name where this device knows one, else the name
  /// they gave (which nothing checks) beside their key.
  String publicSender(ChatMessage m) {
    final person = m.object.author;
    final known = _plainName(person);
    if (known != short(person)) return name(person);
    final given = m.name?.trim();
    return given == null || given.isEmpty
        ? short(person)
        : '$given · ${short(person)}';
  }

  Widget publicChatView(
    BuildContext context,
    String space, {
    VoidCallback? back,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final messages = publicChatMessages(space);
    final limit = publicChatLimit[space] ?? 100;
    final description = memo(
      'chatAbout/$space',
      () {
        final own = publicChats.info(space)?.description ?? '';
        // A chat called by name has no owner's record: friends' adverts say
        // what it is for.
        return own.isNotEmpty ? own : listings.descriptionOf(space);
      },
    );
    // Reading the chat marks it read on this device, after the frame.
    if (messages.isNotEmpty &&
        messages.first.object.created > publicChats.seenUpTo(space)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        publicChats.markRead(space);
        redraw();
      });
    }
    void send() {
      final text = publicComposer.text;
      if (text.trim().isEmpty) return;
      publicComposer.clear();
      unawaited(
        publicChats
            .send(space, text, name: ownDisplayName())
            .then((_) {
              publicMessages.clear();
              latestItems.clear();
              redraw();
            })
            .catchError((Object e) {
              publicComposer.text = text;
              notice('Could not send: $e');
            }),
      );
      publicFocus.requestFocus();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (back != null)
              IconButton(
                tooltip: 'Back to list',
                onPressed: back,
                icon: const Icon(Icons.arrow_back),
              ),
            CircleAvatar(
              radius: 18,
              backgroundColor: scheme.tertiaryContainer,
              child: const Icon(Icons.public, size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    publicChatName(space),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium,
                  ),
                  Text(
                    description.isEmpty
                        ? 'Public chat · anyone with the address can read and write'
                        : description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              tooltip: 'Chat options',
              onSelected: (action) {
                if (action == 'notify') {
                  update(
                    () => publicChats.setNotifies(
                      space,
                      !publicChats.notifies(space),
                    ),
                  );
                }
                if (action == 'invite') {
                  act(() => inviteToPublicChat(context, space));
                }
                if (action == 'copy') {
                  Clipboard.setData(
                    ClipboardData(
                      text: PublicChats.link(
                        space,
                        name: publicChatName(space),
                      ),
                    ),
                  );
                  notice('Chat link copied. Anyone you send it to can join.');
                }
                if (action == 'advert') {
                  act(
                    () => listings.setAdvertised(
                      space,
                      !listings.advertises(space),
                    ),
                  );
                }
                if (action == 'leave') {
                  act(() async {
                    await publicChats.leave(space);
                    unawaited(listings.refresh());
                    update(() {
                      publicChat = null;
                      showConversation = false;
                    });
                  });
                }
              },
              itemBuilder: (_) => [
                CheckedPopupMenuItem(
                  value: 'notify',
                  checked: publicChats.notifies(space),
                  child: const Text('Notify me'),
                ),
                const PopupMenuItem(
                  value: 'invite',
                  child: Text('Invite friends…'),
                ),
                PopupMenuItem(value: 'copy', child: Text('Copy chat link')),
                CheckedPopupMenuItem(
                  value: 'advert',
                  checked: listings.advertises(space),
                  child: const Text('Show to friends in Browse'),
                ),
                PopupMenuItem(value: 'leave', child: Text('Leave chat')),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: .5),
              borderRadius: BorderRadius.circular(16),
            ),
            child: messages.isEmpty
                ? empty(
                    'Say hello',
                    'Everyone who joins sees what is written here, and so '
                        'can their friends who join.',
                    Icons.waving_hand_outlined,
                  )
                : ListView.builder(
                    key: PageStorageKey('publicchat/$space'),
                    reverse: true,
                    padding: const EdgeInsets.all(12),
                    itemCount:
                        messages.length + (messages.length >= limit ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index == messages.length) {
                        return Center(
                          child: TextButton(
                            onPressed: () => update(
                              () => publicChatLimit[space] = limit + 100,
                            ),
                            child: const Text('Show earlier messages'),
                          ),
                        );
                      }
                      final m = messages[index];
                      final older = index + 1 < messages.length
                          ? messages[index + 1]
                          : null;
                      return KeyedSubtree(
                        key: ValueKey(m.object.id),
                        child: publicBubble(
                          context,
                          m,
                          groupStart:
                              older == null ||
                              older.object.author != m.object.author,
                        ),
                      );
                    },
                  ),
          ),
        ),
        const SizedBox(height: 8),
        ChatComposer(
          controller: publicComposer,
          focusNode: publicFocus,
          hint: 'Message ${publicChatName(space)}',
          onSend: send,
        ),
      ],
    );
  }

  Widget publicBubble(
    BuildContext context,
    ChatMessage m, {
    required bool groupStart,
  }) {
    final theme = Theme.of(context);
    final mine = m.object.author == node.person;
    final space = m.object.space;
    Future<void> menu(Offset at) async {
      final overlay =
          Overlay.of(context).context.findRenderObject() as RenderBox;
      final choice = await showMenu<String>(
        context: context,
        position: RelativeRect.fromRect(
          at & const Size(1, 1),
          Offset.zero & overlay.size,
        ),
        items: [
          const PopupMenuItem(value: 'copy', child: Text('Copy text')),
          const PopupMenuItem(value: 'link', child: Text('Copy link')),
          if (!mine)
            const PopupMenuItem(
              value: 'person',
              child: Text('About the sender'),
            ),
          if (publicChats.owns(space))
            const PopupMenuItem(value: 'hide', child: Text('Remove from chat')),
        ],
      );
      if (!context.mounted) return;
      switch (choice) {
        case 'copy':
          await Clipboard.setData(ClipboardData(text: m.text));
          notice('Copied');
        case 'link':
          await Clipboard.setData(
            ClipboardData(text: Links.message(space, m.object.id)),
          );
          notice('Link copied');
        case 'person':
          await showPersonDetails(context, m.object.author);
        case 'hide':
          await act(() async {
            await publicChats.hide(space, m.object.id);
            publicMessages.clear();
            notice('Removed for everyone in the chat');
          });
      }
    }

    return GestureDetector(
      onLongPressStart: (d) => unawaited(menu(d.globalPosition)),
      onSecondaryTapUp: (d) => unawaited(menu(d.globalPosition)),
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Container(
            margin: EdgeInsets.only(top: groupStart ? 8 : 2),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
            decoration: bubbleDecoration(
              theme.colorScheme,
              mine: mine,
              groupStart: groupStart,
              highlighted: false,
            ),
            // As wide as its text, not the row: the time sits at its end.
            child: IntrinsicWidth(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!mine && groupStart)
                    GestureDetector(
                      onTap: () => unawaited(
                        showPersonDetails(context, m.object.author),
                      ),
                      child: Text(
                        publicSender(m),
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                  MessageText(m.text),
                  Text(
                    messageClock(m.sent),
                    textAlign: TextAlign.right,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
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
}
