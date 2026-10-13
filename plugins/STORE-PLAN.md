# Plugin store plan

Status: revision 2 (13 October 2026), after
[STORE-PLAN-REVIEW.md](STORE-PLAN-REVIEW.md). Phase 1 is built (see "Releases"
in PLUGINS.md); the rest is plan. Covers "F2F
distribution" from phase 2 of [PLUGINS.md](../PLUGINS.md), and the next step it
lists: "`plugin_release` objects so friends can share plugins".

Items marked **Decision** are product choices still open. They are collected at
the end and not decided here. Where the plan needs a value before one is chosen,
it uses the more conservative option and says so.

## Summary

The work splits in two:

- **A trust kernel in the host.** Package transfer lives in `transport`.
  Release format, verification, publisher pinning, install transactions and
  prompts live in `core`. Execution and storage snapshots live in `native`.
  This is the only code that can install, replace or stop a plugin. The
  built-in Settings › Plugins screen keeps working without any store.
- **A store plugin** (`plugins/store`, WASM). It handles browsing, friends'
  listings, catalogs, reviews and details pages. It can *request* host
  actions, and each one shows a host-owned prompt. A wrong or malicious store
  can show misleading text. It cannot install unverified code, skip a prompt,
  change a policy or channel, downgrade, or publish as the person.

Delivery comes in four phases. Phase 1 is authenticated sharing with manual
updates. Discovery and unattended updates come later, once install and recovery
are proven.

## What the code does today (and what that decides)

- `PluginPackage.read` (`core/lib/src/plugins.dart`) unzips `manifest.json`,
  `plugin.wasm`, `ui.rfwtxt` and `assets/`. It ignores unknown files, lets a
  duplicate entry silently replace the first, and trusts declared sizes. There
  is no signature and no author.
- `Plugins.install` writes the new files over the installed ones *before* the
  host has loaded them. It keeps storage and the `InstalledPlugin` for any
  package with the same `id`, whoever wrote it.
- `Running::reload` (`native/rust/src/plugin.rs`) replaces the instance before
  calling `restore` and `init`. A trap there leaves no previous version
  running. It also shares the live `storage.bin`, so the new version's
  `restore` can already have changed storage. Only compile, import-check and
  instantiate failures leave the old version in place.
- The host instantiates through typed `bindgen!` for world `plugin`, so
  `Plugin::instantiate` needs **every export** of that world. Imports are
  different: a component imports only what it uses, `check_imports` compares
  them with the grants, and the linker may offer more.
- `SignedObject.valid()` checks a device signature and a device certificate
  signed by the person's root key. Non-public objects must be sealed. Unknown
  kinds store and relay, so new core kinds are additive.
- `PeerNetwork._chunks` serves the chunks listed in *any* object's `chunks`
  payload to a peer that `canOffer` allows. Any object shaped like a file is
  therefore transportable by `Files` with no new network code.
- Live requests, the `p:<id>` capability and datagram channels route by the
  short id only.

## Formats

### Release descriptor: `plugin_release`

This answers the review's question about reusing an existing signing
representation: **use a whole ordinary `SignedObject`.** There is no new
signature scheme and no partial-object signing. Verification is
`SignedObject.valid()`, plus checks that the device is not revoked and the
author is not blocked.

A descriptor is always public-shaped: empty audience, plaintext payload, space
`_plugins:<publisher>`. It is written by one of the publisher's devices and
carries no chunks and no encryption key.

```json
{
  "id": "wiki",
  "version": "0.2.0",
  "api": "0.1",
  "name": "Wiki",
  "summary": "Linked pages anyone in the scope can edit",
  "grants": ["identity", "objects"],
  "kinds": ["page"],
  "manifest": "<sha256 of manifest.json bytes>",
  "digest": "<content digest, below>",
  "changes": "Markdown, at most 4 KiB",
  "icon": "<base64 PNG, at most 8 KiB>",
  "channel": "stable",
  "minApp": "0.2.40",
  "source": {"url": "https://…", "commit": "…"},
  "labels": []
}
```

- **Release identity** is the descriptor's object id, a hash over its signed
  wire form. Skip lists, rollback records, warnings and catalogs refer to
  that id, never to version text.
- **Public release:** the descriptor is stored and syncs in
  `_plugins:<publisher>`, so following that space gossips releases friend to
  friend.
- **Private release** (a group, chosen friends, a beta): the descriptor is
  *not* stored as an object of its own. It travels only inside sealed
  distribution objects, and recipients verify it without ingesting it. The
  release module must refuse to store a `plugin_release` that arrives
  embedded. Public and private releases share one format from phase 1.
