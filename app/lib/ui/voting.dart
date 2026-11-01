part of 'app.dart';

extension _VotingPages on _OurNetAppState {
  /// Proposals with liquid delegation, in followed forums and groups.
  Widget voting(BuildContext context) =>
      LiquidPage(node: node, name: name, friends: people);
}
