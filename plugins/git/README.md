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

## How it works

| Kind | Holds |
|---|---|
| `x.git.repo` | name, description |
| `x.git.push` | the refs moved (`refs`, and `old`: what the pusher had), whether forced, the IDs of the chunks carrying its pack (`parts`; `chunks` is a file's field in every build), size and object count |
| `x.git.chunk` | 45 000 bytes of a pack, base64 |

- A push's pack is what `git pack-objects --revs` makes for the new commits
  minus everything the repository already had, so a repository is the union
  of its pushes' packs. Each pack is self-contained (no thin packs), so it
  can be read alone. One push carries 16 MB at most.
- The refs are what the pushes, in order of when they were signed, left
  them. Pushes made apart (offline, say) can each build on a tip the other
  replaced: the first signed keeps the branch, and a later one that was not
  built on it and not forced goes to `<branch>@<first 8 of its author's ID>`
  (`main@3fa9c2d1`). The page says so; its author fetches, merges, pushes
  again and deletes the side branch (`git push ournet :main@3fa9c2d1`).
  Nothing is lost, and every device reaches the same refs. In public only the space's own person's pushes count; elsewhere the
  audience is who may push.
- A fetch asks for the packs whose new commits this clone lacks, oldest
  first, and hands each to `git index-pack`. A push that has not fully
  arrived yet is reported, not guessed at.
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
- Large repositories: more than 16 MB per push, and packs too big to read
  on a phone, would want the file chunks core already has (`plugin files`
  is not a grant yet).
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
4. **No build step.** With script plugins (plugins/SCRIPTING.md) a
   repository is the plugin, and the app installs from a repository and tag
   with no toolchain, Android included.

Suggested order: 1 and 2, then 3; 4 follows scripting.
