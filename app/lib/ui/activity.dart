part of 'app.dart';

/// The activity feed: what happened lately across forums, notes, calendars,
/// files and friends, one row per thing per day, newest arrival first. Each
/// row opens the thing where it lives. See docs/ACTIVITY.md.
extension _ActivityPage on _OurNetAppState {
  static const _sectionLabels = {
    ActivitySection.posts: 'Posts',
    ActivitySection.notes: 'Notes',
    ActivitySection.calendar: 'Calendar',
    ActivitySection.files: 'Files',
    ActivitySection.people: 'People',
    ActivitySection.chat: 'Chat',
  };

  static const _sectionIcons = {
    ActivitySection.posts: Icons.forum_outlined,
    ActivitySection.notes: Icons.note_alt_outlined,
    ActivitySection.calendar: Icons.calendar_month_outlined,
    ActivitySection.files: Icons.folder_outlined,
    ActivitySection.people: Icons.person_add_alt,
    ActivitySection.chat: Icons.chat_bubble_outline,
  };

  /// The sections switched off, as saved; chat is off until switched on.
  Set<ActivitySection> restoreActivityHidden() {
    final saved = node.store.setting('activityHidden');
    if (saved is! List) return {ActivitySection.chat};
    return {
      for (final s in ActivitySection.values)
        if (saved.contains(s.name)) s,
    };
  }

  void toggleActivitySection(ActivitySection section, bool shown) {
    update(() {
      shown ? activityHidden.remove(section) : activityHidden.add(section);
    });
    node.store.set('activityHidden', [for (final s in activityHidden) s.name]);
  }

  /// The rows the scope and filters show, newest first.
  List<ActivityEntry> activityRows() => memo('activityRows', () {
    final group = activeRoom?.object.space;
    return [
      for (final e in activity.entries)
        if (!activityHidden.contains(e.section) &&
            e.inScope(scope, group: group))
          e,
    ];
  });

  /// New rows in the scope and filters on screen: the navigation's badge.
  int activityUnseen() => memo('activityUnseen', () {
    final seen = activity.seen;
    var n = 0;
    for (final e in activityRows()) {
      if (e.at <= seen) break;
      if (e.byOthers(node.person) && ++n >= 100) break;
    }
    return n;
  });

