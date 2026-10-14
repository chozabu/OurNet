# Xeres review

Two reviews of Xeres (11 October 2026): a broad survey, then a detailed look at its networking.

## Xeres review for OurNet

Reviewed 11 October 2026. Xeres snapshot: `d696baea6a84349204271fbd10f246cf3cf17af3`, cloned to `.research/Xeres`. OurNet comparison uses this workspace's current code. This is a broad source survey with deeper inspection of selected systems, not an audit of every line. Neither application was built, run or benchmarked for this review; apparent UX advantages are inferred from controllers, views and help text.

Xeres is Java, not JavaScript: Spring Boot backend, JavaFX desktop UI, a shared `common` module, H2 storage, Netty networking and Bouncy Castle/JCA cryptography. JavaScript is available for scripts. Its README advertises compatibility with RetroShare 0.6.6 and later; the source contains the corresponding binary packet/TLV serializers, service negotiation and GXS/Turtle implementations. Interoperability was not independently tested.

The most useful lessons are a usable always-on node, better transfer management, whole-database encryption, shared community infrastructure, and explicit privacy documentation. Replacing OurNet's protocol or transport with RetroShare's would sacrifice several of OurNet's existing strengths.

### Scale and review coverage

| Measurement | Xeres | OurNet |
| --- | ---: | ---: |
| Production language files | 1,073 Java | 134 Dart |
| Production physical lines | 121,613 | 57,618 |
| Test/support Java files | 360 | Not counted here |
| Test/support Java physical lines | 34,640 | Not counted here |

Counts cover Xeres's three `src/main/java` trees and OurNet's `core/lib`, `transport/lib`, `app/lib`. Xeres test counts include `src/test` and `testFixtures`. Physical lines include comments, blank lines and repeated licence headers. Resources, dependencies, OurNet Rust and platform code are excluded. These are size indicators, not measures of complexity or quality; test files are not test cases. Xeres is smaller than the full RetroShare project, but is not a tiny implementation.

Inspected repository/module structure, networking and serializer inventory, service registration/negotiation, selected GXS transaction and verification paths, Turtle search/routing limits, file transfer manager/agents/chunk distribution/scheduling, community services, reputation, REST controllers, paging, remote authentication, database encryption/migrations, backups, UI support/controllers, architecture tests and user documentation. Read relevant OurNet storage, networking, files and private-forum paths alongside its protocol and existing RetroShare comparison. Peripheral implementations such as audio codecs, every serializer and every UI controller received less scrutiny.

### Where Xeres is ahead, and what to adapt

#### 1. A personal node is an actual product

Xeres has REST controllers for contacts, chat, groups, files and statistics, WebSocket notifications, JavaFX clients, remote mode and Docker deployment. Its Android offering is a client of a running node, rather than an independent mobile RetroShare node. Remote documentation describes TLS 1.3 and certificate pinning in the Android client; that separate client's implementation was not inspected.

OurNet already separates `core`, `transport` and Flutter, and has a headless CLI. What it lacks is a similarly complete operator/client boundary and packaged always-on experience. This is especially relevant to phones sleeping and keeping content available while a laptop is closed.

Adapt: package an own-device node with persistent storage, service restart, pairing, updates and a small status/control API. Keep it an admitted device with normal device permissions and revocation. Prefer authenticated existing device links for control; exposing a new HTTP API is optional. An always-on own device improves availability, but does not itself implement friend-carrier routing.

Evidence: `app/api/controller`, `ui/client`, `docker-compose.yml`, `ui/src/main/resources/help/en/04g.Remote.md`; OurNet `transport/bin/node.dart` and `transport/lib/src/network.dart`.

#### 2. File sharing is a first-class workflow

Xeres has shared files, network search, download/upload views and search trends. Its transfer engine tracks chunk availability, assigns work across sources, persists partial-download chunk maps, and schedules peers. A partial download can supply completed portions to others. Transfers work over direct and Turtle virtual peers.

OurNet already has encrypted content-addressed chunks, multiple potential holders, four concurrent batch requests per fetch, bounded job queues and verified chunks retained across restarts. It would be inaccurate to call its transfers non-resumable or single-source. Xeres's lead is the broader file-sharing workflow and explicit chunk availability/scheduling, not simply parallelism.

Adapt: a transfer centre showing direction, bytes, source availability, queue state, failure/retry and cancel; an explicit paused state with persisted transfer intent; throughput/fairness controls that reserve capacity for chat, calls and sync; source availability hints so requests avoid holders known to lack chunks. Preserve object authorization and ciphertext storage. The current 64 MiB limit needs a larger-file design and measurements, not just a larger constant.

Do not copy its timing constants: upload scheduling still uses fixed 50 ms delays and comments acknowledge incomplete bandwidth accounting. Its `fileCommandQueue` is an unbounded `LinkedBlockingQueue`; keep OurNet's bounded queues.

Evidence: `xrs/service/filetransfer/{FileTransferManager,FileTransferAgent,ChunkDistributor,FileDownload,BandwidthScheduler,FileTransferRsService}.java`, `ui/controller/file`; OurNet `transport/lib/src/files.dart`.

#### 3. Whole-database encryption protects metadata too

Xeres configures H2 with `CIPHER=AES` and converts older plaintext databases. Its help explains using Windows DPAPI to remember the database credential.

OurNet opens ordinary SQLite. Private object contents, private blobs and previews are encrypted, but table structure, identifiers, kind/space/time information and routing/peer indexes remain visible. A recovery phrase or encrypted backup does not encrypt the live database.

