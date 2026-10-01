part of 'app.dart';

/// A private group's forum tab: the same discussions and replies as a public
/// forum, but only the group's members can read them.
extension _GroupForum on _OurNetAppState {
  /// Starts reading the open group's forum, once per group. It is read as soon
  /// as the group opens so the tab can show what is unread.
  void ensureRoomForum(EverydayItem room) {
    final forum = roomForum;
    if (forum != null && forum.space == room.object.space) return;
    final started = roomForum = RoomForum(node, room);
    roomForumReady = false;
    roomForumError = null;
    unawaited(() async {
      try {
        await started.load();
      } catch (e) {
        if (roomForum == started) roomForumError = e;
      }
      if (mounted && roomForum == started) update(() => roomForumReady = true);
    }());
  }

  Future<void> refreshGroupForum() async {
    final forum = roomForum;
    if (forum == null) return;
    if (activeRoom == null) {
      roomForum = null;
      return;
    }
    try {
      await forum.refresh();
    } catch (_) {
      roomForum = null;
    }
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
    final posts = thread == null ? forum.topics : forum.thread(thread);
    final objects = [
      for (final p in posts)
        if (contentVisible(p.object)) p.object,
    ];
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
                for (final o in objects) {
                  node.store.set('seen/${o.id}', true);
                }
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
              }),
            ),
          ),
        ),
        if (thread != null)
          compose(
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
              if (mounted) update(() => groupReplies.remove(space));
            }),
            draftKey: 'groupforum/$space/$thread',
            replying: replying,
            cancelReply: () => update(() => groupReplies.remove(space)),
            attach: () => act(() async {
              final result = await FilePicker.pickFile();
              final path = result?.path;
              if (path == null) return;
              if ((result!.lengthSync() ?? 0) > Files.maxSize) {
                throw StateError('Prototype file limit is 64 MiB');
              }
              await files.publish(
                path,
                postSpace: space,
                audience: await forum.audience(),
                kind: 'room_post',
                post: {
                  'parent': replying ?? thread,
                  'text': composer.text.trim(),
                },
              );
              await forum.refresh();
              if (mounted) update(() {});
            }),
          ),
      ],
    );
  }
}
