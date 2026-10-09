import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:iroh_quic/iroh_quic.dart' as iroh;
import 'package:ournet_core/ournet_core.dart';
import 'sync_queue.dart';

part 'pairing.dart';
part 'friend_invitation.dart';

/// The only application module that knows the iroh API. Protocol and policy
/// remain in the Dart core. Connections authenticate independent device keys.
class PeerNetwork {
  PairingSession? pairing;
  FriendSession? friendInvitation;
  final Node node;
  final updates = StreamController<void>.broadcast();
  void notifyListeners() {
    if (!updates.isClosed) updates.add(null);
  }

  /// This app's build stamp, sent to peers so either side can spot a
  /// mismatch. Empty for development builds.
  final String build;

  /// This app's release version (x.y.z), sent alongside [build]. Builds of
  /// one release differ per platform; the version says which side is older.
  final String version;

  PeerNetwork(this.node, {this.build = '', this.version = ''}) {
    final saved = node.store.setting('peerHealth');
    if (saved is Map) {
      for (final MapEntry(:key, :value) in saved.entries) {
        if (value is! Map) continue;
        if (value['synced'] case final int ms) {
          lastSync[key] = _savedSync[key] = DateTime.fromMillisecondsSinceEpoch(
            ms,
          );
        }
        if (value['build'] case final String b) peerBuilds[key] = b;
        if (value['version'] case final String v) peerVersions[key] = v;
      }
    }
    final marks = node.store.setting('syncMarks');
    if (marks is Map) {
      for (final MapEntry(:key, :value) in marks.entries) {
        if (_Mark.parse(value) case final mark?) _marks[key as String] = mark;
      }
    }
  }
  iroh.Endpoint? _endpoint;
  StreamSubscription<void>? _changes;
  StreamSubscription<void>? _relayStatus;
  Timer? _debounce;
  final Map<String, Timer> _retry = {};
  bool _automatic = true;
  Timer? _networkChange;
  Timer? _watchdog;
  DateTime? _relaysDownSince;

  /// A home relay has connected since the endpoint started.
  bool _relayWasUp = false;
  DateTime? _restartedAt;
  int _watchdogRestarts = 0;
  final Map<String, int> _failures = {};
  final Map<
    String,
    ({int window, InventoryCursor? local, InventoryCursor? remote})
  >
  _resume = {};
  final Set<String> _busy = {};
  final Set<iroh.Connection> _connections = {};
  final Set<Future<void>> _jobs = {};
  late final _syncQueue = SyncQueue(_sync);

  /// When each device last completed a sync; kept across restarts.
  final Map<String, DateTime> lastSync = {};

  /// Most recent exchange failure per device; success clears it.
  final Map<String, String> syncErrors = {};

  /// When a sync with each device was last attempted, in this session.
  final Map<String, DateTime> lastAttempt = {};

  /// When each device last reached this one with an admitted request.
  final Map<String, DateTime> lastInbound = {};

  /// Build stamp each device reported in its most recent exchange.
  final Map<String, String> peerBuilds = {};

  /// Release version each device reported; absent for builds that predate it.
  final Map<String, String> peerVersions = {};

  /// Inbound handshakes that failed since the network started. The accept
  /// loop survives them; the count shows whether peers are struggling.
  int acceptFailures = 0;
  String? lastAcceptError;

  /// Home relay connections; empty in local mode or before the first report.
  List<({String url, bool connected, String? error})> relays = const [];

  /// Whether this network uses relays and address lookup.
  bool local = false;

  final Map<String, DateTime> _heardAt = {};

  /// Devices a request failed to reach since they were last heard from.
  final Set<String> _outOfReach = {};

  /// Tells [peerSeen] about a device that is syncing with this one, at most
  /// once a minute each, unless it was out of reach in between: then it is
  /// back, and what waits for it (a last position) goes at once. Only syncs
  /// count: a position or typing request does not, or two devices would
  /// answer each other for ever.
  void _heard(String device) {
    final now = DateTime.now(), last = _heardAt[device];
    final back = _outOfReach.remove(device);
    if (peerSeen == null && peerSeenListeners.isEmpty ||
        !back && last != null && now.difference(last).inSeconds < 60) {
      return;
    }
    _heardAt[device] = now;
    peerSeen?.call(device);
    for (final listener in peerSeenListeners.toList()) {
      listener(device);
    }
  }

  /// When each device's [lastSync] was last written to the profile.
  final Map<String, DateTime> _savedSync = {};

  /// Persists a completed sync at most every few minutes per device: every
  /// sync would otherwise rewrite the setting (a disk sync each time). The
  /// newest time is written when the network stops.
  void _rememberSync(String device) {
    final saved = _savedSync[device];
    if (saved == null ||
        DateTime.now().difference(saved) >= const Duration(minutes: 5)) {
      _remember([device]);
    }
  }

  /// Writes the sync times not yet persisted, in one setting update.
  void _rememberUnsaved() {
    final unsaved = [
      for (final MapEntry(:key, :value) in lastSync.entries)
        if (_savedSync[key] != value) key,
    ];
    if (unsaved.isNotEmpty) _remember(unsaved);
  }

