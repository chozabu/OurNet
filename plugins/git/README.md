# Git over OurNet

Git repositories shared the way everything else in OurNet is: as signed
objects that sync to an audience, so a friend can clone while you are
offline, and every push says who made it.

```
git clone ournet://3f9c01ab7e/my-project
cd my-project
# …work…
git push
```

## Using it

1. Install **Git** in Settings › Plugins. It asks for `local`: programs you
   run on this computer (git) may talk to it.
2. Put `git-remote-ournet` on your PATH:
   `cargo install --path plugins/git-remote-ournet` (or copy
   `plugins/target/release/git-remote-ournet(.exe)` somewhere on the PATH).
3. Open Git in a scope and make a repository. Where you make it decides who
   gets it:
   - **Personal**: your own devices.
   - **A group**: its members, who can all push.
   - **Public**: your own public space, `x.git.u.<you>`. Friends follow it
     when they open Git in public, and only you can push to it.
4. Push an existing repository to the address the page shows:
   `git remote add ournet ournet://<key>/<name>` then `git push ournet main`.
   `ournet://<name>` works too while only one repository here has that name.

With the app open, `git clone`, `fetch`, `pull` and `push` work as with any
remote. A push that would lose commits is refused unless forced (`+main` or
`--force`), and a push is refused when someone else pushed since you
fetched. The page shows the code at each branch and tag, the README,
commits with their changes, and the pushes: who moved which branch, when.

## Repository settings (0.3)

**Settings → Rebuild local index** retries unreadable packs and replaces this
repository's derived indexes, without changing signed history. Repair is local
and can run while browsing.

**Settings → Delete repository** asks for the repository name and publishes a
signed `x.git.delete` record. Anyone allowed to push may delete (all members in
a group; only the owner in a public space). It retires records at or before its
signed timestamp. It stays deleted after restart/reindex/sync, including late
old pushes. Creating the same name again starts fresh; the old deletion boundary
remains. Local clones are untouched. Signed records and encrypted attachment
chunks are retained by the host: this is a synced logical deletion, not secure
erasure or immediate storage reclamation. Older Git plugins ignore the new kind
and may still show the old repository, so upgrade the plugin on your devices.

Code browsing has a searchable branch/tag list and a collapsible **Code** clone
panel. The repository URL is always selectable and has a Copy button; the clone
command has its own Copy button in the Code panel. **Activity** pages through every push; commit history includes merge
parents and retains loaded pages. Commit diffs include old/new line numbers and
**Show more changes**, rather than silently stopping at a fixed line count.
Large comparisons use patience anchors with bounded quadratic work, falling back
to replacement blocks where no useful anchors exist.

The updated helper requires an app with the streaming local-bridge endpoints.
The older helper's small-push protocol remains accepted. No app version or peer
capability floor is raised by this plugin update.

## Large-pack browsing (0.4)

Requires app host API 0.4. An upgrade rebuilds old derived indexes and retries
packs that 0.3 rejected as too large. No deletion or re-push is needed.

The browser reads 64 KiB windows from encrypted file chunks, verifies and indexes
incrementally, and stores SHA-to-location lookups in a worker-owned SQLite cache.
Offsets are 64-bit. Large raw blobs are hashed through a fixed inflate dictionary
without holding their bodies in memory; their presence does not hide other
files. Object batches and range windows stay bounded regardless of pack size.
Progress distinguishes checking the pack from indexing its objects. Checkpoints
resume at completed object boundaries after restart.

The helper batches large ref updates into ordinary signed records and batches
local object-presence checks through Git, so many tags do not mean thousands of
Git subprocesses. The branch picker pages its search results.

These are structural improvements, not a claim that every Git feature or kernel/
Unreal-sized repository has been validated. See [the limits audit](LIMITS.md).

## Forks, pull requests and network (0.5)

Requires app host API 0.5. Older hosts refuse this package; older plugins still
understand the ordinary repository/push records used for fork contents.

