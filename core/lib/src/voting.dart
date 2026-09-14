import 'model.dart';

/// Resolve latest signed votes and topic delegations. A direct vote wins over
/// delegation; cycles and dangling delegations contribute no vote.
Map<String, int> effectiveVotes(
  String objectId,
  String space,
  List<SignedObject> objects,
) {
  final sorted = objects.toList()
    ..sort((a, b) {
      final time = b.created.compareTo(a.created);
      return time != 0 ? time : b.id.compareTo(a.id);
    });
  final direct = <String, int>{}, delegations = <String, String>{};
  for (final o in sorted.where((o) => o.isPublic && o.space == space)) {
    final p = o.data['payload'] as Json;
    if (o.kind == 'vote' &&
        p['object'] == objectId &&
        [-1, 0, 1].contains(p['value']))
      direct.putIfAbsent(o.author, () => p['value'] as int);
    if (o.kind == 'delegate' && p['person'] is String)
      delegations.putIfAbsent(o.author, () => p['person']);
  }
  int resolve(String person, Set<String> visited) {
    if (!visited.add(person)) return 0;
    if (direct.containsKey(person)) return direct[person]!;
    final next = delegations[person];
    return next == null || next.isEmpty ? 0 : resolve(next, visited);
  }

  return {
    for (final person in {...direct.keys, ...delegations.keys})
      person: resolve(person, {}),
  };
}
