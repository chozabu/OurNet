part of 'app.dart';

/// Walls in the app (docs/WALL.md): posts from followed walls are Activity
/// rows shown as full cards, with the composer above them; a person's wall
/// opens as a page of its own. The widgets are in wall_page.dart.
extension _WallSection on _OurNetAppState {
  WallContext get wallContext => WallContext(
    node: node,
    nameOf: name,
    avatar: (person, radius) => conversationAvatar(person, radius: radius),
    notice: notice,
    openWall: openWall,
  );

  /// Opens [person]'s wall as a page of its own.
  void openWall(String person) {
    noteNavigator.currentState?.push(
      MaterialPageRoute<void>(
        builder: (_) => WallScreen(wall: wallContext, person: person),
      ),
    );
  }

  /// Whether Activity shows the composer: wall rows are on, and the scope
  /// is not a group's (a wall belongs to no group).
  bool get activityComposer =>
      !activityHidden.contains(ActivitySection.wall) &&
      activeRoom == null &&
      scope != ScopeKind.group;

  Widget activityWallComposer() => WallComposer(
    wall: wallContext,
    view: wallFeed,
    posted: _wallRefresh.schedule,
  );

  /// Whether a wall row is still worth showing: its wall is followed and its
  /// owner has not hidden the post.
  bool wallRowShown(ActivityEntry e) =>
      node.subscriptions.contains(e.space) &&
      !(e.post != null && wallFeed.hidden(e.post!));

  /// The wall post an Activity row is about, as a card; the plain row while
  /// the feed has not read back that far yet ([readWallBack]).
  Widget activityWallCard(
    BuildContext context,
    ActivityEntry e, {
    required bool fresh,
  }) {
    final post = e.post == null ? null : wallFeed.post(e.post!);
    if (post == null) return activityTile(context, e, fresh: fresh);
    return WallPostCard(
      key: ValueKey(post.id),
      wall: wallContext,
      view: wallFeed,
      post: post,
      votes: forumVotes,
      highlight: fresh,
      changed: _wallRefresh.schedule,
    );
  }

  /// Reads the wall feed further back, a page at a time, while [rows] name
  /// posts it has not reached: Activity and the feed page back together.
  void readWallBack(List<ActivityEntry> rows) {
    if (wallLoadingMore || !wallFeed.loaded || wallFeed.exhausted) return;
    final missing = rows.any(
      (e) => e.post != null && wallFeed.post(e.post!) == null,
    );
    if (!missing) return;
    wallLoadingMore = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        wallFeed
            .more()
            .catchError((Object e) {
              notice('Could not read earlier posts: $e');
              return false;
            })
            .whenComplete(() {
              wallLoadingMore = false;
              if (mounted) redraw();
            }),
      );
    });
  }
}