  void _remember(Iterable<String> devices) {
    final saved = Map<String, dynamic>.from(
      node.store.setting('peerHealth') as Map? ?? const {},
    );
    for (final device in devices) {
      final synced = lastSync[device];
      if (synced != null) _savedSync[device] = synced;
      final build = peerBuilds[device];
      final version = peerVersions[device];
      saved[device] = {
        if (synced != null) 'synced': synced.millisecondsSinceEpoch,
        if (build != null) 'build': build,
        if (version != null) 'version': version,
      };
    }
    node.store.set('peerHealth', saved);
  }

  /// Records the build and version a peer stated in a request or reply.
  void _notePeer(String device, Json message) {
    var changed = false;
    if (message['build'] case final String b
        when b.length <= 64 && peerBuilds[device] != b) {
      peerBuilds[device] = b;
      changed = true;
    }
    if (message['version'] case final String v
        when v.length <= 32 && peerVersions[device] != v) {
      peerVersions[device] = v;
      changed = true;
    }
    if (message['caps'] case final List c
        when c.length <= 32 && c.every((e) => e is String && e.length <= 32)) {
      peerCaps[device] = c.cast<String>().toSet();
    }
    if (changed) _remember([device]);
  }

  /// What this build can do beyond the base sync protocol. Peers ignore names
  /// they do not know, and a feature is used only when the peer lists it, so
  /// builds of any age keep syncing.
  ///
  /// `cursor_paging`: inventories page by (created, id) cursor.
  /// `blob_inline`: chunk bytes travel base64 in `blob` replies.
  /// `multi_request`: one connection serves several requests, one stream
  /// each, in turn; it waits [servedIdle] for the next.
  /// `since_sync`: answers `delta`, and `pull` limited to `only` some
  /// objects, so two devices that agreed before exchange only what changed.
  static const caps = [
    'cursor_paging',
    'blob_inline',
    'multi_request',
    'since_sync',
  ];

  /// Capabilities each peer last announced; empty for builds that predate them.
  final Map<String, Set<String>> peerCaps = {};

  /// Build, version and capability fields for outgoing sync messages.
  Json get _stamp => {
    if (build.isNotEmpty) 'build': build,
    if (version.isNotEmpty) 'version': version,
    'caps': caps,
  };

  final Map<String, int> _progress = {};

  /// Fires as syncs start, exchange pages and finish. Kept separate from
  /// [updates] so progress only rebuilds widgets that show it.
  final syncActivity = StreamController<void>.broadcast();

  /// Devices with a sync in progress, mapped to items exchanged so far.
  Map<String, int> get syncing => Map.unmodifiable(_progress);
  void _activity() {
    if (!syncActivity.isClosed) syncActivity.add(null);
  }

  final List<String> events = [];
  bool get running => _endpoint != null;
  String? error;
  int _activeInbound = 0;
  Future<Json> Function(String, Json)? signal;

  /// Called when a friend's device says its person is typing to this one.
  /// Only ever sent live; nothing is stored. Builds without it refuse the
  /// request, which the sender ignores.
  void Function(String device)? typing;

  /// Called when a friend's device (or one of this person's own) reports a
  /// position: the device and the fix as sent. Live only, never stored as an
  /// object or forwarded; builds without it refuse the request.
  void Function(String device, Object? fix)? position;

  /// Called when a device has just been heard from after being quiet, so
  /// whatever should reach it on reconnecting (a last position) can be sent.
  void Function(String device)? peerSeen;

  /// More [peerSeen] listeners, for features that share the one hook.
  final List<void Function(String device)> peerSeenListeners = [];

  /// Called with a friend's group-call message (presence, join, signalling):
  /// the device and the payload, returning the reply. Live only, never stored;
  /// builds without it refuse the request.
  Future<Json> Function(String device, Json payload)? groupCall;
  static final _alpn = utf8.encode('ournet/2');

  void log(String message) {
    events.insert(0, '${DateTime.now().toIso8601String()} $message');
    if (events.length > 100) events.removeLast();
    notifyListeners();
  }

  Future<void> _lifecycle = Future.value();
  Future<void> _transition(Future<void> Function() action) {
    final next = _lifecycle.then((_) => action());
    _lifecycle = next.catchError((Object _) {});
    return next;
  }

  // Camera/permission activities can pause and resume before bind or close
  // finishes. Keep endpoint ownership and subscriptions in transition order.
  Future<void> start({bool local = false, bool automatic = true}) =>
      _transition(() => _start(local: local, automatic: automatic));

