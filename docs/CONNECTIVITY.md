# Connectivity and friend carriers

Design, 19 September 2026. [PROTOCOL.md](PROTOCOL.md) describes what is
implemented; this document says what we are building and why. Sections marked
*implemented* are also described there.

## Why

### The goal

Two friends should stay in touch as reliably as they would on a centralised
messenger: a message sent now arrives soon, wherever each of them is and
whichever network they are on. And they should get this without an account
server, a mailbox operator or any other party that must exist for OurNet to
work.

### Being reachable is mostly solved

Home routers and mobile networks put both friends behind NAT. iroh handles
this: it punches a direct QUIC path when it can (usually between home
networks), and otherwise falls back to a relay that forwards encrypted packets
over HTTPS, which gets through almost any network (typically carrier-grade NAT
on mobile). When both devices are online they connect, directly or through a
relay. The remaining weaknesses here are smaller: reliance on number0's public
relays and discovery, and calls, whose media did not use any fallback path.

### Being online at the same time is the real problem

A phone stops networking when OurNet goes to the background. That saves
battery, but it means two phone-only friends exchange anything only while both
have the app open at the same moment. A message can sit on the sender's phone
for hours.

Waking up periodically does not fix this on its own. If each phone wakes every
15 minutes for a few seconds, two phones' wake-ups almost never overlap. Two
sleeping devices cannot reach each other. Either something wakes the
recipient while the sender is still online, or a third device that *is* online
holds the message until the recipient appears.

### Why not a mailbox server

A server that stores everyone's messages would solve the timing problem, but it
contradicts the project: it becomes the thing that must be operated, trusted,
funded and kept available, and a point where metadata collects. Infrastructure
in OurNet should be help that friends choose to offer each other, never a hub
that everyone depends on.

### Why friends are the answer

Friends are already the trust boundary. Their devices are already admitted,
they already exchange objects, and between them they have a variety of
uptimes: someone has a desktop left on, a phone on Wi-Fi and charging, a
Raspberry Pi. If friends can carry each other's messages, the network gets
most of the benefit of a mailbox, without anyone running one for strangers.

This fits the open question in [CORE_IDEA.md](CORE_IDEA.md) about
friend-to-friend routing. Stored data (messages, then files) can travel over
friendship links. Live media, where latency matters, connects directly.

### The friend graph is public

Every device that passes an object on signs handoff evidence for it, and
recipients can inspect that path. Who is friends with whom is therefore not
secret, and we do not design around hiding it. Using the graph openly is what
makes routing through friends of friends possible. We protect content, not the
fact of friendship.

## Principles

- **No required infrastructure.** Every piece can be absent and OurNet still
  works between two devices that are online together.
- **Help is opt-in and bounded.** Carrying for others is a choice, with a
  storage quota set by the person providing it.
- **Carriers never read content.** They hold ciphertext and learn metadata only.
- **Anyone can run infrastructure for their friends.** A relay, a carrier or a
  push distributor should be as easy to offer as it is to use.
- **Low power by default.** Background work is short and infrequent; faster
  delivery comes from wake-ups, not from staying connected.

## Plan and status

| # | Piece | Solves | Status |
|---|---|---|---|
| 1 | Default STUN for calls | Calls between two home networks | Implemented |
| 2 | Android background sync | Collecting queued messages without opening the app | Implemented |
| 2b | Stay online after sending | Recipient's wake-up finding the sender offline | Implemented |
| 3 | Friend carriers (below) | Delivery when sender and recipient are never online together | Designed |
| 4 | Stay connected (Android foreground service) | Fast delivery; ringing a sleeping phone | Implemented |
| 4c | Windows notification area | The same on a desktop: closing the window no longer disconnects | Implemented |
| 4b | Push wake-up (FCM through a push server) | The same with less battery | Implemented; needs a Firebase project and the server deployed |
| 5 | Own relays, shared in contact cards | Dependence on number0's relays | Relay list implemented; no OurNet relay deployed yet |
| 6 | Call media over iroh when ICE fails | Calls behind carrier-grade NAT without TURN | Spiked, not shipped (below) |
| 7 | Packaged friend node (relay, carrier, push) | Making 3–5 one command to offer | Planned |
| 8 | Friend relays: live traffic through a mutual friend's device | No direct path, and relays blocked or down | Implemented, not yet tested across real NATs ([FRIEND_RELAY.md](FRIEND_RELAY.md)) |

### Relay list (implemented)

