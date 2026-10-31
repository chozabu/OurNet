part of 'app.dart';

/// The scope the content destinations show: All, Personal, Public or one
/// group. See docs/SCOPES.md.
extension _Scopes on _OurNetAppState {
  /// The scope on screen: null is All.
  ScopeKind? get scope => activeRoom != null ? ScopeKind.group : viewScope;

  /// Shows [kind] (null for All) in whichever destination is open.
  void setScope(ScopeKind? kind) {
    activeRoom = null;
    listRoom = null;
    viewScope = kind == ScopeKind.group ? null : kind;
  }

  /// Shows [room]'s content: in [section], or in the destination that is open
  /// when it has a part for groups (else the group's chat).
  void showGroup(EverydayItem room, {Destination? section}) {
    activeRoom = room;
    listRoom = null;
    viewScope = null;
    tab =
        section ??
        (tab.section?.allows(ScopeKind.group) == true
            ? tab
            : Destination.messages);
  }

  /// Saves the scope, to open in it next time.
  void rememberScope() {
    final room = activeRoom;
    node.store.set(
      'lastScope',
      room != null ? 'group:${room.object.space}' : viewScope?.name,
    );
  }

  /// Opens in the scope last shown. A group is found once the rooms are
  /// read; one left since opens in All.
  void restoreScope() {
    final saved = node.store.setting('lastScope');
    if (saved is! String) return;
    if (!saved.startsWith('group:')) {
      viewScope = ScopeKind.values.where((k) => k.name == saved).firstOrNull;
      if (viewScope == ScopeKind.group) viewScope = null;
      return;
    }
    final space = saved.substring('group:'.length);
    unawaited(
      (roomsView ??= Everyday(node).rooms()).then((rooms) {
        final room = groupRooms(
          rooms,
        ).where((r) => r.object.space == space).firstOrNull;
        // Only if nothing has been picked meanwhile.
        if (room != null &&
            mounted &&
            activeRoom == null &&
            viewScope == null) {
          update(() => activeRoom = room);
        }
      }, onError: (Object _) {}),
    );
  }

  /// Leaves a scope that cannot hold [kind] content, for opening something
  /// from elsewhere (a notification, search, a link): back to All.
  void reveal(ScopeKind kind) {
    if (scope != null && scope != kind) setScope(null);
  }

  /// Unread entries in a group's chat: the scoped group's by default.
  int groupChatUnread([EverydayItem? room]) {
    room ??= activeRoom;
    if (room == null) return 0;
    final space = '${room.data['room']}';
    return unreadCounts['room_item/$space'] ??= node.roomUnread(space);
  }

  /// What is unread in Chat for the scope on screen: direct messages, the
  /// groups' chats and joined public chats, as the scope shows them.
  int chatsUnread() => memo('chatsUnread', () {
    if (activeRoom != null) return groupChatUnread();
    final kind = viewScope;
    return (kind == ScopeKind.public ? 0 : unread('message')) +
        (kind == null
            ? knownRooms.fold<int>(0, (n, room) => n + groupChatUnread(room))
            : 0) +
        (kind == ScopeKind.personal
            ? 0
            : publicChats.joined.fold<int>(
                0,
                (n, chat) => n + publicChats.unread(chat),
              ));
  });

  /// What is unread in Forums for the scope on screen.
  int forumsUnread() => memo('forumsUnread', () {
    if (activeRoom != null) return groupForumUnread();
    return switch (viewScope) {
      ScopeKind.personal => 0,
      ScopeKind.public => unread('post'),
      _ =>
        unread('post') +
            knownRooms.fold<int>(0, (n, room) => n + groupForumUnreadOf(room)),
    };
  });

  /// What is unread that the scope on screen leaves out: direct messages,
  /// the groups' chats and forums, and joined public chats, except what
  /// this scope shows. None in All. For the scope header's arrow.
  int elsewhereUnread() => memo('elsewhereUnread', () {
    final room = activeRoom;
    final kind = scope;
    if (kind == null) return 0;
    return (kind == ScopeKind.personal ? 0 : unread('message')) +
        knownRooms
            .where((r) => r.object.space != room?.object.space)
            .fold<int>(
              0,
              (n, r) => n + groupChatUnread(r) + groupForumUnreadOf(r),
            ) +
        (kind == ScopeKind.public
            ? 0
            : publicChats.joined.fold<int>(
                0,
                (n, chat) =>
                    n +
                    memo('chatUnread/$chat', () => publicChats.unread(chat)),
              ));
  });

