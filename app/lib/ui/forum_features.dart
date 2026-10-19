part of 'app.dart';

extension _ForumFeatures on _OurNetAppState {
  /// Latest owner-signed definition per forum, computed once per build.
  Json? forumInfo(String id) => memo('forums', () {
    final latest = <String, SignedObject>{};
    for (final o in node.store.objects(kind: 'forum', limit: Node.maxScan)) {
      if (!isForumDefinition(node, o)) continue;
      final old = latest[o.space];
      final order = old == null ? 1 : o.created.compareTo(old.created);
      if (order > 0 || order == 0 && o.id.compareTo(old!.id) > 0) {
        latest[o.space] = o;
      }
    }
    return {
      for (final entry in latest.entries)
        entry.key: entry.value.data['payload'] as Json,
    };
  })[id];

  String forumName(String id) => forumInfo(id)?['name'] as String? ?? id;

  /// What the forum is for: its owner's description, or for a forum called by
  /// name what its adverts say.
  String? forumDescription(String id) {
    final own = forumInfo(id)?['description'];
    if (own is String && own.isNotEmpty) return own;
    final listed = memo(
      'forumDescription/$id',
      () => listings.descriptionOf(id),
    );
    return listed.isEmpty ? null : listed;
  }

  bool ownsForum(String id) => id.startsWith('forum2:${node.person}:');
  bool contentVisible(SignedObject o) {
    if (!node.visible(o) ||
        memo(
          'hidden',
          () => node.store.trueSettings('hidden/'),
        ).contains(o.id)) {
      return false;
    }
    if (o.kind != 'post') return true;
    // Posts removed by their forum's owner, keyed by space and object.
    return !memo(
      'moderated',
      () => {
        for (final m in node.store.objects(
          kind: 'forum_hide',
          limit: Node.maxScan,
        ))
          if (m.isPublic && m.space.startsWith('forum2:${m.author}:'))
            '${m.space}/${m.data['payload']['object']}',
      },
    ).contains('${o.space}/${o.id}');
  }

  Future<void> forumSettings(BuildContext context) async {
    final description = await ask(
      context,
      'Forum description',
      initial: forumInfo(space)?['description'] ?? '',
      lines: 3,
    );
    if (description == null) return;
    await node.publish('forum', {
      'name': forumName(space),
      'description': description,
    }, space: space);
  }

