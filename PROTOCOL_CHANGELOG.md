# Protocol and storage changelog

What each release added to what OurNet writes, and what it still reads. Store
rollouts are staged, so friends run mixed versions for days: every change is
additive, and anything older builds cannot read is **read in one release and
written in a later one** (see "Rollout switches").

Versions are app versions (`app/pubspec.yaml`).

## Unreleased: algorithm identifiers

Additive. Everything new builds sign or seal names its algorithm, so a
successor (a post-quantum signature, say) can be added later without
guessing at old data. Nothing already stored is re-signed or re-hashed.

| Field | Where | Meaning | Older builds |
| --- | --- | --- | --- |
| `sig: 'ed25519'` | signed object `data`, evidence `data`, device certificate `data`, revocation `proof` | The signature algorithm, covered by the signature itself so it cannot be swapped. Absent means Ed25519. Data naming another algorithm fails verification. | Ignore it; the signature covers it. |
| `aead: 'chacha20-poly1305'` | encrypted payloads (beside `box` and `wraps`) | The cipher of the box, every wrap and the group seal. Absent means ChaCha20-Poly1305. A payload naming another cipher is refused. | Ignore it. |
| `aead: 'chacha20-poly1305'` | sealed roots, sealed backups (beside `kdf`) | As above. A sealed root naming another cipher is invalid; such a backup asks for a newer version. | Ignore it. |

Blobs already carry a version byte, and wraps `kem`; local preview caches are
never exchanged and are unchanged.

## 0.2.24: per-path handoff evidence, one storage limit

Additive. Evidence was one set per object, merged between every holder and
capped at 128 records, so an object stopped being offered after about 63
device deliveries in total: forum posts past that many subscribers, messages
in groups of about 32 people with two devices each, and profiles, friend lists
and revocations in any network of more than about 60 devices. Every holder
also saw every delivery, with device names and times.