  Future<void> _start({required bool local, required bool automatic}) async {
    if (running) return;
    try {
      await iroh.Iroh.init();
      _endpoint = await iroh.Endpoint.bind(
        secretKey: iroh.SecretKey.fromBytes(
          await node.identity.deviceKey.extractPrivateKeyBytes(),
        ),
        alpns: [_alpn],
        relayMode: local ? iroh.RelayMode.disabled : iroh.RelayMode.n0Default,
      );
      error = null;
      this.local = local;
      _automatic = automatic;
      _restartFailed = false;
      acceptFailures = 0;
      lastAcceptError = null;
      relays = const [];
      _relaysDownSince = null;
      _relayWasUp = false;
      if (!local) {
        _relayStatus = _endpoint!.homeRelayStatus().listen((status) {
          relays = [
            for (final r in status)
              (url: r.url, connected: r.connected, error: r.lastError),
          ];
          // Logged so that a message or call that did not arrive can be
          // matched to a gap in reachability (a sleeping phone, say).
          if (relays.any((r) => r.connected)) {
            final since = _relaysDownSince;
            if (since != null && _relayWasUp) {
              log(
                'Home relay back after '
                '${DateTime.now().difference(since).inSeconds} s',
              );
              // Devices that failed while this one was unreachable may be
              // fine; retry them now rather than when their backoff ends.
              for (final device in _failures.keys.toList()) {
                _retryNow(device);
              }
            }
            _relayWasUp = true;
            _relaysDownSince = null;
            _watchdogRestarts = 0;
          } else if (relays.isNotEmpty) {
            if (_relaysDownSince == null && _relayWasUp) {
              log('Home relay lost: ${relays.first.error ?? 'disconnected'}');
            }
            _relaysDownSince ??= DateTime.now();
          }
          notifyListeners();
        }, onError: (Object _) {});
        _watchdog = Timer.periodic(watchdogInterval, (_) => _checkRelays());
      }
      if (automatic)
        _changes = node.changes.stream.listen((_) {
          // A busy editor must not postpone delivery indefinitely. Batch from
          // the first change, rather than restarting the timer on every edit.
          _debounce ??= Timer(const Duration(milliseconds: 400), () {
            _debounce = null;
            for (final device in node.contacts.keys.toList()) {
              // A device that keeps failing is most likely switched off.
              // Dialling it on every edit costs a connection attempt (and a
              // radio wake) each time; its retry, its next request to this
              // device, or the relay coming back reaches it instead.
              if (_backingOff(device)) continue;
              unawaited(sync(device));
            }
          });
        });
      unawaited(_accept());
      log(local ? 'Local network started' : 'Network started');
      if (automatic) unawaited(syncAll());
    } catch (e) {
      error = '$e';
      log('Network unavailable: $e');
      rethrow;
    }
  }

  String contactCard() => canonical({
    'version': 2,
    'certificate': node.identity.certificate.toJson(),
    'address': _endpoint == null ? null : b64(_endpoint!.addr.encode()),
  });
  Future<void> addCard(String card) async {
    if (card.length > 16384) throw StateError('Contact card too large');
    final j = jsonDecode(card) as Json;
    if (j['version'] != 2) throw StateError('Unsupported contact card');
    final certificate = DeviceCertificate.fromJson(j['certificate']);
    if (j['address'] != null) {
      await iroh.Iroh.init();
      final address = iroh.EndpointAddr.decode(unb64(j['address']));
      if (b64(address.id.asBytes()) != certificate.device) {
        throw StateError('Address does not match device');
      }
    }
    await node.addContact(certificate);
    if (j['address'] != null) {
      node.store.set('address/${certificate.device}', j['address']);
    }
    log('Contact device added: ${certificate.label}');
  }

  /// Known addresses for the certificates [Node.sharedCertificates] offers.
  Map<String, String> _sharedAddresses(String device) {
    final peer = node.contacts[device];
    if (peer == null) return const {};
    final self = _endpoint;
    final addresses = <String, String>{};
    for (final wire in node.sharedCertificates(peer)) {
      final id = DeviceCertificate.fromJson(wire).device;
      final address = id == node.identity.device
          ? (self == null ? null : b64(self.addr.encode()))
          : node.store.setting('address/$id');
      if (address is String) addresses[id] = address;
    }
    return addresses;
  }

  /// Stores address hints for admitted devices, from [peer]'s exchange. A
  /// device's own address replaces what is stored, so a device that moves
  /// stays reachable; hints about other devices only fill a gap, so no peer
  /// can redirect the rest.
  Future<void> _learnAddresses(String peer, Object? shared) async {
    if (shared is! Map || shared.length > Node.maxSharedCertificates) return;
    for (final MapEntry(:key, :value) in shared.entries) {
      if (key is! String ||
          value is! String ||
          value.length > 4096 ||
          !node.contacts.containsKey(key) ||
          (key != peer && node.store.setting('address/$key') != null)) {
        continue;
      }
      try {
        final address = iroh.EndpointAddr.decode(unb64(value));
        if (b64(address.id.asBytes()) == key) {
          node.store.set('address/$key', value);
        }
      } catch (_) {}
    }
  }

  /// Outgoing connections opened since this network was created.
  int dialed = 0;

  Future<iroh.Connection> _connect(String device) async {
    if (!node.allowedPeer(device)) throw StateError('Device not admitted');
    final ep = _endpoint;
    if (ep == null) throw StateError('Network is stopped');
    dialed++;
    final encoded = node.store.setting('address/$device') as String?;
    final address = encoded == null
        ? iroh.EndpointAddr(iroh.PublicKey.fromBytes(unb64(device)))
        : iroh.EndpointAddr.decode(unb64(encoded));
    var abandoned = false;
    final pending = ep.connect(address, _alpn).then((connection) {
      if (abandoned || !identical(ep, _endpoint)) {
        connection.close();
        throw StateError('Connection cancelled');
      }
      return connection;
    });
    try {
      return await pending.timeout(const Duration(seconds: 15));
    } catch (_) {
      abandoned = true;
      rethrow;
    }
  }

