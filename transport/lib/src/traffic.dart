import 'dart:async';
import 'dart:math';

/// Bytes sent and received, and how many exchanges they came from.
class ByteCount {
  int tx, rx, n;
  ByteCount([this.tx = 0, this.rx = 0, this.n = 0]);

  int get total => tx + rx;

  void add(int sent, int received, [int count = 0]) {
    tx += sent;
    rx += received;
    n += count;
  }

  List<int> toJson() => [tx, rx, n];

  static ByteCount parse(Object? json) {
    if (json is List && json.length >= 2 && json.every((e) => e is int)) {
      return ByteCount(json[0] as int, json[1] as int, json.length > 2 ? json[2] as int : 0);
    }
    return ByteCount();
  }
}

/// What has passed between this device and one other.
class DeviceTraffic {
  /// Request and reply bytes; [ByteCount.n] counts exchanges.
  final ByteCount payload = ByteCount();

  /// Bytes on the wire, including encryption and protocol overhead.
  final ByteCount wire = ByteCount();

  /// Smoothed time to answer a small request, this session.
  double? latencyMs;

  /// Quickest answer this session.
  int? bestMs;
  DateTime? lastExchange;
}

/// One day's traffic, in local time.
class DayTraffic {
  int payloadTx = 0, payloadRx = 0, wireTx = 0, wireRx = 0;
  int get payload => payloadTx + payloadRx;
  int get wire => wireTx + wireRx;
}

/// A rate in bytes per second.
class Rate {
  final double tx, rx;
  const Rate(this.tx, this.rx);
  static const zero = Rate(0, 0);
}

/// Counts what the network moves. Payload bytes are the requests and replies
/// themselves, counted as they finish; wire bytes come from the QUIC
/// connections and include everything around them. Nothing here runs on a
/// timer unless a screen is watching, and the totals are saved a while after
/// they change, so it costs nothing when idle.
class TrafficStats {
  static const historyLength = 120;
  static const keepDays = 60;
  static const _maxTypes = 48;
  static const _maxDevices = 256;

  /// Where the totals are kept, and the wire total of connections still open.
  void Function(Map<String, Object?> json)? onSave;
  ByteCount Function()? openWire;

  /// When this session began.
  final DateTime started = DateTime.now();

  /// When the lifetime totals began.
  DateTime since = DateTime.now();

  final ByteCount payload = ByteCount();
  final ByteCount wire = ByteCount();
  final ByteCount sessionPayload = ByteCount();
  final ByteCount sessionWire = ByteCount();
  final Map<String, DeviceTraffic> devices = {};
  final Map<String, ByteCount> requestsOut = {};
  final Map<String, ByteCount> requestsIn = {};
  final Map<String, DayTraffic> days = {};

  /// This session only.
  int failed = 0, refused = 0, dialFailures = 0, inboundConnections = 0;

  DeviceTraffic _device(String id) {
    final known = devices[id];
    if (known != null) return known;
    if (devices.length >= _maxDevices) {
      // Never reached by admitted devices in practice; stop growth anyway.
      return devices['other'] ??= DeviceTraffic();
    }
    return devices[id] = DeviceTraffic();
  }

  ByteCount _type(Map<String, ByteCount> map, String type) {
    final key = map.containsKey(type) || map.length < _maxTypes ? type : 'other';
    return map[key] ??= ByteCount();
  }

  String? _dayKey;
  DateTime _dayKeyUntil = DateTime.fromMillisecondsSinceEpoch(0);

  DayTraffic _today() {
    final now = DateTime.now();
    if (_dayKey == null || !now.isBefore(_dayKeyUntil)) {
      String two(int v) => v.toString().padLeft(2, '0');
      _dayKey = '${now.year}-${two(now.month)}-${two(now.day)}';
      _dayKeyUntil = DateTime(now.year, now.month, now.day + 1);
    }
    final day = days[_dayKey!] ??= DayTraffic();
    if (days.length > keepDays) {
      final keys = days.keys.toList()..sort();
      for (final key in keys.take(days.length - keepDays)) {
        days.remove(key);
      }
    }
    return day;
  }

  /// One request and its reply. [outbound] is true when this device asked.
  void recordExchange({
    String? device,
    required String type,
    required bool outbound,
    required int sent,
    required int received,
    Duration? took,
  }) {
    payload.add(sent, received, 1);
    sessionPayload.add(sent, received, 1);
    _type(outbound ? requestsOut : requestsIn, type).add(sent, received, 1);
    _today()
      ..payloadTx += sent
      ..payloadRx += received;
    if (device != null) {
      final d = _device(device);
      d.payload.add(sent, received, 1);
      d.lastExchange = DateTime.now();
      if (outbound && took != null && type != 'blob' && type != 'blobs') {
        final ms = took.inMicroseconds / 1000;
        final old = d.latencyMs;
        d.latencyMs = old == null ? ms : old * 0.7 + ms * 0.3;
        d.bestMs = min(d.bestMs ?? 1 << 30, ms.round());
      }
    }
    _changed();
  }