Internet mode no longer binds with iroh's built-in default relays. It passes an
explicit list: relays added in Settings (kept on that device), OurNet's own
(`PeerNetwork.ourRelays`, empty until one is deployed), then number0's four
public relays. iroh takes the fastest as the home relay and moves to another
when it fails. A device's address names its home relay, and peers dial that
relay directly, so devices with different lists still reach each other. An
entry that is not a relay URL is skipped rather than stopping the network.

Each device's health shows how it was last reached: direct on the local
network, direct over the internet, or through which relay. This comes from
iroh's path events on every admitted connection (`PeerNetwork.paths`, also in
diagnostics).

### More direct paths (implemented)

Every connection that goes direct instead of through a relay is faster and
leaves the relay operator out of it. Three changes from October 2026 aim at
more of them, with no new infrastructure:

- **Port mapping.** Our iroh binding (`vendor/iroh_mobile/rust`) had been
  built without iroh's `portmapper` feature, and the upstream prebuilt
  Windows library the same. iroh now asks the router for a port mapping
  (UPnP, NAT-PMP or PCP) and announces the mapped address, so a device
  behind a home router that allows it becomes directly reachable even from
  networks where hole punching fails. Windows builds now use our own build
  of the binding (`tool/build-iroh.ps1`, run by `tool/setup.ps1` and
  `tool/package.ps1`), as Android already did; Linux still uses the
  upstream library (see `tool/setup.sh`).
- **Friends' address hints in the lookup.** Devices already gossip each
  other's addresses (`address/<device>`, learned in every exchange). iroh's
  address lookup now asks those stored hints as well as number0's DNS
  lookup, rather than only when a dial starts, so a device stays findable
  when number0's record is stale or unreachable. The hint is answered from
  the store, never from the network. Our binding exports a marker symbol
  (`ournet_address_lookup_keeps_n0`) because upstream's would drop number0's
  lookup for ours; without it OurNet binds as before. No DHT and no mDNS.
- **Measuring it.** Diagnostics count connections since the network started,
  for each device and in total (`connectionPaths`), by the path each ended
  on: local network or internet, IPv4 or IPv6, or relay, and how many began
  on a relay and moved to a direct path. The counts are kept as connections
  close, never by scanning.

### Call media over iroh (spiked, not shipped)

The idea: when ICE fails, carry WebRTC's packets as QUIC datagrams on the
iroh connection the call's signalling already uses, which reaches through a
relay where nothing else does. Each side runs a local UDP shim and offers it
to its own WebRTC as an extra candidate; ICE, DTLS and SRTP run through it
unchanged. The spike (`app/integration_test/call_iroh_spike_test.dart`,
October 2026, Windows) found:

- libwebrtc never sends to a loopback candidate (127.0.0.1): no packet
  reached the shim and the link failed. The planned loopback shim does not
  work.
- A shim on the device's own network address does connect, through iroh
  datagrams alone (ICE and DTLS, packets up to 628 bytes). Not tried: media
  (RTP packets near 1,200 bytes, which may exceed what a datagram carries
  over a relay), Android, two devices on different networks, and the cost of
  passing every packet through Dart.

So nothing ships; calls keep ICE with STUN as before. Continuing would mean
the own-address shim, a fallback for packets too large for a datagram, and
moving the packet pump out of the UI isolate (or into native code), then
checking it between a phone and a desktop on separate networks.

### Default STUN (implemented)

Calls previously used no ICE servers unless configured, so they could not
connect across two NATs. With no configuration, calls now use public STUN
servers (Google, Cloudflare); local mode uses none. STUN operators learn the
caller's IP address, not the call. TURN is still needed on networks where a
direct path is impossible; piece 6 aimed to remove that need, and is not
shipped (above).

### Android background sync (implemented)

A WorkManager task runs about every 15 minutes when there is a network. It
syncs every admitted device, then keeps answering for 10 seconds for peers
that are retrying. It can be turned off in Settings. What it collects is
announced by notifications: one per chat, whose Reply and Mark read buttons
work the same way, opening the profile briefly if the app is not running.

On its own this helps when the other side is online: a friend's desktop, or
anyone with the app open. Combined with carriers, a phone collects waiting
messages within roughly one period. Staying connected (piece 4) is what makes
delivery fast.

WorkManager usually runs in the app's own process, where the profile's file
lock does not exclude it. So the profile has one owner at a time, registered
in the isolate name server. A background run or notification button hands
its work to a live app isolate instead of opening the profile a second time,
and the app asks a background run to finish before opening the profile.

### Stay online after sending (implemented)

