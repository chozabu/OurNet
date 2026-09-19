import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/services/background_sync.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    IsolateNameServer.removePortNameMapping(profileOwner);
    onBackgroundSync = null;
  });

  Future<String?> ask(SendPort owner, String command) async {
    final reply = ReceivePort();
    owner.send([command, reply.sendPort]);
    final messages = await reply.take(2).toList();
    reply.close();
    return messages.last as String?;
  }

  test('the app waits for a background run to release the profile', () async {
    final background = ReceivePort();
    expect(
      IsolateNameServer.registerPortWithName(background.sendPort, profileOwner),
      isTrue,
    );
    var released = false;
    background.listen((message) {
      final reply = (message as List)[1] as SendPort;
      reply.send('ack');
      expect(message[0], 'yield');
      Timer(const Duration(milliseconds: 50), () {
        released = true;
        IsolateNameServer.removePortNameMapping(profileOwner);
        reply.send('done');
      });
    });
    await claimProfile();
    expect(released, isTrue);
    expect(
      IsolateNameServer.lookupPortByName(profileOwner),
      isNot(background.sendPort),
    );
    background.close();
  });

  test('an owner that no longer answers is replaced', () async {
    final gone = ReceivePort();
    IsolateNameServer.registerPortWithName(gone.sendPort, profileOwner);
    gone.close();
    final started = DateTime.now();
    await claimProfile();
    expect(DateTime.now().difference(started), lessThan(Duration(seconds: 5)));
    expect(IsolateNameServer.lookupPortByName(profileOwner), isNotNull);
  });

  test('a background run hands its sync to the owning app', () async {
    await claimProfile();
    var synced = 0;
    onBackgroundSync = (command) async {
      expect(command, 'sync');
      synced++;
    };
    final owner = IsolateNameServer.lookupPortByName(profileOwner)!;
    expect(await ask(owner, 'sync'), 'done');
    expect(synced, 1);
    // The app never gives up the profile it holds.
    expect(await ask(owner, 'yield'), 'done');
    expect(IsolateNameServer.lookupPortByName(profileOwner), owner);
  });
}