  /// The final counters of a connection that has ended.
  void recordWire(String? device, int tx, int rx) {
    if (tx <= 0 && rx <= 0) return;
    wire.add(tx, rx);
    sessionWire.add(tx, rx);
    _today()
      ..wireTx += tx
      ..wireRx += rx;
    if (device != null) _device(device).wire.add(tx, rx);
    _changed();
  }

  /// Wire totals including connections still open.
  ByteCount wireNow({bool session = false}) {
    final base = session ? sessionWire : wire;
    final open = openWire?.call();
    return open == null
        ? ByteCount(base.tx, base.rx, base.n)
        : ByteCount(base.tx + open.tx, base.rx + open.rx, base.n);
  }

  // --- Live rates, sampled only while something watches ---

  final List<Rate> history = [];
  final _ticks = StreamController<void>.broadcast();
  Stream<void> get ticks => _ticks.stream;
  Timer? _timer;
  int _watchers = 0;
  ByteCount? _last;
  DateTime? _lastAt;

  /// Starts sampling once a second until the returned function is called.
  void Function() watch() {
    if (_watchers++ == 0) {
      history.clear();
      _last = wireNow(session: true);
      _lastAt = DateTime.now();
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => _sample());
    }
    var released = false;
    return () {
      if (released) return;
      released = true;
      if (--_watchers == 0) {
        _timer?.cancel();
        _timer = null;
      }
    };
  }

  void _sample() {
    final now = DateTime.now(), cur = wireNow(session: true);
    final last = _last, lastAt = _lastAt;
    _last = cur;
    _lastAt = now;
    if (last != null && lastAt != null) {
      final dt = max(0.001, now.difference(lastAt).inMicroseconds / 1e6);
      history.add(Rate(max(0, cur.tx - last.tx) / dt, max(0, cur.rx - last.rx) / dt));
      if (history.length > historyLength) {
        history.removeRange(0, history.length - historyLength);
      }
    }
    if (!_ticks.isClosed) _ticks.add(null);
  }

  /// The rate over the last few samples.
  Rate get rate {
    if (history.isEmpty) return Rate.zero;
    final recent = history.sublist(max(0, history.length - 3));
    return Rate(
      recent.fold(0.0, (s, r) => s + r.tx) / recent.length,
      recent.fold(0.0, (s, r) => s + r.rx) / recent.length,
    );
  }

  // --- Saving ---

  Timer? _saving;

  void _changed() {
    _saving ??= Timer(const Duration(seconds: 30), flush);
  }

  /// Saves the totals now.
  void flush() {
    _saving?.cancel();
    _saving = null;
    try {
      onSave?.call(toJson());
    } catch (_) {
      // The profile closed first; counters are a view, not a record.
    }
  }

  /// Starts the lifetime counters again from zero.
  void reset() {
    payload
      ..tx = 0
      ..rx = 0
      ..n = 0;
    wire
      ..tx = 0
      ..rx = 0
      ..n = 0;
    devices.clear();
    requestsOut.clear();
    requestsIn.clear();
    days.clear();
    since = DateTime.now();
    flush();
  }

  Map<String, Object?> toJson() => {
    'v': 1,
    'since': since.millisecondsSinceEpoch,
    'p': payload.toJson(),
    'w': wire.toJson(),
    'dev': {
      for (final e in devices.entries)
        e.key: {'p': e.value.payload.toJson(), 'w': e.value.wire.toJson()},
    },
    'out': {for (final e in requestsOut.entries) e.key: e.value.toJson()},
    'in': {for (final e in requestsIn.entries) e.key: e.value.toJson()},
    'days': {
      for (final e in days.entries)
        e.key: [e.value.payloadTx, e.value.payloadRx, e.value.wireTx, e.value.wireRx],
    },
  };

  void load(Object? json) {
    if (json is! Map) return;
    if (json['since'] case final int ms) {
      since = DateTime.fromMillisecondsSinceEpoch(ms);
    }
    final p = ByteCount.parse(json['p']), w = ByteCount.parse(json['w']);
    payload.add(p.tx, p.rx, p.n);
    wire.add(w.tx, w.rx, w.n);
    if (json['dev'] case final Map dev) {
      for (final e in dev.entries) {
        if (e.key is! String || e.value is! Map) continue;
        final d = _device(e.key as String);
        final v = e.value as Map;
        final dp = ByteCount.parse(v['p']), dw = ByteCount.parse(v['w']);
        d.payload.add(dp.tx, dp.rx, dp.n);
        d.wire.add(dw.tx, dw.rx, dw.n);
      }
    }
    for (final (key, into) in [('out', requestsOut), ('in', requestsIn)]) {
      if (json[key] case final Map m) {
        for (final e in m.entries) {
          if (e.key is String) into[e.key as String] = ByteCount.parse(e.value);
        }
      }
    }
    if (json['days'] case final Map m) {
      for (final e in m.entries) {
        final v = e.value;
        if (e.key is! String || v is! List || v.length < 4) continue;
        if (!v.every((x) => x is int)) continue;
        days[e.key as String] = DayTraffic()
          ..payloadTx = v[0] as int
          ..payloadRx = v[1] as int
          ..wireTx = v[2] as int
          ..wireRx = v[3] as int;
      }
    }
  }
}
