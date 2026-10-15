import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ournet/services/network.dart';
import 'package:ournet/services/undelivered.dart';
import 'package:ournet/services/wake.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart' show validWake;

/// Just enough of OurNetPushServer: registrations, grants and wakes.
class FakePushServer {
  final devices = <String, ({String secret, String fcm, Set<String> grants})>{};
  final requests = <(String, Json)>[];
  final wakes = <String>[];
  var next = 0;

  /// Answers wakes with this status instead, when set.
  int? wakeStatus;

  late final client = MockClient((request) async {
    final body = jsonDecode(request.body) as Json;
    requests.add((request.url.path, body));
    http.Response reply(int status, Object json) =>
        http.Response(jsonEncode(json), status);
    final device = devices[body['device']];
    bool admin() => device != null && device.secret == body['secret'];
    switch (request.url.path) {
      case '/v1/register' when body['device'] == null:
        final id = 'device${next++}'.padRight(22, 'x');
        final secret = 's${next++}'.padRight(43, 'x');
        devices[id] = (secret: secret, fcm: body['fcm'] as String, grants: {});
        return reply(201, {'device': id, 'secret': secret});
      case '/v1/register':
        if (device == null) return reply(404, {'error': 'Unknown device'});
        if (!admin()) return reply(403, {'error': 'Wrong secret'});
        devices[body['device'] as String] = (
          secret: device.secret,
          fcm: body['fcm'] as String,
          grants: device.grants,
        );
        return reply(200, {'device': body['device']});
      case '/v1/grants':
        if (!admin()) return reply(403, {'error': 'Wrong secret'});
        device!.grants
          ..clear()
          ..addAll((body['replace'] as List).cast<String>());
        return reply(200, {'grants': device.grants.length});
      case '/v1/unregister':
        if (!admin()) return reply(403, {'error': 'Wrong secret'});
        devices.remove(body['device']);
        return reply(200, {});
      case '/v1/wake':
        if (wakeStatus case final status?) return reply(status, {});
        final hash = sha256
            .convert(utf8.encode(body['token'] as String))
            .toString();
        if (device == null || !device.grants.contains(hash)) {
          return reply(403, {'error': 'Not allowed'});
        }
        wakes.add(body['device'] as String);
        return reply(202, {});
    }
    return reply(404, {'error': 'Unknown endpoint'});
  });

  bool allows(Json address) =>
      devices[address['device']]?.grants.contains(
        sha256.convert(utf8.encode(address['token'] as String)).toString(),
      ) ==
      true;
}

Future<Node> node(String label) async =>
    Node(await LocalIdentity.create(label: label), Store());

