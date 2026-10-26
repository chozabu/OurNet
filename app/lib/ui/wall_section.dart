part of 'app.dart';

/// The Wall section and people's walls (docs/WALL.md): the pages are in
/// wall_page.dart; this ties them to the app.
extension _WallSection on _OurNetAppState {
  WallContext get wallContext => WallContext(
    node: node,
    nameOf: name,
    avatar: (person, radius) => conversationAvatar(person, radius: radius),
    notice: notice,
    openWall: openWall,
  );

  /// Every followed wall, with a composer for this person's own.
  Widget wallSection(BuildContext context) =>
      WallPage(wall: wallContext, view: wallFeed, scope: scope);

  /// Posts and comments by others not yet looked at: the navigation's badge.
  int wallUnseen() =>
      memo('wallUnseen', () => wallFeed.loaded ? wallFeed.unseen() : 0);

  /// Opens [person]'s wall as a page of its own.
  void openWall(String person) {
    noteNavigator.currentState?.push(
      MaterialPageRoute<void>(
        builder: (_) => WallScreen(wall: wallContext, person: person),
      ),
    );
  }
}