Adapt: design whole-database encryption with a random database key protected by the vault/OS keystore. Include WAL/journal behavior, upgrades, backups, crash recovery and locked-device background access. This complements existing payload encryption. Xeres does not prove all exported/downloaded files are encrypted: its download engine writes ordinary files, and its backup method serializes key material to XML. Evaluate each export independently.

Evidence: `configuration/DataSourceConfiguration.java`, `service/backup/BackupService.java`, `ui/src/main/resources/help/en/07h.Remember credentials.md`; OurNet `core/lib/src/store.dart`.

#### 4. Community features share infrastructure

Forums, channels, boards and identities share `GxsRsService`, authentication requirements, transactions, signature verification and helper services. Channels require a publish signature for root posts; boards require author signatures. Comments and votes reuse shared models. Group headers can be learned separately from downloading subscribed content.

OurNet's generic signed objects are already a good foundation. The opportunity is to avoid repeating feature-specific validation, discovery, moderation and presentation logic as kinds grow. A channel is a useful small feature: announcements/resources published by authorized people, with discussion separately controlled. It should reuse existing audiences and provenance.

Adapt: shared, explicitly registered policies for author permissions, audience/relay rules, moderation and feature capabilities. Community discovery should use small signed recommendations/headers with bounded expiry and scopes. Keep user choices about what is relayed; do not inherit automatic propagation of every discoverable group.

Do not assume full private-community support: `isGxsAllowedForPeer` rejects `EXTERNAL`, and `isGxsAllowedForFriendGroup` returns false with an implementation comment. OurNet's private membership/key workflows are more complete in the inspected paths. Also keep OurNet's incremental/event-driven sync: Xeres periodically loops through subscribed groups and can return broad ID lists after detecting an update.

Evidence: `xrs/service/gxs/GxsRsService.java`, `xrs/service/{channel,board,forum}`, OurNet `core/lib/src/{node,everyday,room_forum}.dart` and `transport/lib/src/network.dart`.

#### 5. Reach beyond direct friends is implemented

Turtle supports search and tunnels across friends, with request IDs, duplicate suppression, response routing, hit limits, request-size limits, timeouts and idle cleanup. GXS tunnels exchange authenticated DH material for distant chat. This gives Xeres real discovery/file/chat reach beyond a direct peer link.

OurNet deliberately publishes a graph and records provenance. Anonymous Turtle routing cannot simply be added while retaining those promises unchanged. The transferable lessons are bounded request propagation, duplicate suppression, expiry, reverse response paths and cleanup when a route disappears.

Adapt these mechanics for accountable friend-carrier delivery and scoped discovery. Anonymous routing, Tor/I2P integration and pseudonyms require an explicit product decision. Do not assume Xeres implements all of RetroShare's offline mail capabilities: the inspected `MailRsService` handles direct mail; this review did not establish a complete GRouter-style offline custody path.

Evidence: `xrs/service/turtle/TurtleRsService.java`, `xrs/service/gxstunnel/GxsTunnelRsService.java`, `xrs/service/mail/MailRsService.java`.

#### 6. Network behavior is inspectable

Xeres exposes RTT, traffic counters and Turtle statistics through both API and UI. Downloads and uploads are visible independently. OurNet already has relay status, sync health, errors and per-sync progress, so the useful extension is quantitative visibility rather than another generic status indicator.

Adapt: bytes by traffic class, outstanding work, source/route availability, retry timing and a copyable redacted explanation of why an operation is waiting. Measure incrementally, without scanning stored history.

Evidence: `api/controller/statistics/StatisticsController.java`, `ui/controller/statistics`; OurNet `app/lib/ui/{sync_health,sync_status}.dart`.

#### 7. Privacy and trust choices are explained specifically

Xeres ships individual help pages for DHT, LAN discovery, DNS, UPnP, update checks, link previews, external URLs and remembered credentials. Its link-preview documentation explicitly says fetching happens from the reader's device and exposes their IP to the destination. Contact trust currently has limited functionality; one documented use is enabling previews only for fully trusted friends.

Adapt: explain OurNet's iroh discovery/relays, STUN/TURN, map tile requests, public graph, location sharing and background networking next to their controls. If adding rich previews, prefer sender-supplied signed preview data or an explicit fetch choice, with bounded processing and clear origin. Avoid silent recipient-side requests caused by arbitrary received messages.

Xeres also gives local opinions precedence over friends' aggregate reputation. We can take the local-control principle without adopting a global score for people: forum-scoped moderation, personal blocks and attributed advice suit OurNet better.

Evidence: `ui/src/main/resources/help/en/07*.md`, `03b.Contacts.md`, `service/ReputationService.java`.

#### 8. Architecture rules are executable

Xeres's ArchUnit tests prohibit backend access to UI classes except designated bridges and check service/item conventions. It also uses Flyway SQL migrations and separate data-folder upgrades.

Adapt: enforce `core`/`transport` independence from Flutter, keep authorization/crypto out of widgets, and check protocol-policy registration. OurNet's saved-profile upgrade fixtures and performance budgets remain valuable; SQL migrations alone do not replace them. Test counts do not establish superior test coverage.

Evidence: `app/src/test/java/io/xeres/app/AppCodingRulesTest.java`, `common/src/testFixtures`, `app/src/main/resources/db/migration`.

### Advantages OurNet should preserve

