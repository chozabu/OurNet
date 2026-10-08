# OurNet and RetroShare compared

Review of 8 October 2026. RetroShare is the friend-to-friend network OurNet
takes its inspiration from. This records how the two compare, what OurNet
could learn from it, and what we decided. RetroShare code read: the GUI at
`D:\git\RetroShare` (master, 15 September 2026) and `libretroshare` and
`BitDHT` at upstream HEAD `10afd02` (5 October 2026; the local checkout's
submodules were empty). RetroShare was read, not built or run, so statements
about how it behaves in use are partly from what is known of the project.

## In short

RetroShare has the deeper network: anonymous routing, file swarming,
pseudonyms and reputation, refined over about 20 years. OurNet is the better
product: mobile first, modern cryptography, real sync between a person's own
devices, everyday apps, and much more engineering discipline per line of
code. RetroShare's weak points are what OurNet was designed around. OurNet's
open gaps (carriers, reach beyond direct friends, offline delivery, discovery)
are problems RetroShare solved long ago, often in ways OurNet can borrow.

## Scale and shape

| | RetroShare | OurNet |
|---|---|---|
| Age, team | Since about 2006, many contributors | Since August 2026, one developer and AI |
| Core | About 257k lines of C++ (libretroshare) | About 15k lines of Dart (`core`, `transport`) |
| UI | About 180k lines of Qt Widgets, 56 translations | About 41k lines of Flutter, English only |
| Tests | Old unit tests and a network simulator, uneven | About 450 tests across core, transport, widgets and integration, plus timing budgets |
| Stack | OpenSSL, RNP (PGP), SQLCipher, BitDHT, UPnP, Tor and I2P control | `cryptography`, sqlite3, iroh QUIC, WebRTC |
| Licence | libretroshare LGPL-3, GUI AGPL-3 | AGPL-3 |

RetroShare owns its whole network stack: its own transport (`pqi`), its own
TCP over UDP (`tcponudp`), its own DHT and serialisation. OurNet hands all of
that to iroh, so about 2.5k lines of transport replace roughly 50k.

## Area by area

### Identity and devices
- **RetroShare:** an RSA PGP key is the person, and each device ("location")
  has its own SSL certificate. It has had one person on many devices since
  about 2010, but each location is a silo: chat history, subscriptions, mail
  and files do not sync between a person's own locations. On top of that are
  GXS identities: unlimited pseudonyms, anonymous or signed by the PGP key,
  used in forums, chat lobbies, distant chat and mail.
- **OurNet:** an Ed25519 root, root-signed device certificates and X25519
  agreement keys. Devices share content, contacts, subscriptions and personal
  state, grant each other keys for older history, and hold a root copy sealed
  under the recovery phrase.
- **OurNet ahead** on multiple devices, the most important everyday
  difference. **RetroShare ahead** on pseudonymity, which OurNet leaves out on
  purpose. Neither can rotate a root key.

### Making friends
RetroShare: paste a long certificate or short invite; an optional friend
server, reached over Tor, matches strangers; LAN broadcast discovery.
Onboarding is famously hard. OurNet: expiring single-use invites, QR codes,
LAN discovery, comparison codes, connecting along a public friend chain, and
members asking to add people to groups. **OurNet clearly ahead.** RetroShare's
friend server is the kind of central hub OurNet avoids.

### Reachability and NAT
RetroShare: UPnP and NAT-PMP, BitDHT (Kademlia on the BitTorrent DHT), its
own UDP hole punching, relaying through a friend, proxies, Tor and I2P hidden
nodes. Capable but fragile, and weak on mobile carrier-grade NAT. OurNet: iroh
QUIC hole punching with HTTPS relays as fallback, endpoint rebuilds on network
changes, a relay watchdog. **OurNet ahead on reliability for little code;
RetroShare ahead on independence**: OurNet relies on number0's relays and
discovery until own relays (CONNECTIVITY.md piece 5) exist, and the relay
operator sees connection metadata.

### Offline delivery and reach
RetroShare's clearest lead:
- Distant mail (GRouter, GxsTrans) is routed through friends and held for
  days until the recipient appears: OurNet's friend carrier design, working.
