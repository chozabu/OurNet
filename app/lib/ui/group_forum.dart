part of 'app.dart';

/// A private group's forum tab: the same discussions and replies as a public
/// forum, but only the group's members can read them.
extension _GroupForum on _OurNetAppState {
  Widget allForumList(BuildContext context) =>
      FutureBuilder<List<SignedObject>>(
        future: allGroupTopics ??= loadAllGroupTopics(),
        builder: (context, snapshot) {
          final objects = memo('allForumTopics/${snapshot.data.hashCode}', () {
            return rankTopics([
              ...discussionObjects(),
              for (final post in snapshot.data ?? const <SignedObject>[])
                if (allGroupForums.containsKey(post.space)) post,
            ], (post) => allGroupTopicTimes[post.id] ?? post.created);
          });
          return Column(
            children: [
              if (snapshot.connectionState != ConnectionState.done)
                const LinearProgressIndicator(),
              if (snapshot.hasError)
                TextButton(
                  onPressed: () => update(() => allGroupTopics = null),
                  child: const Text('Could not load group discussions. Retry'),
                ),
              Expanded(child: objectList(context, objects)),
            ],
          );
        },
      );

  /// Load groups serially, retaining their insertion indexes across updates.
  Future<List<SignedObject>> loadAllGroupTopics() {
    return allGroupLoading ??= _loadAllGroupTopics().whenComplete(() {
      allGroupLoading = null;
    });
  }