Now a device keeps the chain that brought an object to it and its own
deliveries, and reconciles with each peer only what the two should share
(see [Handoff evidence](PROTOCOL.md#handoff-evidence)). The per-object cap is
gone; 128 records now bounds one received item, which is a path.

| Field | Where | Meaning | Older builds |
| --- | --- | --- | --- |
| `paths` | inventory | Object ID to the first 16 hex digits of the digest of the evidence this device should share with the peer; objects with none are left out | Ignored. They compare `have` and are sent all evidence, as before, except an object with more than 126 records, which they would refuse: sent only when they lack it, with its path |

Builds without it keep merging what they are sent, so while one of them
holds an object, evidence passed through it still spreads, and still stops at
their 128 records. A device hands an object on along the shortest chain it received it by, and
does not offer an item carrying more than 128 records, which a receiver would
refuse on every sync.

Storage: the 512 MiB bound on objects received from peers and the 512 MiB
bound on files are replaced by one limit on both together, `storageLimit` in
settings (20 GiB by default), with a warning past `storageWarning` (5 GiB by
default). `receivedBudget` is no longer read. Older builds keep their own
512 MiB checks.

Local storage: a derived table, `evidence_routes`, records
each evidence record's signer and what it names. It is filled from the stored
evidence when a profile is first opened by this build, and kept by trigger.

## 0.2.23: re-shared group entries shown at their original time

No protocol change. Local storage only: each device remembers, in settings
(`everyday/first/<author>/<entry>`, cursor `everyday/firstCursor`), when a
group entry written without `sent` was first written, from versions its author
signed. A re-shared copy without `sent` (as 0.2.21 and earlier made them) is
shown at that time when this device holds the original. Profiles from earlier
builds read their group items once more to fill it in.

## 0.2.22: group entries always carry when they were sent

Additive: no new fields. `sent` on `room_item` (optional since 0.2.12) is now
written on every new group entry, kept by edits, and kept by copies made when
history is re-shared. A copy of an entry from before `sent` takes the earliest
time the owner's device holds for it, from the entry's author or from an
earlier owner copy. Earlier builds left it out of copies, so such entries
moved to the newest place after a membership change; the next change by an
owner on this build puts them back. Copies are written oldest first so the
stored order follows `sent`. Older builds already read `sent`; builds before
0.2.12 ignore it.

## 0.2.21: group keys, members adding people to groups

Additive. Device wraps are unchanged, so builds without it read everything
they read before. They do not count people added by a member until the
owner's device folds them into a room record, and until then neither write
to them nor show what they write. What a member on such a build writes before
then is not sealed with the group's key, so people added later do not see it.

| Field | Where | Meaning | Older builds |
| --- | --- | --- | --- |
| `groupKey` | room record | The group's key (`id`, `key`): new with every owner membership change. See PROTOCOL.md, Group keys. | Ignored. |
| `invite` | room record | `members`: any member may add people. Absent: the owner alone. | Ignored. |
| `group` | encrypted payload of private objects addressed to a whole group | The content key sealed under the group's key (`id`, `box`). | Ignored; they open their device wrap. |
| `room_invite` | new private object kind (room space, audience the members and those added) | A member adds `people` with their `certificates`, handing them `groupKey`; `epoch` is the room's. | Store and relay it unread. |
| `groupKeys` | sync inventory | The group keys the sender holds for groups shared with the receiver. Objects sealed with them are offered to the sender even when not addressed to it. | Not sent, so they are offered only what is addressed to them. |

## 0.2.19: friend lists, connecting through friends, asking to add to a group

Additive. Builds without it drop `friends`, and store and relay `connect`
and `room_add` unread, so a request still travels through friends on older
builds.

| Field | Where | Meaning | Older builds |
| --- | --- | --- | --- |
| `friends` | new public object kind (space `_identity`) | Who the author is connected to (`friends`, person IDs) and their devices (`devices`, certificates). Newest wins. Offered to every peer, like `profile`. See PROTOCOL.md, Independent objects. | Refuse it on receipt and do not relay it. |
| `connect` | new private object kind (space `_connect`, `via` the people between) | `type` `request` (sender's `devices`, `via`, optional `text`) or `accept` (`request`, answerer's `devices`). Expires after 30 days. | Store and relay it unread. |
| `room_add` | new private object kind (room space, audience the owner) | A member asks the owner to add `people`, carrying their `certificates`; `epoch` is the room's. | Store and relay it unread; the owner sees nothing. |
| `connectIgnored/<id>`, `connectApplied/<id>`, `roomAdd/<id>` | settings | Requests hidden, answers applied, add requests settled, on this device. | Ignored. |

## 0.2.17: profile pictures, blocking on every device

Additive. Builds without it drop the new kinds, show initials as before and
keep their own block list.

| Field | Where | Meaning | Older builds |
| --- | --- | --- | --- |
| `avatar` | new public object kind (space `_identity`) | A profile picture: `image` (base64 JPEG/PNG, ≤ 64 KiB encoded) and `type`. Newest wins; no `image` removes it. Offered to every peer, like `profile`. See PROTOCOL.md, Independent objects. | Refuse it on receipt (a public object outside the spaces they follow) and do not relay it. |
| `contact_state` | new private object kind (space `_contacts`, audience only the author) | Blocking, unblocking or disconnecting from `person` (`state`: `friend`, `blocked`, `unblocked`, `forgotten`), applied on all the author's devices; newest per choice wins. | Store and pass it on unread; their block list stays local. |
| `approvedBy`, `approved` | device certificate data | Which device added this one, and when. Covered by the root's signature like any other field. | Verify the signature as before; not shown. |
| `forgotten`, `contactStates`, `clearedRemoved` | settings | People disconnected from, when each choice was made, removed devices no longer listed. | Ignored. |

## 0.2.14: call history, retrying unreachable devices, call state

Additive. Builds without it show call entries as plain messages.

| Field | Where | Meaning | Older builds |
| --- | --- | --- | --- |
| `call` | `message` payload (space `_messages`) | A one to one call entry: `video`, `outcome` (`answered`, `missed`, `declined`, `failed`), `seconds` when answered. Written by the caller when the call ends. | Show the message's `text` ("Missed call", "Call · 4 min"). |
| `state` | new one to one call signal | `muted` and `camera` booleans, sent after an answer when either changes. | `Unknown call signal`; the sender ignores the refusal. |
| repeated `offer` | one to one call signal | The same session offered again to a device that could not be reached, for up to 30 s. | Rings when it arrives, as any offer. |

## Unreleased: group calls and call robustness

Additive. Builds without it never see the new traffic.

| Field | Where | Meaning | Older builds |
| --- | --- | --- | --- |
| `groupcall` | new request type over `ournet/2`, to one device | Group call presence, joining and signalling. Live only, never stored. See PROTOCOL.md, Group calls. | Answer `Unknown request`; the sender stops asking that device for the run. |
| `v: 2` | `offer` / `answer` signals of one to one calls | The sender accepts `ice` messages carrying a `candidates` list. | Ignored; candidates then go one to a message as before. |
| `restart` | new one to one call signal | A new offer with fresh candidates after a network change; the answer is in the reply. | `Unknown call signal`; the call ends when the connection is lost, as before. |

## Unreleased: maps and live location

Additive. No new object kind and no change to existing ones.

| Field | Where | Meaning | Older builds |
| --- | --- | --- | --- |
| `position` | new request type over `ournet/2`, to one device | A live position: integer `lat`, `lng` (1e-7 degrees), `at`, optional `acc`, `hdg`, `spd`. Never stored as an object or forwarded. See PROTOCOL.md, Locations. | Answer `Unknown request`; the sender stops asking that device for the run. |
| `positions` | new table in the profile database | The last known position of each person, one row, replaced in place. | Never read; not part of the schema version. |
| `shareLocation`, `mapOnline`, `mapStyle`, `mapFriends`, `mapCamera` | settings | Pause sharing, allow map downloads, map type, show friends, last view. | Ignored. |
| `<profile>-tiles.db` | new file beside the profile | Cached and saved map tiles. Safe to delete. | Not present. |
| `device_positions` | new table in the profile database | The last known position of each of this person's own devices. | Never read. |
| `locationPrimary` | `note_self` register (field), value a device ID or `''` | The device that sends this person's position to friends. Syncs between their own devices. | Stored and ignored: every device keeps sending to friends until the build is updated. |
| `shareOwnDevices` | setting | Whether this device sends its position to the person's other devices. | Ignored. |

## Unreleased: calendar

Additive. Builds without it store and relay these unread.

| Field | Where | Meaning | Older builds |
| --- | --- | --- | --- |
| `cal_event` | new object kind, space `_calendar` (personal) or a group's room ID | An event, an override of one occurrence of a repeating event, or a deletion. See PROTOCOL.md, Calendar. | Store, relay and ignore. |
| `cal_rsvp` | new object kind, a group's room ID | A member's answer to an event. | Store, relay and ignore. |
| `calShow`, `calColor`, `calRemind` | `note_self` registers (target: calendar or event) | Which calendars the personal view shows, their colours, a person's own reminders. | Keep, replicate and do not display (unknown registers are accepted). |
| `ournet://event/...` | text in messages and posts | A link to an event. | Shown as written, not tappable. |

Repeats are expanded on the reader's side from one record, so a series costs one
object however long it runs. Nothing is stored per occurrence except changes.

## 0.2.11

No wire or database change. A blocked person is labelled "(blocked)" wherever their
name shows, unblocking syncs at once, diagnostics list blocked people, and file
chunks written on a removed device can be fetched by the person's own devices.

## 0.2.10

No wire or database change. Copy diagnostics failed on decimal numbers (frame
timings) because it used the signing encoder; it now uses plain JSON.

## 0.2.9

No wire or database change. Copy diagnostics gains a `history` section: counts of
private objects held and readable, what is unreadable and why, and which people
lack a profile. No content or keys.

## 0.2.8

| Field | Where | Meaning | Older builds |
| --- | --- | --- | --- |
| `ownRelay: true` | sync inventory | The sender takes relayed objects from this person's other devices. | Ignore it, so are never sent any. |

A device sends it to all peers; it is acted on only between two devices of the
same person. Such a device may then hand on, and accept without a handoff:
objects this person wrote on a device since removed, and other people's objects
whose delivery receipt was lost when a device on the route was removed. Every
signature is still checked. A removed device is still refused as a source by
friends, and a friend is never sent a removed device's work.

Reactions, edits and deletions that arrive before their message is readable are
now kept and applied once it is (`messageUpdates/<kind>/waiting`).

## 0.2.7

No wire or database change. App fixes only: the share-history dialogs open, and
Android widgets and shared files start after the connection service has run
the app before its screen existed.

## 0.2.5

No wire or database change. A device now offers its history to each of its
owner's other devices once (setting `historyOffered`), and the history button
beside a device hands over files, inbox, groups and notes as well as chats.

## 0.2.4

### Wire formats

| Field | Where | Meaning | Older builds |
| --- | --- | --- | --- |
| `v: 2` | signed object `data`, beside `domain` | Object format. Absent means the format before it. A build refuses an object whose `v` is neither absent nor 2. | Ignore it; the signature covers it. |
| `caps: [...]` | `pull` request and reply, `push` request | What the sender can do: `cursor_paging`, `blob_inline`. A feature is used only if the peer lists it. Unknown names are ignored. | Ignore it. |
| `reg: 1` | `note_op` payload | Register format. | Ignore it. |
| `driveFormat: 1` | `drive` payload | Drive revision format. | Ignore it. |
| `chunkBytes` | file manifests (`message`, `file`, `drive`, `inbox`, `room_item`, note `file:*:meta`) | Size of each plaintext chunk, currently 131072. Any power of two from 1 KiB to 1 MiB is accepted on read; anything else makes the payload invalid. | Ignore it. |
| `kem: 'x25519'` | each entry of `wraps` in an encrypted payload | How the content key was agreed. A wrap naming another scheme is refused. Room for a hybrid post-quantum scheme. | Ignore it. |
| `{type: 'pairing', v: 1, ...}` | Add device invitation (was `{pairing: 1, ...}`) | The invitation names its type and version. | **Reject it.** New builds still read the old form. |
| `{type: 'friend', v: 1, ...}` | Friend invitation (was `{friend: 1, ...}`) | As above. | **Reject it.** New builds still read the old form. |

`expires == 0` still means "never expires" on the wire. `SignedObject.hasExpiry`
names it in code; nothing changed on the wire.

### Confirmation code

Pairing and friend codes are 12 hex characters (48 bits) shown as
`ABCD-EFGH-IJKL`, up from 8 (32 bits). The first eight characters are the
earlier code, so a new and an older build still show matching prefixes.

### Cryptography

- New recovery-phrase seals use Argon2id at 128 MiB and 3 passes (was 64 MiB).
  Existing seals keep the parameters recorded in them; opening accepts up to
  256 MiB and 10 passes as before.
- Wrap key derivation gains a salt, `utf8('ournet/wrap/2')`, in HKDF. Readers
  try the salted derivation first and fall back to the unsalted one, so wraps
  from every earlier build still open. **Writing the salted form is off** (see
  below).

### Blobs

Encrypted chunks may lead with a version byte, `0x01`, followed by the nonce,
ciphertext and tag; the byte is authenticated as AEAD associated data. Readers
accept both forms. A blob from before versioning starts with its random nonce,
so its first byte is `0x01` one time in 256: such a blob is tried as versioned
and, failing authentication, as legacy. Because of that a future version byte
cannot be told from a legacy nonce, so an unknown version fails authentication
rather than being named. Unencrypted chunks carry no version byte. **Writing
the version byte is off** (see below).

### Database (`user_version` 2)

`Store._migrate` steps a database one version at a time, each in a transaction.
Version 2 moves three lists out of the settings blob:

- `device_contacts(device PRIMARY KEY, person, label, wire)`
- `device_revoked(device PRIMARY KEY)`
- `space_subscriptions(space PRIMARY KEY, since)`

and deletes the `contacts`, `revoked` and `subscriptions` settings. A profile
that never chose subscriptions starts on `general`, as before. An 0.2.3 build
refuses a version 2 database ("needs a newer OurNet version"), so a profile
cannot be moved back.

### Rollout switches

`WireFormat.saltedWraps` and `WireFormat.versionedBlobs` (`core/lib/src/model.dart`)
are both **false** in 0.2.4: this release reads the new forms and writes the old
ones. A build older than 0.2.4 cannot open a salted wrap or a versioned blob, so
turning them on before those builds are gone would make friends' private
messages and attachments unreadable to them. Turn each on in a later release,
once 0.2.4 or newer is what friends run, and record it here.

### Backup files

Settings can save a profile to one zip and restore it (`core/lib/src/backup.dart`).
This is a local file format, not something sent to peers:

- `manifest.json` (plain): `format: "ournet-backup"`, `version: 1`, `schema`
  (the database `user_version`), app version, person, device, label, time, item
  count.
- `identity.json`: the identity secrets sealed with Argon2id (default 128 MiB,
  3 passes; opening accepts 8-256 MiB, 1-10 passes) and ChaCha20-Poly1305 under
  a passphrase of at least 12 characters, bound to the person.
- `ournet.db`: a `VACUUM INTO` snapshot of the database, blobs included.

A build refuses a backup whose `version` or `schema` is newer than it knows, and
refuses to open one with the wrong passphrase or a damaged database before it
touches the profile. Restoring keeps the replaced database and keys aside until
the restored profile has opened, and puts them back if it does not.

### Not done

Device labels are inside the root-signed certificate, so a label cannot be
blanked when a certificate is shared with a friend: the signature would fail,
and every object carries its author's certificate anyway. Hiding labels needs a
certificate format whose signature covers the label separately.
