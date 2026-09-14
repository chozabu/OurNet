# Previous prototype review

Reviewed: `D:/git/ournetcc`, 9 September 2026.

## Recommendation

Create a second, narrowly scoped prototype with a revised protocol. Preserve the previous repository as a reference and selectively reuse components, interface work and test scenarios. Do not require compatibility with its wire format or database at this stage.

This records the recommendation at review time. The user subsequently approved
implementing the second prototype in OurNetAS. No previous source files were
changed during this review.

The central reason is product fit: the old foundation distributes complete per-device histories, while the intended product needs independently shareable private conversations, folders, locations and public communities. Rewriting in another language without revising those semantics would preserve the main problem.

## Evidence and limits

Read the foundation spec, relay discussion notes, application README, core manifests, bridge workflow, build script, and relevant identity, envelope, custody, storage, sync, node, networking, DM, media and Flutter sources. This was an architectural source review, not a complete security audit or a hands-on UI review.

Ran these commands offline in the existing core workspace:

```
cargo test --offline -p custody -p sync -p node --lib
cargo test --offline -p node --test convergence --test convergence_prop -p sync --test sync_loopback
```

All 20 selected tests passed. The property test internally runs eight generated cases. One unused-mut warning was emitted. These checks establish that the selected existing scenarios work; they do not establish hostile-network safety, battery performance, production transport behaviour or complete provenance convergence. Internet, Android, voice and scale tests were not run.

The previous repository already had local changes in `app/rust/Cargo.toml`, `core/Cargo.toml` and `core/node/tests/scale.rs`. They were preserved.

## What exists

The prototype is more substantial than its main document suggests:

- Persistent local identity and device keys, signed device attestations and content envelopes.
- SQLite-backed per-device append-only histories.
- Signed custody records, graph-based admission distance and quarantine recovery.
- Real iroh integration, contact checks and automatic transitive synchronisation.
- Encrypted DMs, sender history copies, read receipts and encrypted attachments.
- Public file publication and forum posts/replies.
- Flutter screens for messaging, files, forums, settings, profiles and network/location visualisation.
- Voice control, Opus media, audio and jitter-buffer code.
- Loopback, convergence, property, iroh and media test sources.
- Bridge regeneration tooling and CI checks.

Some screens and behaviours are experiments, not complete products. For example, location, votes and delegation are encoded as specially tagged forum posts. Public file publication is not yet a private synchronised drive.

`SPEC.md` still says iroh, Flutter and attachments are future work. `app/README.md` is boilerplate. Source comments also contain stale implementation claims. The documents are useful design history, but cannot be treated as an accurate completion report.

## What to retain

1. Persistent person identities with separately authorised device keys.
2. Signed, immutable objects and explicit content identifiers.
3. Careful deterministic encoding and verification of the actual signed bytes.
4. Provenance stored separately from object bodies, supporting multiple arrival paths.
5. Separating invalid input from missing context, policy decisions and recorded anomalies.
6. Friend-mediated propagation and local control over immediate contacts.
7. Separation between application logic and UI.
8. The transport abstraction and realistic multi-node test scenarios.
9. The existing Flutter UI as a source of reusable views and interaction lessons.

Retain these ideas without assuming their current representations are final.

## Foundation changes needed

### 1. Sharing must be independent of unrelated device history

`core/sync/src/lib.rs::missing_for` offers accepted entries after each peer's device-chain head. It does not select by recipient, audience or subscription. `core/forums/src/lib.rs` explicitly says subscriptions affect rendering while sync offers everything.

`core/log/src/lib.rs::placement` requires a new entry to follow the held device head. Consequently, a public post following a private message depends on the private message's entry being available for chain placement. Encryption hides the message body, but the current design still distributes its envelope/ciphertext and recipient metadata with the history.

This couples private data, public publication, subscriptions, deletion and catch-up. A new subscriber potentially needs unrelated earlier history. Fixing it requires new protocol semantics, not merely a UI filter.

Recommendation: independently verifiable signed objects with explicit context/version relationships, plus audience-scoped replication. Use scoped logs where ordered history is useful. If retaining broader chains, specify headers/proofs/checkpoints that permit selective disclosure and pruning without requiring unrelated payloads.

### 2. Separate person identity from live endpoints

The envelope distinguishes person and device keys, but `core/node/src/lib.rs::bind_iroh` seeds the endpoint with the long-term identity secret. `core/net/src/iroh_adapter.rs` consequently treats endpoint ID as person identity. Custody records also use the identity key for normal signing, and `Node::bootstrap` stores identity and device secret material in the SQLite metadata.

The device model is therefore only partially implemented. Independent devices need individually addressable endpoints and an authenticated mapping to the same person. Reusing the root identity secret across devices does not give independent transport revocation.

Recommendation: authorise device endpoints and operational signing keys under a stable person identity. Define enrolment, revocation, historical verification and recovery before broad application expansion. Key storage also needs a deliberate platform-aware design.

### 3. Custody claims do not prove mutual admission

`CustodyAttestation` signs the object hash, claimant, claimed previous relayer and timestamp. The claimed previous relayer does not countersign that record, and the record does not reference a specific preceding receipt.

