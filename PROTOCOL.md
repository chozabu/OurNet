# Prototype protocol v2

This describes the implementation, not a production security guarantee.

## Identity and admission

A person is an Ed25519 root public key. Each device has an independent Ed25519
operational key and X25519 agreement key. The root signs a certificate binding
them, with a device label. iroh authenticates the operational device key.
Adding a certificate locally admits that device; the other side must independently
admit yours. An authenticated connection alone does not confer admission.

Enrolment sends a root-signed certificate back to the requesting device. The
root secret is not copied. Root-signed revocations stop future admission and
forwarding locally once received. This prototype conservatively excludes revoked
devices' evidence, including historical evidence; nuanced historical validity
and recovery policy are not implemented.

Sync inventories carry root-signed device certificates with address hints.
A person's own devices receive all admitted contacts; friends receive only
that person's other devices, and a friend's certificate for any other person
is ignored. Linked devices therefore list, send and decrypt the same
conversations. Messages encrypted before a device was learned stay unreadable
there.

## Independent objects

Canonical JSON sorts map keys and admits integer numbers, strings, booleans,
nulls, arrays and maps. Signatures are domain separated. Objects contain their
device certificate, kind, space, creation time, optional expiry, audience, optional
relay audience, payload and signature. Their IDs hash the signed representation.
There is no dependency on an author's unrelated earlier private objects.

Public objects travel to admitted friends subscribed to their space. Private
objects travel only to author devices, selected recipient people, or explicitly
named relays. The author encrypts a payload key for each known authorised device
using X25519, HKDF and ChaCha20-Poly1305. Newly enrolled devices cannot decrypt
older messages without a future history-transfer mechanism. Static recipient
key compromise can expose recorded envelopes: this is not a ratcheting protocol.

Inventory filters object identifiers using the same recipient policy; it does
not advertise unrelated private object IDs. Public profiles and revocations have
special propagation handling. Expired/blocked objects are excluded from views
and forwarding; expiry cannot erase recipients' copies.

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

One inventory covers a window of history rather than everything a device holds,
so the message stays bounded as a profile grows. Entries are the newest 2,000
objects offerable to that peer, and `from`/`until` give the creation times they
cover: window 0 is open above the newest object, the last window is open below
the oldest, and successive windows overlap by an entry so equal creation times
are never split. `more` says whether an older window follows. An offer only
considers objects inside the window it was given, because outside it a missing
entry says nothing about what the peer holds. A pull request names the `window`
it is on and the reply answers with the same one, so both sides walk history
together; a page that changes nothing moves to the next window, and a sync ends
when the last window is quiet. Inventories carrying no window (earlier builds)
cover all history, as before.

## Transfers and limits

The iroh ALPN is `ournet/2`. Requests use bounded JSON QUIC streams. Pull/push
exchange up to 32 objects and about 1 MiB per page, with at most 16 rounds in one
sync. Exhausted pages schedule a continuation after yielding. Changes trigger
debounced sync; failed peers get exponential retry backoff.
The UI exposes manual sync. A sleeping phone stops idle networking.
A pull request and its reply may carry an optional `build` string (at most 64
characters) naming the sender's app build; peers ignore it, or show it when it
differs from their own. A failed inbound handshake is logged and counted, and
the endpoint keeps accepting further connections.

Local limits: 10,000 objects (a store bound, no longer a sync-message bound),
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
admitted iroh connections. Media uses direct candidates or user-configured
STUN/TURN and does not inherit the iroh relay path.

A call to a person sends the same offer (one session id) to each of their
admitted devices. The first `answer` binds the call to that device; the caller
sends `hangup` for the session to the others and ignores their later signals.
A `hangup` from any still-ringing device ends the call for all of them.

Voice messages are ordinary encrypted `message` attachments whose payload also
carries `audio: {mime, duration}` (milliseconds) and an optional `transcript`,
made on the sending device before the message is signed.

Plugin permissions, moderation/governance, real-world ID hooks, identity backup,
forward-secret messaging and cross-version migrations require subsequent designs.
