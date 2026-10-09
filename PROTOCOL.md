# Prototype protocol v2

This describes the implementation, not a production security guarantee.

## Identity and admission

A person is an Ed25519 root public key. Each device has an independent Ed25519
operational key and X25519 agreement key. The root signs a certificate binding
them, with a device label. iroh authenticates the operational device key.
Adding a certificate locally admits that device; the other side must independently
admit yours. An authenticated connection alone does not confer admission.

Enrolment sends a root-signed certificate back to the requesting device, and,
unless the approving person opts out, a copy of the root secret sealed under
their recovery phrase: Argon2id (parameters carried with the copy, 64 MiB and
3 passes by default) keying ChaCha20-Poly1305, with the person's key as
associated data. Any device holding a copy can add and revoke devices once the
phrase opens it, so losing one device no longer freezes the identity. A device
from before phrases holds its root in the clear until it first adds or removes
a device, when it must set a phrase and seals it. Anyone who has both a
device holding a copy and its phrase controls the identity; there is no root
rotation. Root-signed revocations stop future admission and
forwarding locally once received. Revoked devices' evidence, including
historical evidence, is excluded, and a friend never takes or is sent a revoked
device's work. This person's own devices are the exception: a device that sends
`ownRelay` in its inventory is handed, by the person's other devices, what the
person wrote on a device since removed and what reached them only through one,
signatures checked, without a delivery route. Other historical validity and
recovery policy are not implemented.

Sync inventories carry root-signed device certificates with address hints.
A person's own devices receive all admitted contacts; friends receive only
that person's other devices, and a friend's certificate for any other person
is ignored. Linked devices therefore list, send and decrypt the same
conversations. Messages encrypted before a device was learned stay unreadable
there until one of the person's other devices grants their keys (below).

## Independent objects

Canonical JSON sorts map keys and admits integer numbers, strings, booleans,
nulls, arrays and maps. Signatures are domain separated. Objects contain their
device certificate, kind, space, creation time, optional expiry, audience, optional
relay audience, payload and signature. Their IDs hash the signed representation.
There is no dependency on an author's unrelated earlier private objects.

Algorithms are named where they are used, so a successor can be added beside
them. Signed data (objects, evidence, device certificates, revocation proofs)
carries `sig: "ed25519"` among the signed fields; encrypted payloads, sealed
roots and sealed backups carry `aead: "chacha20-poly1305"`, which covers a
payload's box, wraps and group seal alike; each wrap names its key agreement
as `kem: "x25519"`. Absent means those same algorithms, as written before the
fields existed. Anything naming another algorithm is refused on its own.

Public objects travel to admitted friends subscribed to their space, and to a
person's own devices when subscribed or when that person wrote them. Which
spaces a person follows is itself personal state replicated between their own
devices, one register per space, so two devices do not disagree about which
forums they keep and pass on. Private
objects travel only to author devices, selected recipient people, or explicitly
named relays. The author encrypts a payload key for each known authorised device
using X25519, HKDF and ChaCha20-Poly1305. A device enrolled later holds no key
for anything written before it, and a friend who has not yet learned of a
device keeps encrypting to that person's other devices alone.

A device that can read such an object grants its payload key to its owner's
other devices: a private `keys` object in space `_keys`, audience only its own
person, whose payload lists up to 400 `{object, key}` pairs. The object itself
is untouched, so its author, signature and time stay as they were. A grant is
believed only from the device's own person and addressed to that person
alone. Each device grants, in the background, keys for objects stored since
its last pass that another admitted device of its own cannot open. Earlier
history is granted only on request: when pairing with history shared, or
from the device list. A grant is encrypted to the owner's devices admitted
when it is written; a device added later is covered by a later grant. Older
builds store and relay `keys` objects and otherwise ignore them.

Enrolment also re-issues what its owner can re-issue, for new devices on
builds without grants: drive revisions, inbox entries, the groups and notes
this person owns, and personal note state. Each note register is copied as an
owner checkpoint that replaces only the version it copies, so concurrent
branches survive, and the note's edit time is restored afterwards. Rooms keep
their epoch: membership has not changed, and bumping it would strand what
other members wrote concurrently. Static recipient
key compromise can expose recorded envelopes: this is not a ratcheting protocol.

Inventory filters object identifiers using the same recipient policy; it does
not advertise unrelated private object IDs. Public profiles and revocations have
special propagation handling. Expired/blocked objects are excluded from views
and forwarding; expiry cannot erase recipients' copies.

