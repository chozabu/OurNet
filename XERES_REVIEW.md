# Xeres review for OurNet

Reviewed 11 October 2026. Xeres snapshot: `d696baea6a84349204271fbd10f246cf3cf17af3`, cloned to `.research/Xeres`. OurNet comparison uses this workspace's current code. This is a broad source survey with deeper inspection of selected systems, not an audit of every line. Neither application was built, run or benchmarked for this review; apparent UX advantages are inferred from controllers, views and help text.

Xeres is Java, not JavaScript: Spring Boot backend, JavaFX desktop UI, a shared `common` module, H2 storage, Netty networking and Bouncy Castle/JCA cryptography. JavaScript is available for scripts. Its README advertises compatibility with RetroShare 0.6.6 and later; the source contains the corresponding binary packet/TLV serializers, service negotiation and GXS/Turtle implementations. Interoperability was not independently tested.

The most useful lessons are a usable always-on node, better transfer management, whole-database encryption, shared community infrastructure, and explicit privacy documentation. Replacing OurNet's protocol or transport with RetroShare's would sacrifice several of OurNet's existing strengths.

## Scale and review coverage

| Measurement | Xeres | OurNet |
| --- | ---: | ---: |
| Production language files | 1,073 Java | 134 Dart |
| Production physical lines | 121,613 | 57,618 |
| Test/support Java files | 360 | Not counted here |
| Test/support Java physical lines | 34,640 | Not counted here |

Counts cover Xeres's three `src/main/java` trees and OurNet's `core/lib`, `transport/lib`, `app/lib`. Xeres test counts include `src/test` and `testFixtures`. Physical lines include comments, blank lines and repeated licence headers. Resources, dependencies, OurNet Rust and platform code are excluded. These are size indicators, not measures of complexity or quality; test files are not test cases. Xeres is smaller than the full RetroShare project, but is not a tiny implementation.

Inspected repository/module structure, networking and serializer inventory, service registration/negotiation, selected GXS transaction and verification paths, Turtle search/routing limits, file transfer manager/agents/chunk distribution/scheduling, community services, reputation, REST controllers, paging, remote authentication, database encryption/migrations, backups, UI support/controllers, architecture tests and user documentation. Read relevant OurNet storage, networking, files and private-forum paths alongside its protocol and existing RetroShare comparison. Peripheral implementations such as audio codecs, every serializer and every UI controller received less scrutiny.

## Where Xeres is ahead, and what to adapt

### 1. A personal node is an actual product

Xeres has REST controllers for contacts, chat, groups, files and statistics, WebSocket notifications, JavaFX clients, remote mode and Docker deployment. Its Android offering is a client of a running node, rather than an independent mobile RetroShare node. Remote documentation describes TLS 1.3 and certificate pinning in the Android client; that separate client's implementation was not inspected.

OurNet already separates `core`, `transport` and Flutter, and has a headless CLI. What it lacks is a similarly complete operator/client boundary and packaged always-on experience. This is especially relevant to phones sleeping and keeping content available while a laptop is closed.

Adapt: package an own-device node with persistent storage, service restart, pairing, updates and a small status/control API. Keep it an admitted device with normal device permissions and revocation. Prefer authenticated existing device links for control; exposing a new HTTP API is optional. An always-on own device improves availability, but does not itself implement friend-carrier routing.

Evidence: `app/api/controller`, `ui/client`, `docker-compose.yml`, `ui/src/main/resources/help/en/04g.Remote.md`; OurNet `transport/bin/node.dart` and `transport/lib/src/network.dart`.

### 2. File sharing is a first-class workflow

Xeres has shared files, network search, download/upload views and search trends. Its transfer engine tracks chunk availability, assigns work across sources, persists partial-download chunk maps, and schedules peers. A partial download can supply completed portions to others. Transfers work over direct and Turtle virtual peers.

OurNet already has encrypted content-addressed chunks, multiple potential holders, four concurrent batch requests per fetch, bounded job queues and verified chunks retained across restarts. It would be inaccurate to call its transfers non-resumable or single-source. Xeres's lead is the broader file-sharing workflow and explicit chunk availability/scheduling, not simply parallelism.