Future<void> befriend(Node a, Node b) async {
  await a.addContact(b.identity.certificate);
  await b.addContact(a.identity.certificate);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('friends learn each other\'s wake addresses as they sync', () async {
    final a = await node('A'), b = await node('B');
    final na = Network(a), nb = Network(b);
    addTearDown(() async {
      await na.stop();
      await nb.stop();
      await a.close();
      await b.close();
    });
    a.store.set('wakeRegistration', {
      'url': 'https://push.example',
      'device': 'aDeviceAtThePushServer',
      'secret': 'x' * 43,
      'key': 'k' * 43,
    });
    await na.start(local: true);
    await nb.start(local: true);
    await na.addCard(nb.contactCard());
    await nb.addCard(na.contactCard());

    await na.sync(b.identity.device);
    final told = b.store.setting('wake/${a.identity.device}');
    expect(told, wakeAddressFor(a, b.identity.device));
    expect(told, isNotNull);
    // B has no registration, so A holds none for it.
    expect(a.store.setting('wake/${b.identity.device}'), isNull);

    // Turned off: the next exchange makes B forget it.
    a.store.set('pushWake', false);
    await nb.sync(a.identity.device);
    expect(b.store.setting('wake/${a.identity.device}'), isNull);
  });

  test('a phone grants each friend device its own wake token', () async {
    final server = FakePushServer();
    final phone = await node('Phone');
    final sam = await node('Sam'), priya = await node('Priya');
    final stranger = await node('Stranger');
    addTearDown(() async {
      for (final n in [phone, sam, priya, stranger]) {
        await n.close();
      }
    });
    await befriend(phone, sam);
    await befriend(phone, priya);
    var fcm = 'fcm-1';
    final registration = WakeRegistration(
      phone,
      fcmToken: () async => fcm,
      client: server.client,
    );
    addTearDown(registration.close);

    expect(registration.addressFor(sam.identity.device), isNull);
    await registration.refresh();
    expect(registration.registered, isTrue);
    expect(server.devices.values.single.fcm, 'fcm-1');

    final toSam = registration.addressFor(sam.identity.device)!;
    final toPriya = registration.addressFor(priya.identity.device)!;
    expect(validWake(toSam), isTrue);
    expect(toSam['url'], defaultWakeServer);
    expect(toSam['token'], isNot(toPriya['token']));
    expect(server.allows(toSam), isTrue);
    expect(server.allows(toPriya), isTrue);
    expect(registration.addressFor(stranger.identity.device), isNull);
    // Only hashes reach the server.
    expect(
      server.devices.values.single.grants,
      isNot(contains(toSam['token'])),
    );

    // Nothing changed: no further requests.
    final sent = server.requests.length;
    await registration.refresh();
    expect(server.requests.length, sent);

    // Blocking Priya revokes her token and leaves Sam's.
    phone.block(priya.person, true);
    await registration.refresh();
    expect(server.allows(toPriya), isFalse);
    expect(server.allows(toSam), isTrue);
    expect(registration.addressFor(priya.identity.device), isNull);

    // A new FCM token is sent to the same registration.
    fcm = 'fcm-2';
    registration.tokenChanged(fcm);
    await registration.refresh();
    expect(server.devices.length, 1);
    expect(server.devices.values.single.fcm, 'fcm-2');
    expect(server.allows(toSam), isTrue);

    // A server that forgot the device gets a fresh registration and grants.
    server.devices.clear();
    phone.store.set('wakeRegistration', {
      ...registration.registration!,
      'renewed': 0,
    });
    await registration.refresh();
    expect(server.devices.length, 1);
    expect(
      server.allows(registration.addressFor(sam.identity.device)!),
      isTrue,
    );

    // Turning it off unregisters and stops telling friends.
    phone.store.set('pushWake', false);
    await registration.refresh();
    expect(server.devices, isEmpty);
    expect(registration.addressFor(sam.identity.device), isNull);
    expect(registration.registered, isFalse);
  });

  test('without an FCM token nothing is registered', () async {
    final server = FakePushServer();
    final phone = await node('Phone'), sam = await node('Sam');
    addTearDown(() async {
      await phone.close();
      await sam.close();
    });
    await befriend(phone, sam);
    final registration = WakeRegistration(
      phone,
      fcmToken: () async => null,
      client: server.client,
    );
    await registration.refresh();
    expect(server.requests, isEmpty);
    expect(wakeAddressFor(phone, sam.identity.device), isNull);
  });

  test('an undelivered message wakes the recipient once', () async {
    final server = FakePushServer();
    final alex = await node('Alex'), sam = await node('Sam');
    addTearDown(() async {
      await alex.close();
      await sam.close();
    });
    await befriend(alex, sam);
    final registration = WakeRegistration(
      sam,
      fcmToken: () async => 'fcm',
      client: server.client,
    );
    await registration.refresh();
    // What Sam's device tells Alex's in an exchange.
    alex.store.set(
      'wake/${sam.identity.device}',
      registration.addressFor(alex.identity.device),
    );

    final undelivered = Undelivered(alex)..start();
    final sender = WakeSender(
      alex,
      undelivered,
      client: server.client,
      grace: const Duration(milliseconds: 50),
    )..start();
    addTearDown(() async {
      await sender.close();
      undelivered.close();
    });

    await alex.publish(
      'message',
      {'text': 'Hello'},
      space: '_messages',
      audience: [sam.person],
    );
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(server.wakes, [registration.registration!['device']]);

    // A second message wakes again; the first is not repeated.
    await alex.publish(
      'message',
      {'text': 'Still there?'},
      space: '_messages',
      audience: [sam.person],
    );
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(server.wakes.length, 2);

    // Delivered before the grace period ends: no wake.
    await syncPair(alex, sam);
    await alex.publish(
      'message',
      {'text': 'Quick'},
      space: '_messages',
      audience: [sam.person],
    );
    await pumpEventQueue();
    await syncPair(alex, sam);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(server.wakes.length, 2);

    // A device gone from the server is forgotten.
    server.wakeStatus = 410;
    await alex.publish(
      'message',
      {'text': 'Gone?'},
      space: '_messages',
      audience: [sam.person],
    );
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(alex.store.setting('wake/${sam.identity.device}'), isNull);
  });

  test('wake addresses are checked before they are stored or sent', () {
    final ok = {'url': 'https://push.example', 'device': 'abc', 'token': 'def'};
    expect(validWake(ok), isTrue);
    expect(validWake({...ok, 'url': 'http://push.example'}), isFalse);
    expect(validWake({...ok, 'extra': 1}), isFalse);
    expect(validWake({...ok, 'token': 'x' * 129}), isFalse);
    expect(validWake({'url': ok['url'], 'device': 'abc'}), isFalse);
  });
}