- **Conflict:** two descriptors with the same publisher, `id` and `version`
  but different `digest` are a publisher fault, either a mistake or a
  compromised device. Neither is offered automatically. Both show with a
  warning, and manual install needs a second confirmation.

### Distribution: `plugin_package`

A distribution is an ordinary signed object that can be written by **any**
device: the publisher's, or a friend sharing a plugin. It may use any
audience. Its payload is the intact descriptor wire JSON plus the
`Files`-shaped fields, so the existing chunk serving works unchanged:

```json
{
  "release": { "data": {…}, "signature": "…", "certificate": {…} },
  "name": "wiki-0.2.0.ournet-plugin",
  "size": 812345,
  "chunks": ["…"],
  "chunkBytes": 131072,
  "key": null
}
```

- The host keeps two signatures apart. The **publisher** is the descriptor's
  author, the **distributor** is the package object's author. The UI says
  "Wiki by Alex, shared by Carol". Sharing never makes Carol the author.
- A public distribution is written by the publisher next to its descriptor.
  Friends who installed it serve its chunks through the existing relay path
  without writing objects of their own. Private shares are distributions with
  a `people` or group audience and a sealed key.
- Different distributions of one release can have different zip bytes. Each
  zip is checked against the same descriptor `digest`.
- **Size budget:** at most 32 MiB of package means at most 256 chunk hashes
  (about 17 KiB). With a descriptor of at most 20 KiB (icon 8 KiB as base64,
  changes 4 KiB), a sealed payload stays well under 64 KiB. The module checks
  both caps, and a test covers the largest case.

### Package: `.ournet-plugin`

The zip from `pack` gains `signature.json`, which is exactly the descriptor's
`SignedObject.toJson()`. The digest excludes that one entry, so the format is
not circular: the descriptor names the contents, and the distribution names
the zip's chunks. A package passed around as a file is verified the same way
as one fetched over F2F.

**Content digest:** SHA-256 of `canonical()` applied to the list
`[[name, sha256hex(bytes)], …]` for every entry except `signature.json`. The
list is sorted by the UTF-8 bytes of the name. Hashes use the raw entry bytes,
before the CRLF normalisation of `ui.rfwtxt`.

**Decoding rules**, applied to signed and unsigned packages alike:

- Allowed entries are `manifest.json`, `plugin.wasm`, optional `ui.rfwtxt`,
  optional `signature.json`, and `assets/<name>` matching the existing asset
  pattern. Directory entries are skipped.