  /// How long a pooled connection is kept after its last request, and how
  /// long a served connection waits for the next one. iroh keeps an open
  /// connection alive with a packet every 5 s, so both stay short: long
  /// enough for a sync session's pages or a file's chunks to follow each
  /// other, and within the time a phone's radio stays up after sending.
  static const pooledIdle = Duration(seconds: 3);
  static const servedIdle = Duration(seconds: 5);

  /// Requests that may share a connection. Each is safe to send again, which
  /// a pooled connection closed by its peer just as it was reused needs.
  static const _poolable = {
    'pull',
    'push',
    'delta',
    'blob',
    'position',
    'typing',
  };
  final Map<String, _Pooled> _pool = {};
  final Set<String> _dialing = {};

  Future<Json> request(String device, Json request) async {
    try {
      return await _request(device, request);
    } on StateError {
      // A refusal, or a request never sent: not a sign of being out of reach.
      rethrow;
    } catch (_) {
      _outOfReach.add(device);
      rethrow;
    }
  }

  Future<Json> _request(String device, Json request) async {
    Json? reply;
    if (_poolable.contains(request['type']) &&
        peerCaps[device]?.contains('multi_request') == true) {
      final pooled = await _pooledFor(device);
      if (pooled != null) {
        final reused = pooled.uses++ > 0;
        try {
          reply = await _exchange(pooled.connection, request);
        } on TimeoutException {
          _drop(device, pooled);
          rethrow;
        } catch (_) {
          _drop(device, pooled);
          // A reused connection may have been closed by the peer while idle;
          // the request never reached it, so send it on a new connection.
          if (!reused) rethrow;
        } finally {
          _release(device, pooled);
        }
      }
    }
    if (reply == null) {
      final connection = await _connect(device);
      _connections.add(connection);
      try {
        reply = await _exchange(connection, request);
      } finally {
        connection.close();
        _connections.remove(connection);
      }
    }
    // Refusals carry the stamp too, so an incompatible peer is identifiable.
    if (node.contacts.containsKey(device)) _notePeer(device, reply);
    if (reply['error'] != null) throw StateError(reply['error']);
    return reply;
  }

  Future<Json> _exchange(iroh.Connection connection, Json request) async {
    final (send, recv) = await connection.openBi();
    await send.writeAll(bytes(request));
    await send.finish();
    final data = await recv
        .readToEnd(3 * 1024 * 1024)
        .timeout(const Duration(seconds: 20));
    return jsonDecode(utf8.decode(data)) as Json;
  }

  /// [device]'s pooled connection, taken for one request, or null when it is
  /// in use or being dialled: that request then uses a connection of its own,
  /// so nothing waits behind another request. Connection failures propagate.
  Future<_Pooled?> _pooledFor(String device) async {
    final existing = _pool[device];
    if (existing != null && !existing.closed) {
      if (existing.busy) return null;
      existing.idle?.cancel();
      existing.busy = true;
      return existing;
    }
    if (!_dialing.add(device)) return null;
    try {
      final connection = await _connect(device);
      final pooled = _Pooled(connection)..busy = true;
      _pool[device] = pooled;
      _connections.add(connection);
      unawaited(
        connection.closed().then(
          (_) => _drop(device, pooled),
          onError: (Object _) => _drop(device, pooled),
        ),
      );
      return pooled;
    } finally {
      _dialing.remove(device);
    }
  }

  void _release(String device, _Pooled pooled) {
    pooled.busy = false;
    if (pooled.closed) return;
    pooled.idle?.cancel();
    pooled.idle = Timer(pooledIdle, () => _drop(device, pooled));
  }

  void _drop(String device, _Pooled pooled) {
    if (pooled.closed) return;
    pooled.closed = true;
    pooled.idle?.cancel();
    if (identical(_pool[device], pooled)) _pool.remove(device);
    _connections.remove(pooled.connection);
    pooled.connection.close();
  }

  Future<void> sync(String device) {
    final job = _syncQueue.schedule(device);
    if (_jobs.add(job)) {
      unawaited(
        job.then<void>(
          (_) {
            _jobs.remove(job);
          },
          onError: (Object error, StackTrace stack) {
            _jobs.remove(job);
          },
        ),
      );
    }
    return job;
  }