When OurNet goes to the background with messages that no recipient device
has acknowledged yet (no receipt), it stays online instead of stopping the
network, for up to 3 minutes or until the receipts arrive. Android freezes
a backgrounded app within seconds, so the wait runs in a one-off WorkManager
task, which Android lets run; it is handed to the app isolate like any other
background work.

### Stay connected (implemented)

Android can keep an app running, and online, in a foreground service, as
long as it shows a notification. With "Stay connected" (on by default on
Android), OurNet runs one, so it stays reachable while in the background or
swiped away: messages arrive within seconds, notifications appear, and calls
can ring. Friends need nothing extra, and no third party is involved.

The service keeps the app's own Flutter engine alive beyond its activity, so
everything runs exactly as when the app is open; reopening attaches to the
same engine. If Android restarts the process, or after a reboot or update,
the service starts the engine itself. The service is declared as a special
use (peer-to-peer messaging), which keeps network access in Doze.

The cost is battery (an idle iroh connection to a relay) and a permanent,
minimised notification. It can be turned off in Settings, which leaves
background sync and staying online after sending.

Staying reachable after the phone changes network. iroh's own network
monitoring does not always notice Android moving from Wi-Fi to mobile data,
and the binding has no `network_change()`, so a phone that left home could
stay unreachable (no messages, no position) until OurNet was reopened. The
service now reports default-network changes (`ConnectivityManager`), and
`PeerNetwork.networkChanged` rebuilds the endpoint three seconds after a
change settles (at most every 30 seconds), then syncs with everyone. A
watchdog also rebuilds it when every home relay has been down for 90
seconds, backing off to 15 minutes while it stays down, unless a device has
synced or reached this one within that time: then the endpoint works without
a relay (on the same network, say), and a rebuild would only cut those direct
connections. Neither happens
during a call, or while a pairing or invitation is open; peers find the new
endpoint by its ID through iroh's address lookup.

Android may still stop the service, or restart it out of sight (then it has
no background location). Opening OurNet checks and starts it again, and
Settings warns when it has stopped or when battery optimisation applies to
OurNet, with a button to OurNet's system page (Battery: Unrestricted). It
does not ask with the direct battery-optimisation prompt, whose permission
Play reserves for a few kinds of app.

Calls with the screen off. While a call rings or lasts, the app tells the
service (`call` on `ournet/connection`). Ringing lets OurNet show over the
lock screen and turn the screen on, through the incoming-call notification's
full-screen intent (`CallScreen`); outside calls the lock screen covers it as
usual. A call in progress adds the microphone (and, for video, camera) types
to the service, without which Android silences the microphone once the
screen locks; with "Stay connected" off, the service runs just for the call.
Android refuses these types to a service started out of sight, so the app
asks again whenever it returns to the screen during a call. The network log
records each time the home relay is lost and comes back, to match a missed
message to a gap in reachability.

### Windows notification area (implemented)

On Windows, closing the window hides it and OurNet keeps running from an icon
in the notification area, online and showing notifications, until "Quit
OurNet" in the icon's menu. A desktop that stays on is the friend most likely
to be online when a phone wakes to sync. Chat notifications have a reply box
and a Mark read button; notifications for forums without replies to you are
silent. "Start with Windows" (off by default, main profile only) adds a
per-user startup entry that opens OurNet straight into the notification area.

Opening OurNet again while it runs shows the existing window rather than
failing on the locked profile. Windows only delivers notification clicks to
a running OurNet: a notification clicked after quitting does nothing. Both
options are in Settings; turning off the icon makes closing quit again.

### Push wake-up (implemented)

A friend's device that has a message for a sleeping Android phone asks a push
server to wake it. The server sends an empty, high-priority Firebase Cloud
Messaging (FCM) message; the phone then syncs as a background run does, or
hands the sync to the app if it is running. Nothing else travels through the
server: the message still comes straight from the friend, who stays online for
a few minutes after sending (piece 2b) or is a desktop that stays on.

FCM, rather than a UnifiedPush distributor, because Google Play services keeps
one connection open for every app on the phone, so a wake costs OurNet almost
nothing while it waits. A distributor app (or one built into OurNet) would hold
a connection of its own, which saves little over staying connected. The cost is
a server: sending through FCM needs the Firebase project's credentials, which
cannot be handed to friends. The server is OurNetPushServer (PHP and SQLite, at
`https://push.chozabu.net` by default, setting `wakeServer`).

- **Registering.** With "Wake for friends' messages" on (Settings, Android, on
  by default), the phone registers its FCM token with the server and gets an ID
  and an admin secret. Firebase is configured from
  `app/android/app/src/main/res/values/firebase.xml`; left empty, nothing
  starts and the setting says push is unavailable.
