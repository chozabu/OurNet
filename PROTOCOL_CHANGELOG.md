# Protocol and storage changelog

What each release added to what OurNet writes, and what it still reads. Store
rollouts are staged, so friends run mixed versions for days: every change is
additive, and anything older builds cannot read is **read in one release and
written in a later one** (see "Rollout switches").

Versions are app versions (`app/pubspec.yaml`).

## Unreleased: maps and live location

Additive. No new object kind and no change to existing ones.

| Field | Where | Meaning | Older builds |
| --- | --- | --- | --- |
| `position` | new request type over `ournet/2`, to one device | A live position: integer `lat`, `lng` (1e-7 degrees), `at`, optional `acc`, `hdg`, `spd`. Never stored as an object or forwarded. See PROTOCOL.md, Locations. | Answer `Unknown request`; the sender stops asking that device for the run. |
| `positions` | new table in the profile database | The last known position of each person, one row, replaced in place. | Never read; not part of the schema version. |
| `shareLocation`, `mapOnline`, `mapStyle`, `mapFriends`, `mapCamera` | settings | Pause sharing, allow map downloads, map type, show friends, last view. | Ignored. |
| `<profile>-tiles.db` | new file beside the profile | Cached and saved map tiles. Safe to delete. | Not present. |

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
