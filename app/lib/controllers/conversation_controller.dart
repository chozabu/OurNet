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

  /// Consumes new arrivals; returns the people who sent any of them.
  Future<Set<String>> refreshConversations() async {
    final arrivedFrom = <String>{};
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
        if (object.author != node.person) arrivedFrom.add(object.author);
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
          _insert(peer, loaded, object);
        }
      }
      await Future<void>.delayed(Duration.zero);
    }
    if (conversationCursor < end) conversationCursor = end;
    return arrivedFrom;
  }

  void _insert(String peer, List<SignedObject> loaded, SignedObject object) {
    // Ignore arrivals older than the loaded range until that page opens.
    if (loaded.isNotEmpty &&
        !conversationEnd.contains(peer) &&
        compareMessages(object, loaded.last) > 0) {
      return;
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

  /// Shows a message this person just sent at once, at the newest end,
  /// without waiting for the next refresh. The reader is taken there.
  void sent(String peer, SignedObject object) {
    if (conversationPending.contains(peer)) showLatest(peer);
    final loaded = conversationOlder[peer];
    if (loaded != null) _insert(peer, loaded, object);
  }

  final _keys = <String, GlobalKey>{};

  /// A key for a loaded message's row, so it can be scrolled into view.
  GlobalKey keyFor(String id) => _keys.putIfAbsent(id, GlobalKey.new);

  /// Loads older pages until [id] is in [peer]'s loaded window, up to
  /// [pages]. False when it is not found.
  bool loadUntil(String peer, String id, {int pages = 40}) {
    for (var i = 0; i < pages; i++) {
      if (messages(peer).any((o) => o.id == id)) return true;
      if (!hasOlder(peer)) return false;
      loadOlder(peer);
    }
    return messages(peer).any((o) => o.id == id);
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
    // Keys belong to loaded rows; drop those for rows no longer loaded.
    final loaded = {
      for (final list in conversationOlder.values)
        for (final o in list) o.id,
    };
    _keys.removeWhere((id, _) => !loaded.contains(id));
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