- **One token per friend device.** The phone derives a token for each admitted
  device (HMAC of the device ID under a key kept in the profile) and grants the
  server their SHA-256 hashes, replacing the whole list whenever its contacts
  change. Blocking or revoking a device removes its token; the others keep
  working. The server never sees tokens or device IDs, only hashes.
- **Sharing the address.** Each exchange and its reply carries `wake`: the
  server URL, the phone's ID there, and the token for that peer only. A peer
  that is not admitted gets none. (0.2.39 left it out of the quick `delta`
  exchange that friends who synced before use, so they never learnt it.)
- **Waking.** Four seconds after this person writes a private message, each
  recipient device that has no receipt for it and told this device a wake
  address gets one wake (any platform can send). A later message wakes again;
  a delivered one does not.
- **Abuse.** Only a device holding a granted token can wake the phone; a forged
  or revoked token, or an unknown ID, is refused the same way. The server
  allows one wake per token every 5 seconds and 120 per phone per hour, and
  FCM collapses wakes queued while the phone is offline into one.

The push server learns the phone's FCM token, when it is woken, and the IP
addresses of devices that wake it; Google learns when the phone is woken. Turning
the setting off unregisters and deletes the FCM token.

- **Calls.** A caller wakes each callee device it is not connected to, or
  cannot reach, with a `call` wake carrying the call's ID, and keeps offering
  the call for 55 seconds. The phone rings straight from the push
  (`IncomingCall`: ringtone, full-screen notification, Answer and Decline),
  before the app runs, and starts the connection service so the app comes up
  and receives the offer; the app's own incoming-call notification then
  replaces the push's, and an Answer or Decline already given is carried out.
  When the call ends unanswered, or another device answers, the caller sends
  `cancel` to stop the ringing. Call wakes skip the 5-second spacing (the
  hourly cap still applies), live 30 seconds, and share a collapse key, so a
  queued call is replaced by its cancel. The push carries no caller, so it
  rings as "Incoming OurNet call" until the app has the offer. On Android 14
  and later, full-screen notifications need the person's permission unless
  the app is classed as a calling app.

Not yet: a way to ask a carrier to wake the recipient.

An earlier UnifiedPush implementation, which pushed the messages themselves, is
on the `unifiedpush-wakeup` branch.

## Friend carriers

### Why this shape

The timing problem needs a device that is online when the sender is, and again
when the recipient is. The best candidates are friends' devices, for the
reasons above. We could restrict carriers to mutual friends of sender and
recipient. With a public graph there is no reason to, and a larger pool of
carriers means more coverage. So a message can travel several hops along
friendship links, each hop between people who are actually friends.

We name carriers when sending, rather than letting anyone forward, because
naming them:

- keeps each object's list of possible holders explicit and signed, which fits
  the existing admission and evidence rules;
- lets carriers refuse anything not addressed through them, so they cannot be
  used as open storage;
- gives the recipient a readable path: "via Sam, then Priya".

### What already exists

- **Own devices carry already.** Private objects go to all of the author's
  devices and all of the recipients' devices, and any holder can hand an
  object to anyone in its audience. A desktop left on already relays between
  its owner's phone and their friends.
- **`via` names extra holders.** A private object may list relay persons in
  its signed `via` field. Those people's devices accept it without being able
  to decrypt it, and hand it on to the audience (or to other `via` persons).
  Each hop adds a handoff and a receipt, and admission checks only the link
  from the immediate peer. The forwarding holder test shows a named helper
  storing ciphertext across a restart and delivering it while the sender is
  offline.
- **Receipts flow back.** A recipient's receipt is evidence on the object.
  Evidence reconciliation copies it to any holder that syncs with a device
  that has it, so carriers upstream learn about delivery.

What is missing: nothing ever sets `via`, there is no way to find carriers
beyond one's own friends, and carriers keep copies forever.

### Design

#### 1. Publish the friend graph

Each person publishes a signed public `friends` object listing the root keys
of the people they have admitted. It spreads the way profiles do (any holder
offers it to its friends), except that it stops at a hop limit, where profiles
today spread without one. Each version replaces the author's previous one;
removing a friend publishes a new version.

Today a friend receives only a person's own device certificates. After this
change, a device can build a local view of the graph to the depth that routing
needs (three hops).

#### 2. Opt in to carrying

A device setting, "Carry messages for my friends", with a storage quota
(presets such as 100 MB, 1 GB and 10 GB). The `friends` object marks which of
the person's devices carry, and whether each is usually online (a desktop or
server rather than a phone), so senders can prefer carriers that are likely
to be reachable.

