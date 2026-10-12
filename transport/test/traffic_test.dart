import 'package:ournet_transport/ournet_transport.dart';
import 'package:test/test.dart';

void main() {
  test('exchanges and wire bytes add up, and survive saving', () {
    Map<String, Object?>? saved;
    final stats = TrafficStats()..onSave = (json) => saved = json;
    stats.recordExchange(
      device: 'd1',
      type: 'pull',
      outbound: true,
      sent: 100,
      received: 900,
      took: const Duration(milliseconds: 40),
    );
    stats.recordExchange(device: 'd1', type: 'push', outbound: false, sent: 5, received: 50);
    stats.recordWire('d1', 2000, 3000);

    expect(stats.payload.tx, 105);
    expect(stats.payload.rx, 950);
    expect(stats.payload.n, 2);
    expect(stats.devices['d1']!.latencyMs, closeTo(40, 0.01));
    expect(stats.wireNow().total, 5000);

    stats.flush();
    final reloaded = TrafficStats()..load(saved);
    expect(reloaded.payload.total, stats.payload.total);
    expect(reloaded.wire.rx, 3000);
    expect(reloaded.requestsOut['pull']!.n, 1);
    expect(reloaded.days.values.single.wire, 5000);
  });

  test('unknown request types cannot grow the table without bound', () {
    final stats = TrafficStats();
    for (var i = 0; i < 200; i++) {
      stats.recordExchange(type: 't$i', outbound: false, sent: 1, received: 1);
    }
    expect(stats.requestsIn.length, lessThanOrEqualTo(49));
  });
}