- Refused: any other name, duplicate names, `\`, `..`, absolute paths, more
  than 300 entries, more than one `signature.json`, or an archive over 32 MiB.
- Sizes are checked from the central directory before anything is inflated.
  The total declared uncompressed size must be at most 32 MiB. Inflation keeps
  a running count and aborts once an entry exceeds its declared size, which
  catches headers that lie.
- Decoding runs on the blob worker, never the UI isolate.

**Checks against the descriptor:** `id`, `version`, `api`, `grants`, kind
names and the `manifest` hash must equal the parsed manifest. Otherwise the
package is refused.

A package without `signature.json` still installs from a file. It shows as
**unsigned**, has no publisher and never updates from the network.

### Lifecycle objects

- **`plugin_withdrawal`** is a separate public object by the publisher in
  `_plugins:<publisher>`: `{id, releases: [descriptor ids], reason,
  severity}`. It blocks those releases for new installs and updates, and warns
  people who have them installed. It stops a running plugin **only** where the
  person opted into "stop this plugin if its publisher withdraws it"
  (**Decision 8**).
- **`plugin_warning`** is a friend's flag on a release. Like `Listings`, only
  its writer offers it and it is never relayed. Curators warn inside their
  catalogs. Publisher withdrawal, curator advice, friends' warnings and the
  person's own block are shown as four different things. None of them can
  replace code.
- **Staleness:** F2F delivery is not guaranteed. Details pages say when the
  publisher's space last synced ("last heard from Alex's releases 9 days
  ago"). Nothing fails closed on missing news.

## Identity: publisher + id

- An **implementation** is (publisher root key, id) and is recorded as
  `publisher` in the `plugins` setting.
- **One installation per short id.** Installing the same id from a different
  publisher is an uninstall followed by a fresh install. Storage, grants,
  cursors, snapshots and the update policy go. The prompt explains why.
- **Data compatibility is explained, not implied.** The prompt says that
  plugins sharing an id share their data format (`x.<id>.*`) and can read each
  other's existing objects. Pinning protects *updates*, not data.
- **Decision 1:** should a shared id be a documented compatibility promise
  ("reuse an id only to be compatible")? This plan does not assume one. A
  separate data-format identity can be added later as an optional manifest
  field. It should not come from filtering on an author fingerprint in `app`,
  which would block compatible implementations.
- **Live routing:** the `plugin` live request gains an optional `publisher`
  field. A receiving host whose installed publisher differs refuses it, and
  older builds ignore it. This is additive and cheap, so it ships in phase 1.
  Capabilities (`p:<id>`) and datagram channels stay id-only for now.
  Plugins already have to check what they receive.
- **Existing installs:** bundled first-party packages gain `signature.json`
  and take the project publisher on their next install from assets. Unsigned
  installs moving to a signed package keep storage only after an explicit
  prompt.
- **First-party ids** (`wiki`, `microblog`, `tictactoe`, `pong`, `vpn`, `echo`,
  `store`) are pre-pinned to the project key shipped in the app
  (**Decision 2** covers who holds that key).
- **Publisher transfer** (phase 4): a descriptor field `transferTo`, signed by
  the pinned publisher.

## Install transaction and recovery

**On-disk layout:**

```
<plugins>/<id>/storage.bin              live storage (as now)
<plugins>/<id>/v/<digest>/              one directory per verified version
<plugins>/<id>/snap/<descriptor id>.bin storage before an update
```

The `plugins` setting records `active` and `previous` (descriptor id and
digest), plus a cursor snapshot. The setting is the source of truth, and a
single `store.set` flips it.

**Install or update:**

1. Verify (above) and unpack to `v/<digest>.tmp`, then rename it to
   `v/<digest>`.
2. Ask the host to compile and import-check without instantiating, as
   `reload` does today. Do this before any prompt finishes, so the person
   never agrees to something that cannot load.
3. Show the host-owned prompt.
4. **Snapshot:** a job on the plugin's own thread flushes and copies
   `storage.bin`, so nothing races its writes. Dart saves the cursors next to
   it.
5. Flip `active`, keeping `previous`, then reload or start.
6. If `restore` or `init` of the new version traps, the host reports it and
   recovers on its own. The storage snapshot and cursors are restored, the
   setting flips back, the previous version starts, and the failed
   **descriptor id** is skipped. The person gets a notice. This needs
   `Running::reload` changed to report a failure after instantiation instead
   of leaving nothing running.

**What rollback realistically guarantees:**

- It brings back the previous code and storage as they were at the update.
- Objects stored since then are replayed to the old version, because the
  cursors are restored with the snapshot. Storage and cursors stay consistent.
- It does *not* undo objects the newer version published. Those are signed
  and may have synced, so the old version receives any of its own kinds. That
  is the existing additive-compatibility rule.
- One snapshot per plugin, bounded by the 16 MiB storage cap. It is deleted
  after the next successful update or when the person keeps the new version.

**Startup cleanup:** delete `*.tmp`, and versions and snapshots that are
neither `active` nor `previous`.

Automatic rollback when a start fails is in phase 1, because manual updates
need it too. Roll back on request comes in phase 3.

## Updates

An update is offered when a verified descriptor and package arrive from the
pinned publisher, on the plugin's channel, with a greater semver version, and
with a supported `api` and `minApp`. They arrive through the publisher spaces
this device follows (installing a plugin follows its publisher's space) or
through a share.

- **Phase 1: manual only.** The update shows in Settings › Plugins with its
  changelog and the grants it adds. Updating runs the transaction above.
- **Unattended updates (phase 3)** are an explicit per-plugin subscription
  offered in the host install prompt: "Install future updates of Wiki from
  Alex automatically". They run only when all of these hold:
  - the publisher is pinned and the channel was selected;
  - there are no new grants and the API and app are compatible;
  - verification is complete;
  - **the recipient's own structural check passes** (below);
  - it is a safe restart point, meaning no call is running and the plugin's
    `canRestart` allows it.
  **Decision 5** is the default (this plan assumes ask).
- **New grants** always prompt with only the new grants listed: **Update**,
  **Not now**, **Skip this release**. `tun` always prompts.
- **Policy, channel and listing changes** happen only through host prompts,
  whoever requests them. A store cannot move anyone onto beta.
- **No downgrades**, except restoring `previous`. After a rollback, the
  *failed newer* descriptor id is skipped.

**Compatibility checks** live in one function in `plugin_manifest.dart`, used
by both the publisher lint and the recipient. Comparing the old schema with the
new, these all fail the check:

- a removed kind or field;
- a changed type;
- `max` lowered or `min` raised;
- `values` narrowed;
- list `items` tightened;
- a newly `required` field.

Incompatible data needs new kinds or an explicit format version, never a
changed meaning. The publisher lint refuses unless overridden. On the
recipient, a failed check blocks *unattended* updates and adds a warning to the
manual prompt. Semantic changes cannot be caught this way, which is one reason
unattended updates are opt-in.

## Discovery (phase 2 onward)

All discovery is local. There is no global search.

- **Friends' listings:** `plugin_listing` `{id, publisher, release}`, following
  the `Listings` pattern. Only its writer offers it, it is never relayed, and
  it expires after 30 days. It is **off until enabled**, globally or per
  plugin, pending **Decision 4**. Changes go through a host prompt.
- **Followed publishers:** every release in `_plugins:<publisher>`.
- **Catalogs** (like F-Droid repos): `x.store.catalog` objects, either public
  in `x.store.c.<slug>` or group-private as a community allow-list. Entries
  are `{id, publisher, note, category}` plus curator warnings. Catalogs are
  advice only. They never install, replace or stop anything.
- **Reviews:** `x.store.review`, addressed to the reviewer's friends, so only
  friends' opinions count.

**Seeding:** the `active` and `previous` package chunks are kept, so every
friend running a plugin can serve it. Above that, retention is capped at
256 MiB by default and shows under storage. Phones fetch on unmetered networks
unless the person asks.

## Host API for stores (`plugins` grant)

A grantable **imported** interface, so components that do not use it link as
before.

```wit
interface plugins {
  record page-of-releases { items: list<release>, cursor: option<string> }
  installed: func() -> list<installed>;            // bounded by installs
  releases: func(id: option<string>, publisher: option<string>,
                 after: option<string>, limit: u32) -> page-of-releases; // ≤ 100
  listings: func(id: option<string>, after: option<string>, limit: u32) -> page-of-listings;
  follow-publisher: func(person: string, on: bool) -> result<_, string>;
  /// Each returns a ticket; the host fetches, verifies and prompts.
  request-install: func(release: string) -> u64;
  request-uninstall: func(id: string) -> u64;
  request-publish: func() -> u64;
  request-policy: func(id: string, policy: string, channel: string) -> u64;
  request-listed: func(id: string, on: bool) -> u64;
  request-warning: func(release: string, reason: string) -> u64;
  cancel: func(ticket: u64);
}
```

**No new export.** Typed instantiation needs every export of the world, so
adding one would stop every existing component from loading. Host events go
through the existing `on-event` export instead, on a reserved surface
`@plugins` (manifests may not name surfaces starting with `@`):

- `install` with `{ticket, state, progress?, error?}`;
- `changed` with `{what: "releases" | "listings" | "installed"}`. It carries
  no snapshot, and the store re-reads pages from its cursor.

**Limits:**

- At most one host prompt open per plugin.
- Requests are rate-limited, with a cooldown after the person declines.
- Pages are capped at 100 items.
- Events go only to plugins granted `plugins`, and reads return only what
  this device can read.

If a later API does need new exports, it becomes a new world that includes
`plugin`. The host binds both and picks one by the manifest's `api`.

**Test:** the existing packages in `plugins/dist` and `core/test/fixtures` load
and run unchanged on the new host.

Images in the store use host-drawn RFW widgets, `ReleaseIcon(release)` and
`PackageImage(release, asset)`, so the store never decodes images.

## Publishing

The publish dialog is host-owned (Settings › Plugins › Developer › Publish).
A store can only open it.

1. Read and verify the package as an install would, including a compile and
   import check.
2. Check the id: unpinned, or pinned to this person. Warn if friends use the
   same id from someone else.
3. Check the version is greater than this person's last release of that id,
   and run the compatibility lint.
4. Ask for the changelog, the channel and the audience: public, a group, or
   chosen friends.
5. Write the descriptor. A public release stores it, plus a public
   distribution. A private one writes only a sealed distribution.
6. Save a signed copy of the package for sharing as a file.

**Share** on an installed plugin writes a private distribution to chosen
friends or a group. The recipient sees "Alex shared Wiki 0.2" and installs
through the host prompt.

## Phases

1. **Authenticated sharing.**
   - Descriptor, distribution and package formats, the digest and the decoding
     rules.
   - Publisher pinning and one installation per id.
   - The optional `publisher` field on live requests.
   - Publish, share and export; verified download through `Files`.
   - Host install and update prompts; manual updates in Settings › Plugins.
   - Atomic versioned install, storage snapshots, and automatic recovery when
     a start fails (including the `reload` fix).
   - Public and private distribution both in the format. The first UI may
     expose only public publishing, share with friends, and files.
   - Tests:
     - verification and digest edge cases (duplicates, lying sizes, bad
       paths);
     - conflict handling;
     - a two-node publish, fetch and update test in `transport`;
     - a recovery test that kills the process between each step of the
       transaction;
     - old packages loading on the new host;
     - an upgrade fixture with a pinned plugin.
2. **Discovery.** Opt-in listings, the `plugins` interface, the first-party
   store (Discover, Installed, Updates, Details), and bounded seeding.
3. **Updates and recovery.** Opt-in unattended updates, the recipient
   compatibility check, roll back on request, withdrawals and warnings, and
   safe restart scheduling.
4. **Communities and infrastructure.** Catalogs, reviews, channels, publisher
   transfer, reproducible builds with rebuild attestations, and CI publishing
   from a paired headless node.

**Does phase 1 build anything later phases replace?** No. The formats,
pinning, transaction and recovery are final. Later phases add objects
(listings, withdrawals, catalogs), an imported interface and policies.
Settings › Plugins remains the fallback UI. Phase 1 is useful on its own:
publish a plugin, friends install it from a share or your release space,
and they see and apply your updates.

## Platform policy

Before downloaded updates are enabled for first-party plugins in Play or
Microsoft Store builds, check current store policy against the real runtime
and host API, and record the result here. The choice of runtime is not proof of
compliance.

## Review response

Where this revision stands on each point of STORE-PLAN-REVIEW.md:

| # | Review point | Response |
|---|---|---|
| 1 | Non-circular format, publisher vs distributor | **Agreed and adopted.** The descriptor is a whole `SignedObject` with nothing removed. The distribution is a separate signed object, with any distributor. The digest spec and decoding limits are above. One simplification: mirroring friends write no distribution objects, because the existing `_chunks` relay already serves the publisher's. |
| 2 | Publisher + id, shared kinds | **Agreed.** One install per id, and a publisher change wipes local state. Added an optional `publisher` on live requests, an additive check the review did not cover. Whether a shared id is a compatibility promise stays open (Decision 1). |
| 3 | Unattended updates opt-in | **Agreed** as the shape: an explicit per-plugin subscription in phase 3. The default stays open (Decision 5). |
| 4 | Transactions and rollback | **Agreed, and the code is worse than the review assumed.** `reload` drops the old instance before `restore`/`init`, and storage is shared live. Fixed with versioned directories, a thread-side storage snapshot taken with the cursors, a single setting flip, and automatic recovery. The rollback wording is corrected: the failed descriptor is skipped, by id. |
| 5 | Listings, withdrawal, warnings | **Agreed.** Withdrawal is its own object that blocks and warns, and stopping a plugin is opt-in. Warnings come in four distinct kinds. The listing default is left to Decision 4 (off until decided). |
| 6 | Narrow, bounded API; WIT compatibility | **Agreed; confirmed in code.** Typed `bindgen!` instantiation needs every export, so the plan adds **no** export and uses `on-event` with a reserved `@plugins` surface. The interface is paged, with tickets, cancellation and prompt limits. |
| 7 | Lint is not a guarantee | **Agreed.** It covers types, min, values and items as well, in one function shared by publisher and recipient. The recipient enforces it for unattended updates and warns on manual ones. |
| — | Revised phases | **Adopted.** Automatic recovery on a failed start stays in phase 1, because manual updates need it too. |
| — | Platform policy | **Agreed;** added as a gate. |

## Open decisions

1. **Shared ids:** is reusing a plugin id an explicit data-compatibility
   promise, and what should the prompt say when replacing an implementation?
2. **Project key:** a dedicated OurNet identity (the review recommends this,
   and I agree), or Alex's own? Custody, recovery and rotation need writing
   down either way.
3. **First-party updates over F2F** between app releases, once phase 1 is
   proven and the platform check is done: yes or no?
4. **Listing default:** opt-in (the review) or on by default (like public
   space listings)? Off until decided.
5. **Unattended update default** when the person subscribes per plugin:
   offered pre-ticked or not? This plan assumes not.
6. **Partial grants:** keep all-or-nothing for 0.x? The plan assumes yes.
7. **Third-party stores:** may any plugin be granted `plugins`? Both
   documents suggest yes, behind host prompts.
8. **Remote stop:** should "stop if withdrawn" be offered at all, and if so
   pre-selected for any severity?
