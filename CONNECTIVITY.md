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
| 3 | Friend carriers (below) | Delivery when sender and recipient are never online together | Designed |
| 4 | Push wake-up (UnifiedPush) | Fast delivery; ringing a sleeping phone | Planned |
| 5 | Own relays, shared in contact cards | Dependence on number0's relays | Planned |
| 6 | Call media over iroh when ICE fails | Calls behind carrier-grade NAT without TURN | Planned |
| 7 | Packaged friend node (relay, carrier, push) | Making 3–5 one command to offer | Planned |

### Default STUN (implemented)

Calls previously used no ICE servers unless configured, so they could not
connect across two NATs. With no configuration, calls now use public STUN
servers (Google, Cloudflare); local mode uses none. STUN operators learn the
caller's IP address, not the call. TURN is still needed on networks where a
direct path is impossible; piece 6 aims to remove that need.

### Android background sync (implemented)

A WorkManager task runs about every 15 minutes when there is a network. It
syncs every admitted device, then keeps answering for 10 seconds for peers
that are retrying. It can be turned off in Settings. What it collects is
announced by notifications: one per chat, whose Reply and Mark read buttons
work the same way, opening the profile briefly if the app is not running.

On its own this helps when the other side is online: a friend's desktop, or
anyone with the app open. Combined with carriers, a phone collects waiting
messages within roughly one period. Wake-ups (piece 4) are what make delivery
fast.

WorkManager usually runs in the app's own process, where the profile's file
lock does not exclude it. So the profile has one owner at a time, registered
in the isolate name server. A background run or notification button hands
its work to a live app isolate instead of opening the profile a second time,
and the app asks a background run to finish before opening the profile.

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
  Push (piece 4) shortens this: a carrier that is online can wake the
  recipient as soon as it holds something for them.
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
