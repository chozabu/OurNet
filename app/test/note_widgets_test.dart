import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/services/note_widgets.dart';
import 'package:ournet_core/ournet_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('widget cold drain, replay, hidden snapshots and deep links', () async {
    final a = Node(await LocalIdentity.create(), Store());
    final notes = Notes(a);
    final note = await notes.create(checklist: true);
    final check = note.checks.single;
    final opens = <String?>[], messages = <String>[];
    final service = NoteWidgets(notes, (id, _) async {
      opens.add(id);
    }, messages.add);
    final operation = {
      'id': 'tap-1',
      'note': note.id,
      'profile': service.profile,
      'epoch': note.epoch,
      'field': 'check:$check:done',
      'value': true,
      'parents': [],
    };
    var pending = <Map<String, dynamic>>[operation], ack = 0;
    Map<String, dynamic>? published;
    Map<String, dynamic>? launch = {
      'id': 'open-1',
      'note': note.id,
      'profile': service.profile,
    };
    var show = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(service.channel, (call) async {
          switch (call.method) {
            case 'state':
              return {
                'pending': pending,
                'launch': launch,
                'configs': [
                  {
                    'widget': 3,
                    'note': note.id,
                    'profile': service.profile,
                    'show': show,
                  },
                ],
              };
            case 'ack':
              ack++;
              pending = [];
              return null;
            case 'publish':
              published = Map<String, dynamic>.from(call.arguments);
              return null;
            case 'claim':
              launch = null;
              return null;
            default:
              return null;
          }
        });
    await service.drain();
    expect(ack, 1);
    expect(opens, [note.id]);
    expect((await notes.get(note.id))!.value('check:$check:done'), true);
    expect((published!['snapshots'] as List).single['checks'], isEmpty);
    expect((published!['snapshots'] as List).single['text'], '');
    final count = a.store.count;
    pending = [operation];
    show = true;
    await service.drain();
    expect(a.store.count, count);
    expect(opens.length, 1);
    expect(
      (published!['snapshots'] as List).single['checks'].single['done'],
      true,
    );
    await notes.edit(note.id, note.epoch, 'deleted', true, []);
    await service.drain();
    expect((published!['snapshots'] as List).single['available'], false);
    service.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(service.channel, null);
    await a.close();
  });

  test(
    'stale membership widget work is retained for review, never republished',
    () async {
      final a = Node(await LocalIdentity.create(), Store());
      final b = Node(await LocalIdentity.create(), Store());
      await a.addContact(b.identity.certificate);
      final notes = Notes(a);
      final note = await notes.create(checklist: true);
      final service = NoteWidgets(notes, (_, _) async {}, (_) {});
      await notes.changeMembers(note.id, [b.person]);
      var failed = false, ack = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(service.channel, (call) async {
            if (call.method == 'state') {
              return {
                'pending': [
                  {
                    'id': 'old',
                    'profile': service.profile,
                    'note': note.id,
                    'epoch': note.epoch,
                    'field': 'check:${note.checks.single}:done',
                    'value': true,
                    'parents': [],
                  },
                  {'id': 'other-profile', 'profile': 'another profile'},
                ],
                'configs': [],
              };
            }
            if (call.method == 'failed') failed = true;
            if (call.method == 'ack') ack = true;
            return null;
          });
      final count = a.store.count;
      await service.drain();
      expect(failed, true);
      expect(ack, false);
      expect(a.store.count, count);
      service.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(service.channel, null);
      await a.close();
      await b.close();
    },
  );

  test(
    'board lists pinned then recent notes and skips board configs',
    () async {
      final a = Node(await LocalIdentity.create(), Store());
      final notes = Notes(a);
      final older = await notes.create(title: 'Pinned list', items: ['Milk']);
      await notes.create(text: 'Recent thought', color: 'mint');
      await notes.pin(older.id, true);
      final service = NoteWidgets(notes, (_, _) async {}, (_) {});
      Map<String, dynamic>? published;
      var boards = <int>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(service.channel, (call) async {
            if (call.method == 'state') {
              return {
                'pending': [],
                'boards': boards,
                'configs': [
                  {
                    'widget': 7,
                    'kind': 'board',
                    'profile': service.profile,
                    'show': true,
                  },
                ],
              };
            }
            if (call.method == 'publish') {
              published = Map<String, dynamic>.from(call.arguments);
            }
            return null;
          });
      await service.drain();
      expect(published!['board'], isEmpty);
      expect(published!['snapshots'], isEmpty);
      boards = [7];
      await service.drain();
      final board = (published!['board'] as List).cast<Map>();
      expect(board.map((n) => n['title']), ['Pinned list', '']);
      expect(board.first['pinned'], true);
      expect(board.first['checks'].single['text'], 'Milk');
      expect(board.last['text'], 'Recent thought');
      expect(board.last['color'], isNot(0xffffffff));
      service.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(service.channel, null);
      await a.close();
    },
  );
}
