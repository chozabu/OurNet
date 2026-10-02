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
replaced in place, and never expires it. Sharing is on for all admitted
friends unless the person pauses it (`shareLocation` setting, per device).
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

Inventory exchanges both object IDs and digests of held evidence IDs. Peers can
therefore reconcile new provenance even when both already have the content.
Evidence is unioned after validation; exceeding resource bounds is rejected.

One inventory covers a window of history rather than everything a device holds.
Cursor-capable pulls set `cursorPaging: true` and pass the receiver's previous
`next` token as `after` (null for the first page). Each device walks its own
history in descending `(created, id)` order. A page inspects at most 2,000 routes
plus one lookahead, including routes it cannot share; only offerable objects
appear in `have`. Sparse sharing therefore cannot make an inventory scan the
whole profile. Cursors are `[created, id]` positions, not access capabilities.

Inventories retain `from`/`until` timestamp bounds and add an exclusive `after`
and inclusive `through` position for exact boundaries across timestamp ties.
The first page is open at the newest end and the last at the oldest end.
`more` and `next` describe the next page. An offer considers only its supplied
bounds. A quiet exchange advances each side that has more history; completion
requires both sides' last pages to be quiet. Continuations first reconcile the
newest page, then resume the retained cursors.

Peers without cursor support use the existing numbered `window` requests and
overlapping timestamp bounds. Inventories carrying no bounds (earlier builds)
cover all history, as before.

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

Local limits: 512 MiB of stored objects once they are received from peers (a
store bound, not a sync-message bound, and not applied to this device's own
writes; the number of objects is not capped),
256 KiB per signed object, 128 evidence records per
object, 64 MiB per file, 512 MiB total stored blob bytes, and four simultaneous
inbound requests. These bounds are not a complete DoS resistance strategy.

Files use 128 KiB content-addressed chunks, encrypted separately for private
attachments. The encrypted manifest holds the chunk key and hashes. Sources
check that the requesting friend may receive the referenced object and that the
chunk belongs to it. Downloads verify hashes, authentication tags and final size.
Current downloads try author devices then other admitted holders; blind encrypted relay file serving,
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

Voice messages are ordinary encrypted `message` attachments whose payload also
carries `audio: {mime, duration}` (milliseconds) and an optional `transcript`,
made on the sending device before the message is signed.

Plugin permissions, moderation/governance, real-world ID hooks, identity backup,
forward-secret messaging and cross-version migrations require subsequent designs.