**Fork** creates an independent repository containing the history known to this
device. Personal repositories stay personal, group forks stay in that group,
and public forks go in the forker's own public space. The signed metadata names
the upstream and its creation epoch, so deleting and recreating the same name
does not silently attach old forks or requests to a new project. Copying runs in
background steps, supports pause/resume and restart, and reuses encrypted chunks.
Each copied pack has an idempotency marker. A changed or recreated target stops
the copy. Deleting upstream does not delete the fork's independent push records.

Open **Pull requests** in a fork, choose the upstream URL/key and full target
branch ref, and submit a title/Markdown description. Requests pin exact base and
head commits. Discussions, approvals, requests for changes, head updates and
close/reopen actions are separately signed. Reviews name their commit; the UI
refuses approval if the proposed head changed since it was displayed. Threads
and discussions are paged from disk, with authority checks and out-of-order
delivery recovery. Public proposals live in the proposer's public space, so
discovery follows the existing friend/follow model rather than a global server.

**Merge fast-forward** is available to target maintainers. It checks ancestry
incrementally, imports source packs without moving target refs, then advances
the reviewed ref only if both the displayed proposal and target still match.
Merged requests cannot be reopened. Diverged branches require a real local Git
merge: fetch upstream into your clone, merge its target branch into your proposed
branch, push, and use **Update proposed head** before requesting review again.
The app does not yet create arbitrary three-way merge commits or resolve conflicts.

**Compare** accepts refs or commit IDs from a repository or its visible forks.
It compares exact snapshots (not an automatic three-dot merge-base comparison).
The file viewer adds a lazy folder sidebar, line numbers, background syntax
highlighting, find-in-file, file copying and immutable line-location links.
Paste a copied location into Compare's **Open a copied Git location** field;
opening these URLs through the operating system is not wired up yet.

**Network** shows commit-parent connections, branch/owner lanes and visible
forks. Pan/zoom the graph and select a commit to inspect its changes. Commit
windows and branch lanes are paged; the traversal queue/visited state live on
disk. Missing commits are labelled and can be retried by refreshing after sync.
This is the network visible to this device, not a claim to discover private or
unreachable forks. Full kernel/Unreal qualification, LFS, SHA-256, ref/push metadata
scaling, inline review threads and three-way merge UI remain separate work.

## How it works

| Kind | Holds |
|---|---|
| `x.git.repo` | name, description |
| `x.git.delete` | repository name; its signed timestamp retires old records |
| `x.git.push` | the refs moved (`refs`, and `old`: what the pusher had), whether forced, size and object count; its pack is attached as the push's file (the `files` API: encrypted chunks fetched from whoever has them) |

Before 0.2 a pack travelled in `x.git.chunk` objects of base64; 0.2 reads
none of those pushes, and rebuilds what it keeps from the pushes it can
read. Push such repositories again.

- A push's pack is what `git pack-objects --revs` makes for the new commits
  minus everything the repository already had, so a repository is the union
  of its pushes' packs. Each pack is self-contained (no thin packs), so it
  can be read alone. The current desktop helper spools packs to a temporary
  file and streams uploads/downloads through the local bridge. Pack transfers
  use the same encrypted chunk trees, disk checks, progress and cancellation
  as folder sync; there is no fixed pack-transfer size ceiling. Temporary
  disk space for the pack is required on the sending computer.
- The refs are what the pushes, in order of when they were signed, left
  them. Pushes made apart (offline, say) can each build on a tip the other
  replaced: the first signed keeps the branch, and a later one that was not
  built on it and not forced goes to `<branch>@<first 8 of its author's ID>`
  (`main@3fa9c2d1`). The page says so; its author fetches, merges, pushes
  again and deletes the side branch (`git push ournet :main@3fa9c2d1`).
  Nothing is lost, and every device reaches the same refs. In public only the space's own person's pushes count; elsewhere the
  audience is who may push.
- A fetch asks for the packs whose new commits this clone lacks, oldest
  first, and hands each to `git index-pack`, fetching a pack not on this
  device from friends. A pack no friend could give yet is reported, not
  guessed at, and asked for again every 30 seconds.
