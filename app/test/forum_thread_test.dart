import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/ui/forum_thread.dart';
import 'package:ournet_core/ournet_core.dart';

void main() {
  test('post ages are short and then dated', () {
    final now = DateTime(2026, 10, 2, 12);
    expect(postAge(now.subtract(const Duration(seconds: 20)), now), 'now');
    expect(postAge(now.subtract(const Duration(minutes: 5)), now), '5m');
    expect(postAge(now.subtract(const Duration(hours: 3)), now), '3h');
    expect(postAge(now.subtract(const Duration(days: 2)), now), '2d');
    expect(postAge(DateTime(2026, 3, 12), now), '12 Mar');
    expect(postAge(DateTime(2024, 3, 12), now), '12 Mar 2024');
  });

  test('folding a post hides everything beneath it', () async {
    final node = Node(await LocalIdentity.create(), Store());
    final posts = <SignedObject>[];
    for (var i = 0; i < 6; i++) {
      posts.add(await node.publish('post', {'text': 'p$i'}, space: 'general'));
    }
    await node.close();
    // root
    //  ├ a (1)
    //  │  └ a1 (2)
    //  │     └ a2 (3)
    //  └ b (1)
    //     └ b1 (2)
    final depths = {
      posts[0].id: 0,
      posts[1].id: 1,
      posts[2].id: 2,
      posts[3].id: 3,
      posts[4].id: 1,
      posts[5].id: 2,
    };
    int depthOf(SignedObject o) => depths[o.id]!;

    final open = threadRows(posts, depthOf, {});
    expect(open.length, 6);
    expect(open[3].ancestors, [posts[0].id, posts[1].id, posts[2].id]);
    expect(open.map((r) => r.hasChildren), [
      true,
      true,
      true,
      false,
      true,
      false,
    ]);

    final folded = threadRows(posts, depthOf, {posts[1].id});
    expect(folded.map((r) => r.object.id), [
      posts[0].id,
      posts[1].id,
      posts[4].id,
      posts[5].id,
    ]);
    expect(folded[1].collapsed, isTrue);
    expect(folded[1].hidden, 2);
    expect(folded[1].hasChildren, isFalse);

    // The first post of a discussion cannot be folded.
    expect(threadRows(posts, depthOf, {posts[0].id}).length, 6);
  });
}