  Widget activityPage(BuildContext context) {
    // What was new when the page opened stays marked while it is open.
    final floor = activityFloor ??= activity.seen;
    if (activity.loaded && activity.unseen() > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || tab != Destination.activity) return;
        activity.markSeen();
        redraw();
      });
    }
    final rows = activityRows();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final section in ActivitySection.values)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    avatar: Icon(_sectionIcons[section], size: 18),
                    label: Text(_sectionLabels[section]!),
                    selected: !activityHidden.contains(section),
                    showCheckmark: false,
                    onSelected: (shown) =>
                        toggleActivitySection(section, shown),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: !activity.loaded
              ? const Center(child: CircularProgressIndicator())
              : rows.isEmpty && activity.exhausted
              ? empty(
                  'Nothing yet',
                  'Forum posts, changes to shared notes, events, files and '
                      'new friends show here as they arrive.',
                  Icons.dynamic_feed_outlined,
                )
              : activityList(context, rows, floor),
        ),
      ],
    );
  }

  Widget activityList(
    BuildContext context,
    List<ActivityEntry> entries,
    int floor,
  ) {
    // Day headings, and a line where what had been seen before begins.
    final rows = <Object>[];
    int? day;
    var dividerShown = false;
    final anyNew = entries.any(
      (e) => e.at > floor && e.byOthers(node.person),
    );
    for (final e in entries) {
      if (anyNew && !dividerShown && e.at <= floor) {
        rows.add('seen');
        dividerShown = true;
      }
      final at = DateTime.fromMillisecondsSinceEpoch(e.at);
      final d = DateTime(at.year, at.month, at.day).millisecondsSinceEpoch;
      if (d != day) {
        rows.add(d);
        day = d;
      }
      rows.add(e);
    }
    rows.add('more');
    final colors = Theme.of(context).colorScheme;
    return ListView.builder(
      itemCount: rows.length,
      itemBuilder: (context, index) => switch (rows[index]) {
        final int d => Padding(
          padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
          child: Text(
            activityDay(context, d),
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(color: colors.primary),
          ),
        ),
        'seen' => Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              const Expanded(child: Divider()),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  'Seen before',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              const Expanded(child: Divider()),
            ],
          ),
        ),
        'more' => activity.exhausted
            ? const SizedBox(height: 24)
            : Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: activityLoadingMore
                      ? const CircularProgressIndicator()
                      : OutlinedButton(
                          onPressed: loadMoreActivity,
                          child: const Text('Show earlier'),
                        ),
                ),
              ),
        final ActivityEntry e => activityTile(
          context,
          e,
          fresh: e.at > floor && e.byOthers(node.person),
        ),
        _ => const SizedBox.shrink(),
      },
    );
  }

  void loadMoreActivity() {
    update(() => activityLoadingMore = true);
    unawaited(
      activity
          .more()
          .catchError((Object e) {
            notice('Could not load earlier activity: $e');
            return false;
          })
          .whenComplete(() => update(() => activityLoadingMore = false)),
    );
  }

  String activityDay(BuildContext context, int day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime.fromMillisecondsSinceEpoch(day);
    final days = today.difference(d).inDays;
    if (days == 0) return 'Today';
    if (days == 1) return 'Yesterday';
    final local = MaterialLocalizations.of(context);
    return days < 7
        ? local.formatFullDate(d).split(',').first
        : local.formatMediumDate(d);
  }

  /// "You", a friend's name, or two names and how many more.
  String activityPeople(List<String> people) {
    String one(String p) => p == node.person ? 'You' : name(p);
    if (people.length <= 2) return people.map(one).join(' and ');
    return '${one(people.first)}, ${one(people[1])} and '
        '${people.length - 2} more';
  }

  /// Where it happened, as the row's second line names it.
  String activityPlace(ActivityEntry e) {
    if (e.group case final group?) {
      return knownRooms
              .where((r) => r.object.space == group)
              .map((r) => r.data['name'] as String)
              .firstOrNull ??
          'A group';
    }
    final kind = e.items.firstOrNull?.object.kind;
    return switch (kind) {
      'post' => forumName(e.space),
      PublicChats.messageKind => publicChats.info(e.space)?.name ?? e.space,
      'message' => 'Direct messages',
      'note_op' => 'Notes',
      'inbox' => 'My inbox',
      'drive' => 'Private drive',
      'file' => '${e.space} · Public',
      Calendar.eventKind => 'My calendar',
      _ => 'Friends',
    };
  }

  /// One line of what was written, for the row's preview.
  String? activityLine(ActivityItem item) {
    final d = item.data;
    if (d == null) return null;
    final text = d['title'] ?? d['name'] ?? d['text'];
    if (text is! String) return null;
    final line = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    return line.isEmpty ? null : line;
  }

  /// What happened, as a sentence after who did it.
  String activityWhat(ActivityEntry e) {
    final first = e.items.firstOrNull;
    if (e.section == ActivitySection.people || first == null) {
      return 'is now a friend';
    }
    final n = e.count;
    switch (e.section) {
      case ActivitySection.people:
        return 'is now a friend';
      case ActivitySection.notes when first.object.kind == 'note_op':
        final title = '${e.note?.data['title'] ?? ''}'.trim();
        final label = title.isNotEmpty
            ? '“$title”'
            : '${e.note?.data['label'] ?? 'a note'}'.toLowerCase();
        if (e.note?.data['removed'] == true) return 'removed $label';
        return n == 1 ? 'changed $label' : 'changed $label · $n edits';
      case ActivitySection.notes:
        return first.data?['type'] == 'check'
            ? 'updated a list${n > 1 ? ' · $n changes' : ''}'
            : n == 1
            ? 'saved a note'
            : 'saved $n notes';
      case ActivitySection.posts:
        if (n > 1) return 'posted $n times';
        return first.data?['title'] is String ? 'started a discussion' : 'replied';
      case ActivitySection.calendar:
        final events = {for (final i in e.items) i.data?['event']}.length;
        return events > 1 || n > e.items.length
            ? 'changed events'
            : first.data?['deleted'] == true
            ? 'removed an event'
            : 'added or changed an event';
      case ActivitySection.files:
        return n == 1 ? 'shared a file' : 'shared $n files';
      case ActivitySection.chat:
        return n == 1 ? 'sent a message' : 'sent $n messages';
    }
  }

  Widget activityTile(
    BuildContext context,
    ActivityEntry e, {
    required bool fresh,
  }) {
    final colors = Theme.of(context).colorScheme;
    final people = e.people;
    final mine = !e.byOthers(node.person);
    final lines = <String>{
      if (e.section == ActivitySection.notes &&
          e.items.firstOrNull?.object.kind == 'note_op')
        ?'${e.note?.data['text'] ?? ''}'
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .firstOrNull
      else
        for (final i in e.items) ?activityLine(i),
    }.take(2).toList();
    final time = MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(e.at)),
    );
    final image = e.section == ActivitySection.files
        ? e.items
              .where((i) => i.data != null && isImagePayload(i.data!))
              .firstOrNull
        : null;
    return Opacity(
      opacity: mine ? .6 : 1,
      child: Card(
        color: fresh ? colors.secondaryContainer : null,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => unawaited(
            openActivity(e).catchError((Object err) => notice('$err')),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    people.isEmpty
                        ? CircleAvatar(
                            radius: 18,
                            child: Icon(_sectionIcons[e.section], size: 18),
                          )
                        : conversationAvatar(people.first),
                    Positioned(
                      right: -4,
                      bottom: -4,
                      child: CircleAvatar(
                        radius: 9,
                        backgroundColor: colors.surface,
                        child: Icon(
                          _sectionIcons[e.section],
                          size: 12,
                          color: colors.primary,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: activityPeople(people),
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            TextSpan(text: ' ${activityWhat(e)}'),
                          ],
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      for (final line in lines)
                        Text(
                          line,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                      const SizedBox(height: 2),
                      Text(
                        '${activityPlace(e)} · $time',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (image != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: SizedBox.square(
                      dimension: 56,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: InlineImage(
                          key: ValueKey(image.object.id),
                          files: files,
                          object: image.object,
                          payload: image.data!,
                          online: network.running,
                          thumbnail: true,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<EverydayItem?> activityRoom(String space) async =>
      knownRooms.where((r) => r.object.space == space).firstOrNull ??
      (await Everyday(
        node,
      ).rooms()).where((r) => r.object.space == space).firstOrNull;

  /// Opens what [e] is about where it lives: the note, the discussion, the
  /// event, the file or the conversation; their list when it is several.
  Future<void> openActivity(ActivityEntry e) async {
    activityFloor = null;
    final item = e.items.firstOrNull;
    if (e.section == ActivitySection.people) {
      openConversation(e.space);
      return;
    }
    if (item == null) return;
    final o = item.object;
    final data = item.data;
    switch (o.kind) {
      case 'note_op':
        await openNote(e.space);
      case 'message':
        openConversation(e.space.substring('dm:'.length));
      case PublicChats.messageKind:
        openPublicChat(o.space);
      case 'room_item' when e.section == ActivitySection.chat:
        await openGroup(o.space);
      case 'post':
        if (e.count == 1 && data != null) {
          await openSource(EverydayItem(o, data));
        } else {
          openForum(o.space);
        }
      case 'room_post':
        final room = await activityRoom(o.space);
        if (room == null || !mounted) return;
        update(() {
          showGroup(room, section: Destination.forums);
          if (e.count == 1 && data != null) {
            groupThreads[o.space] =
                (data['parent'] ?? data['copyOf'] ?? o.id) as String;
          } else {
            groupThreads.remove(o.space);
          }
        });
      case Calendar.eventKind:
        final events = {for (final i in e.items) i.data?['event']};
        if (events.length == 1 && e.count <= e.items.length && data != null) {
          await openEventLink(Calendar.link(o.space, data['event'] as String));
          return;
        }
        final room = e.group == null ? null : await activityRoom(e.group!);
        update(() {
          if (room != null) {
            showGroup(room, section: Destination.calendar);
          } else {
            tab = Destination.calendar;
            reveal(ScopeKind.personal);
          }
        });
      default:
        if (data != null) await openSource(EverydayItem(o, data));
    }
  }
}
