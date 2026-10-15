import 'package:flutter/material.dart';
import 'package:ournet_core/ournet_core.dart';

class PlaceLinks extends InheritedWidget {
  final void Function(PlaceLink) open;
  const PlaceLinks({super.key, required this.open, required super.child});
  static PlaceLinks? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PlaceLinks>();
  @override
  bool updateShouldNotify(PlaceLinks oldWidget) => false;
}

class PlaceLinkChip extends StatelessWidget {
  final PlaceLink place;
  const PlaceLinkChip(this.place, {super.key});
  @override
  Widget build(BuildContext context) {
    final links = PlaceLinks.maybeOf(context);
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width * .6,
      ),
      child: ActionChip(
        avatar: Text(place.emoji),
        label: Text(
          place.name.isEmpty ? 'Shared place' : place.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        onPressed: links == null ? null : () => links.open(place),
      ),
    );
  }
}
