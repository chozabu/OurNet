import 'package:flutter/widgets.dart';
import 'package:ournet_core/ournet_core.dart';

/// Retains loaded messages and scroll positions while consuming only new
/// arrivals. Navigation and message rendering do not own history pagination.
class ConversationController {
  final Node node;
  bool _disposed = false;
  ConversationController(this.node) {
    conversationCursor = node.store.insertionCursor;
  }
  final conversationOlder = <String, List<SignedObject>>{};
  final conversationEnd = <String>{};
  final conversationPending = <String>{};
  final conversationScroll = <String, ScrollController>{};
  int conversationCursor = 0;
  int compareMessages(SignedObject a, SignedObject b) {
    final time = b.created.compareTo(a.created);
    return time == 0 ? a.id.compareTo(b.id) : time;
  }

  Future<void> refreshConversations() async {
    final end = node.store.insertionCursor;
    while (!_disposed && conversationCursor < end) {
      final page = node.store.insertedAfter(conversationCursor, ['message']);
      if (page.isEmpty) break;
      for (final (cursor, object) in page) {
        conversationCursor = cursor;
        final peers = object.author == node.person
            ? object.audience
            : object.audience.contains(node.person)
            ? [object.author]
            : <String>[];
        for (final peer in peers) {
          final loaded = conversationOlder[peer];
          if (loaded == null) continue;
          final scroll = conversationScroll[peer];
          if (loaded.isNotEmpty &&
              (conversationPending.contains(peer) ||
                  scroll == null ||
                  !scroll.hasClients ||
                  scroll.offset > 16)) {
            // Do not move the reader's visible messages under background sync.
            // Keep only a dirty flag, not an unbounded queue of unseen arrivals.
            conversationPending.add(peer);
            continue;
          }
          // Ignore arrivals older than the loaded range until that page opens.
          if (loaded.isNotEmpty &&
              !conversationEnd.contains(peer) &&
              compareMessages(object, loaded.last) > 0) {
            continue;
          }
          var low = 0, high = loaded.length;
          while (low < high) {
            final mid = (low + high) ~/ 2;
            if (compareMessages(loaded[mid], object) < 0) {
              low = mid + 1;
            } else {
              high = mid;
            }
          }
          if (low == loaded.length || loaded[low].id != object.id) {
            loaded.insert(low, object);
          }
        }
      }
      await Future<void>.delayed(Duration.zero);
    }
    if (conversationCursor < end) conversationCursor = end;
  }

  ScrollController scrollFor(String peer) =>
      conversationScroll.putIfAbsent(peer, ScrollController.new);

  List<SignedObject> messages(String peer) =>
      conversationOlder.putIfAbsent(peer, () {
        final page = node.store.conversation(node.person, peer);
        if (page.length < 50) conversationEnd.add(peer);
        return page;
      });

  bool hasOlder(String peer) => !conversationEnd.contains(peer);
  bool hasPending(String peer) => conversationPending.contains(peer);

  void loadOlder(String peer) {
    final loaded = messages(peer);
    if (loaded.isEmpty || !hasOlder(peer)) return;
    final page = node.store.conversation(
      node.person,
      peer,
      before: loaded.last,
    );
    conversationOlder[peer] = [...loaded, ...page];
    if (page.length < 50) conversationEnd.add(peer);
  }

  void showLatest(String peer) {
    final page = node.store.conversation(node.person, peer);
    conversationOlder[peer] = page;
    conversationPending.remove(peer);
    if (page.length < 50) {
      conversationEnd.add(peer);
    } else {
      conversationEnd.remove(peer);
    }
  }

  void dispose() {
    _disposed = true;
    for (final controller in conversationScroll.values) {
      controller.dispose();
    }
  }
}