- That a forum or channel exists spreads to every friend, so groups are found
  beyond direct friends; posts sync only between subscribers, as in OurNet.
- Channels and forums can be found and fetched from non-friends over
  anonymous turtle tunnels.

OurNet has carriers designed but not built (nothing sets `via` yet), and
forum posts stop at subscribed direct friends ([idea 2](#2-forum-discovery)).
Until [idea 3](#3-per-path-evidence-done), every object also stopped after
about 63 device deliveries.

### Cryptography
| | RetroShare | OurNet |
|---|---|---|
| Signing | RSA-2048 with SHA-1 for GXS (`gxssecurity.cc`), RSA PGP | Ed25519 |
| Content encryption | AES-128-CBC with an RSA envelope; tunnels AES with HMAC-SHA1 | X25519, HKDF, ChaCha20-Poly1305 |
| Link | TLS preferring ephemeral DH, falling back to `HIGH` ciphers without forward secrecy | QUIC with TLS 1.3, forward secret |
| Forward secrecy of content | Per hop: chat over TLS, distant chat over ephemeral DH tunnels | None: static recipient envelopes |
| At rest | GXS database under SQLCipher; private group data in plaintext on members' devices | Private payloads stay encrypted; the database is not, and some derived tables are plaintext (friends' `positions`) |
| Passphrase stretching | PGP passphrase | Argon2id at 64 MiB |

OurNet's primitives are a generation ahead; RetroShare is stuck on RSA and
SHA-1 because signatures are embedded in stored data. RetroShare has forward
secrecy for chat and OurNet does not. That matters more once carriers hold
OurNet ciphertext. Neither project has been audited.

### Privacy and metadata
RetroShare hides the social graph: friends of friends are anonymous, turtle
tunnels hide who downloads or searches, and a node can run over Tor or I2P
alone. OurNet publishes the friend graph and signs every handoff, on purpose.
These are opposite philosophies: RetroShare suits activists and hostile ISPs,
OurNet an accountable network of real friends. OurNet should say plainly that
it is not an anonymity tool, since people coming from RetroShare may assume it
is.

### Data model and sync
RetroShare GXS is a generic exchange of signed groups and messages, with
admin and publish keys, circles, and a reputation check before accepting
messages. Sync runs every 60 seconds, 20 items per request, messages up to
200 KB, and every service is a thin layer over it. It is elegant, but heavy,
slow to propagate and a long-standing source of performance trouble. OurNet
has independent signed objects, handoff evidence, cursor-paged inventories,
Lamport registers, note branches and group epochs. **OurNet ahead** on
incremental cost and convergence. **RetroShare ahead** on one abstraction
reused everywhere; OurNet's per-kind rules in PROTOCOL.md keep growing.

### Groups and communities
RetroShare: forums, channels (one-to-many publishing with files, its
standout feature), boards (Reddit-like, voted), chat lobbies, circles,
reputation and a ban list, and The Wire (off by default). OurNet: private
groups with keys and epochs, members adding people, owner-moderated `forum2:`
forums, shared lists, group calendars and notes, group calls, and voting with
delegation, which RetroShare lacks. **RetroShare ahead** on public communities
and abuse handling; **OurNet ahead** on private small-group collaboration.

### Messaging and calls
RetroShare: 1:1 chat (online only, plus distant chat), lobbies, mail; a dated,
desktop-only VOIP plugin. OurNet: 1:1 and group chat with delivery and read
receipts, voice messages with on-device Whisper, WebRTC calls that ring a
locked Android phone, group calls as a mesh of up to 8. **OurNet far ahead.**
Its gap: no TURN or media over iroh yet, so calls fail between two
carrier-grade NATs.

### File sharing
RetroShare: shared directories with hashing, browsing friends' files,
anonymous search across the network, swarming multi-source downloads,
per-friend sharing flags, banned-file lists, deep indexing, large files.
OurNet: encrypted 128 KiB chunks, 64 MiB per file, downloads
from the author and then other holders, private drive sync with revisions; no
search, swarming or resumable large transfers. **RetroShare far ahead** on
file sharing; OurNet's drive sync between own devices has no RetroShare
equivalent.

### Everyday apps
OurNet: Keep-style notes and widgets, a calendar with recurrence and ICS,
maps with live location and offline tiles, drive sync, voting. RetroShare:
only a calendar added in October 2026 (`p3gxscalendar`, 323 lines, raw ICS in
GXS messages). **OurNet clearly ahead.**

### Platforms and distribution
RetroShare: Windows, Linux and macOS; a headless `retroshare-service` with a
JSON API and web UI; Android only as an experimental service with the web UI;
no store presence. OurNet: Android (Play internal testing) and Windows
(Microsoft Store), foreground service, background sync, Windows notification
area; no Linux, macOS or iOS. **OurNet ahead** for ordinary users,
**RetroShare ahead** for Linux, servers and scripting.

### Extensibility
RetroShare: a plugin interface (VOIP and FeedReader are plugins), per-friend
service permissions (`ServicePermissionDialog`), a JSON API generated from its
headers, bandwidth limits and QoS. OurNet: a basic headless CLI node.
**RetroShare ahead.**

### Engineering practice
OurNet: performance budgets with profile-mode baselines, rules against
rescanning history, additive protocol changes checked by upgrade fixtures, a
PROTOCOL.md that describes what is implemented, no TODO comments.
RetroShare: 129 TODO/FIXME comments, `unfinished/` and `unused/` directories,
compile-time feature flags leaving half-maintained paths, documentation its
README calls lacking. RetroShare's code has, however, survived years of
hostile real-world use, and OurNet's has not.

## Where each is ahead

**RetroShare:** anonymity (turtle routing, Tor and I2P, hidden graph);
offline mail through friends; group discovery beyond direct friends; file
sharing; pseudonyms and reputation; public community tools and abuse handling;
no dependence on a company's relays; Linux and headless use; plugins, JSON
API, per-friend permissions, bandwidth control; forward secrecy for chat;
maturity.

**OurNet:** sync between a person's own devices, with recovery; onboarding;
reliable NAT traversal on mobile; a real Android app and store distribution;
modern cryptography; calls; everyday apps; provenance, which RetroShare lacks;
convergence semantics; performance and compatibility discipline; a codebase
about 17 times smaller.

## Ideas from RetroShare, and what we decided

### 1. Custody rules for carriers
RetroShare's GRouter finds routes without knowing the graph, sending items
probabilistically and learning from returning receipts. OurNet does not need
that: the friend graph is public, so senders choose routes (`via`). What does
apply is how it holds items: keep until a receipt arrives, pass receipts back
along the path so upstream holders drop their copies, expire after a few days,
suppress duplicates arriving by two paths, and give each friend a quota. Copy
those when building carriers. The graph is only as complete as friend lists'
reach, which the evidence change below improves.

### 2. Forum discovery
RetroShare relays every forum's header to every friend, subscribed or not,
which floods users with junk forums; it copes with reputation filters,
expiring unsubscribed headers and showing how many friends follow each. The
proposal for OurNet: a header travels only when a person passes it on.
Subscribing or recommending publishes a small signed header that friends see
as "Forums your friends follow: Cooking (3 friends)", limited to friends of
friends and not relayed automatically. A flood then needs real friends to
choose to pass a forum on, and every hop is accountable. For posts to reach a
new subscriber C whose friend B does not follow the forum, prefer admitting
C's device to a subscriber for that forum's space only (scoped admission, as
group members are admitted) over making B carry posts it does not read. Not
yet decided or built.

### 3. Per-path evidence (done)
Evidence used to be one set per object, merged between every holder and
capped at 128 records. Each delivery to a device adds a handoff and a receipt,
so an object stopped after about 63 device deliveries in total, whatever the
path shape: forum posts past that many subscribers, messages in groups of
about 32 people with two devices each, and profiles, friend lists and
revocations in any network of more than about 60 devices. A revocation could
miss a direct friend if friends of friends synced first. Every holder also saw
every delivery, with device names and times.

Per-hop provenance is a core OurNet feature, so the records are kept, but per
path: a device holds the chain that brought an object to it and its own
deliveries, and reconciles with each peer only what the two should share
(receipts from readers also flow back to the author and its carriers, so
delivery status still works). Implemented on 8 October 2026; see
[PROTOCOL.md](PROTOCOL.md#handoff-evidence), PROTOCOL_CHANGELOG.md and
`core/test/evidence_paths_test.dart`. How it scales:

- An item carries its path: about two records per hop, plus at most 32
  reader receipts between upstream devices. 128 records per item caps depth
  at about 60 hops, not reach.
- A device stores its path plus two records per delivery it made itself, so
  storage grows with its own work, not with an object's audience.
- Inventories add a 64-bit digest per object shared with the peer (left out
  when they share nothing), about 66 bytes an entry, roughly 60% more than
  before. A sync with nothing new on the 991-object history test took 26 ms.
- Builds without it keep merging what they are sent, so while one of them
  holds an object, evidence passing through it still spreads and still stops
  at its 128. While the rollout is mixed, an older peer holding many objects
  that this device has delivered to more than 63 devices re-offers them on
  every sync.
- The second forum limit is untouched: a friend who does not follow a forum
  still does not relay it (see 2).

Decided afterwards (8 October 2026): no hop limit and no limit on forum size.
Identity objects (profiles, pictures, friend lists, revocations) are relayed
to every friend, followed or not, so without the old cap they now reach the
whole connected network and every device keeps every reachable person's
newest ones, with earlier versions never deleted. Left unlimited for now;
revisit scoping them (pictures to a few hops, friend lists to the chain
length connecting looks for) and deleting superseded versions when networks
grow large. To keep unlimited reach safe, the 512 MiB bounds became one
configurable storage limit (20 GiB, with a warning at 5 GiB), and a device
hands an object on along its shortest chain and does not offer paths a
receiver would refuse.

### 4. Per-friend permissions and bandwidth
RetroShare has a grid of friends against services (chat, forums, channels,
file transfer, tunnels, VOIP, distant chat) with per-friend overrides
enforced centrally, global and per-friend bandwidth limits with flow control,
priority queues, and per-friend file-sharing groups. In OurNet every admitted
friend gets location (if sharing is on), can ring, can fetch chunks they are
allowed, relays forums they follow, passes connect requests, and will be able
to use carrier storage, while the only budgets are global (one storage limit,
20 GiB by default since 8 October 2026, and 4 inbound requests). Proposed: per-friend switches (location,
calls ring, silent or blocked, carry for them, relay their connect requests,
add me to groups) in synced personal state; per-friend quotas for carried
storage and chunk requests, so one friend cannot fill the shared budget;
messages ahead of file chunks; and scoped admission for spaces. Not yet
decided or built.

### 5. Reputation
RetroShare rates identities: opinions are combined across friends, and
relays drop content from low-scoring ones. We do not want to rate people.
Alternatives in keeping with OurNet: moderation scoped to a forum (owner and
delegated moderators sign bans that relays honour within that forum),
per-author rate and size limits per forum, and optionally sharing one's
blocks with friends as advice ("2 of your friends blocked this person"),
never aggregated beyond one hop and never a score.

### 6. Forward secrecy
Secrecy matters less to OurNet than to RetroShare. Links are already forward
secret. The exposure is ciphertext on others' devices plus a later stolen
device key, which carriers deleting on delivery reduces more than any cipher
would. Cheapest worthwhile steps: rotate device agreement keys periodically
(keeping payload keys in a local table under the vault, as key grants do;
not yet built), and add algorithm identifiers to signatures and envelopes,
additively, which RetroShare never did. The identifiers are done (0.2.25):
signed data carries `sig: 'ed25519'` among its signed fields, and encrypted
payloads, sealed roots and sealed backups carry `aead: 'chacha20-poly1305'`.
Absent means those algorithms; anything naming another is refused
individually. See [PROTOCOL.md](PROTOCOL.md) and PROTOCOL_CHANGELOG.md.

## Lessons to avoid
- Cryptography with no way to upgrade it (algorithm identifiers added in
  0.2.25; root keys still cannot be rotated).
- Per-device silos (already avoided).
- Services nobody maintains: RetroShare's wiki, Wire and photo services sit
  half-finished behind compile flags. Keep the "built and verified" bar of
  PARITY.md as kinds are added.
- The complexity that kept RetroShare niche.