Profile pictures are public `avatar` objects in `_identity`, propagated like
`profile`: payload `image` (base64 JPEG or PNG, at most 64 KiB encoded; builds
write a 256 pixel square JPEG under 48 KiB) and `type` (`image/jpeg` or
`image/png`). The newest one by `created` from its author decides; one without
`image` removes the picture. Readers decode only bytes that start with a JPEG
or PNG signature. Builds without it drop the kind on receipt, as any public
object outside the spaces they follow, and do not pass it on.

Friend lists are public `friends` objects in `_identity`, propagated like
`profile`: payload `friends` (person IDs, at most 1000, the people the author's
devices sync with) and `devices` (the author's root-signed device
certificates, at most 32). The newest from its author counts. Two people are
linked when either lists the other and neither, having published a list,
leaves the other out; a chain is the shortest run of links between two people.
Each device publishes when its contacts say more than the newest list, merged
with that list so a person's devices converge rather than alternate.

Asking someone outside one's contacts to connect is a private `connect`
object in space `_connect`, audience the person asked, `via` the people on the
chain between (and, for a friend of a friend, every common friend), expiring
after 30 days. It is encrypted to the devices their list (or profile) names;
the people in `via` store and pass it on unread, as any private object they
relay. Payload: `type` `request`, `devices` (the sender's certificates), `via`
and an optional `text`. Accepting admits those devices and answers with
`type` `accept`, `request` (the request's ID) and the answerer's `devices`,
relayed back the same way. A device admits the devices in an answer only when
it holds the named request, written by its own person to the answerer, and
only once per answer. Nothing is admitted from a request alone.

A group member who is not its owner asks the owner to add people with a
private `room_add` in the room's space, audience the owner: `epoch`, `people`
(at most 16) and `certificates` (their devices, since the owner may not know
them). The owner's approval is an ordinary membership change; the devices are
admitted as a group's members are, not as friends. Builds without these kinds
store and relay `connect` and `room_add` unread and drop `friends`.

### Group keys and members adding people

A group's room record may carry `groupKey` (`id`, and `key`, 32 bytes in
base64) and `invite` (`members`, or absent for the owner alone). An object
addressed to every reader of a group (a room's whole membership; group notes
in `<room>#<key>` belong to their room) also seals its content key under the
group's current key: the encrypted payload gains `group`, `{id, box}`, the
content key under ChaCha20-Poly1305 with associated data
`ournet/group/2/<id>`. A room record seals itself with the key it carries.
Device wraps are unchanged, so builds without group keys read as before.

Where `invite` is `members`, any member adds people with a private
`room_invite` in the room's space, audience the members and the people added:
`epoch` (the room's), `people` (at most 16), `certificates` (their devices)
and `groupKey` (the room's). The owner may write one too. A group's members
are its owner's record plus the people its invites add, in the order the
invites were written, counting an invite only once its author is a member and
only for people in its audience, up to 64; a leave counts only if written
after its author was last added. Every device reading the same records
derives the same members. Invites keep the epoch and key; the owner folds the
people they add into its next record (same epoch, next generation), so builds
without invites count them then. Any owner membership change starts a new
epoch with a new key and re-shares what the group holds under it; turning
`invite` on is such a change, and is not turned off.

Someone added holds the group's key, from the invite or any record, and so
can open what was written to the group before they joined: the originals,
not copies, with their authors and signatures. Members pass such objects on
as any other: a device offers a private object sealed with a group's current
key to a peer whose person is one of that group's readers, besides the
object's own audience, and takes one it is not addressed to when it holds the
key it is sealed with. An inventory names the group keys the receiver holds
for groups the sender is in with them (`groupKeys`), and only objects sealed
with one of those are offered this way: older builds name none, and are
offered only what is addressed to them.

## Calendar

Events are two private kinds, ignored by builds that do not know them (they
store and pass them on unread, like any unknown kind):

- `cal_event`: an event, a changed occurrence of a repeating event (an
  *override*), or a record that either was deleted. Payload: `event` (stable
  entry ID), `clock` (Lamport counter), optional `deleted`, `title`, `desc`,
  `loc`, `url`, `allDay`, `start`/`end` (milliseconds since the epoch) or
  `day`/`days` for all-day events, `repeat` (`freq`, `interval`, `days`,
  `monthly`, `until`, `count`), `reminders` (minutes before, up to five),
  `color`, `busy`, `sent`, and for an override `series` and `instance`. A voice
  note is the usual `chunks`/`key`/`size`/`name` file fields plus `audio` and
  `transcript`. Entries with the same `event` are versions of one thing: the
  higher `clock` wins and ties break on object ID. An override has the fixed
  entry ID `<series>~<instance>`, where `instance` is the occurrence's original
  start in milliseconds (the date for all-day events), so two people changing
  different occurrences never conflict.
- `cal_rsvp`: `event`, optional `instance`, and `response` (`yes`, `no`,
  `maybe`, `none`). Each person's newest answer counts, and an answer for one
  occurrence overrides their answer for the series.

A person's own calendar is `cal_event` in the space `_calendar`, encrypted to
their own devices only: it counts only when written by that person for that
person alone. A private group's calendar is the same kind in the group's room
space, encrypted to its members, accepted from a member and with every
audience member in the room record. Like the group forum it has no epochs:
whoever is a member now reads what members wrote. History shared with a new
member, and events by someone who has been removed, are republished by the
group's owner as copies carrying `history: true` and `originalAuthor`; copies
count only from the owner. A new device of the owner is handed the group's
events by the same re-issue as its posts, and one of any person's devices
gets their personal calendar from [history sharing](#identity-and-admission).

Which group calendars show in a person's own calendar, calendar colours and
a person's own reminders for an event are personal state (`note_self`
registers `calShow`, `calColor`, `calRemind`), which syncs between their own
devices only.

Event links are `ournet://event/<calendar>/<entry>` with an optional
`?at=<occurrence>`; the calendar is `_calendar` or a room ID, percent-encoded.
They are text, resolved against the events a device holds: a link to an event
a device cannot read shows as unavailable.

## Locations

Live position sharing is not an object kind. A position is a request, like a
typing indicator: `{type: "position", fix: {...}}` over the admitted, encrypted
connection to one device, answered with `{}`. It is never signed, stored as an
object, indexed in an inventory or forwarded by a friend, so it cannot grow a
history or travel by relay. The fix is all integers: `lat` and `lng` in
ten-millionths of a degree, `at` (the device's clock, milliseconds), and
optionally `acc` (metres), `hdg` (degrees) and `spd` (centimetres per second).
A receiver ignores a fix that is out of range, more than ten minutes ahead of
its own clock, or not newer than the one it holds for that person.

A device sends its position to every admitted device of its person's friends
and of its own person that it has heard from in the last ten minutes, when it
has moved about 20 m (at most one per device every five seconds, the latest
always sent), and every fifteen minutes while still. A device that has just
synced with it is sent the current position at once, which is how a returning
friend catches up. Builds without the request answer `Unknown request`; the
sender stops asking that device for the run.

Each device keeps one row per person (`positions`: person, fix, device label)
replaced in place, and never expires it. A person's own devices also get a row
each (`device_positions`: device, fix, label), so they can see one another.
Sharing with friends is on unless the person pauses it (`shareLocation`
setting, per device). Only the person's primary device sends to friends: it is
a personal-state register (`note_self` field `locationPrimary`, target `self`,
value a device ID, `''` for none) that syncs between the person's own devices.
While none is chosen every device sends to friends, as builds before it did;
builds that predate the register store it and ignore it. Sending to the
person's own devices is separate and on unless switched off on that device
(`shareOwnDevices` setting).
The map's tiles are public data and live in a separate file (`-tiles.db`).

## Handoff evidence

Evidence is separate from content. A sender signs a handoff naming the object,
recipient device and a prior receipt (or originates it as an author device).
The receiving device signs a receipt referencing that specific handoff. Admission
verifies the complete supplied path and requires a handoff from the authenticated
immediate peer to this device for newly received objects.

Another person cannot forge an author's handoff by merely claiming receipt.
Signers can still collude, copy outside this protocol or withhold evidence.
Signatures do not establish endorsement, factual accuracy or legal responsibility.

Evidence is kept per path. A device holds the chain of handoffs and receipts
that brought an object to it, back to an author device, and the handoffs it
made itself with the receipts answering them. It is not sent how other copies
travelled, so how far an object can go is bounded by path depth, not by how
many devices it reaches, and no holder learns the whole delivery tree. Tracing
misuse goes hop by hop: each device can prove who handed it an object and whom
it handed it to.

Two devices reconcile the records they should both hold for an object:
handoffs between them and the receipts answering those, and, for a private
object, receipts signed by its readers on their way back to its author. The
latter pass between two devices that are both upstream (the author's devices
and the people in `via`), and between an upstream device and the reader who
signed them, so a sender learns delivery through a carrier or through another
of its own devices; one group member does not learn when another received
something. Of those reader receipts, two devices pass each other the first 32
by ID. An item sends these records with every record they depend on, so the
receiver can verify each to an author device.

Inventory lists each object a device holds with a digest of all its evidence
IDs (`have`), and, from builds with per-path evidence, a digest of the
records it should share with that peer (`paths`: object ID to the first 16
hex digits of the digest, leaving out objects the two share nothing for).
A peer is offered an object it holds only when the two `paths` digests
differ, with the shared records. `have` lists the objects an inventory
covers; its values are empty (builds before 0.2.29 sent a whole-evidence
digest, which no supported build reads). Received evidence is stored after
validation, and one item may carry at most 128 records.

One inventory covers a window of history rather than everything a device holds.
Cursor-capable pulls set `cursorPaging: true` and pass the receiver's previous
`next` token as `after` (null for the first page). Each device walks its own
history in descending `(created, id)` order. A page inspects at most 2,000 routes
plus one lookahead, including routes it cannot share; only offerable objects
appear in `have`. Sparse sharing therefore cannot make an inventory scan the
whole profile. Cursors are `[created, id]` positions, not access capabilities.

Inventories carry `cursorPaging: true` and `from`/`until` timestamp bounds,
which 0.2.27 and 0.2.28 read, and an exclusive `after`
and inclusive `through` position for exact boundaries across timestamp ties.
The first page is open at the newest end and the last at the oldest end.
`more` and `next` describe the next page. An offer considers only its supplied
bounds. A quiet exchange advances each side that has more history; completion
requires both sides' last pages to be quiet. Continuations first reconcile the
newest page, then resume the retained cursors.

Peers must list the capabilities `cursor_paging`, `multi_request` and
`since_sync` (0.2.27 and later) in sync requests and replies; a device refuses
to sync with one that does not, and says why.

Devices that agreed before exchange only what changed since (`delta`, see
PROTOCOL_CHANGELOG.md 0.2.27). With `delta_items`, a `delta` request carries
the objects the asker wrote and never handed to the peer, and the reply
carries them back with the peer's receipts and the peer's own new objects: a
message and its receipt cross in one request. A `push` may list `view`, the
objects whose holdings the reply should describe, so agreement needs no
further pull.

A local change starts a sync only with the devices it concerns: those that may
be offered a changed object, and those whose sharing policy changed since the
two last agreed (or that never have). Up to four syncs run at once, devices
heard from most recently first.

## Transfers and limits

The iroh ALPN is `ournet/2`. Requests use bounded JSON QUIC streams. Pull/push
exchange up to 32 objects and about 1 MiB per page, with at most 16 rounds in one
sync. Exhausted pages schedule a continuation after yielding. Changes trigger
debounced sync; failed peers get exponential retry backoff.
The UI exposes manual sync. A backgrounded phone stops idle networking unless
it stays connected (on Android, a foreground service, on by default). After
sending, it stays online for up to 3 minutes while a recipient device has not
returned a receipt. On Android a
periodic task (about every 15 minutes, with network) syncs every admitted device
and answers inbound requests for a further 10 seconds; it can be turned off.
A pull request and its reply may carry an optional `build` string (at most 64
characters) naming the sender's app build; peers ignore it, or show it when it
differs from their own. A failed inbound handshake is logged and counted, and
the endpoint keeps accepting further connections.

Local limits: a storage limit on stored objects and files together (setting
`storageLimit`, 20 GiB by default; past it, objects from peers and files are
refused, this device's own objects are not, and the number of objects is not
capped), with a warning shown past `storageWarning` (5 GiB by default),
256 KiB per signed object, 128 evidence records per received item (a path, so
about 60 hops; a device does not offer an item with more), 64 MiB per file,
and eight simultaneous inbound connections (an admitted device beyond them
is answered "busy" and tries again within seconds, without counting it as a
failure). A device hands an object on along the
shortest chain it received it by. These bounds are not a complete DoS resistance strategy.

Files use 128 KiB content-addressed chunks, encrypted separately for private
attachments. The encrypted manifest holds the chunk key and hashes. Sources
check that the requesting friend may receive the referenced object and that the
chunk belongs to it. Downloads verify hashes, authentication tags and final size.
Downloads ask for missing chunks 16 at a time (`blobs`: a JSON line with each
chunk's size, then the raw bytes), with four such requests in flight spread
over the devices that may hold the file, its author's first; chunks one
holder lacks are asked of the next. Peers listing `concurrent_streams`
answer up to four requests on one connection at once. Blind encrypted relay file serving,
garbage collection, retention controls and resumable large-file UX remain work.

## Infrastructure and media

Local mode disables iroh relays. Internet mode uses iroh's default discovery and
relay infrastructure; replacing those defaults needs operator configuration.
There is no application account server. Media uses WebRTC, with signalling over
admitted iroh connections. Media uses the user's configured
STUN/TURN servers, or public STUN servers (Google, Cloudflare) when none are
configured; local mode uses none by default. Media does not inherit the iroh
relay path, so networks needing a relay still need TURN.
Planned connectivity work (friend carriers, push wake-up, own relays) is
designed in [CONNECTIVITY.md](CONNECTIVITY.md).

A call to a person sends the same offer (one session id) to each of their
admitted devices. The first `answer` binds the call to that device; the caller
sends `hangup` for the session to the others and ignores their later signals.
A `hangup` from any still-ringing device ends the call for all of them.

One to one calls take candidates in batches when both sides say so: an `offer`
or `answer` carrying `v: 2` means the sender accepts `ice` messages with a
`candidates` list (otherwise one `candidate` per message, as before), and a
caller whose connection drops sends `restart` (a new offer with fresh ICE
credentials) and gets the answer in the reply. Builds without these ignore
`v` and refuse `restart` (`Unknown call signal`), which ends in a plain hang up.

A device the offer cannot reach (offline, or a phone asleep) is offered the
same session again every 3 seconds for 30 seconds; it gets every candidate
found so far once the offer arrives. A device that refuses (`Busy`, not
admitted, calling unavailable) is not asked again. Once a call is answered
either side may send `state` (`muted`, `camera`: booleans) when it mutes or
pauses its camera, so the other shows that rather than silence or a black
picture. Builds without it refuse `state` (`Unknown call signal`), which the
sender ignores.

When a one to one call it placed ends, the caller records it in the chat as an
ordinary `message` to the person called: `text` describes it ("Missed call",
"Video call · 12 min") for builds that know nothing of calls, and `call` holds
`video`, `outcome` (`answered`, `missed`, `declined` or `failed`) and, when
answered, `seconds`. Calls between a person's own devices are not recorded.
Only a missed call is notified; the others are marked read on arrival.

### Group calls

A private group's call is a mesh of one to one WebRTC connections, kept
together by a request type `groupcall` over `ournet/2` whose `payload` has an
`op` and the group's `space`. It is live only: nothing is stored, nothing is
relayed, and builds without it answer `Unknown request` (the sender stops
asking that device for the run). Every message is refused unless the sender is
an admitted device of a person in the group's `members` and so is this device.

A call is identified by a random `call` id and has a host: the first device to
join. The host numbers devices as they join (`seq`, 0 for the host) and keeps
the roster. Whoever is lowest in the roster is the host, so when the host
leaves the next device takes over without any exchange. At most 8 devices.

| `op` | From | Meaning |
| --- | --- | --- |
| `ask` | anyone | Is a call going? Reply `{info}`: `{call, host, rev, members:[{d, s, m, v}]}` or null. |
| `join` | joiner → host | Reply `{ok, seq, call, host, rev, members}`, `{ok:false, host}` from a device that is not the host, or `{full}`. |
| `presence` | host → every group device | The roster, `rev` increasing; empty `members` means the call has ended. Sent on every change and every 30 s; a call not renewed for 80 s has lapsed. |
| `offer` | later joiner → earlier | `{call, sdp, seq, muted, video}`; the reply is `{sdp}`, the answer. The device that joined later always offers. |
| `restart` | the offerer | A new offer for the same link with fresh candidates; reply `{sdp}`. |
| `ice` | either | `{call, candidates:[...]}`, in bursts. |
| `state` | participant → the others | `{muted, video}`. |
| `beat` | participant → host | Every 20 s; the host drops a device silent for 80 s. |
| `leave` | participant → the others | The device is out. |

Two calls started at once (neither device had heard of the other's) are
resolved by the lower `call` id winning; the other side leaves and joins it.
Each link carries one audio and one video transceiver from the start, so a
camera is switched on or off by swapping the track, with no renegotiation.

Voice messages are ordinary encrypted `message` attachments whose payload also
carries `audio: {mime, duration}` (milliseconds) and an optional `transcript`,
made on the sending device before the message is signed.

Plugin permissions, moderation/governance, real-world ID hooks, identity backup,
forward-secret messaging and cross-version migrations require subsequent designs.