Carrying is per person in the `via` field, since that is what the protocol
names. Any of that person's carrying devices may hold the message.

#### 3. Choose routes when sending

When publishing a private object whose recipients this device cannot reach
right now:

1. Find short paths from the sender to each recipient through people with at
   least one carrying device. Keep a hop limit (three) and prefer carriers
   that are usually online.
2. Take up to two or three paths that share as few carriers as possible, so
   one offline carrier does not stall delivery.
3. Put the union of their carriers in `via`, capped (say at eight persons).

Delivery needs no new rules. Each holder offers the object to admitted peers
who are in the audience or in `via`, so it moves along whichever path is
reachable first, and duplicates are reconciled away. A direct path, when
available, is still used and usually wins.

Routes are fixed when the message is signed: `via` cannot change afterwards
without a new object. That is acceptable for the first version, as long as
more than one path is chosen.

#### 4. Retention and quotas

A carrier holds a message only until it has been delivered. It drops the object
and its evidence once it holds a receipt for every recipient person (any one
device of each person is enough, since a person's devices sync each other). If
no receipt ever arrives, a maximum age (14 days) is the backstop.

So in the steady state a carrier stores only the undelivered backlog for
friends who are currently offline, not their history. Quotas are:

- a total quota chosen by the carrier's owner;
- a share per upstream friend (the peer that handed the object over), so one
  person cannot use the whole quota;
- when full, refuse new objects rather than evict messages already accepted.

The sender keeps its own copy until it sees a receipt, and still delivers
directly when it can. Nothing is lost because a carrier refused or dropped an
object.

#### 5. Files (second phase)

Messages are small, but attachments can be up to 64 MiB. Because carriers
store only undelivered items, carrying everything is cheaper than it sounds.
The cost only grows when someone stays offline for a long time while receiving
lots of media. The second phase carries attachment chunks as well, within the
same quotas:

- Carriers serve encrypted chunks they cannot read to anyone in the object's
  audience or `via`. Chunks are already content-addressed and encrypted
  separately, so this is mainly an authorisation rule. PROTOCOL.md lists
  "blind encrypted relay file serving" as remaining work.
- When a carrier is short of space, messages and small objects take priority,
  and large or old attachment chunks are evicted first. A dropped file is not
  lost: its author still serves it directly.

Whether carriers fetch chunks eagerly or only on request is open (see below).

#### 6. What users see

- Delivery status shows where a message is waiting, for example "Waiting at
  Sam's", and when a recipient's device has it.
- Carrier settings show quota use and who is using it.
- The provenance view, which already shows handoff evidence, shows the route a
  message took.

### What this costs

- **Metadata.** A carrier learns that the sender sent something to the
  recipients, when, and roughly how large; not what. Longer routes show this
  to more people. People who want fewer observers can turn off routing beyond
  direct friends. Whether that is per message or a setting is open.
- **Storage and bandwidth** for carriers, bounded by quotas they choose.
- **Latency** grows with hops, and each carrier adds its own wake-up interval.
  A recipient that stays connected (piece 4) collects from an online carrier
  at once; push (4b) could let a carrier wake one that does not.
- **Evidence size.** Each hop adds a handoff and a receipt, against the limit
  of 128 evidence records per object. Hop and `via` limits keep this small.

### Open questions

- **Recipient preferences.** Should a recipient be able to publish carriers
  they prefer or refuse, and should senders honour that?
- **Routes chosen later.** Could `via` name a rule instead of persons ("any
  carrier within two hops of the recipient"), so routes adapt after sending?
  That changes what `via` means and how admission checks it.
- **Chunk fetching.** Should carriers fetch attachment chunks as soon as they
  hold the object, or only when the recipient asks through them?
- **Public objects.** Forum posts and other public objects already spread by
  subscription. Should carriers ever hold public objects for friends who are
  offline?
- **Graph depth and size.** How far does the `friends` object travel, and how
  large can a person's list be before it needs paging?

### Validation

Transport tests with real local endpoints, extending the forwarding holder
test:

- A → C → D → B delivers while A and B are never online together.
- With two paths and one carrier offline, the other path delivers.
- Carriers drop the object once B's receipt reaches them, and the maximum age
  drops it when no receipt arrives.
- A carrier over quota refuses new objects; the sender still delivers
  directly later.
- A carrier cannot decrypt anything it holds, and refuses objects that do not
  name it in `via`.
- A route through a revoked device or a blocked person is not chosen, and
  such a device's evidence is still excluded.

Sync work must stay independent of history length (see AGENTS.md): carriers
track held objects and pending receipts incrementally rather than scanning.
