import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart';

/// Two local QUIC peers and the shipped VPN, with synthetic memory interfaces.
/// Build with tool/with-native-profile.ps1; run the executable without builds
/// or tests running alongside it. No personal profile or system VPN is used.
Future<void> main(List<String> args) async {
  try {
    await _run(args);
  } catch (error, stack) {
    stderr.writeln('$error\n$stack');
    exit(1);
  }
  // PluginHost's process-wide NativeCallable listener keeps an isolate alive
  // even after all plugins stop. This standalone CLI has finished cleanup.
  exit(0);
}

Future<void> _run(List<String> args) async {
  final dir = await Directory.systemTemp.createTemp('ournet-latency-');
  final a = Node(await LocalIdentity.create(), Store());
  final b = Node(await LocalIdentity.create(), Store());
  final na = PeerNetwork(a), nb = PeerNetwork(b);
  final pa = Plugins(a, directory: '${dir.path}/a');
  final pb = Plugins(b, directory: '${dir.path}/b');
  final subscriptions = <StreamSubscription<dynamic>>[];
  final results = <String, Object?>{
    'utc': DateTime.now().toUtc().toIso8601String(),
    'platform': Platform.operatingSystem,
    'dart': Platform.version,
    'build': 'Dart AOT executable, release native profile',
    'scope':
        'Two peers in one process, local QUIC, memory TUN; no Flutter UI, '
        'system adapter, relay or WAN. RTT, not one-way latency.',
  };
  Future<void> until(bool Function() ready) async {
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (!ready()) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('Timed out waiting for VPN readiness');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<void> measure(
    String name,
    Future<void> Function() send, {
    int count = 100,
  }) async {
    stderr.writeln('Measuring $name');
    final samples = <double>[];
    for (var i = 0; i < count; i++) {
      final clock = Stopwatch()..start();
      await send();
      samples.add(clock.elapsedMicroseconds / 1000);
    }
    samples.sort();
    results[name] = {
      'samples': count,
      'minMs': samples.first,
      'medianMs': samples[(count - 1) ~/ 2],
      'p95Ms': samples[(count * .95).ceil() - 1],
      'maxMs': samples.last,
    };
  }

  try {
    stderr.writeln('Starting local peers');
    await na.start(local: true, automatic: false);
    await nb.start(local: true, automatic: false);
    // iroh discovers its local sockets asynchronously after bind.
    await Future<void>.delayed(const Duration(seconds: 1));
    await na.addCard(nb.contactCard());
    await nb.addCard(na.contactCard());
    stderr.writeln('Synchronizing local peers');
    await na.sync(b.identity.device);
    if (na.syncErrors.isNotEmpty) throw StateError('${na.syncErrors}');
    await measure('requestRtt', () async {
      if (await na.ping(b.identity.device) == null) {
        throw StateError('Ping failed');
      }
    });

    Completer<void>? datagramReply;
    var sequence = 0;
    var datagramBytes = 4;
    nb.node.registry.handleDatagrams('latency', (device, data) {
      unawaited(nb.datagram(device, 'latency', data));
    }, owner: 'latency-benchmark');
    na.node.registry.handleDatagrams('latency', (_, data) {
      if (data.length == datagramBytes &&
          ByteData.sublistView(data).getUint32(0) == sequence) {
        datagramReply?.complete();
        datagramReply = null;
      }
    }, owner: 'latency-benchmark');
    Future<void> datagram() async {
      final reply = datagramReply = Completer<void>();
      final payload = Uint8List(datagramBytes);
      ByteData.sublistView(payload).setUint32(0, ++sequence);
      if (!await na.datagram(b.identity.device, 'latency', payload)) {
        throw StateError('Datagram send failed');
      }
      await reply.future.timeout(const Duration(seconds: 5));
    }

    await measure('coldDatagramRtt', datagram, count: 1);
    await measure('warmDatagramRtt', datagram);
    datagramBytes = 1000;
    await measure('warmDatagram1000ByteRtt', datagram);
    pa.link = na;
    pb.link = nb;
    final package = PluginPackage.read(
      await File('../app/assets/plugins/vpn.ournet-plugin').readAsBytes(),
    );
    for (final p in [pa, pb]) {
      stderr.writeln('Installing VPN for ${p == pa ? 'a' : 'b'}');
      p.openTun = (_, _) async => {'memory': true};
      await p.install(package, grants: package.manifest.grants);
      await until(() {
        if (p['vpn']?.status == PluginStatus.failed) {
          throw StateError('${p['vpn']!.error}');
        }
        return p['vpn']?.status == PluginStatus.running;
      });
    }
    // Exchange the capabilities advertised by both installed plugins before
    // the VPN takes its peer snapshot.
    await na.sync(b.identity.device);
    await nb.sync(a.identity.device);
    stderr.writeln('Starting VPN interfaces');
    for (final p in [pa, pb]) {
      p.event('vpn', 'Vpn', 'toggle', {});
      await until(
        () => '${p.surface('vpn', 'Vpn')['status']}'.startsWith('On'),
      );
    }
    pa.event('vpn', 'Vpn', 'allow', {'person': b.person});
    pb.event('vpn', 'Vpn', 'allow', {'person': a.person});
    for (final p in [pa, pb]) {
      await until(
        () =>
            (p.surface('vpn', 'Vpn')['peers'] as List?)?.any(
              (dynamic peer) => peer['allow'] == 'Allowed',
            ) ??
            false,
      );
    }
    Completer<void>? vpnReply;
    var vpnSequence = 0;
    subscriptions.add(
      pb.tunPackets.listen((received) {
        final reply = Uint8List.fromList(received.packet);
        reply.setRange(12, 16, received.packet.sublist(16, 20));
        reply.setRange(16, 20, received.packet.sublist(12, 16));
        pb.tunReceive('vpn', reply);
      }),
    );
    subscriptions.add(
      pa.tunPackets.listen((received) {
        final packet = received.packet;
        if (packet.length == 1000 &&
            ByteData.sublistView(packet).getUint32(20) == vpnSequence) {
          vpnReply?.complete();
          vpnReply = null;
        }
      }),
    );
    final packet = Uint8List(1000)..[0] = 0x45;
    ByteData.sublistView(packet).setUint16(2, packet.length);
    packet[8] = 64;
    packet[9] = 17;
    packet.setRange(12, 16, _address(a.identity.device));
    packet.setRange(16, 20, _address(b.identity.device));
    Future<void> vpn() async {
      final reply = vpnReply = Completer<void>();
      ByteData.sublistView(packet).setUint32(20, ++vpnSequence);
      pa.tunReceive('vpn', packet);
      await reply.future.timeout(const Duration(seconds: 5));
    }

    await vpn(); // Warm plugin and interface paths outside the measured phase.
    await measure('warmVpn1000ByteRtt', vpn);
    // Synthetic network load, not a Flutter responsiveness measurement.
    b.registry.handleDatagrams('load', (_, _) {}, owner: 'latency-benchmark');
    var attempted = 0, accepted = 0;
    final pending = <Future<void>>{};
    final loadPacket = Uint8List(1000);
    final load = Timer.periodic(const Duration(milliseconds: 1), (_) {
      if (pending.length >= 8) return;
      for (var i = 0; i < 8; i++) {
        attempted++;
        late final Future<void> job;
        job = na
            .datagram(b.identity.device, 'load', loadPacket)
            .then((sent) {
              if (sent) accepted++;
            })
            .whenComplete(() {
              pending.remove(job);
            });
        pending.add(job);
      }
    });
    try {
      await measure('vpn1000ByteRttDuringDatagramLoad', vpn, count: 1000);
    } finally {
      load.cancel();
      await Future.wait(pending.toList());
    }
    results['backgroundLoad'] = {
      'attemptedPackets': attempted,
      'acceptedPackets': accepted,
      'packetBytes': loadPacket.length,
      'note': 'Accepted by local transport; delivery is not acknowledged.',
    };
    // Use the real encrypted attachment chunk-serving path, with two bounded
    // workers. Fixture creation and metadata sync are outside the timed phase.
    final source = File('${dir.path}/bulk.bin');
    await source.writeAsBytes(List.generate(1024 * 1024, (i) => i % 251));
    final object = await Files(
      b,
      nb,
    ).publish(source.path, audience: [a.person]);
    await nb.sync(a.identity.device);
    if (a.store.get(object.id) == null)
      throw StateError('Bulk fixture not synced');
    final payload = (await b.content(object))!;
    final hashes = payload['chunks'] as List;
    var loading = true;
    var batches = 0, bulkBytes = 0;
    final bulkErrors = <Object>[];
    final firstBatch = Completer<void>();
    Future<void> bulk() async {
      try {
        while (loading) {
          final (header, data) = await na.requestBytes(b.identity.device, {
            'type': 'blobs',
            'object': object.id,
            'hashes': hashes,
          });
          final sizes = (header['sizes'] as List).cast<int>();
          if (sizes.length != hashes.length ||
              sizes.any((size) => size <= 0) ||
              sizes.fold(0, (a, b) => a + b) != data.length) {
            throw StateError('Incomplete bulk response');
          }
          batches++;
          bulkBytes += data.length;
          if (!firstBatch.isCompleted) firstBatch.complete();
        }
      } catch (error) {
        bulkErrors.add(error);
        if (!firstBatch.isCompleted) firstBatch.completeError(error);
      }
    }

    final workers = [bulk(), bulk()];
    try {
      await firstBatch.future;
      await measure('requestRttDuringBulk', () async {
        if (await na.ping(b.identity.device) == null)
          throw StateError('Ping failed');
      });
      await measure('vpn1000ByteRttDuringBulk', vpn);
    } finally {
      loading = false;
      await Future.wait(workers);
    }
    if (bulkErrors.isNotEmpty)
      throw StateError('Bulk traffic failed: $bulkErrors');
    results['bulkLoad'] = {
      'workers': 2,
      'completedBatches': batches,
      'receivedBytes': bulkBytes,
    };
    results['rssMiB'] = ProcessInfo.currentRss / (1024 * 1024);
    final report = const JsonEncoder.withIndent('  ').convert(results);
    stdout.writeln(report);
    if (args.isNotEmpty) await File(args.first).writeAsString('$report\n');
  } finally {
    stderr.writeln('Closing temporary peers');
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    await pa.close();
    await pb.close();
    await Future.wait([na.stop(), nb.stop()]);
    await a.close();
    await b.close();
    await dir.delete(recursive: true);
  }
}

List<int> _address(String device) {
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(device)) {
    hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
  }
  return [10, 77, 1 + hash % 254, 1 + (hash >> 8) % 254];
}
