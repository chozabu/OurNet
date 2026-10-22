# Git limits and large-project qualification

The goal is ordinary small and very large projects, with memory bounded by active
work rather than repository size. A fixed memory budget must restrict an expensive
preview, not make the repository disappear. Linux-kernel and Unreal-scale history
are qualification targets; neither complete repository has been tested here yet.

## Removed in 0.4

- The 16 MiB whole-pack browsing cutoff: attachments are read in bounded ranges.
- The 16 MiB settings quota for the object index: object locations live in a
  disk-backed SQLite cache on a dedicated worker, with bounded page-cache memory.
- Loading every object's location into the guest: lookups query the disk index.
- 32-bit pack offsets: locations now use 64-bit offsets.
- Failing an entire pack because of a large raw blob: blobs are hashed in a
  streaming inflate cursor; objects after them are still indexed.
- The fixed 64-level delta-chain rejection: local delta traversal detects cycles
  and accounts for its memory use instead of counting levels.
- A single signed record limiting how many tags can be pushed: the helper splits
  ref metadata into bounded records and attaches the pack once.
- One Git process per ref/object-presence check in the common path: local refs
  and object-presence checks are obtained in batches.
- Sending/rendering every branch/tag in an open picker: search results are paged.
- The silent 300-changed-file diff cutoff: diffs page through additional files.
  Tree comparison is iterative and avoids quadratic per-directory name scans.
- The eight-level annotated-tag cutoff: tag peeling detects cycles instead.
- The arbitrary 200-byte ref-name check: names use Git ref-name validation. The
  optional HEAD metadata field still has a per-record size bound.

## Resource bounds, not repository-size claims

- Guest memory remains 64 MiB. Compressed input windows, inflate dictionaries,
  caches and index-write batches are bounded independently of repository size.
- Disk capacity and the user's attachment storage allowance still apply. Index
  writes retain a disk-space reserve and report disk errors.
- The whole-file legacy plugin API still has a 16 MiB per-call bound; 0.4 browsing
  uses range calls (at most 256 KiB each). Streaming transfer bypasses that API.
- SHA-1 Git packs themselves have a 32-bit object count per pack. Repositories
  may contain multiple packs; this is a Git format field, not a project limit.
- File/diff/README views deliberately bound preview work. Git clone/fetch keeps
  the original bytes; the browser is not an unlimited text/image renderer.

## Remaining architectural limits and feature gaps

These must be addressed before claiming universal large-project support:

- Decoded-object previews currently have a 16 MiB working-object budget. Large
  raw blobs do not fail the index, but oversized delta results/bases can lack a
  preview. Giant commit/tree objects and forward REF deltas still require a
  streamed decoded-object backend and explicit fallback diagnostics. Cloning
  continues to use real Git and preserves the original pack.
- Repo/push/ref metadata still uses the guest's small settings store and cached
  vectors/maps. Many pushes or refs can exhaust the 16 MiB settings quota or the
  64 MiB guest heap even though the object index no longer does. This metadata
  needs disk-backed cursors/materialized ref state as well. Loaded commit/diff
  pages also need bounded windows for arbitrarily long browsing sessions.
- SHA-256 Git object format is not implemented; the parser and validation use
  SHA-1 IDs. It must be negotiated explicitly, not mistaken for corrupt SHA-1.
- Git LFS transport is not implemented. LFS pointer files are Git blobs; their
  external LFS objects are not automatically mirrored by this remote. This is
  particularly relevant to Unreal projects using LFS.
- Shallow/partial-clone filters and atomic multi-ref pushes are not advertised.
  Submodules remain separate Git repositories/remotes, as in ordinary Git.
- Non-UTF-8 names, very large flat directories, giant diffs, deeply nested trees,
  unusual ref/pack combinations need dedicated fixtures. Annotated-tag chains
  and deep diff trees now have basic cycle/depth regressions.
- The desktop helper remains separately installed. Android can browse via the
  native host but does not run a local Git command-line helper.

## Validation

Automated cases cover encrypted random reads across deep chunk trees, a derived
index exceeding the old 16 MiB quota, 64-bit offset encoding, bounded object
batches, checkpoint resumption, a streamed 17 MiB raw blob followed by metadata,
10,000-ref batching, and the real OurNet checkout pack (about 22 MB) through the
native host, including browsing, repair and restart. An opt-in checkout test is
`OURNET_GIT_SCALE=1 dart test test/git_plugin_test.dart` from `core`.
The opt-in disk-index test also passed with one million entries, persisted and
reopened (`OURNET_INDEX_SCALE=1 dart test test/plugin_index_test.dart`). This tests
the index backend, not importing a million-object Git repository.

Outstanding qualification requires multi-gigabyte packs, millions of objects,
large delta bases/chains, many independent pushes, interrupted/resumed imports,
LFS-backed assets, SHA-256 repositories and physical-device memory/frame tests.
Do not replace any of those with a claim that a small fixture proves all sizes.