- Independent own-device synchronization and historical key grants. Xeres's remote client is a different tradeoff; chat backlog is stored against locations/identities, not evidence of OurNet-style device convergence.
- Existing private-group encryption and collaboration: notes, calendars, drive revisions and group calls have no directly comparable complete workflow in the inspected Xeres tree.
- Modern wire primitives and algorithm identifiers. Xeres uses RSA/SHA-1 in compatibility paths, although it also has newer ChaCha20-Poly1305 helpers. Do not describe its entire crypto stack as legacy or infer system security from primitive names alone.
- Iroh's QUIC transport and relay fallback. Xeres's TCP/DHT/proxy paths demonstrate alternatives, but this review does not establish better NAT reliability or independence from all infrastructure.
- Bounded attachment workers, durable encrypted previews and incremental history behavior. Xeres uses keyset paging and bounded image caching, but also has broad periodic group loops and an unbounded transfer command queue. No measured performance winner is established.
- Accountable provenance and person/device identity. Changing anonymity semantics would be a product/protocol change, not a refactor.

### Suggested order

1. Transfer centre and diagnostics, retaining encrypted caches and existing concurrency bounds. Define user-visible paused/cancelled/failed states and test interruptions and restarts.
2. Whole-database encryption design and migration prototype. Benchmark real history and validate backup/recovery/background access before adoption.
3. Packaged own-device node. Validate that a phone can receive history/files after other interactive devices go offline; document that friend carriers remain separate work.
4. Scoped community discovery and a small publishing/channel workflow using existing permission semantics.
5. Carrier routing/custody with per-friend quotas and expiry. Borrow Turtle's resource-control patterns, not its anonymity promises.

Privacy explanations and dependency-boundary checks are small improvements that can accompany this work. This order prioritizes benefits to current users before expanding the protocol surface.