Adapt: a transfer centre showing direction, bytes, source availability, queue state, failure/retry and cancel; an explicit paused state with persisted transfer intent; throughput/fairness controls that reserve capacity for chat, calls and sync; source availability hints so requests avoid holders known to lack chunks. Preserve object authorization and ciphertext storage. The current 64 MiB limit needs a larger-file design and measurements, not just a larger constant.

Do not copy its timing constants: upload scheduling still uses fixed 50 ms delays and comments acknowledge incomplete bandwidth accounting. Its `fileCommandQueue` is an unbounded `LinkedBlockingQueue`; keep OurNet's bounded queues.

Evidence: `xrs/service/filetransfer/{FileTransferManager,FileTransferAgent,ChunkDistributor,FileDownload,BandwidthScheduler,FileTransferRsService}.java`, `ui/controller/file`; OurNet `transport/lib/src/files.dart`.

### 3. Whole-database encryption protects metadata too

Xeres configures H2 with `CIPHER=AES` and converts older plaintext databases. Its help explains using Windows DPAPI to remember the database credential.

OurNet opens ordinary SQLite. Private object contents, private blobs and previews are encrypted, but table structure, identifiers, kind/space/time information and routing/peer indexes remain visible. A recovery phrase or encrypted backup does not encrypt the live database.

Adapt: design whole-database encryption with a random database key protected by the vault/OS keystore. Include WAL/journal behavior, upgrades, backups, crash recovery and locked-device background access. This complements existing payload encryption. Xeres does not prove all exported/downloaded files are encrypted: its download engine writes ordinary files, and its backup method serializes key material to XML. Evaluate each export independently.

Evidence: `configuration/DataSourceConfiguration.java`, `service/backup/BackupService.java`, `ui/src/main/resources/help/en/07h.Remember credentials.md`; OurNet `core/lib/src/store.dart`.

### 4. Community features share infrastructure

Forums, channels, boards and identities share `GxsRsService`, authentication requirements, transactions, signature verification and helper services. Channels require a publish signature for root posts; boards require author signatures. Comments and votes reuse shared models. Group headers can be learned separately from downloading subscribed content.

OurNet's generic signed objects are already a good foundation. The opportunity is to avoid repeating feature-specific validation, discovery, moderation and presentation logic as kinds grow. A channel is a useful small feature: announcements/resources published by authorized people, with discussion separately controlled. It should reuse existing audiences and provenance.

Adapt: shared, explicitly registered policies for author permissions, audience/relay rules, moderation and feature capabilities. Community discovery should use small signed recommendations/headers with bounded expiry and scopes. Keep user choices about what is relayed; do not inherit automatic propagation of every discoverable group.

Do not assume full private-community support: `isGxsAllowedForPeer` rejects `EXTERNAL`, and `isGxsAllowedForFriendGroup` returns false with an implementation comment. OurNet's private membership/key workflows are more complete in the inspected paths. Also keep OurNet's incremental/event-driven sync: Xeres periodically loops through subscribed groups and can return broad ID lists after detecting an update.

Evidence: `xrs/service/gxs/GxsRsService.java`, `xrs/service/{channel,board,forum}`, OurNet `core/lib/src/{node,everyday,room_forum}.dart` and `transport/lib/src/network.dart`.

### 5. Reach beyond direct friends is implemented

Turtle supports search and tunnels across friends, with request IDs, duplicate suppression, response routing, hit limits, request-size limits, timeouts and idle cleanup. GXS tunnels exchange authenticated DH material for distant chat. This gives Xeres real discovery/file/chat reach beyond a direct peer link.

OurNet deliberately publishes a graph and records provenance. Anonymous Turtle routing cannot simply be added while retaining those promises unchanged. The transferable lessons are bounded request propagation, duplicate suppression, expiry, reverse response paths and cleanup when a route disappears.

Adapt these mechanics for accountable friend-carrier delivery and scoped discovery. Anonymous routing, Tor/I2P integration and pseudonyms require an explicit product decision. Do not assume Xeres implements all of RetroShare's offline mail capabilities: the inspected `MailRsService` handles direct mail; this review did not establish a complete GRouter-style offline custody path.

Evidence: `xrs/service/turtle/TurtleRsService.java`, `xrs/service/gxstunnel/GxsTunnelRsService.java`, `xrs/service/mail/MailRsService.java`.

### 6. Network behavior is inspectable