  Future<void> _sync(String device) async {
    if (!running || !node.allowedPeer(device) || !_busy.add(device)) return;
    _progress[device] = 0;
    final resume = _resume.remove(device);
    lastAttempt[device] = DateTime.now();
    _activity();
    try {
      // Bounded work per session; exhausted pages schedule a continuation.
      var exhausted = true;
      // Both sides reconcile their current slices, then walk back through
      // older ones once the current exchange agrees. A
      // continuation checks the newest window, then resumes where the last
      // session stopped, so history beyond one session's pages is reached.
      var window = 0;
      InventoryCursor? localCursor, remoteCursor;
      var cursorPaging = true;
      // Devices that agreed before exchange only what changed since.
      final quick = await _syncChanges(device);
      if (quick != null) exhausted = !quick;
      // A walk from the newest window notes where both logs stood, which
      // becomes their mark once it reaches the end with nothing changed.
      final startSeq = node.changeSeq, startPolicy = node.policyDigest(device);
      Json? lastReply;
      for (var page = 0; quick == null && page < 16; page++) {
        final inventory = cursorPaging
            ? node.inventoryAfter(peerDevice: device, after: localCursor)
            : node.inventory(peerDevice: device, window: window);
        final reply = await request(device, {
          'type': 'pull',
          'inventory': inventory,
          'window': window,
          if (cursorPaging) 'cursorPaging': true,
          if (cursorPaging) 'after': remoteCursor?.toJson(),
          'addresses': _sharedAddresses(device),
          ..._stamp,
        });
        lastReply = reply;
        if (page == 0 && resume == null) {
          _walkStart.remove(device);
          if (_Mark.parse({
                'mine': startSeq,
                'theirs': reply['seq'],
                'myPolicy': startPolicy,
                'theirPolicy': reply['policy'],
              })
              case final start?) {
            _walkStart[device] = start;
          }
        }
        final incoming = await node.receive(device, reply['items']);
        final remoteInventory = reply['inventory'] as Json;
        final outgoing = await node.offer(device, remoteInventory);
        await _learnAddresses(device, reply['addresses']);
        final pushed = await request(device, {
          'type': 'push',
          'items': outgoing,
          'caps': caps,
        });
        _progress[device] = _progress[device]! + incoming + outgoing.length;
        _activity();
        if (cursorPaging && remoteInventory['cursorPaging'] != true) {
          // Old builds ignore the cursor fields. Restart numbered pagination
          // from the top; mixing the two kinds of boundaries could skip data.
          cursorPaging = false;
          window = 0;
          continue;
        }
        // Without changes on either side the next page would be identical,
        // e.g. items the peer ignores; move on rather than resend them.
        if (incoming == 0 && pushed['changed'] == 0) {
          if (inventory['more'] != true && remoteInventory['more'] != true) {
            exhausted = false;
            break;
          }
          if (window == 0 && resume != null && resume.window > 0) {
            window = resume.window;
            localCursor = resume.local;
            remoteCursor = resume.remote;
          } else {
            window++;
            if (cursorPaging) {
              if (inventory['more'] == true) {
                localCursor = InventoryCursor.parse(inventory['next']);
              }
              if (remoteInventory['more'] == true) {
                remoteCursor = InventoryCursor.parse(remoteInventory['next']);
              }
            }
          }
        }
      }
      final start = _walkStart[device];
      if (quick == null && !exhausted) {
        _walkStart.remove(device);
        // Nothing about sharing changed on either side during the walk.
        if (start != null &&
            node.policyDigest(device) == start.myPolicy &&
            lastReply?['policy'] == start.theirPolicy) {
          _setMark(device, start);
        }
      }
      if (quick == null && exhausted) {
        _resume[device] = (
          window: window,
          local: localCursor,
          remote: remoteCursor,
        );
      }
      syncErrors.remove(device);
      lastSync[device] = DateTime.now();
      _heard(device);
      _rememberSync(device);
      _failures.remove(device);
      _retry.remove(device)?.cancel();
      if (exhausted && running) {
        _retry[device] = Timer(const Duration(seconds: 1), () => sync(device));
      }
      log('Synced ${node.contacts[device]?.label ?? device}');
    } catch (e) {
      // How far back through history this pair had reached is progress, not
      // state to discard: a link that drops mid-session would otherwise
      // restart at the newest window every time and never reach the rest.
      if (resume != null) _resume.putIfAbsent(device, () => resume);
      syncErrors[device] = e.toString();
      final failures = (_failures[device] ?? 0) + 1;
      _failures[device] = failures;
      _retry.remove(device)?.cancel();
      final seconds = (15 * (1 << failures.clamp(0, 6))).clamp(30, 900);
      if (running) {
        _retry[device] = Timer(Duration(seconds: seconds), () => sync(device));
      }
      log('Sync delayed: $e');
    } finally {
      _busy.remove(device);
      _progress.remove(device);
      _activity();
    }
  }

  /// Where this device's and each peer's change logs stood when the two last
  /// agreed, and the [Node.policyDigest] of each side then.
  final Map<String, _Mark> _marks = {};

  /// Where both logs stood when the current walk through history began.
  final Map<String, _Mark> _walkStart = {};
  DateTime? _marksSaved;

  void _setMark(String device, _Mark mark) {
    _marks[device] = mark;
    final saved = _marksSaved;
    // A mark older than the newest is still right (it covers more), so it
    // is written at most every few minutes, and when the network stops.
    if (saved == null ||
        DateTime.now().difference(saved) >= const Duration(minutes: 5)) {
      _saveMarks();
    }
  }