  /// The scope header's dropdown arrow, marked when another scope has
  /// something unread ([elsewhereUnread]).
  Widget scopeArrow() {
    final count = elsewhereUnread();
    const arrow = Icon(Icons.arrow_drop_down, size: 20);
    if (count == 0) return arrow;
    return Tooltip(
      message: '$count unread in other scopes',
      child: Badge.count(
        key: const ValueKey('scope-elsewhere-unread'),
        count: count,
        maxCount: 99,
        offset: const Offset(4, -4),
        child: arrow,
      ),
    );
  }

  /// Unread posts in a group's forum.
  int groupForumUnreadOf(EverydayItem room) =>
      unreadCounts['room_post/${room.object.space}'] ??= node.unreadSinceFloor(
        'room_post',
        room.object.space,
      );

  List<EverydayItem> groupRooms(List<EverydayItem>? rooms) {
    if (rooms == null) return const [];
    final groups = rooms.where((r) => r.data['note'] != true).toList();
    String spaces(List<EverydayItem> list) =>
        [for (final r in list) r.object.space].join(' ');
    // The navigation's badges sum over the groups: draw them again once the
    // groups first arrive, or change.
    if (spaces(groups) != spaces(knownRooms)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => redraw());
    }
    return knownRooms = groups;
  }

  /// A group's name, from the rooms last read.
  String groupName(String space) =>
      knownRooms.where((r) => r.object.space == space).firstOrNull?.data['name']
          as String? ??
      groupNames[space] ??
      'Group';

  /// The groups a list in All shows among other things; none in other
  /// scopes. Built from the rooms as last read.
  Widget scopedRooms(
    Widget Function(BuildContext context, List<EverydayItem> rooms) builder,
  ) => scope == null
      ? _roomsBuilder(builder)
      : Builder(builder: (context) => builder(context, const []));

  /// The newest [kind] object in [space] (see [latestItems]).
  SignedObject? latestIn(String kind, String space) {
    final key = '$kind/$space';
    if (latestItems.containsKey(key)) return latestItems[key];
    return latestItems[key] = node.store.latestIn(kind, space);
  }

  /// The newest [kind] object in [space] that this device shows and [where]
  /// accepts, for a list row's latest activity. Reads only the newest few
  /// through the (kind, space, created) index, never the kind's history;
  /// kept like [latestItems].
  SignedObject? latestShownIn(
    String kind,
    String space, {
    bool Function(SignedObject)? where,
  }) {
    final key = 'shown/$kind/$space';
    if (latestItems.containsKey(key)) return latestItems[key];
    return latestItems[key] = node.store
        .objects(kind: kind, space: space, limit: 20)
        .where((o) => node.visible(o) && (where?.call(o) ?? true))
        .firstOrNull;
  }

  /// The chat list: friends (a person's ID) and [rooms] (their group chats)
  /// together, pinned conversations first, then the most recent.
  List<Object> chatEntries(
    ({List<String> active, List<String> archived}) order,
    List<EverydayItem> rooms, {
    List<String> chats = const [],
  }) {
    if (rooms.isEmpty && chats.isEmpty) return order.active;
    final recent = recentChats();
    final entries = <({Object entry, bool pinned, int time, int rank})>[
      for (final (i, person) in order.active.indexed)
        (
          entry: person,
          pinned: node.store.setting('chatPinned/$person') == true,
          time: recent[person]?.created ?? 0,
          rank: i,
        ),
      for (final (i, room) in rooms.indexed)
        (
          entry: room,
          pinned: false,
          time:
              latestIn('room_item', '${room.data['room']}')?.created ??
              room.object.created,
          rank: order.active.length + i,
        ),
      for (final (i, chat) in chats.indexed)
        (
          entry: (chat: chat),
          pinned: false,
          time:
              latestIn(PublicChats.messageKind, chat)?.created ??
              publicChatCreated(chat),
          rank: order.active.length + rooms.length + i,
        ),
    ];
    entries.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      final time = b.time.compareTo(a.time);
      return time != 0 ? time : a.rank.compareTo(b.rank);
    });
    return [for (final e in entries) e.entry];
  }

  /// A group's chat in the All chat list: opening it shows the group, and
  /// back returns here.
  Widget groupChatTile(BuildContext context, EverydayItem room) {
    final theme = Theme.of(context);
    final space = '${room.data['room']}';
    final latest = latestIn('room_item', space);
    final count = groupChatUnread(room);
    final muted = chatMuted(node, room.object.space);
    final members = (room.data['members'] as List).length;
    final fallback = Text('$members members · Private group');
    return ListTile(
      leading: CircleAvatar(
        radius: 20,
        backgroundColor: theme.colorScheme.secondaryContainer,
        child: const Icon(Icons.people_outline),
      ),
      title: chatRowTitle(theme, room.data['name'], muted: muted),
      subtitle: latest == null || !node.visible(latest)
          ? fallback
          : FutureBuilder<Json?>(
              future: node.content(latest),
              builder: (context, snapshot) {
                final text = MessageText.plain(contentPreview(snapshot.data));
                if (text.isEmpty) return fallback;
                final who = latest.author == node.person
                    ? 'You'
                    : name(latest.author);
                return Text(
                  '$who: $text',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                );
              },
            ),
      trailing: chatRowTrailing(
        theme,
        latest?.created,
        unread: count > 0,
        marks: [
          if (groupCalls.infoFor(room.object.space) case final call?)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: GroupCallChip(people: call.people.length),
            ),
          if (count > 0)
            Badge(
              backgroundColor: muted
                  ? theme.colorScheme.outline
                  : theme.colorScheme.primary,
              label: Text('$count'),
            ),
        ],
      ),
      selected: listRoom?.object.space == room.object.space,
      onTap: () => openGroupInList(room, Destination.messages),
    );
  }

  /// The group whose chat or forum is on screen: the scoped group, or one
  /// opened beside a list in another scope (see [listRoom]).
  EverydayItem? get openRoom =>
      activeRoom ??
      (tab == Destination.messages || tab == Destination.forums
          ? listRoom
          : null);

  /// Opens [room]'s chat or forum ([section]) beside the list it was picked
  /// from, as a conversation opens: the scope, and so the list, stay.
  void openGroupInList(EverydayItem room, Destination section) {
    update(() {
      tab = section;
      listRoom = room;
      publicChat = null;
      if (section == Destination.forums) {
        showForum = true;
      } else {
        showConversation = true;
      }
    });
    if (section == Destination.messages) markRoomSeen('${room.data['room']}');
  }

  /// A group's chat or forum opened beside a list: its bar, then the section.
  Widget groupListDetail(BuildContext context, {VoidCallback? back}) {
    final room = listRoom!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        groupBar(
          context,
          room,
          back: back,
          extra: IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Show only this group',
            onPressed: () => update(() => showGroup(room)),
            icon: const Icon(Icons.filter_center_focus),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(child: everydayPage(context)),
      ],
    );
  }

  /// Keeps the scoped group current when the rooms are read again: its
  /// latest record (members change), or All once it is left or closed.
  void _resolveActiveRoom(
    AsyncSnapshot<List<EverydayItem>> snapshot,
    List<EverydayItem> rooms,
  ) {
    if (!snapshot.hasData || snapshot.connectionState != ConnectionState.done) {
      return;
    }
    // A group opened beside a list goes once it is left.
    final listed = listRoom;
    if (listed != null &&
        !rooms.any((r) => r.object.space == listed.object.space)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (listRoom == listed) update(() => listRoom = null);
      });
    }
    final current = activeRoom;
    if (current == null) return;
    final latest = rooms
        .where((r) => r.object.space == current.object.space)
        .firstOrNull;
    if (latest?.object.id == current.object.id) return;
    // Not during the build. Choosing a group reads the rooms again (see
    // [update]), so this list is never older than the choice.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (activeRoom?.object.id != current.object.id) return;
      update(() => activeRoom = latest);
    });
  }

  Widget _roomsBuilder(
    Widget Function(BuildContext context, List<EverydayItem> rooms) builder,
  ) => FutureBuilder<List<EverydayItem>>(
    future: roomsView ??= Everyday(node).rooms(),
    builder: (context, snapshot) {
      final rooms = groupRooms(snapshot.data);
      _resolveActiveRoom(snapshot, rooms);
      return builder(context, rooms);
    },
  );

  ({String title, String detail, IconData icon}) scopeLabel(ScopeKind? kind) =>
      switch (kind) {
        null => (
          title: 'All',
          detail: 'Everything you can see',
          icon: Icons.all_inclusive,
        ),
        ScopeKind.personal => (
          title: 'Personal',
          detail: 'Yours, and what you share with individual friends',
          icon: Icons.person_outline,
        ),
        ScopeKind.public => (
          title: 'Public',
          detail: 'Public chats, forums and files · visible to others',
          icon: Icons.public,
        ),
        ScopeKind.group => (
          title: activeRoom?.data['name'] as String? ?? 'Group',
          detail: 'Private group',
          icon: Icons.people_outline,
        ),
      };

  /// The scopes to pick from: All, Personal, Public, each group, and making
  /// a group. Shown by the scope header's picker ([pickScope]).
  /// [after] runs once one is picked (closing a drawer or sheet).
  Widget scopeList(BuildContext context, {VoidCallback? after}) =>
      _roomsBuilder((context, rooms) {
        void pick(VoidCallback change) {
          update(change);
          after?.call();
        }

        Widget kindTile(ScopeKind? kind) {
          final label = scopeLabel(kind);
          return ListTile(
            leading: Icon(label.icon),
            title: Text(label.title),
            subtitle: Text(label.detail),
            selected: activeRoom == null && viewScope == kind,
            onTap: () => pick(() => setScope(kind)),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                'Showing',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
            kindTile(null),
            kindTile(ScopeKind.personal),
            kindTile(ScopeKind.public),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 4, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Private groups',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                  if (rooms.isNotEmpty)
                    TextButton(
                      onPressed: () => pick(() => tab = Destination.groups),
                      child: const Text('See all'),
                    ),
                ],
              ),
            ),
            for (final room in rooms)
              ListTile(
                leading: const Icon(Icons.lock_outline),
                title: Text(
                  room.data['name'],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (groupCalls.infoFor(room.object.space) case final call?)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: GroupCallChip(people: call.people.length),
                      ),
                    countBadge(groupChatUnread(room)),
                  ],
                ),
                selected: activeRoom?.object.space == room.object.space,
                onTap: () {
                  pick(() => showGroup(room));
                  if (tab == Destination.messages) {
                    markRoomSeen('${room.data['room']}');
                  }
                },
              ),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('Create group'),
              onTap: busy
                  ? null
                  : () {
                      after?.call();
                      // The drawer or sheet this sits in has just closed.
                      final host = noteNavigator.currentContext;
                      if (host != null) act(() => createPrivateGroup(host));
                    },
            ),
          ],
        );
      });

  /// The scope picker, from the header.
  Future<void> pickScope(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheet).height * .85,
        ),
        child: SingleChildScrollView(
          child: scopeList(sheet, after: () => Navigator.pop(sheet)),
        ),
      ),
    ),
  );

  /// Whether the place open filters by scope: a content destination or a
  /// plugin's section. Its app bar shows the scope picker ([scopeTitle]).
  bool get scopedTab =>
      tab.section != null ||
      (tab == Destination.plugin && pluginSection != null);

  /// The app bar's title on a scoped place, so a filter is never forgotten:
  /// the place's name, small, over the scope; tapping it picks another.
  /// Wide screens add what the scope is, or a group's members.
  Widget scopeTitle(BuildContext context, String place, {required bool wide}) =>
      _roomsBuilder((context, rooms) {
        final room = activeRoom;
        final label = scopeLabel(scope);
        final colors = Theme.of(context).colorScheme;
        final small = TextStyle(fontSize: 12, color: colors.onSurfaceVariant);
        return Material(
          color: room == null
              ? colors.surfaceContainerHigh
              : inboxDragging
              ? colors.tertiaryContainer
              : colors.primaryContainer,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: const ValueKey('scope-header'),
            onTap: () => unawaited(pickScope(context)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 3, 8, 3),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(label.icon, size: 22),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          place,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: small,
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                label.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            scopeArrow(),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (wide) ...[
                    const SizedBox(width: 12),
                    Flexible(
                      child: room == null
                          ? Text(
                              label.detail,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: small,
                            )
                          : groupStatus(room, small),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      });

  /// A scoped place under what its group adds: on a phone a strip with the
  /// group's members and buttons (the app bar holds its name, and on a wide
  /// screen its buttons too), then its call and add requests.
  Widget scopedPage(BuildContext context, {required bool wide}) {
    final body = page(context);
    final room = activeRoom;
    if (!scopedTab || room == null) return body;
    // The notes screen brings its own search and capture bar, which need the
    // room once the keyboard is up.
    final typing = MediaQuery.viewInsetsOf(context).bottom > 0;
    if (typing && tab == Destination.notes) return body;
    Widget top = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!wide) groupStrip(context, room),
        groupCallBanner(context, room.object.space),
        groupAddRequestsBanner(context, room),
      ],
    );
    if (tab == Destination.maps) {
      top = Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: top,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        top,
        if (!wide) const SizedBox(height: 8),
        Expanded(child: body),
      ],
    );
  }

  /// A phone's strip under the app bar while a group is the scope: who is
  /// in it, and its buttons.
  Widget groupStrip(BuildContext context, EverydayItem room) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: inboxDragging ? colors.tertiaryContainer : colors.primaryContainer,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 4, 0),
        child: Row(
          children: [
            Expanded(child: groupStatus(room, const TextStyle(fontSize: 12))),
            ...groupButtons(context, room),
          ],
        ),
      ),
    );
  }

  /// Who is in [room] and who is online; while something is dragged over the
  /// inbox, where it goes.
  Widget groupStatus(EverydayItem room, TextStyle style) {
    if (inboxDragging) return Text('Drop to save here', style: style);
    final members = (room.data['members'] as List).cast<String>();
    return SyncStatus(
      network: network,
      people: members,
      prefix: '${members.length} members · ',
      offline: '${members.length} members · offline',
      maxLines: 1,
      style: style,
    );
  }

  /// [room]'s buttons: calls (from its chat, until one is going), muting,
  /// members and info.
  List<Widget> groupButtons(BuildContext context, EverydayItem room) => [
    if (tab == Destination.messages &&
        groupCalls.infoFor(room.object.space) == null) ...[
      // A call is the group's to start, from its chat; once one is going the
      // banner below offers Join instead.
      IconButton(
        visualDensity: VisualDensity.compact,
        tooltip: 'Start a video call',
        onPressed: groupCalls.active
            ? null
            : () => joinGroupCall(context, room.object.space, video: true),
        icon: const Icon(Icons.videocam_outlined),
      ),
      IconButton(
        visualDensity: VisualDensity.compact,
        tooltip: 'Start a voice call',
        onPressed: groupCalls.active
            ? null
            : () => joinGroupCall(context, room.object.space),
        icon: const Icon(Icons.call_outlined),
      ),
    ],
    IconButton(
      visualDensity: VisualDensity.compact,
      tooltip: chatMuted(node, room.object.space)
          ? 'Unmute notifications'
          : 'Mute notifications',
      onPressed: () => toggleGroupMute(room.object.space),
      icon: Icon(
        chatMuted(node, room.object.space)
            ? Icons.volume_off_outlined
            : Icons.volume_up_outlined,
      ),
    ),
    IconButton(
      visualDensity: VisualDensity.compact,
      tooltip: 'Group members',
      onPressed: busy ? null : () => act(() => manageGroup(context, room)),
      icon: const Icon(Icons.manage_accounts_outlined),
    ),
    IconButton(
      visualDensity: VisualDensity.compact,
      tooltip: 'Group info',
      onPressed: () => unawaited(groupInfo(context, room)),
      icon: const Icon(Icons.info_outline),
    ),
  ];

  /// A group opened beside a list ([groupListDetail]): its name and who is
  /// in it, its buttons, then its call and requests. [back] adds a back
  /// arrow, [extra] a last button.
  Widget groupBar(
    BuildContext context,
    EverydayItem room, {
    VoidCallback? back,
    Widget? extra,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: inboxDragging
              ? colors.tertiaryContainer
              : colors.primaryContainer,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: EdgeInsets.fromLTRB(back == null ? 12 : 0, 4, 4, 4),
            child: Row(
              children: [
                if (back != null)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Back to list',
                    onPressed: back,
                    icon: const Icon(Icons.arrow_back),
                  )
                else ...[
                  const Icon(Icons.people_outline, size: 22),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        room.data['name'],
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      groupStatus(room, const TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
                ...groupButtons(context, room),
                ?extra,
              ],
            ),
          ),
        ),
        groupCallBanner(context, room.object.space),
        groupAddRequestsBanner(context, room),
      ],
    );
  }

  /// What a destination says when the scope holds nothing of its kind,
  /// following [ScopedSection]'s table.
  Widget scopeUnavailable(BuildContext context, ScopedSection section) {
    final where = scopeLabel(scope).title;
    final why = switch (section) {
      ScopedSection.notes => 'Notes are private to you or a group.',
      ScopedSection.calendar => 'Calendars are private to you or a group.',
      ScopedSection.chat => 'Chats are with friends, in groups or public.',
      ScopedSection.forums =>
        'Forums are public, or inside a group. Pick Public or a group.',
      ScopedSection.files => 'Files are not shown here.',
      ScopedSection.maps =>
        'Maps show you and the friends sharing their location with you. '
            'They are not split by group yet.',
      ScopedSection.activity => 'Activity covers every scope.',
    };
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(tab.icon, size: 48, color: Colors.teal),
            const SizedBox(height: 16),
            Text(
              'No ${tab.title.toLowerCase()} in $where',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(why, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: () => update(() => setScope(null)),
              child: const Text('Show all'),
            ),
          ],
        ),
      ),
    );
  }
}
