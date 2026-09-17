import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';

void main() {
  late Node node;
  late NoteState state;
  setUp(() async {
    node = Node(await LocalIdentity.create(), Store());
    state = NoteState(node);
  });
  tearDown(() => node.close());

  /// Notes as the list shows them: by [NoteState.listKey], then ID.
  List<String> shown(Map<String, int> updated) {
    final ids = updated.keys.toList()
      ..sort((a, b) {
        final order = state
            .listKey(a, updated[a]!)
            .compareTo(state.listKey(b, updated[b]!));
        return order == 0 ? a.compareTo(b) : order;
      });
    return ids;
  }

  Future<int> move(Map<String, int> updated, String note, String target) async {
    final before = state.version;
    await state.move(
      [
        for (final id in shown(updated))
          (id: id, key: state.listKey(id, updated[id]!)),
      ],
      note,
      target,
      now: 5000000,
    );
    return state.version - before;
  }

  test('time keys sort newest first and are valid order keys', () {
    final older = NoteState.timeKey(1000, 'a');
    final newer = NoteState.timeKey(2000, 'a');
    expect(newer.compareTo(older), lessThan(0));
    expect(NoteState.timeKey(1000, 'b'), isNot(older));
    for (final key in [older, newer, NoteState.timeKey(0, '')]) {
      expect(key, matches(RegExp(r'^1[0-9A-Za-z]{11}$')));
      expect(key.endsWith('0'), false);
    }
    expect(
      validContent('note_self', {
        'target': 'n',
        'field': 'rank',
        'value': older,
        'parents': [],
        'clock': 1,
      }),
      true,
    );
  });

  test('moving among a thousand notes writes one key', () async {
    final updated = {for (var i = 0; i < 1000; i++) 'n$i': 1000000 + i * 10};
    final start = shown(updated);
    expect(start.first, 'n999');

    // Down the list, to the top, and to the end.
    expect(await move(updated, 'n999', 'n500'), 1);
    expect(await move(updated, 'n3', 'n998'), 1);
    expect(await move(updated, 'n998', 'n0'), 1);
    final expected = [...start]
      ..remove('n999')
      ..insert(start.indexOf('n500') - 1, 'n999')
      ..remove('n3')
      ..insert(0, 'n3')
      ..remove('n998')
      ..insert(998, 'n998');
    expect(shown(updated), expected);

    // A note edited later rises above moved notes; the rest keep their order.
    updated['n10'] = 6000000;
    expect(shown(updated), ['n10', ...expected..remove('n10')]);
  });

  test(
    'positions from older builds stay last and can be moved among',
    () async {
      final updated = {for (var i = 0; i < 6; i++) 'n$i': 1000 + i};
      final legacy = orderSequence(3);
      await state.setAll([
        ('order', 'n0', legacy[2]),
        ('order', 'n1', legacy[1]),
        ('order', 'n2', legacy[0]),
      ]);
      expect(shown(updated), ['n5', 'n4', 'n3', 'n2', 'n1', 'n0']);
      expect(await move(updated, 'n5', 'n1'), 1);
      expect(shown(updated), ['n4', 'n3', 'n2', 'n5', 'n1', 'n0']);
      expect(await move(updated, 'n0', 'n4'), 1);
      expect(shown(updated), ['n0', 'n4', 'n3', 'n2', 'n5', 'n1']);
    },
  );

  test('repeated moves into one gap keep keys short and writes few', () async {
    final updated = {for (var i = 0; i < 500; i++) 'n$i': 1000 + i};
    var most = 0;
    // Always place the next note directly after 'n499', so the same gap
    // keeps narrowing.
    for (var i = 0; i < 450; i++) {
      final order = shown(updated);
      final target = order[order.indexOf('n499') + 1];
      final writes = await move(updated, 'n$i', target);
      if (writes > most) most = writes;
      final after = shown(updated);
      expect(after[after.indexOf('n499') + 1], 'n$i');
    }
    for (final id in updated.keys) {
      expect(state.listKey(id, updated[id]!).length, lessThanOrEqualTo(64));
    }
    // The gap ran out at least once, and respacing stayed local.
    expect(most, inInclusiveRange(2, 40));
  });

  test('moved positions sync between own devices', () async {
    final fresh = await LocalIdentity.create();
    final laptop = Node(
      await fresh.enrol(await node.identity.authorise(fresh.certificate)),
      Store(),
    );
    addTearDown(laptop.close);
    await node.addContact(laptop.identity.certificate);
    await laptop.addContact(node.identity.certificate);
    final updated = {for (var i = 0; i < 5; i++) 'n$i': 1000 + i};
    await move(updated, 'n4', 'n1');
    await syncPair(node, laptop);
    final mine = NoteState(laptop);
    await mine.refresh();
    expect(mine.rank('n4'), state.rank('n4'));
    expect(
      [for (final id in shown(updated)) mine.listKey(id, updated[id]!)],
      [for (final id in shown(updated)) state.listKey(id, updated[id]!)],
    );
  });
}