  void _saveMarks() {
    _marksSaved = DateTime.now();
    node.store.set('syncMarks', {
      for (final MapEntry(:key, :value) in _marks.entries) key: value.toJson(),
    });
  }

  /// Exchanges only what changed since this device and [device] last agreed:
  /// true once they agree again, false when there is more than one session's
  /// worth, and null when a full sync is needed (no mark, an older peer, a
  /// change to what may be shared, or more changes than are listed).
  Future<bool?> _syncChanges(String device) async {
    final mark = _marks[device];
    if (mark == null || peerCaps[device]?.contains('since_sync') != true) {
      return null;
    }
    final policy = node.policyDigest(device);
    if (policy != mark.myPolicy) return null;
    final seq = node.changeSeq;
    final mine = node.changedSince(mark.mine);
    if (mine == null) return null;
    final reply = await request(device, {
      'type': 'delta',
      'since': mark.theirs,
      'policy': mark.theirPolicy,
      'changes': node.changeInventory(device, mine),
      ..._stamp,
    });
    final theirSeq = reply['seq'], theirPolicy = reply['policy'];
    final changes = reply['changes'], view = reply['view'];
    if (reply['full'] == true ||
        theirSeq is! int ||
        theirPolicy is! String ||
        changes is! Json ||
        view is! Json ||
        changes['have'] is! Map) {
      return null;
    }
    final theirs = (changes['have'] as Map).keys.whereType<String>().toList();
    final held = node.store.routesOf(theirs);
    // Each side already holds what the other changed: nothing to send.
    var agreed =
        held.length == theirs.length &&
        node.agrees(device, view, mine) &&
        node.agrees(device, changes, held, offeredOnly: false);
    final ids = {for (final r in mine) r.id, ...theirs}.toList();
    for (var round = 0; !agreed && round < 16; round++) {
      var more = false;
      final pulled = await request(device, {
        'type': 'pull',
        'only': ids,
        'inventory': node.changeInventory(device, node.store.routesOf(ids)),
        'addresses': _sharedAddresses(device),
        ..._stamp,
      });
      final incoming = await node.receive(device, pulled['items']);
      final outgoing = await node.offer(
        device,
        pulled['inventory'] as Json,
        only: ids,
        truncated: () => more = true,
      );
      await _learnAddresses(device, pulled['addresses']);
      final pushed = await request(device, {
        'type': 'push',
        'items': outgoing,
        'caps': caps,
      });
      _progress[device] = _progress[device]! + incoming + outgoing.length;
      _activity();
      agreed =
          incoming == 0 &&
          pushed['changed'] == 0 &&
          !more &&
          pulled['more'] != true;
    }
    if (!agreed) return false;
    _setMark(
      device,
      _Mark(
        mine: seq,
        theirs: theirSeq,
        myPolicy: policy,
        theirPolicy: theirPolicy,
      ),
    );
    return true;
  }

  /// Failed at least twice in a row and is waiting for its retry.
  bool _backingOff(String device) =>
      (_failures[device] ?? 0) >= 2 && _retry.containsKey(device);

  /// Cuts short [device]'s backoff: it is (or may be) reachable again.
  void _retryNow(String device) {
    if (!running || !_backingOff(device)) return;
    _retry.remove(device)?.cancel();
    unawaited(sync(device));
  }

  Future<void> syncAll() async {
    if (!running) return;
    await Future.wait(node.contacts.keys.toList().map(sync));
  }

  Future<void> _accept() async {
    final endpoint = _endpoint!;
    while (identical(_endpoint, endpoint)) {
      try {
        final connection = await endpoint.accept();
        if (connection == null) break;
        final peer = b64(connection.remoteId.asBytes());
        if ((!node.allowedPeer(peer) &&
                pairing?.available != true &&
                friendInvitation?.available != true) ||
            _activeInbound >= 4 && _idleInbound.isEmpty) {
          connection.close();
          continue;
        }
        if (_activeInbound >= 4) {
          // Make room by closing a connection that is only waiting for a
          // next request; its caller sends that on a new connection.
          final idle = _idleInbound.first;
          _idleInbound.remove(idle);
          idle.close();
        }
        _activeInbound++;
        _connections.add(connection);
        final job = _serve(connection, peer);
        _jobs.add(job);
        unawaited(
          job.whenComplete(() {
            _activeInbound--;
            _connections.remove(connection);
            _jobs.remove(job);
          }),
        );
      } catch (e) {
        // accept() also completes the handshake, so one peer that gives up
        // or speaks another protocol must not stop all inbound connections.
        if (!identical(_endpoint, endpoint) || endpoint.isClosed) break;
        acceptFailures++;
        lastAcceptError = '$e';
        log('Accept failed: $e');
      }
    }
  }

  /// Served connections between requests, which may be closed for others.
  final Set<iroh.Connection> _idleInbound = {};