  Future<List<SignedObject>> _loadAllGroupTopics() async {
    final cursor = node.store.insertionCursor;
    final rooms = groupRooms(await (roomsView ??= Everyday(node).rooms()));
    final spaces = rooms.map((r) => r.object.space).toSet();
    allGroupForums.removeWhere((space, _) => !spaces.contains(space));
    final topics = <SignedObject>[];
    final times = <String, int>{};
    for (final room in rooms) {
      final forum = allGroupForums.putIfAbsent(
        room.object.space,
        () => roomForum?.space == room.object.space
            ? roomForum!
            : RoomForum(node, room),
      );
      if (forum.loaded) {
        await forum.refresh();
      } else {
        await forum.load();
      }
      for (final post in forum.topics) {
        topics.add(post.object);
        times[post.object.id] = post.sent;
      }
    }
    allGroupTopicTimes = times;
    if (mounted && node.store.insertionCursor != cursor) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) update(() => allGroupTopics = null);
      });
    }
    return topics;
  }

  /// Starts reading the open group's forum, once per group. It is read as soon
  /// as the group opens so the tab can show what is unread.
  void ensureRoomForum(EverydayItem room) {
    final forum = roomForum;
    if (forum != null && forum.space == room.object.space) return;
    final started = roomForum =
        allGroupForums[room.object.space] ?? RoomForum(node, room);
    roomForumReady = false;
    roomForumError = null;
    unawaited(() async {
      try {
        if (started.loaded) {
          await started.refresh();
        } else {
          await started.load();
        }
      } catch (e) {
        if (roomForum == started) roomForumError = e;
      }
      if (mounted && roomForum == started) update(() => roomForumReady = true);
    }());
  }

  Future<void> refreshGroupForum() async {
    final forum = roomForum;
    if (forum == null) return;
    if (openRoom == null) {
      roomForum = null;
      return;
    }
    try {
      await forum.refresh();
    } catch (_) {
      roomForum = null;
    }
  }

  /// Marks everything in a group's forum read, and recounts the badges.
  void markGroupForumRead(String space) {
    node.store.markSpaceSeen('room_post', space, node.person);
    unreadCounts.clear();
  }

  /// Posts by others in the open group's forum that have not been read.
  int groupForumUnread() {
    final forum = roomForum;
    if (forum == null || !roomForumReady) return 0;
    return memo(
      'groupForumUnread',
      () => forum.shown
          .where(
            (p) =>
                p.author != node.person &&
                node.store.setting('seen/${p.object.id}') != true,
          )
          .length,
    );
  }

  Widget groupForumView(BuildContext context, EverydayItem room) {
    ensureRoomForum(room);
    final forum = roomForum!;
    if (roomForumError != null) {
      return Center(child: Text('Could not load the forum: $roomForumError'));
    }
    if (!roomForumReady) {
      return const Center(child: CircularProgressIndicator());
    }
    final space = room.object.space;
    final thread = groupThreads[space];
    final replying = groupReplies[space];
    final posts = thread == null
        ? forum.topics
        : forum.thread(thread, score: (p) => postVotes(p.object, p.data).score);
    final visible = [
      for (final p in posts)
        if (contentVisible(p.object)) p.object,
    ];
    final objects = thread == null
        ? rankTopics(visible, (o) => forum.post(o.id)?.sent ?? o.created)
        : visible;
    // Open is read, as for a chat: everything in the forum, including what
    // it does not show, or the badge could never clear.
    if (groupForumUnreadOf(room) > 0 || groupForumUnread() > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || openRoom?.object.space != space) return;
        markGroupForumRead(space);
        redraw();
      });
    }
    final heading = thread == null
        ? 'Discussions'
        : forum.shown
                  .where((p) => p.object.id == thread)
                  .map((p) => p.data['title'] as String?)
                  .firstOrNull ??
              'Discussion';
    return Column(
      children: [
        const SizedBox(height: 4),
        if (thread == null)
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: busy
                  ? null
                  : () => act(() => newDiscussion(context, group: forum)),
              icon: const Icon(Icons.add_comment_outlined),
              label: const Text('New discussion'),
            ),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: Text(heading)),
            if (thread == null) forumSortMenu(),
            if (thread != null)
              IconButton(
                tooltip: 'All discussions',
                icon: const Icon(Icons.arrow_back),
                onPressed: () => update(() {
                  groupThreads.remove(space);
                  groupReplies.remove(space);
                }),
              ),
            TextButton(
              onPressed: () {
                markGroupForumRead(space);
                refresh();
              },
              child: const Text('Mark read'),
            ),
          ],
        ),
        Expanded(
          child: objectList(
            context,
            objects,
            forum: ForumScope(
              key: 'groupforum/$space/$thread',
              thread: thread,
              depth: (o) => forum.depth(o.id),
              replies: (o) => forum.replies(o.id),
              open: (id) => update(() {
                groupThreads[space] = id;
                groupReplies.remove(space);
              }),
              reply: (id) => update(() {
                groupThreads[space] ??= id;
                groupReplies[space] = id;
                submittedForumThreads.remove(
                  'groupforum/$space/${groupThreads[space]}',
                );
              }),
            ),
            inline:
                thread == null ||
                    (replying == null &&
                        submittedForumThreads.contains(
                          'groupforum/$space/$thread',
                        ))
                ? null
                : InlineReply(
                    replying ?? thread,
                    (context) =>
                        groupReplyBox(context, forum, space, thread, replying),
                  ),
          ),
        ),
      ],
    );
  }

  /// The reply box that opens under the post being answered.
  Widget groupReplyBox(
    BuildContext context,
    RoomForum forum,
    String space,
    String thread,
    String? replying,
  ) {
    final root = replying == null || replying == thread;
    return compose(
      context,
      () => act(() async {
        final draftKey = composerContext;
        final submitted = composer.text;
        if (submitted.trim().isEmpty) return;
        await forum.publish({
          'text': submitted.trim(),
          'parent': replying ?? thread,
        });
        await finishDraft(draftKey, submitted);
        await forum.refresh();
        if (mounted) {
          update(() {
            groupReplies.remove(space);
            if (draftKey != null &&
                draftKey == composerContext &&
                composer.text.isEmpty) {
              submittedForumThreads.add(draftKey);
              composerFocus.unfocus();
            }
          });
        }
      }),
      draftKey: 'groupforum/$space/$thread',
      inline: true,
      hint: root ? 'Add a comment…' : 'Write a reply…',
      cancelReply: root ? null : () => update(() => groupReplies.remove(space)),
      attach: () => act(() async {
        final draftKey = composerContext;
        final submitted = composer.text;
        final parent = replying ?? thread;
        final result = await FilePicker.pickFile();
        final path = result?.path;
        if (path == null) return;
        await files.publish(
          path,
          postSpace: space,
          audience: await forum.audience(),
          kind: 'room_post',
          post: {'parent': parent, 'text': submitted.trim()},
        );
        await finishDraft(draftKey, submitted);
        await forum.refresh();
        if (mounted) {
          update(() {
            groupReplies.remove(space);
            if (draftKey != null &&
                draftKey == composerContext &&
                composer.text.isEmpty) {
              submittedForumThreads.add(draftKey);
              composerFocus.unfocus();
            }
          });
        }
      }),
    );
  }
}
