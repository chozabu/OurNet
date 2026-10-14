# Review of the F2F plugin store plan

Review date: 13 October 2026.

This memo reviews [STORE-PLAN.md](STORE-PLAN.md) against the earlier proposal
for explicit F2F sharing of authenticated plugin releases. It proposes a
combination for review; these recommendations are not yet agreed product
decisions or implemented behaviour.

## Overall recommendation

Use STORE-PLAN.md as the architectural base. Keep its split between host-owned
verification, installation and update management, and a WASM store plugin for
browsing, recommendations and catalogues. Keep the built-in Extensions screen
so installation and recovery work without a store plugin.

Reduce the first implementation to signed releases, publisher pinning,
explicit sharing, verified downloads, manual installation and updates, and
atomic package replacement. Introduce discovery next, then unattended updates
and more complex lifecycle policies once recovery is proven.

## 1. Separate release authentication from distribution

The current proposal embeds a signed `plugin_release` in `signature.json`
with its chunk list omitted. Removing fields covered by a signature invalidates
that signature. A release describing the chunks of a ZIP which contains that
same release also introduces a circular dependency.

Proposed structure:

- **Signed release descriptor:** publisher identity, plugin ID, version, API,
  manifest assertions, content digest, changelog and relevant release policy
  metadata. Authenticate it with the existing device certificate/root identity
  model, but specify its exact signed representation separately from transport.
- **Distribution object:** carries the intact signed descriptor plus attachment
  chunks, final ZIP size and encryption information. It is itself an ordinary
  signed object, whose distributor need not be the publisher.
- **Package:** contains that same descriptor in `signature.json`. The content
  digest excludes `signature.json`.

The host must distinguish the publisher signature from the distributor's
signature. A friend recommending or mirroring a release does not become its
author. Different distributions may carry the same release through different
ZIP encodings or audiences, while their individual attachment bytes and access
controls remain independently verified.

The content digest proposed in STORE-PLAN.md is useful for this structure, but
requires a precise specification: accepted file names, encoding, ordering,
canonical JSON, duplicate-entry rejection, treatment of unknown files and
exactly one excluded signature entry. Validate compressed size, expanded size,
entry count and paths during decoding, before excessive allocation. Check all
descriptor assertions against the verified manifest.

Review question: what is the smallest existing signing representation we can
reuse for the descriptor without inventing ambiguous partial-object signatures?

## 2. Separate implementation identity from data-format compatibility

Today the short manifest ID determines installation storage, kind names
(`x.<id>.*`) and live routing. Publisher pinning prevents an unrelated author
from replacing an installed plugin, but does not isolate data from another
implementation using the same kinds.

Recommendation:

- Record implementation identity as **publisher root identity + plugin ID**.
- Initially reject simultaneous installations with conflicting short IDs,
  rather than immediately redesigning routing and kind names.
- Never transfer private plugin storage or grants to a different publisher
  merely because the short ID matches.
- Explain that implementations intentionally using the same kinds may read
  compatible existing objects. Do not imply author pinning isolates that data.
- Consider an explicit data-format identity later, additively. Filtering solely
  by an author fingerprint in `app` may prevent useful compatible implementations
  from exchanging objects and should not be the default solution.

Review question: should shared kind names be an explicit compatibility promise,
and what checks or user explanation should accompany replacing an implementation?

## 3. Automatic updates should be an explicit subscription

Same publisher and no additional grants are necessary conditions for unattended
updates, but are not a guarantee of harmless behaviour. New code can misuse
existing access or change how it publishes and processes data.

Recommend **ask** by default, with a host-owned option at installation to trust
future compatible updates from this publisher for this plugin. Automatic
updates then require the pinned publisher, selected channel, no additional
grants, compatible host/API, complete verification and a safe restart point.

Policy and channel changes must be confirmed by host-owned UI. A store must not
silently move someone onto beta or change the update source. Defaults remain
open decisions; this is a recommendation, not a requirement inferred from the
current code.

## 4. Installation and rollback need transactional semantics

The current installer overwrites package files in place. Stage and validate a
new package before atomically switching the active installation, preserving the
previous verified package and recovering safely after interruption.

Retaining an older ZIP alone does not guarantee rollback: a new version may
change plugin storage. Define whether storage is snapshotted, migrations are
restricted, or rollback is conditional. Failed startup/restore must not
silently destroy the only recoverable state. Bound snapshot storage and work.

Correct the rollback wording in STORE-PLAN.md: after restoring the previous
version, skip the **failed newer release**, not the restored version. Identify
skipped releases by authenticated release identity/digest, rather than only
version text. Define rejection of conflicting releases with the same publisher,
ID and version.