  /// Answers [connection]'s requests in turn. A caller that sends one closes
  /// the connection once it has the reply (older builds always do); one that
  /// pools connections sends the next within [servedIdle].
  Future<void> _serve(iroh.Connection connection, String peer) async {
    try {
      var first = true;
      while (true) {
        final iroh.SendStream send;
        final iroh.RecvStream recv;
        if (!first) _idleInbound.add(connection);
        try {
          (send, recv) = await connection.acceptBi().timeout(
            first ? const Duration(seconds: 10) : servedIdle,
          );
        } catch (_) {
          // Closed by the caller, or nothing more within the wait.
          return;
        } finally {
          _idleInbound.remove(connection);
        }
        first = false;
        if (!await _answer(peer, send, recv)) {
          // Give QUIC the opportunity to deliver the refusal before closing.
          await connection.closed().timeout(
            const Duration(seconds: 3),
            onTimeout: () => 'done',
          );
          return;
        }
      }
    } finally {
      _idleInbound.remove(connection);
      connection.close();
    }
  }

  /// Answers one request. False when the connection should not serve more.
  Future<bool> _answer(
    String peer,
    iroh.SendStream send,
    iroh.RecvStream recv,
  ) async {
    try {
      final raw = await recv
          .readToEnd(2 * 1024 * 1024)
          .timeout(const Duration(seconds: 20));
      final j = jsonDecode(utf8.decode(raw)) as Json;
      Json reply;
      if (j['type'] == 'friend') {
        if (friendInvitation == null)
          throw StateError('Invitation unavailable');
        reply = await friendInvitation!.approve(peer, j);
      } else if (j['type'] == 'pair') {
        if (pairing == null) throw StateError('Pairing unavailable');
        reply = await pairing!.approve(peer, j);
      } else {
        if (!node.allowedPeer(peer)) throw StateError('Device not admitted');
        lastInbound[peer] = DateTime.now();
        switch (j['type']) {
          case 'pull':
            _notePeer(peer, j);
            _heard(peer);
            _retryNow(peer);
            // Taken first: this device holds at least this much of its log
            // once the reply is sent, which a walk records as its start.
            final seq = node.changeSeq, policy = node.policyDigest(peer);
            if (j['only'] case final List only
                when only.length <= 2 * Node.maxInventoryEntries &&
                    only.every((id) => id is String)) {
              var more = false;
              final ids = only.cast<String>();
              final items = await node.offer(
                peer,
                j['inventory'],
                only: ids,
                truncated: () => more = true,
              );
              await _learnAddresses(peer, j['addresses']);
              reply = {
                'items': items,
                'more': more,
                'inventory': node.changeInventory(
                  peer,
                  node.store.routesOf(ids),
                ),
                'addresses': _sharedAddresses(peer),
                ..._stamp,
              };
              break;
            }
            final items = await node.offer(peer, j['inventory']);
            await _learnAddresses(peer, j['addresses']);
            reply = {
              'seq': seq,
              'policy': policy,
              'items': items,
              // The window the caller is on, so both sides walk together.
              'inventory': j['cursorPaging'] == true
                  ? node.inventoryAfter(
                      peerDevice: peer,
                      after: InventoryCursor.parse(j['after']),
                    )
                  : node.inventory(
                      peerDevice: peer,
                      window: switch (j['window']) {
                        final int w when w >= 0 => w,
                        _ => 0,
                      },
                    ),
              'addresses': _sharedAddresses(peer),
              ..._stamp,
            };
          case 'push':
            _notePeer(peer, j);
            _heard(peer);
            _retryNow(peer);
            reply = {'changed': await node.receive(peer, j['items'])};
          case 'delta':
            _notePeer(peer, j);
            _heard(peer);
            _retryNow(peer);
            reply = {...await node.answerDelta(peer, j), ..._stamp};
          case 'blob':
            // Require a referenced object that this peer is allowed to receive.
            final o = node.store.get(j['object']);
            if (o == null ||
                !node.canOffer(o, node.contacts[peer]!, {
                  o.space,
                }, relay: true)) {
              throw StateError('File not shared with peer');
            }
            final payload = await node.content(o);
            if (payload == null ||
                !(payload['chunks'] as List? ?? []).contains(j['hash'])) {
              throw StateError('Unknown file chunk');
            }
            final blob = node.store.blob(j['hash']);
            reply = {'bytes': blob == null ? null : b64(blob)};
          case 'typing':
            typing?.call(peer);
            reply = {};
          case 'position':
            if (position == null) throw StateError('Unknown request');
            position!(peer, j['fix']);
            reply = {};
          case 'groupcall':
            if (groupCall == null) throw StateError('Unknown request');
            reply = await groupCall!(peer, j['payload']);
          case 'signal':
            if (signal == null) throw StateError('Calling unavailable');
            reply = await signal!(peer, j['payload']);
          default:
            throw StateError('Unknown request');
        }
      }
      await send.writeAll(bytes(reply));
      await send.finish();
      return true;
    } catch (e) {
      log('Rejected request: $e');
      // Tell the caller why, so it can show the reason rather than a
      // transport failure. Only policy refusals carry their message.
      try {
        await send.writeAll(
          bytes({
            'error': e is StateError ? e.message : 'Request failed',
            if (node.allowedPeer(peer)) ..._stamp,
          }),
        );
        await send.finish();
      } catch (_) {
        return false;
      }
      // Only an admitted device may go on to ask for more.
      return node.allowedPeer(peer);
    }
  }

