import 'package:flutter_test/flutter_test.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet/services/share_inbox.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'interrupted Android shares retain staged files and do not duplicate text',
    () async {
      final node = Node(await LocalIdentity.create(), Store());
      var acknowledged = false, fail = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ShareInbox.channel, (call) async {
            if (call.method == 'ack') {
              acknowledged = true;
              return null;
            }
            return acknowledged
                ? []
                : [
                    {
                      'id': 'share-1',
                      'text': 'A receipt',
                      'error': '',
                      'files': [
                        {'path': 'staged', 'name': 'receipt.jpg'},
                      ],
                    },
                  ];
          });
      final inbox = ShareInbox(node, (path, name) async {
        if (fail) throw StateError('Storage full');
      }, (_) {});
      await inbox.start();
      expect(acknowledged, false);
      expect(await Everyday(node).items(), hasLength(1));
      fail = false;
      await inbox.drain();
      expect(acknowledged, true);
      expect(await Everyday(node).items(), hasLength(1));
      await inbox.drain();
      expect(await Everyday(node).items(), hasLength(1));
      inbox.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ShareInbox.channel, null);
      await node.close();
    },
  );
}