## 5. Listings and withdrawal policies

Recommend usage listings be off until explicitly enabled globally or per plugin.
Installed VPNs or community tools can disclose information users did not intend
to advertise. The host should own approval of listing changes, even when a
store requests them.

Recommend author withdrawal block selection for future installs and updates,
and warn existing users. Automatically stopping an installed plugin is a remote
disable capability, including for anyone who compromises the publisher's
signing device. Offer that only as an explicit subscription policy if desired.

Allow catalog curators and friends to issue independent warnings. Distinguish
publisher withdrawal, curator advice and a user's own block decision; none
should silently grant a catalogue authority to replace code or stop execution.

Withdrawal should be a separately specified signed lifecycle object/event,
rather than an underspecified "release-less" variant of a package release.
Define behaviour when revocation or withdrawal information is unavailable or
stale; F2F discovery cannot guarantee immediate delivery.

## 6. Keep the store API narrow, bounded and consent-driven

Allow third-party stores through a grantable additive interface. Keep host-owned
consent for installation, uninstall, publishing, policy/channel changes,
listing visibility and publishing warnings as the user's identity.

Add pagination and hard limits for installed/release/listing reads, progress
cancellation and prompt rate limits. Do not emit unbounded snapshots through
`on-plugins`; use bounded incremental events and insertion cursors. Scope events
to the requesting plugin and avoid leaking private release metadata.

Check WIT compatibility explicitly: adding a required export to the existing
world may not preserve linking with old components just because the SDK gives
new source code a default implementation. Use an optional/versioned path if
necessary and test existing packaged components unchanged.

Keep package transfer in `transport`, policy and verification in `core`, and
execution in `native`. Route new kinds and live handlers through the registry.
Use bounded background work for downloads, hashing, archive validation,
compilation and images; give each operation its own progress and errors.

## 7. Compatibility lint: useful, but not a guarantee

Keep the publisher-side lint. Extend its proposed checks beyond removed fields,
lowered maxima and newly required fields: types, minimums, allowed values,
list-item schemas and kind removal can also break mixed versions. Semantic
changes cannot generally be proved safe by a manifest comparison.

Decide whether recipients also enforce structural compatibility for automatic
updates. Publisher-side tooling alone can be bypassed by another publisher
client. Require new kinds or an explicit format version for incompatible data,
without changing existing field meanings.

## Suggested answers to the open decisions

| Decision | Recommendation |
|---|---|
| Plugin identity | Publisher + ID for implementation identity; explicit shared data compatibility |
| Project key | Dedicated OurNet identity, with documented custody, recovery and rotation |
| First-party F2F updates | Yes, after the verification and recovery path is proven |
| Usage listing default | Opt-in |
| Automatic update default | Ask; explicit opt-in per plugin/publisher |
| Partial grants | Keep all-or-nothing initially |
| Third-party stores | Allow through a constrained, consent-driven host API |
| Remote disable | Explicit policy only; authors and curators can independently warn |

Before enabling downloaded first-party updates in store-distributed builds,
verify current platform policy against the actual runtime and host API. The
runtime choice alone should not be treated as proof of store compliance.

## Revised delivery phases

1. **Authenticated sharing:** descriptor/distribution format; publisher pinning;
   package import/export and explicit sharing; verified attachment download;
   host install/update prompts; atomic replacement; built-in management UI.
2. **Discovery:** opt-in friend listings; narrow WIT interface; first-party store
   plugin; incremental browsing and details; bounded seeding/retention.
3. **Updates and recovery:** opt-in unattended updates; storage recovery;
   rollback and skipped-release handling; withdrawals; safe restart scheduling.
4. **Communities and publishing infrastructure:** catalogs, reviews, channels,
   private release workflows, publisher transfer, reproducible builds and CI.

Public/private distribution must be designed in phase 1 even if the first UI
only exposes a subset. Do not build a format that assumes every package is public.

## Requested review

Please assess these recommendations against STORE-PLAN.md and the actual code.
Identify disagreements and practical simplifications, especially:

1. A non-circular signing/package format and its certificate verification path.
2. Publisher identity versus shared kind names and existing live routing.
3. Atomic installation and realistic storage rollback guarantees.
4. Backward-compatible WIT changes with existing compiled plugins.
5. Whether the smaller first phase delivers useful F2F sharing without creating
   architectural work that later phases would need to replace.

Please propose amendments to the plan, marking unresolved product decisions
clearly. This memo requests design review; it does not authorize implementation
or decide the privacy/update defaults on the user's behalf.