Xeres exposes RTT, traffic counters and Turtle statistics through both API and UI. Downloads and uploads are visible independently. OurNet already has relay status, sync health, errors and per-sync progress, so the useful extension is quantitative visibility rather than another generic status indicator.

Adapt: bytes by traffic class, outstanding work, source/route availability, retry timing and a copyable redacted explanation of why an operation is waiting. Measure incrementally, without scanning stored history.

Evidence: `api/controller/statistics/StatisticsController.java`, `ui/controller/statistics`; OurNet `app/lib/ui/{sync_health,sync_status}.dart`.

### 7. Privacy and trust choices are explained specifically

Xeres ships individual help pages for DHT, LAN discovery, DNS, UPnP, update checks, link previews, external URLs and remembered credentials. Its link-preview documentation explicitly says fetching happens from the reader's device and exposes their IP to the destination. Contact trust currently has limited functionality; one documented use is enabling previews only for fully trusted friends.

Adapt: explain OurNet's iroh discovery/relays, STUN/TURN, map tile requests, public graph, location sharing and background networking next to their controls. If adding rich previews, prefer sender-supplied signed preview data or an explicit fetch choice, with bounded processing and clear origin. Avoid silent recipient-side requests caused by arbitrary received messages.

Xeres also gives local opinions precedence over friends' aggregate reputation. We can take the local-control principle without adopting a global score for people: forum-scoped moderation, personal blocks and attributed advice suit OurNet better.

Evidence: `ui/src/main/resources/help/en/07*.md`, `03b.Contacts.md`, `service/ReputationService.java`.

### 8. Architecture rules are executable

Xeres's ArchUnit tests prohibit backend access to UI classes except designated bridges and check service/item conventions. It also uses Flyway SQL migrations and separate data-folder upgrades.

Adapt: enforce `core`/`transport` independence from Flutter, keep authorization/crypto out of widgets, and check protocol-policy registration. OurNet's saved-profile upgrade fixtures and performance budgets remain valuable; SQL migrations alone do not replace them. Test counts do not establish superior test coverage.

Evidence: `app/src/test/java/io/xeres/app/AppCodingRulesTest.java`, `common/src/testFixtures`, `app/src/main/resources/db/migration`.

## Advantages OurNet should preserve

- Independent own-device synchronization and historical key grants. Xeres's remote client is a different tradeoff; chat backlog is stored against locations/identities, not evidence of OurNet-style device convergence.
- Existing private-group encryption and collaboration: notes, calendars, drive revisions and group calls have no directly comparable complete workflow in the inspected Xeres tree.
- Modern wire primitives and algorithm identifiers. Xeres uses RSA/SHA-1 in compatibility paths, although it also has newer ChaCha20-Poly1305 helpers. Do not describe its entire crypto stack as legacy or infer system security from primitive names alone.
- Iroh's QUIC transport and relay fallback. Xeres's TCP/DHT/proxy paths demonstrate alternatives, but this review does not establish better NAT reliability or independence from all infrastructure.
- Bounded attachment workers, durable encrypted previews and incremental history behavior. Xeres uses keyset paging and bounded image caching, but also has broad periodic group loops and an unbounded transfer command queue. No measured performance winner is established.
- Accountable provenance and person/device identity. Changing anonymity semantics would be a product/protocol change, not a refactor.

## Suggested order

1. Transfer centre and diagnostics, retaining encrypted caches and existing concurrency bounds. Define user-visible paused/cancelled/failed states and test interruptions and restarts.
2. Whole-database encryption design and migration prototype. Benchmark real history and validate backup/recovery/background access before adoption.
3. Packaged own-device node. Validate that a phone can receive history/files after other interactive devices go offline; document that friend carriers remain separate work.
4. Scoped community discovery and a small publishing/channel workflow using existing permission semantics.
5. Carrier routing/custody with per-friend quotas and expiry. Borrow Turtle's resource-control patterns, not its anonymity promises.

Privacy explanations and dependency-boundary checks are small improvements that can accompany this work. This order prioritizes benefits to current users before expanding the protocol surface.

Source links can be resolved under [the reviewed Xeres snapshot](https://github.com/zapek/Xeres/tree/d696baea6a84349204271fbd10f246cf3cf17af3). Paths above are relative to `app/src/main/java/io/xeres/app` unless their module or resources/test prefix is shown explicitly.