`Custody::admission_distance` constructs a graph from these individually signed claims. It does not verify evidence of mutual friendship for each historical edge. A malicious recipient of a valid object can sign a claim that it received the object directly from its author, even if it obtained it elsewhere. This can shorten the graph used by the horizon check without forging the author's signature.

The authenticated immediate peer is useful evidence. Historical receipt claims are also useful, but they do not establish the stronger friendship and handoff guarantees described in the spec.

Recommendation: distinguish authorship, authenticated local receipt, claimed historical receipt, jointly acknowledged handoff and friendship/admission attestations. Decide which evidence each policy actually requires. If mutual handoff evidence is required, design it explicitly; it still cannot expose off-protocol copying or collusion.

### 4. Content convergence and provenance convergence are separate

Head exchange contains author, device and sequence. Equal sequence heads cause `missing_for` to offer no older entries. Two peers can therefore have the same content head but different custody evidence that this exchange never reconciles. Equal-height forks also need more than sequence comparison, and flagged entries are excluded from normal accepted-entry transfer.

The local union operation is valuable, but does not itself guarantee that all relevant evidence reaches peers.

Recommendation: explicitly reconcile content identifiers, missing ranges/dependencies and provenance evidence. Test delayed shorter paths, equal-height forks and provenance-only updates separately from ordinary content propagation.

### 5. Resource policy belongs in the foundation

The spec defers quotas and treats a six-hop horizon as its initial spam control. A hop bound does not bound how much a direct friend can send. Quarantine stores input, and custody sets grow, so non-admission can still consume resources.

There are some transport bounds, including a blob-size limit; the missing piece is comprehensive resource policy rather than an absence of all limits.

Recommendation: bounded requests, pages, queues, quarantine and evidence storage, with per-peer budgets and explicit retention. Define how evidence can be compacted or omitted while honestly reporting the resulting provenance guarantee.

### 6. Private and ephemeral data need distinct policies

`app/lib/src/ui/meta_posts.dart::publishLocation` publishes coordinates as a forum post. That is broad historical publication under current sync rules, rather than selected-recipient live location sharing.

DM encryption uses ephemeral-to-static key agreement and stores a sender copy. Compromise of the recipient's static secret permits decryption of recorded historical ciphertext addressed to it; an ephemeral sender key alone does not supply forward secrecy against that compromise. This is a code-derived property, not a demonstrated exploit.

Recommendation: define location audience/expiry and messaging compromise/recovery requirements explicitly. Choose a reviewed messaging construction appropriate to those requirements instead of treating the prototype's sealed-message scheme as final.

### 7. Battery behaviour is architectural

The FFI push worker fans sync out to contacts on changes and on a roughly 30–49 second backstop. Flutter polls its event queue every second while live sync is started. Sync batches and blobs use whole byte buffers in several paths.

These patterns are reasonable demonstration shortcuts. They are not evidence of measured poor battery life, but identify obvious workloads to measure and redesign for sleeping phones, many contacts and large files.

Recommendation: event-driven application updates, adaptive retry/backoff, selective synchronisation, bounded streaming and explicit mobile participation modes.

## App-level implications

- Treat communities as identifiable spaces if they need membership, rules and governance. Tags can remain useful labels and discovery tools.
- Distinguish immutable historical claims from current permissions, visibility and replication eligibility. A once-accepted signature need not imply perpetual access or forwarding.
- Treat proven equivocation as evidence of conflicting signatures, not automatically proof of deliberate human misconduct; key cloning and faulty restores are possible causes.
- Make the standard object and capability model extensible enough for plugins without encoding every feature as a special forum string.
- Keep optional discovery/relay infrastructure replaceable. The current internet endpoint uses iroh's N0 preset; the LAN mode demonstrates an infrastructure-free local path, not full internet independence.

## Reuse options

| Path | Assessment |
|---|---|
| Extend the current app and protocol | Fastest route to more demo features, but compounds sharing, identity and provenance assumptions. Not recommended for the broader product. |
| Refactor the existing code onto a revised protocol | Viable, especially if retaining Rust. Considerable storage/sync/identity work is still required. |
| New focused prototype, selectively reusing old work | Recommended. Makes the revised guarantees explicit and allows a fair evaluation of development workflow without carrying compatibility obligations. |

The old repo is an executable reference and source of reusable work. A new prototype should not repeat all its screens, voice implementation or auxiliary experiments before resolving the foundation.

## Proposed next experiment

Validate a small set of requirements together:

1. One identity, two independently addressable devices; revoke one device.
2. A private conversation and a public post created on the same device; a community subscriber can receive the post without fetching the conversation history.
3. A file shared to a selected person through an intermediate willing peer with clearly defined privacy and handoff evidence.
4. A third-party false handoff claim cannot be mistaken for the alleged sender's acknowledgement.
5. New provenance reaches a peer that already has the object; conflicting histories remain discoverable.
6. A sleeping phone resumes bounded sync; an excessive peer cannot force unbounded quarantine or buffering.

Specify these outcomes before choosing the final wire representation. Run them through the smallest usable interface. Compare build workflow and battery behaviour on that foundation, then selectively port proven application features.