  /// Starts a discussion in the public forum, or in [group]'s private one.
  Future<void> newDiscussion(BuildContext context, {RoomForum? group}) async {
    final title = TextEditingController(), body = TextEditingController();
    dynamic attachment;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, change) => AlertDialog(
          title: const Text('New discussion'),
          content: SizedBox(
            width: 540,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: title,
                    autofocus: true,
                    maxLength: 200,
                    decoration: const InputDecoration(
                      labelText: 'Discussion title',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: body,
                    minLines: 3,
                    maxLines: 7,
                    decoration: const InputDecoration(
                      labelText: 'What would you like to discuss?',
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () => unawaited(insertEventLink(context, body)),
                    icon: const Icon(Icons.event_outlined),
                    label: const Text('Mention a calendar event'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final picked = await FilePicker.pickFile();
                      if (context.mounted && picked != null) {
                        change(() => attachment = picked);
                      }
                    },
                    icon: const Icon(Icons.image_outlined),
                    label: Text(
                      attachment == null
                          ? 'Add image or file'
                          : attachment.name as String,
                    ),
                  ),
                  if (attachment != null)
                    TextButton(
                      onPressed: () => change(() => attachment = null),
                      child: const Text('Remove attachment'),
                    ),
                  Text(
                    group != null
                        ? 'Private · only members of this group can read this discussion.'
                        : 'Public · anyone receiving this forum can read this discussion.',
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (title.text.trim().isNotEmpty) Navigator.pop(context, true);
              },
              child: const Text('Publish discussion'),
            ),
          ],
        ),
      ),
    );
    final heading = title.text.trim(), text = body.text.trim();
    Future<void>.delayed(const Duration(seconds: 1), () {
      title.dispose();
      body.dispose();
    });
    if (accepted != true) return;
    if (attachment == null) {
      final content = {'title': heading, 'text': text, 'parent': null};
      if (group != null) {
        await group.publish(content);
      } else {
        await node.publish('post', content, space: space);
      }
    } else {
      final directory = await getTemporaryDirectory();
      if (attachment.lengthSync() case final int size) {
        files.checkRoom(
          size,
          name: attachment.name as String,
          destination: directory.path,
        );
      }
      final temp = File('${directory.path}/${randomId()}.post');
      try {
        final stream = attachment.readAsByteStream() as Stream<List<int>>;
        final output = temp.openWrite();
        try {
          await for (final chunk in stream) {
            output.add(chunk);
          }
        } finally {
          await output.close();
        }
        await files.publish(
          temp.path,
          name: attachment.name as String,
          postSpace: group?.space ?? space,
          post: {'title': heading, 'text': text, 'parent': null},
          audience: group == null ? const [] : await group.audience(),
          kind: group == null ? null : 'room_post',
        );
      } finally {
        if (await temp.exists()) await temp.delete();
      }
    }
    if (group != null) {
      await group.refresh();
      if (mounted) update(() {});
      return;
    }
    update(() {
      selectedThread = null;
      replyTo = null;
    });
  }

  /// The group forum [o] belongs to, when it is a group post.
  RoomForum? groupForumOf(SignedObject o) => o.kind != 'room_post'
      ? null
      : allGroupForums[o.space] ??
            (roomForum?.space == o.space ? roomForum : null);

  /// The content a vote on [o] is worked out from.
  Json postPayload(SignedObject o) => o.kind == 'room_post'
      ? groupForumOf(o)?.post(o.id)?.data ?? const {}
      : o.data['payload'] as Json;

  /// How [o] has been voted on, once per build; a group post counts its
  /// members' votes only.
  VoteTally postVotes(SignedObject o, [Json? payload]) =>
      memo('votes/${o.id}', () {
        final members = groupForumOf(o)?.room.data['members'];
        return forumVotes.tally(
          o,
          payload ?? postPayload(o),
          voters: o.kind != 'room_post'
              ? null
              : {...?(members as List?)?.cast<String>()},
        );
      });

  /// Votes [value] on [o], or takes the vote back when it is already that.
  /// Saved in the background, so the list stays usable.
  void votePost(SignedObject o, Json payload, int value) {
    final next = postVotes(o, payload).mine == value ? 0 : value;
    unawaited(() async {
      try {
        final group = groupForumOf(o);
        if (!o.isPublic && group == null) {
          throw StateError('the group is not open');
        }
        await forumVotes.vote(
          o,
          payload,
          next,
          audience: o.isPublic ? const [] : await group!.audience(),
        );
        redraw();
      } catch (e) {
        notice('Could not vote: $e');
      }
    }());
  }

  static const _upvoted = Color(0xFFFF4500), _downvoted = Color(0xFF7193FF);

  /// Reddit's up arrow, score and down arrow for a forum post.
  Widget voteBar(BuildContext context, SignedObject o, Json payload) {
    final tally = postVotes(o, payload);
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final color = tally.mine > 0
        ? _upvoted
        : tally.mine < 0
        ? _downvoted
        : muted;
    Widget arrow(int value, IconData icon, String tip) => SizedBox(
      width: 28,
      height: 28,
      child: IconButton(
        tooltip: tally.mine == value ? 'Remove vote' : tip,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 28, height: 28),
        iconSize: 18,
        color: tally.mine == value ? color : muted,
        onPressed: () => votePost(o, payload, value),
        icon: Icon(icon),
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        arrow(1, Icons.arrow_upward_rounded, 'Upvote'),
        Tooltip(
          message: '${tally.up} up · ${tally.down} down',
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 18),
            child: Text(
              '${tally.score}',
              textAlign: TextAlign.center,
              style: theme.textTheme.labelMedium?.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        arrow(-1, Icons.arrow_downward_rounded, 'Downvote'),
      ],
    );
  }

  /// [topics] in the order chosen with [forumSortMenu]; [written] is when
  /// each was first written.
  List<SignedObject> rankTopics(
    Iterable<SignedObject> topics,
    int Function(SignedObject) written,
  ) {
    final sort = forumSort;
    final ranked = [
      for (final o in topics)
        (o, written(o), sort == 'new' ? 0 : postVotes(o).score),
    ];
    double hot((SignedObject, int, int) t) => VoteTally.hot(t.$3, t.$2);
    ranked.sort((a, b) {
      final order = switch (sort) {
        'new' => 0,
        'top' => b.$3.compareTo(a.$3),
        _ => hot(b).compareTo(hot(a)),
      };
      if (order != 0) return order;
      final time = b.$2.compareTo(a.$2);
      return time != 0 ? time : b.$1.id.compareTo(a.$1.id);
    });
    return [for (final t in ranked) t.$1];
  }

  /// Chooses how discussions are ordered: Hot, New or Top, as on Reddit.
  Widget forumSortMenu() {
    const labels = {'hot': 'Hot', 'new': 'New', 'top': 'Top'};
    return PopupMenuButton<String>(
      tooltip: 'Sort discussions',
      initialValue: forumSort,
      onSelected: (sort) => update(() => node.store.set('forumSort', sort)),
      itemBuilder: (_) => [
        for (final MapEntry(:key, :value) in labels.entries)
          CheckedPopupMenuItem(
            value: key,
            checked: forumSort == key,
            child: Text(value),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.sort, size: 18),
            const SizedBox(width: 4),
            Text(labels[forumSort]!),
          ],
        ),
      ),
    );
  }
}