  Future<void> stop() {
    _restartFailed = false;
    return _transition(_stop);
  }

  /// Whether the endpoint may be rebuilt now; the app says no during a call,
  /// whose signalling would be cut. An open pairing or invitation also blocks
  /// it, since stopping closes them.
  bool Function()? canRestart;

  bool get _restartable =>
      running &&
      pairing?.available != true &&
      friendInvitation?.available != true &&
      (canRestart?.call() ?? true);

  /// How long a network change settles before the endpoint is rebuilt, and
  /// the least time between two rebuilds for network changes.
  static const networkSettle = Duration(seconds: 3);
  static const networkChangeGap = Duration(seconds: 30);

  /// How often the relay connection is checked, and how long it may be down
  /// before the endpoint is rebuilt (doubling after each rebuild that does
  /// not bring it back, up to [watchdogMaxWait]).
  static const watchdogInterval = Duration(seconds: 30);
  static const watchdogWait = Duration(seconds: 90);
  static const watchdogMaxWait = Duration(minutes: 15);

  /// The device moved to another network (Wi-Fi to mobile data, say). The
  /// endpoint is rebuilt once the change settles, so its sockets and home
  /// relay belong to the new network; otherwise a phone that left home could
  /// stay unreachable until OurNet was reopened.
  void networkChanged() {
    if (_restartFailed) {
      _restartFailed = false;
      unawaited(
        start(local: local, automatic: _automatic).catchError((Object _) {
          _restartFailed = true;
        }),
      );
      return;
    }
    if (!running) return;
    _networkChange?.cancel();
    _networkChange = Timer(networkSettle, () {
      _networkChange = null;
      final last = _restartedAt;
      if (last != null && DateTime.now().difference(last) < networkChangeGap) {
        // Several changes in a row (Wi-Fi flapping): try again after the gap.
        _networkChange = Timer(
          networkChangeGap - DateTime.now().difference(last),
          networkChanged,
        );
        return;
      }
      unawaited(restart('network changed').catchError((Object _) {}));
    });
  }

  void _checkRelays() {
    final since = _relaysDownSince;
    if (since == null) return;
    var wait = watchdogWait * (1 << min(_watchdogRestarts, 4));
    if (wait > watchdogMaxWait) wait = watchdogMaxWait;
    if (DateTime.now().difference(since) < wait) return;
    _watchdogRestarts++;
    unawaited(restart('relay unreachable').catchError((Object _) {}));
  }

  /// Rebuilds the endpoint (same identity, same automatic syncing) and syncs
  /// with everyone, unless [canRestart] or an open pairing says not now.
  Future<void> restart(String reason) => _transition(() async {
    if (!_restartable) return;
    _restartedAt = DateTime.now();
    final automatic = _automatic, wasLocal = local;
    await _stop();
    log('Restarting network: $reason');
    try {
      await _start(local: wasLocal, automatic: automatic);
    } catch (_) {
      // No network to bind to yet: the next network change starts it.
      _restartFailed = true;
      rethrow;
    }
  });

  bool _restartFailed = false;

  Future<void> _stop() async {
    pairing?.close();
    friendInvitation?.close();
    _networkChange?.cancel();
    _networkChange = null;
    _watchdog?.cancel();
    _watchdog = null;
    _relaysDownSince = null;
    final endpoint = _endpoint;
    _endpoint = null;
    await _changes?.cancel();
    _changes = null;
    await _relayStatus?.cancel();
    _relayStatus = null;
    relays = const [];
    _debounce?.cancel();
    _debounce = null;
    for (final timer in _retry.values) {
      timer.cancel();
    }
    _retry.clear();
    for (final MapEntry(:key, :value) in _pool.entries.toList()) {
      _drop(key, value);
    }
    for (final connection in _connections.toList()) {
      connection.close();
    }
    await endpoint?.close();
    await Future.wait(_jobs.toList());
    try {
      _rememberUnsaved();
      if (_marks.isNotEmpty) _saveMarks();
    } catch (_) {
      // The profile closed first; these times are shown, not relied on.
    }
    notifyListeners();
  }
}

/// A connection to one device kept for the requests that follow.
class _Pooled {
  _Pooled(this.connection);
  final iroh.Connection connection;
  bool busy = false, closed = false;
  int uses = 0;
  Timer? idle;
}

/// Where two devices' change logs stood when they last agreed.
class _Mark {
  const _Mark({
    required this.mine,
    required this.theirs,
    required this.myPolicy,
    required this.theirPolicy,
  });
  final int mine, theirs;
  final String myPolicy, theirPolicy;

  static _Mark? parse(Object? value) => switch (value) {
    {
      'mine': final int mine,
      'theirs': final int theirs,
      'myPolicy': final String myPolicy,
      'theirPolicy': final String theirPolicy,
    } =>
      _Mark(
        mine: mine,
        theirs: theirs,
        myPolicy: myPolicy,
        theirPolicy: theirPolicy,
      ),
    _ => null,
  };

  Json toJson() => {
    'mine': mine,
    'theirs': theirs,
    'myPolicy': myPolicy,
    'theirPolicy': theirPolicy,
  };
}
