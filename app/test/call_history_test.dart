import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/services/messaging.dart';
import 'package:ournet_core/ournet_core.dart';

void main() {
  test('a call entry reads right from each side', () {
    final missed = {'video': false, 'outcome': 'missed'};
    expect(callSummary(missed, mine: false), 'Missed call');
    expect(callSummary(missed, mine: true), 'Call · no answer');
    final answered = {'video': true, 'outcome': 'answered', 'seconds': 754};
    expect(callSummary(answered, mine: true), 'Outgoing video call · 12 min');
    expect(callSummary(answered, mine: false), 'Incoming video call · 12 min');
    final declined = {'video': false, 'outcome': 'declined'};
    expect(callSummary(declined, mine: true), 'Call declined');
    expect(callSummary(declined, mine: false), 'You declined a call');
    expect(callLength(42), '42 s');
    expect(callLength(3900), '1 h 5 min');
  });

  test('only missed calls are news', () {
    expect(
      quietCallEntry({
        'call': {'outcome': 'missed'},
      }),
      isFalse,
    );
    expect(
      quietCallEntry({
        'call': {'outcome': 'answered'},
      }),
      isTrue,
    );
    expect(quietCallEntry({'text': 'hello'}), isFalse);
  });

  test('a call entry is a message older builds can show', () async {
    final node = Node(await LocalIdentity.create(), Store());
    final friend = await LocalIdentity.create();
    await node.addContact(friend.certificate);
    final o = await sendCallRecord(
      node,
      friend.person,
      video: false,
      outcome: 'missed',
    );
    expect(o.kind, 'message');
    expect(o.audience, contains(friend.person));
    final content = await node.content(o);
    // Plain text for builds that know nothing of calls.
    expect(content!['text'], 'Missed call');
    expect(callEntry(content), {'video': false, 'outcome': 'missed'});
    expect(contentPreview(content), '📞 Missed call');
    await node.close();
  });
}
