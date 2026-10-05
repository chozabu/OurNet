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
          lastSync[key] = DateTime.fromMillisecondsSinceEpoch(ms);
        }
        if (value['build'] case final String b) peerBuilds[key] = b;
        if (value['version'] case final String v) peerVersions[key] = v;
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

  /// Tells [peerSeen] about a device that is syncing with this one, at most
  /// once a minute each. Only syncs count: a position or typing request does
  /// not, or two devices would answer each other for ever.
  void _heard(String device) {
    final now = DateTime.now(), last = _heardAt[device];
    if (peerSeen == null && peerSeenListeners.isEmpty ||
        last != null && now.difference(last).inSeconds < 60) {
      return;
    }
    _heardAt[device] = now;
    peerSeen?.call(device);
    for (final listener in peerSeenListeners.toList()) {
      listener(device);
    }
  }

  void _remember(String device) {
    final synced = lastSync[device];
    final build = peerBuilds[device];
    final version = peerVersions[device];
    final saved = Map<String, dynamic>.from(
      node.store.setting('peerHealth') as Map? ?? const {},
    );
    saved[device] = {
      if (synced != null) 'synced': synced.millisecondsSinceEpoch,
      if (build != null) 'build': build,
      if (version != null) 'version': version,
    };
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
    if (changed) _remember(device);
  }

  /// What this build can do beyond the base sync protocol. Peers ignore names
  /// they do not know, and a feature is used only when the peer lists it, so
  /// builds of any age keep syncing.
  ///
  /// `cursor_paging`: inventories page by (created, id) cursor.
  /// `blob_inline`: chunk bytes travel base64 in `blob` replies.
  static const caps = ['cursor_paging', 'blob_inline'];

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
      if (!local) {
        _relayStatus = _endpoint!.homeRelayStatus().listen((status) {
          relays = [
            for (final r in status)
              (url: r.url, connected: r.connected, error: r.lastError),
          ];
          if (relays.any((r) => r.connected)) {
            _relaysDownSince = null;
            _watchdogRestarts = 0;
          } else if (relays.isNotEmpty) {
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

  Future<iroh.Connection> _connect(String device) async {
    if (!node.allowedPeer(device)) throw StateError('Device not admitted');
    final ep = _endpoint;
    if (ep == null) throw StateError('Network is stopped');
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

  Future<Json> request(String device, Json request) async {
    final connection = await _connect(device);
    _connections.add(connection);
    try {
      final (send, recv) = await connection.openBi();
      await send.writeAll(bytes(request));
      await send.finish();
      final data = await recv
          .readToEnd(3 * 1024 * 1024)
          .timeout(const Duration(seconds: 20));
      final reply = jsonDecode(utf8.decode(data)) as Json;
      // Refusals carry the stamp too, so an incompatible peer is identifiable.
      if (node.contacts.containsKey(device)) _notePeer(device, reply);
      if (reply['error'] != null) throw StateError(reply['error']);
      return reply;
    } finally {
      connection.close();
      _connections.remove(connection);
    }
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
      for (var page = 0; page < 16; page++) {
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
      if (exhausted) {
        _resume[device] = (
          window: window,
          local: localCursor,
          remote: remoteCursor,
        );
      }
      syncErrors.remove(device);
      lastSync[device] = DateTime.now();
      _heard(device);
      _remember(device);
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
            _activeInbound >= 4) {
          connection.close();
          continue;
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

  Future<void> _serve(iroh.Connection connection, String peer) async {
    iroh.SendStream? replyStream;
    try {
      final (send, recv) = await connection.acceptBi().timeout(
        const Duration(seconds: 10),
      );
      replyStream = send;
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
            final items = await node.offer(peer, j['inventory']);
            await _learnAddresses(peer, j['addresses']);
            reply = {
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
            reply = {'changed': await node.receive(peer, j['items'])};
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
      // Give QUIC the opportunity to deliver the reply before closing.
      await connection.closed().timeout(
        const Duration(seconds: 3),
        onTimeout: () => 'done',
      );
    } catch (e) {
      log('Rejected request: $e');
      // Tell the caller why, so it can show the reason rather than a
      // transport failure. Only policy refusals carry their message.
      try {
        await replyStream?.writeAll(
          bytes({
            'error': e is StateError ? e.message : 'Request failed',
            if (node.allowedPeer(peer)) ..._stamp,
          }),
        );
        await replyStream?.finish();
        await connection.closed().timeout(
          const Duration(seconds: 3),
          onTimeout: () => 'done',
        );
      } catch (_) {}
    } finally {
      connection.close();
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
    for (final connection in _connections.toList()) {
      connection.close();
    }
    await endpoint?.close();
    await Future.wait(_jobs.toList());
    notifyListeners();
  }
}
