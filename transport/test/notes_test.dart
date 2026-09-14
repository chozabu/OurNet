import 'package:test/test.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';

void main() {
  test(
    'shared widget-style offline updates converge over real QUIC',
    () async {
      final a = Node(await LocalIdentity.create(), Store());
      final b = Node(await LocalIdentity.create(), Store());
      final na = PeerNetwork(a), nb = PeerNetwork(b);
      try {
        await na.start(local: true, automatic: false);
        await nb.start(local: true, automatic: false);
        await na.addCard(nb.contactCard());
        await nb.addCard(na.contactCard());
        final notes = Notes(a), other = Notes(b);
        var note = await notes.create(
          checklist: true,
          text: 'Packing together',
        );
        await notes.changeMembers(note.id, [b.person]);
        await na.sync(b.identity.device);
        note = (await notes.get(note.id))!;
        final received = (await other.get(note.id))!;
        await notes.edit(
          note.id,
          note.epoch,
          'check:${note.checks.single}:done',
          true,
          [],
          request: 'widget-offline-1',
        );
        await other.edit(
          received.id,
          received.epoch,
          'text',
          'Bring chargers too',
          received.parents('text'),
        );
        await na.sync(b.identity.device);
        expect((await notes.get(note.id))!.text, 'Bring chargers too');
        expect(
          (await other.get(note.id))!.value('check:${note.checks.single}:done'),
          true,
        );
        expect((await other.summaries()).single.data['entry'], note.id);
        await notes.changeMembers(note.id, []);
        await na.sync(b.identity.device);
        expect(await other.get(note.id), isNull);
      } finally {
        await na.stop();
        await nb.stop();
        await a.close();
        await b.close();
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