- `git-remote-ournet` (gitremote-helpers(7): `list`, `fetch`, `push`) reaches
  the plugin through the app's local bridge (`core/lib/src/local_bridge.dart`):
  a loopback port and a random key in `~/.ournet/bridge.json` (or where
  `OURNET_BRIDGE` says), for plugins granted `local`. Requests reach the
  plugin as `on-request` from device `local`.
- For the page, the plugin reads packs itself (`src/pack.rs`: zlib, deltas,
  commits, trees), a slice per timer tick so a large one never holds its
  thread long, and keeps an index of where each object is in its storage.
  Diffs are line diffs of files up to 300 KB (`src/diff.rs`).

Tests: `cargo test -p git` here, and `core/test/git_plugin_test.dart`, which
pushes and clones with real git through the bridge.

## Not yet

- The helper ships separately; the desktop app could carry it and offer to
  put it on the PATH.
- Pull requests and issues (both would be ordinary signed kinds), forks as
  a button, and per-file history.
- Full large-project qualification: see [LIMITS.md](LIMITS.md). The 0.4 browser
  reads packed ranges and keeps object locations on disk; a large pack or raw
  blob no longer makes the entire push unreadable. Decoded-object previews,
  push/ref metadata and advanced Git features still need further work.
- Android has no local bridge: it browses repositories but nothing there
  runs git against it.

## Who moves a branch: options considered (October 2026)

Commits always sync; only branch pointers can conflict. Compared:

| Option | Verdict |
|---|---|
| Never sync between people | Loses cloning from friends while the pusher is offline |
| Fast-forward syncs, divergence needs a person (current) | Kept: nothing is lost, every device agrees |
| Per-person branches only (Radicle) | No conflicts, but a group has no single main |
| Maintainers move main, others send pull requests | Closest to GitHub; public repos already work so with one maintainer |
| Devices merge automatically | Avoided: competing merges, signed by someone who did not write them, and clean merges can still break code |
| Group vote to move main | Fits group governance later; heavy for everyday pushes |
| Last push wins | The first version; silently drops work |

Decided for later: keep the current rule for personal and group
repositories, then add pull-request objects and an optional maintainer list
per group repository, and perhaps a "Sam's version" view of each person's
branches without changing what syncs.

## Plugin development over git: ideas for later

Today a plugin is built with `cargo run -p pack`, hot reloaded from a
developer folder, then signed in Settings › Plugins. Git could shorten each
step, cheapest first:

1. **Releases name their source.** An optional release field records the
   repository and commit a package was built from; the plugin's page links
   to it here. Friends read what they run, fork it, send changes. `pack`
   already writes zips with fixed times, so rebuilding a commit to check a
   digest may work (unverified for Rust's wasm output).
2. **Push a tag, get a release.** `pack --publish` builds and hands the
   package to the app over the local bridge; the app asks, then signs. With
   git: `git tag v0.3.0 && git push ournet --tags`. The key stays in the app.
3. **Testers follow a branch.** Install a plugin from a repository and a
   branch (`dev`); each push carrying a package updates those who opted in,
   like the developer folder but across friends.
4. **No build step** (done, October 2026). With script plugins
   (plugins/SCRIPTING.md) a repository is the plugin: when the top of the
   branch or tag on show has a `manifest.json` naming a `runtime`, the page
   offers "Install as plugin". The plugin hands the files (manifest, UI,
   `scripts/`, `assets/`) to the app through `plugin-offers`, with the
   repository, ref, commit and who pushed it; the app's install prompt says
   so, installs the bundled runtime if needed, and keeps that source with
   the plugin (Settings › Plugins shows it). The install is unsigned: the
   pusher, not a release, is who answers for it. Android included.

Suggested order: 1 and 2, then 3. Next for 4: offer a newer tag of the same
repository as an update, and let a publisher sign a release naming the
commit, so friends get it through the release space as well.