Source links can be resolved under [the reviewed Xeres snapshot](https://github.com/zapek/Xeres/tree/d696baea6a84349204271fbd10f246cf3cf17af3). Paths above are relative to `app/src/main/java/io/xeres/app` unless their module or resources/test prefix is shown explicitly.

## Xeres networking: detailed review for OurNet

Reviewed 11 October 2026 against Xeres commit `d696baea6a84349204271fbd10f246cf3cf17af3`, retained in `.research/Xeres`. OurNet references describe this workspace. This is source analysis, including selected tests, not a runtime benchmark, interoperability certification or security audit. Third-party Netty, mldht, SOCKS servers and iroh internals were not independently audited. Code concerns below describe visible control flow; their complete runtime impact needs reproduction.

### Conclusions

Xeres's useful networking contribution is its overlay architecture: bounded-ish discovery, temporary reverse paths, virtual peers, reusable authenticated tunnels, chunk availability and service negotiation. Its direct transport is ordinary TCP with mutual TLS 1.3, plus externally configured SOCKS paths for Tor/I2P. It does not reproduce the full RetroShare NAT traversal/UDP transport stack in the inspected tree. Keep iroh for OurNet.

OurNet should learn these six things:

1. Separate authenticated peer identity, route selection and application authorization. A relayed route must not make its immediate carrier the content author or intended reader.
2. Treat discovery, live tunnels and durable offline custody as three different mechanisms. Turtle only solves the first two.
3. Apply admission and resource budgets before expensive work. Deduplication, deadlines and per-person fairness must survive multiple connections and multiple devices.
4. Give acknowledgements explicit meanings. Bytes assembled, verified storage, recipient delivery and user reading are different facts.
5. Share source availability and schedule chunks across sources, retaining OurNet's authenticated encrypted chunks and bounded workers.
6. Instrument the application path: wait time, queue size, useful throughput, retries, traffic class and routing failures. Transport connectivity alone does not explain delivery.

### 1. Direct connection lifecycle

`NetworkService` waits for the own profile, location and identity, sets a local port, resets saved connection state, starts helper services, then starts the peer server/client. Helper activation can be restricted to a private OS network profile. UPnP, LAN broadcast and DHT are independently configurable, although the startup path coordinates them.

`PeerConnectionJob` starts after five seconds and repeats with a 60-second fixed delay. It asks `LocationService` for up to ten candidate connections. The query pages disconnected locations by last-connected time, and selects an address for each. This is a per-tick selection limit, not evidence of a strict semaphore over all outstanding dials. `PeerClient.connect()` launches the Netty connect future without awaiting it or attaching failure accounting in that method. DHT results and immediate connections provide additional dial paths.

The server binds a `NioServerSocketChannel`, backlog 128, with one accept event loop and a worker event-loop group. Each connection has this pipeline:

```text
optional SOCKS5 proxy
    → TLS 1.3
    → packet framing
    → slice reassembly
    → item deserialization and service dispatch
```

TLS requires a peer certificate, but uses an insecure CA trust manager because RetroShare's certificates are not conventional web certificates. After TLS completes, `SSL.checkPeerCertificate()` derives the location identifier, finds a known location or a new location belonging to an accepted complete PGP profile, and verifies the PGP signature for complete profiles. Short-invite partial profiles take a separate later key-completion path. This is custom post-handshake validation, not simply unauthenticated TLS. `PeerHandler` drops application items until it has installed the validated peer connection.

Incoming and outgoing handshakes serialize their admission step on `PeerHandler.class`. An already-connected location is rejected. Service negotiation is delayed by a random 2–8 seconds; service-specific startup is also staggered. Disconnect cancels scheduled peer work, updates location state, removes the peer and emits a disconnect event.

**OurNet comparison.** Iroh authenticates device keys and `Node.allowedPeer` controls admission. `_answer` checks admission again for requests, covering revocation after a link was accepted. `_learnAddresses` checks embedded endpoint identity, lets a device replace its own hint and lets third-party hints only fill an empty slot. These are good boundaries to retain. Do not transfer Xeres's accepted-profile automatic-location behavior into OurNet without retaining root-signed device admission and revocation.

**Lessons.** A route/address candidate is untrusted even when supplied by a friend. Track provenance and success separately from admission. Use a connection generation or instance token for cleanup, so an old disconnect cannot remove a newer connection. Define simultaneous-dial behavior explicitly. Xeres's `PeerConnectionManager.addPeer` uses `put` before detecting duplicates, so its own synchronization is material to correctness; copy the lifecycle concept, not that mutation pattern.

References: `service/{NetworkService,LocationService,PeerService}.java`, `job/PeerConnectionJob.java`, `net/peer/bootstrap/{PeerClient,PeerServer,PeerInitializer}.java`, `net/peer/pipeline/PeerHandler.java`, `net/peer/ssl/SSL.java`.

### 2. Reachability, discovery and address hints

#### UPnP and external address

The UPnP service discovers an IGD using SSDP, obtains control information and requests TCP and UDP mappings for the peer port. It optionally maps the remote-control TCP port. Leases are one hour, with refresh anticipation of one minute; service retries use five minutes. It removes mappings when cleaning up the device. If UPnP fails, optional external-IP DNS lookup can still supply an invite address. Knowing a public IP does not establish an inbound NAT path. UDP mapping also does not prove a peer UDP transport exists: DHT uses UDP while the peer data path inspected here uses TCP.

Network changes are polled every minute after an initial two minutes. Helpers restart when the local IP changes. This is oriented toward desktop networks and does not establish fast mobile recovery. OurNet already reports Android default-network changes, debounces endpoint rebuilding and has a relay watchdog. Keep those controls and avoid disruptive rebuilds during calls/pairing.

#### LAN discovery

UDP broadcast uses port 36405 and 512-byte buffers, approximately every five seconds. Packets contain profile fingerprint, location identifier, listening port and profile name. A known disconnected location can acquire a LAN address; an unknown one prompts a discovery notification. The packet itself is not cryptographic admission.

The peer cache uses a 32-bit peer ID. Its apparent one-minute expiry is checked only when another packet for that same ID arrives; the inspected loop has no global expiry sweep or cardinality cap. Treat this as a warning against assuming a timeout constant proves bounded memory. A change-counter/update path is also unfinished.

#### BitTorrent DHT

Xeres uses mldht's IPv4 DHT. It derives a 20-byte DHT node ID as SHA-1 of `RS_VERSION_0.5.1` plus a NUL and the location ID. Its own DHT identity therefore lets known friends search for its node. It bootstraps through the library and a bundled fallback node list.

`DhtFinderJob` begins after two minutes, then selects one disconnected DHT-enabled location every 15 seconds. This selects one lookup per tick; it does not wait for the previous lookup to finish. When a FIND_NODE response matches a searched key, the response's address becomes a TCP dial candidate. It deliberately does not write that candidate into the persistent address table before a validated connection/discovery exchange. Unsuccessful entries in `searchedKeys` have no explicit age cleanup in the inspected wrapper.

#### Friend-assisted discovery

The discovery service exchanges own contact information, identity IDs, friend PGP IDs and contact addresses for mutual discoverable friends. This is a useful way to repair stale routes without relying solely on a global lookup provider. Some external-address feedback paths are TODOs.

**Lessons for OurNet.** Keep discovery providers as sources of hints, with one shared identity-bound validation path. For infrastructure independence, configurable own iroh relays/discovery are a better next step than adding BitTorrent DHT and a second peer transport. Friend-provided fresh address hints could help, but require bounded TTLs and explicit trust rules; a third party must not overwrite a device's validated address indefinitely. Distinguish public-network LAN visibility from trust in a discovered identity.

References: `net/upnp/UPNPService.java`, `net/bdisc/{BroadcastDiscoveryService,UdpDiscoveryProtocol}.java`, `net/dht/{DhtService,NodeId}.java`, `job/DhtFinderJob.java`, `xrs/service/discovery/DiscoveryRsService.java`.

### 3. Framing, reassembly and dispatch

RetroShare wire frames have an eight-byte header. `PacketDecoder` supports the old complete-packet format and the newer slice format. It checks minimum length and an approximately 256 KiB frame ceiling before extracting a complete frame. `ItemDecoder` groups slices by packet ID before creating an application `RawItem`.

Reassembly has constants for 16 concurrent packets and 195,512 slices per packet. Those are not a small byte budget. Guards use `>` before insertion, permitting one more than the nominal count. No aggregate byte/deadline budget is visible in that class, nor a channel-disconnect disposal override for accumulated slices. Its comment explicitly acknowledges missing cleanup after reassembly errors. Complete reassembly allocates a combined buffer, so both fragment and assembled allocations matter.

Outbound `MultiPacketEncoder` is a stub that throws if enabled; the normal outbound path uses complete packets. Packet priority metadata exists, but the normal send path writes and flushes directly. I found no application send scheduler enforcing those priorities or reacting to Netty write-buffer writability. Do not infer full QoS from fields named `priority`.

`PeerHandler.channelRead` deserializes and invokes service handling on the channel event loop. Some services perform database operations and signature checks there. An event loop can serve more than one connection, so moving code off the UI thread is insufficient to guarantee unrelated peers remain responsive.

**OurNet comparison.** QUIC streams remove the need to recreate TCP slice multiplexing. OurNet bounds incoming requests to 2 MiB, reply reads to 3 MiB, and serving to eight normal inbound connections with four requests each. But these are layers of bounds: a full pool opens a separate connection, and `_connect` is shared by other request types. Four sync jobs, two transfer jobs and four streams do not form a universal per-person request/byte budget. An admitted peer can also occupy multiple inbound connections. Conservatively account for dozens of simultaneous bounded buffers, parsed JSON, reply copies and worker queues rather than quoting one message limit as total memory usage.

**Lessons.** Define limits on bytes, count, work and lifetime at every layer. Use a global and per-person admission budget across connections, reserve control capacity, and propagate cancellation/deadlines through dialing, writing, reading and processing. Keep JSON unless measurement shows it is a material cost; binary framing would not solve scans, unfair queues or repeated verification. OurNet's raw-byte blob batches already avoid base64 overhead for newer peers.

References: `net/peer/{packet,pipeline}`, particularly `PacketDecoder`, `ItemDecoder`, `MultiPacketEncoder`, `PeerHandler`; OurNet `transport/lib/src/network.dart`.

### 4. Capability negotiation and liveness

Xeres sends a service list and enables services found in its registry. Service entries include major/minor versions, but the inspected handler selects by service type and does not visibly enforce those version numbers. Registry lookup also selects item subtype handlers. Unknown items get a disposable default. Service-supported checks constrain selected outgoing fan-out; that alone is not an incoming permission gate.

Each connection owns schedules and service state. Services start at different delays to avoid an initial burst. Reader idle for two minutes closes a link; writer idle for one minute sends a slice probe. RTT normally pings every ten seconds. Twenty offset samples can produce a warning about clock drift above two minutes. Its RTT calculation uses wall time and should not be copied for elapsed-time deadlines.

**OurNet comparison.** OurNet already has explicit optional capability names and a required baseline, operation-specific refusal replies, sync retry backoff, short connection pooling and reuse. Idle pooling is three seconds outbound/five seconds inbound to avoid retaining radio-expensive peer links. Xeres's permanent desktop links are not a sensible universal phone default.

**Lessons.** Prefer capability-specific degradation to raising the whole required peer version. Keep capability data bounded and distinguish feature support from permissions. Jitter retry/periodic maintenance to prevent correlated reconnection storms: OurNet's ordinary exponential retries are deterministic, although busy retries already use jitter. For diagnostics, record both route connectivity and request latency; use monotonic elapsed time, and treat remote clocks as untrusted. A light health notification can be useful on an existing active link, but frequent pings merely for statistics have a mobile battery cost.

References: `xrs/service/{serviceinfo/ServiceInfoRsService,rtt/RttRsService}.java`, `net/peer/PeerConnection.java`, `pipeline/IdleEventHandler.java`; OurNet `PeerNetwork.caps`, `_pooledFor`, `_sync`.

### 5. Turtle search: a temporary response tree

An origin creates a random request ID and stores the requesting client. It sends the request to connected Turtle-supporting friends. A forwarding node records its upstream neighbor. Local hits and downstream responses return through those recorded neighbors; replies do not need a full end-to-end address or graph.

Search guards include a 200-byte accepted request size, a nominal cache count of 120 and a nominal hit limit of 100. Response batches target roughly 10 KB. Replies older than 20 seconds are dropped, while request IDs remain cached ten minutes to suppress repeats. Cleanup runs approximately every ten seconds. These serve different purposes: a short response window and a longer duplicate memory.

Search forwarding goes to all eligible peers except the sender. It uses the depth rule, but not the probabilistic forwarding calculation used for tunnel requests. Nominal maximum depth is six; a per-node bias sometimes permits forwarding at/above that depth and sometimes skips a depth increment. It is intentionally not a strict six-hop resource boundary, partly to obscure distance.

**Problems visible in the implementation.** Local database search and local result sending happen before `putIfAbsent` detects a duplicate. A repeated request may therefore avoid further propagation while still repeating expensive local work. Hit accounting initially uses result packet count rather than hit count. When accumulated results cross the limit, it trims the current packet to the full limit rather than the remaining allowance: 90 previous hits plus a packet of 20 can forward all 20. The origin branch does not apply that forwarding cap. These are source-level concerns, not a demonstrated network attack. Packet-size estimation also uses character length for names rather than an evident exact UTF-8 byte count, and appends before checking the batch target.

**Adaptation.** Scoped community/file discovery can use the response-tree pattern. Reserve a request ID and enforce its budget before search. Store request ID together with origin, scope and query digest; account for both per-person and global work. Return only signed, authorized headers and validate them at the origin. Charge results by actual accepted item count and serialized bytes, use the remaining allowance, and coalesce identical searches. For OurNet, explicit hop/expiry limits are suitable for a discovery request; they need not impose a cap on stored content reach. No privacy-motivated random depth bypass is needed.

References: `TurtleRsService.java:523` and `:689`, `turtle/{SearchRequest,TunnelProbability}.java`, `turtle/item/TurtleFileSearchResultItem.java`.

### 6. Turtle tunnels: discovery becomes a route

For a selected hash, an origin periodically asks friends for a route. Nodes deduplicate request IDs before calling local tunnel clients. A node able to serve the hash returns a tunnel result. As that reply follows the saved reverse path, every intermediate node installs:

```text
tunnel ID → upstream neighbor, downstream neighbor
```

Endpoint nodes also register a virtual location, so file transfer sees another peer rather than a special routing engine. On receipt of tunnel data, the router checks that the sender is one of the two recorded neighbors and derives the forwarding direction itself. It does not simply trust a direction claimed by the packet. Intermediate nodes do not need to store the file hash in their tunnel entry.

Tunnel requests are probabilistically forwarded according to depth and measured request traffic. The calculation targets about 20 forwarded request equivalents per second, using a 50-byte request estimate and a steep load function. This shapes expected traffic rather than enforcing a token-bucket ceiling. Peer count includes all connected peers, with a comment acknowledging the difference from counting Turtle-capable peers.

The manager runs every two seconds and digs at most one monitored hash per pass. Missing tunnels retry after about 50 seconds. Multi-tunnel/aggressive discovery uses a baseline five-minute interval that increases with established throughput. Data tunnels idle out after 60 seconds; request-response windows are 20 seconds and request-ID caches last ten minutes. Valid route data refreshes activity and contributes to smoothed throughput statistics.

**Concerns.** Tunnel-request and tunnel maps have no explicit global/per-peer cardinality or byte cap in the inspected router. Tunnel results allocate a transitive tunnel before checking the response deadline. Cleanup defers endpoint notifications in a map keyed by client, so several removed virtual peers for the same client can overwrite each other's notification. This could leave stale transfer-side state and needs reproduction. Cleanup is largely driven by periodic idle expiry rather than immediate removal of all routes involving a disconnected neighbor.

**Adaptation.** Keep the virtual-route abstraction: direct and relayed paths can expose the same request API while preserving endpoint identity. Use one canonical route token bound to session, authorized next hops and scope. Reject expired/unexpected responses before allocation; invalidate routes promptly on neighbor disconnect, revocation or permission change. Bound setup rate and active-route bytes independently from data rate. Back off route discovery when a route is healthy instead of flooding for theoretical alternatives.

Turtle is a live forwarding path. It does not retain durable encrypted messages across process exits or prove custody. It cannot replace OurNet's planned offline carrier store, quotas, expiry and receipts. Also, anonymity is relative: relays see their immediate neighbors and search terms, and the GXS destination-hash helper embeds a destination identity. Do not describe all routing metadata as hidden.

References: `TurtleRsService.java:272`, `:361`, `:445`, `:755`, `:805`; `turtle/{Tunnel,TunnelRequest,HashInfo,VirtualLocation,TunnelProbability}.java`.

### 7. Authenticated GXS tunnels and reliable messages

`GxsTunnelRsService` layers identity authentication and reliability over Turtle. A secured-tunnel request registers a logical contact and asks Turtle to find the destination. A virtual peer triggers fresh Diffie-Hellman material; RSA signatures authenticate that material, and AES plus HMAC-SHA1 protect subsequent tunnel messages. Several application services share the logical tunnel via service IDs.

Outgoing messages receive a process-wide counter and enter a retry priority queue. A two-second manager resends one due item after its ten-second retry delay. Receivers acknowledge the counter and suppress duplicates with a ten-minute received-message map. Keepalives are six seconds, and a route is considered down after roughly 26 seconds without contact. Status callbacks tell clients when the logical tunnel changes.

**Useful idea.** A stable logical conversation can outlive a particular live route. Retry the same application message ID after route replacement, and make delivery idempotent. This matters more than the physical connection's identity. OurNet's signed object IDs already provide a durable duplicate key.

**Do not copy these details.** The retry queue has no explicit byte/count/attempt/expiry bounds and no evident persistence. ACK removal scans all queued data by counter rather than binding it to the tunnel/session. An authenticated peer's ACK should only complete its own pending item. ACK is emitted before service lookup and client authorization; a transport ACK is therefore not proof of application acceptance. A forced re-dig path constructs a fresh random destination hash while `forceReDiggTunnel` requires the exact registered hash, a visible mismatch worth reproducing. Another removal path compares the logical tunnel ID with the Turtle virtual location, which warrants lifecycle testing rather than assuming route failure always reaches every client.

For OurNet's future routed session, use existing modern primitives, transcript/endpoint/session binding, separate directional keys, sequence/replay protection and application authorization. The inspected DH/signature machinery is not a model to copy verbatim or evidence of a complete modern ratchet. If persistent history and key grants are retained, define their relationship to ephemeral session keys explicitly.

References: `gxstunnel/{GxsTunnelRsService,TunnelPeerInfo,TunnelDhInfo,DestinationHash}.java`.

### 8. GXS synchronization and acknowledgement semantics

GXS first compares update markers and sends group/message ID lists, then requests missing items. Transfers use a shared state machine: START → START_ACKNOWLEDGE → items → END_SUCCESS. Message requests select at most 20 missing IDs per batch. Transactions expire after 2,000 seconds, with periodic cleanup at that scale and removal on peer disconnect. Unknown author keys can defer verification while the identity service obtains them; failed groups/messages enter one-day rejection caches.

Group updates and new messages can send sync notifications to other peers, in addition to one-minute periodic polling. Thus Xeres is not purely polling. However, community services iterate subscribed groups for sync, and detecting an update can lead to broad lists. The mark is a timestamp, not OurNet's insertion/change sequence plus sharing-policy digest. Wall-clock markers need caution around clocks and incomplete batches.

END_SUCCESS is sent when the expected item count is assembled, before `processItems` verifies and stores it. Later verification may reject or defer items. An incoming START installs a transaction with the peer-provided count; the visible manager has no transaction count/byte quota and permits replacement of an incoming entry with the same ID. Item accumulation is not visibly checked against a byte budget or allowed subtype/state before completion. Timeout alone is not a resource bound.

**OurNet lesson.** Keep our cursor paging, persistent delta agreement marks, policy-change invalidation and event-driven/coalesced fan-out. Reuse common verification infrastructure, but do not add a START/ACK round-trip when a request/reply already bounds and identifies the exchange. Where author-key dependencies exist, quarantine under strict budgets and request keys once per dependency. Never advertise unverified records as accepted or advance a sync agreement past unresolved work unless the protocol explicitly records rejection and retry semantics.

For carriers, distinguish:

| Fact | Meaning | Who may issue it |
| --- | --- | --- |
| Transport acknowledgement | Bytes arrived/assembled | Current link endpoint |
| Custody receipt | Verified object committed under an authorized retention policy | Carrier device |
| Recipient delivery | Authorized recipient device accepted the object | Recipient device |
| Read receipt | Recipient reports viewing it | Recipient device |

Xeres does not provide that complete durable custody model. OurNet already has signed handoff/receipt provenance; extend its defined semantics additively rather than treating a successful tunnel send as delivery.

References: `gxs/{GxsRsService,GxsTransactionManager,Transaction}.java`; OurNet `core/lib/src/node.dart`, `transport/lib/src/network.dart`, `PROTOCOL.md`.

### 9. File transport: availability is worth borrowing; verification is not

Xeres's transfer manager owns download/upload agents on a dedicated thread. Commands wake it; otherwise it sleeps until an agent's next deadline. Agents schedule peers in a priority queue. They request chunk maps, allocate nominal 1 MiB chunks across sources, receive smaller data slices (32 KiB maximum block), write by offset and retain a partial chunk map on orderly suspension. This can exploit incomplete sources and different available regions. Random allocation is supported, but it is not a rarity-aware BitTorrent scheduler.

`ChunkDistributor` reserves assigned chunks for ten minutes. It selects a candidate before checking the source's availability map; if that candidate is absent, it returns no work instead of searching the available intersection. This can underuse a partial source. Do not infer an optimal swarm scheduler from the existence of chunk maps.

The transfer engine is separate from transport, and virtual peers let it operate through tunnels. This is the most useful reuse boundary. However, a single manager processes synchronous file reads/writes and handles all agents, so a slow disk action can delay unrelated transfers. The command queue is unbounded. Inbound request validation checks the maximum chunk size in the manager, but wider offset, range, queue and authorization validation must not be assumed from that single check.

The bandwidth service advertises 75% of the local network-interface nominal bitrate, divided by eight. That is not measured internet bandwidth or fair per-peer allowance. A repository search found the peer allowance getter and own allowance getter without consuming call sites in production code. Upload pacing remains a fixed 50 ms schedule with a comment estimating 160 KiB/s for 8 KiB slices; download requests use smoothed observed speed. No full application QoS/backpressure controller was established.

The chunk-checksum response handler is unfinished. The inspected completion path marks and renames a file when its chunk map is complete without a visible whole-file verification step there. This is not a sufficient integrity model for OurNet to borrow. OurNet verifies encrypted chunk IDs/authentication while storing them, checks final size, retries only missing chunks, exports through a temporary file, and serves chunks only through an authorized object's manifest.

**Adaptation.** Add an optional authorized `blob availability` capability: request ranges/pages of manifest chunk positions, return a bounded bitset or list with short expiry, then assign work from `missing ∩ available`. Do not advertise private chunk IDs to arbitrary friends. Maintain a per-source in-flight and failure score, rotate retries after failure, and prioritize low-index chunks for sequential export/preview. Only consider rarest-first for background caching if measurements justify it. Persistent ciphertext chunks already provide restart recovery; persistent user transfer intent is the missing product layer.

Add shared global/per-person traffic budgets and reserve capacity for signals/messages. QUIC manages transport congestion, but does not choose OurNet's product priorities or prevent one person occupying all admitted application work. Backpressure must cover workers, network writes and stored custody, not just the number of futures.

References: `filetransfer/{FileTransferManager,FileTransferAgent,ChunkDistributor,SliceSender,FileDownload,RateTracker,BandwidthScheduler}.java`, `bandwidth/{BandwidthRsService,BandwidthUtils}.java`; OurNet `transport/lib/src/files.dart` and `_chunks`.

### 10. Live chat gossip is another separate mechanism

Chat lobbies relay signed messages/events among known participating neighboring locations. A message cache suppresses repeated forwarding; keepalives and challenges help maintain participants. Checks include room subscription, size, local bans and timestamps. This is a transient gossip network, not reliable historical sync.

The inspected signature helper returns true when the identity key is not yet available, permitting the item to pass through before validation. The relay path also has an unfinished anti-flood comment, and duplicate detection is after signature validation. OurNet should require validation before treating content as authored, and budget/deduplicate early enough to avoid repeated signature work. Quarantine unknown-key data rather than presenting/relaying it as verified. Membership claims, actual cryptographic authorship and permission to send into a room remain separate checks.

References: `chat/ChatRsService.java:682`, `:1078`, `:1123`.

### 11. Concrete OurNet work suggested by this study

| Priority | Change | Scope and compatibility |
| --- | --- | --- |
| 1 | Shared per-person/global request and byte budgets, with reserved control capacity | Local scheduling first; preserve current request meanings. Cover multiple connections/devices. |
| 1 | Jitter ordinary retry backoff and track request wait/throughput by class | Local-only; respect explicit busy responses. |
| 1 | Cancellation and connection-generation cleanup across all stages | Local lifecycle; do not cancel a healthy pooled link because one caller stops. |
| 2 | Authorized chunk-availability hints and smarter source assignment | Optional new capability/request; old peers keep current fetch behavior. |
| 2 | Discovery response paths with signed scope-bound headers | New optional request; strict expiry, budgets, no implied admission. |
| 3 | Durable carrier custody with differentiated receipts | Additive protocol/state design, per-friend quotas, ciphertext-only handling and retention policy. |
| 3 | Route abstraction for authenticated requests through authorized carriers | Preserve endpoint identity, policy and provenance; avoid substituting carrier identity for recipient. |
| 3 | Configurable own iroh relay/discovery infrastructure | Validate against binding support; do not add a second transport just for independence. |

The immediate code-quality lesson is to enforce aggregate budgets, not pile on individual constants. The largest feature lesson is that discovery and live route establishment can be small reusable services, while durable offline delivery needs a different state machine.

### 12. Validation needed before implementing these ideas

OurNet already has tests for connection reuse, delta sync, selective fan-out, backoff, restarted attachments, multi-source batches and bounded transfer queues. Extend those rather than replacing them. For new routing/custody, use deterministic in-process graph fixtures plus actual local QUIC endpoints:

- A–B–C with A/C never online together: B commits ciphertext custody, restarts, delivers to C, forwards C's receipt and eventually releases only releasable custody.
- A diamond and a cycle: repeated requests do no repeated heavy work, each result counts once, and alternate routes do not create duplicate deliveries.
- One friend opens many connections/devices: another friend's typing, message sync and call signalling still get service. Bound buffered bytes and queued work under a slow reader.
- A request is cancelled during dialing, writing, reading, decoding or storage: no stale route, orphaned waiter or late connection survives its generation.
- A revoked peer, forged address hint, wrong-session ACK, exhausted quota and expired route each fail individually without stopping the accept loop.
- Partial sources with complementary chunks, a corrupt chunk, a disappearing source and a restart all preserve verified progress and never export unchecked bytes.
- Capability rollout: peers without availability/routing support keep the current direct paths; unsupported features do not disable unrelated sync.
- Simulated clock jumps: local deadlines use monotonic elapsed time; remote timestamps do not cause data loss or lifetime extension.

Test performance separately from operation duration: bound per-turn work and demonstrate unrelated UI and requests remain responsive. Run relevant core/transport tests and analysis for implementation, extend note-history integration coverage for sync changes, and follow Windows profile/physical Android measurement requirements when changing preview/UI behavior. No production changes or benchmark claims were made in this study.

### Source index

All Xeres Java paths above are relative to `app/src/main/java/io/xeres/app` unless stated otherwise. Stable primary-source entry points:

- [Direct networking and discovery](https://github.com/zapek/Xeres/tree/d696baea6a84349204271fbd10f246cf3cf17af3/app/src/main/java/io/xeres/app/net)
- [Connection jobs](https://github.com/zapek/Xeres/tree/d696baea6a84349204271fbd10f246cf3cf17af3/app/src/main/java/io/xeres/app/job)
- [Turtle router](https://github.com/zapek/Xeres/blob/d696baea6a84349204271fbd10f246cf3cf17af3/app/src/main/java/io/xeres/app/xrs/service/turtle/TurtleRsService.java)
- [Turtle forwarding probabilities](https://github.com/zapek/Xeres/blob/d696baea6a84349204271fbd10f246cf3cf17af3/app/src/main/java/io/xeres/app/xrs/service/turtle/TunnelProbability.java)
- [Authenticated tunnels](https://github.com/zapek/Xeres/blob/d696baea6a84349204271fbd10f246cf3cf17af3/app/src/main/java/io/xeres/app/xrs/service/gxstunnel/GxsTunnelRsService.java)
- [GXS transaction manager](https://github.com/zapek/Xeres/blob/d696baea6a84349204271fbd10f246cf3cf17af3/app/src/main/java/io/xeres/app/xrs/service/gxs/GxsTransactionManager.java)
- [File transfer engine](https://github.com/zapek/Xeres/tree/d696baea6a84349204271fbd10f246cf3cf17af3/app/src/main/java/io/xeres/app/xrs/service/filetransfer)
- [Bandwidth service](https://github.com/zapek/Xeres/blob/d696baea6a84349204271fbd10f246cf3cf17af3/app/src/main/java/io/xeres/app/xrs/service/bandwidth/BandwidthRsService.java)
- [Live chat routing](https://github.com/zapek/Xeres/blob/d696baea6a84349204271fbd10f246cf3cf17af3/app/src/main/java/io/xeres/app/xrs/service/chat/ChatRsService.java)

Selected tests were inspected, and the test inventory includes SSL admission, packet pipelines, Turtle compatibility calculations, transaction state, chunk distribution and rate scheduling. The Turtle service test read here primarily checks a RetroShare-derived identifier calculation; it is not evidence of end-to-end routing/flood/failure coverage. Tests were not executed for this source-only review.
