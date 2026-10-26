# Wall: a person's posts for their friends

Spec, 2026-10-26. Read against `docs/PROTOCOL.md`, `docs/SCOPES.md`,
`docs/ACTIVITY.md`, `core/lib/src/model.dart`, `room_forum.dart`,
`builtin_modules.dart`, `node.dart` (subscriptions, `_offerable`) at `cc6f66d`.
Design discussion: notes/contact-trust.md (tiers) and the project thread.

## Goal

A place tied to a *person* rather than a topic or group: "my news, for my
friends", with comments. Spread is chronological and human-driven only:
friends by default, public walls followable (Twitter-like), reshare is the
only way a post travels further. No ranking, no friends-of-friends visibility.

## Constraint that shapes the design

A private object's audience is capped at 64 people and 128 wraps
(`SignedObject.valid`, `model.dart`). "All my friends" is often more than that,
so friends-only posts cannot be ordinary private objects. Instead each wall has
a **wall key** (per epoch) handed to friends once, and posts are sealed with it.
That also makes a post cost one AEAD box instead of a wrap per device.

## Wire format (all additive; older builds ignore the new kinds)

Space: `wall:<person>` (person ID of the wall's owner). Every object below has an
**empty audience** (routes like public objects, by subscription), so it is
carried by friends who follow the wall like forum posts are.

| Kind | Author | Payload |
|---|---|---|
| `wall_post` | owner only | Public: `{text, title?, share?}`. Friends: `{epoch, box}` where `box` = ChaCha20-Poly1305 under the wall key for `epoch`, plaintext `{text, title?}`. |
| `wall_comment` | anyone who can read the post | `{post, parent?, text}` in the clear for public posts; `{post, epoch, box}` for sealed posts (same epoch as the post). |
| `wall_hide` | owner only | `{object}`: hides a comment (or own post) on this wall. Ignored from anyone else. |
| `wall_key` | owner, **private**, audience ≤ 64 friends, one object per batch | `{epoch, key}` (32 random bytes, base64). |

- Validators go in a new `wallModule` in `builtin_modules.dart` (text ≤ 20,000,
  title ≤ 200, `share` as below, `epoch` int ≥ 0, `box` string).
- A `wall_post` or `wall_hide` whose author is not the person in the space name
  is dropped on receipt (like `forum2:` owner checks in `PublicNames`).
- `wall_comment` on a sealed post must open with the post's epoch key, or it is
  not shown.
- Votes: reuse `forum_votes` (`vote` kind) on wall posts if it is generic over
  object IDs; otherwise leave reactions for later. **Done for public posts**
  (shown as likes); a vote on a friends-only post would be public, so those
  have none yet.

### Keys and epochs

- Epoch 0 is created on first friends-only post. The key is personal state
  replicated to own devices (a `note_self` register `wallKey/<epoch>` or a
  `_keys`-style private object to self: implementer's choice, must survive
  pairing a new device). **Chosen:** the `wall_key` records themselves, whose
  audience always includes the owner; a device linked later is re-sent each
  key it lacks (`WallKeys.shareOwn`, run with key grants).
- On publishing in an epoch, any friend without a `wall_key` for it gets one
  (batches of ≤ 64 people). New friends get the current epoch only, so they do
  not read posts from before they were friends (mirrors "a device enrolled later
  holds no key for anything written before it"). Offer "share earlier posts"
  later if wanted.
- **Rotate** (epoch + 1) when a friend is removed, blocked or forgotten: next
  friends-only post uses the new epoch and keys go to remaining friends only.
  What the removed friend already received stays with them; say so in the UI.
- Comments by a friend use the post's epoch key, so every reader of the post can
  read its comments, even commenters they are not friends with.

### Following and routing

- A wall is followed via the normal subscription set (`Node.subscribe`).
  Every friend's wall is followed by default: add `wall:<friend>` for each
  admitted friend unless the person turned it off (register
  `wallUnfollowed/<person>` or a `false` subscription: reuse whatever
  `subscriptions` already uses for opt-out). Own wall is always followed.
  **Chosen:** subscriptions have no opt-out record (unfollowing deletes the
  row), so friends' walls are added in memory from the contacts and a local
  `wallUnfollowed/<person>` setting stops one, like subscriptions themselves
  (per device).
- Non-friends can follow a public wall by link (`ournet://wall/<person>` in
  `links.dart`), reached through friends who follow it, as public forums are.
  They receive sealed posts too but cannot open them; the UI shows only what
  opens. Accepted metadata leak: timing and size of friends-only posts, to
  followers of the wall. Note it in PROTOCOL.md.
- Do not add walls to `Listings` (following a person is not advertised).

### Reshare

`wall_post.share` = `{object: <signed object JSON of a public wall_post or
forum post>}`. The original is verified as an object in its own right
(signature, public, author) and shown as an embedded card under the resharer's
optional text, keeping the original author. Only public posts can be reshared;
the share action is not offered on sealed posts. A reshare of a reshare embeds
the original, not the chain.

## Core API (`core/lib/src/wall.dart`)

Shaped like `RoomForum`: loaded once, then kept current from an insertion
cursor; never rescan history on refresh (AGENTS.md responsiveness rules).

- `Wall(node, person)`: `posts` newest first with comments threaded,
  `publish(text, {title, audience: WallAudience.friends|public})`,
  `comment(post, text, {parent})`, `hide(object)`, `reshare(object, text)`.
- `WallFeed(node)`: followed walls merged, newest first, paged.
- Key handling in `WallKeys` (create, distribute, rotate on friend removal,
  open). Hook rotation where friends are removed/blocked in `node.dart`.
- Activity (`activity.dart`): rows "Sam posted on their wall" / "Jo and 2 more
  commented on your post", one per wall per day like forum posts. Unread counts
  via `_readKinds`.

## App

- **Wall** section in the main navigation (after Activity): composer at top
  (audience picker: Friends (default) / Public), then `WallFeed`.
- Contact details and own profile: a "Posts" tab showing that person's `Wall`,
  plus Follow/Unfollow for walls.
- Post card: author, time, audience icon, text (links render as chips as in
  forums), comments collapsed to the last two, Comment, Share (public only),
  menu: Copy link, Hide (owner), Delete own post (`wall_hide` of own post).

## Out of scope for v1

- "Friends + contacts" audience: depends on `contactTier`
  (notes/contact-trust.md), not built yet. When it lands, contacts simply don't
  get wall keys or a default follow.
- Images/attachments on posts (add with the existing attachment path later).
- Sharing earlier epochs with new friends; per-post custom audiences.

## Tests

- core: validators; owner-only `wall_post`/`wall_hide`; seal/open; new friend
  can't open earlier epoch; rotation on unfriend (removed friend can't open new
  posts); comment by friend readable by another friend; non-friend follower sees
  public only; reshare verifies original and rejects a tampered one; refresh is
  incremental (cursor), not a rescan.
- Two-node sync test (as other forum tests do): A posts friends-only, B reads,
  C (friend of B only, following A's wall) gets nothing readable.
- Docs: `docs/WALL.md` (user-facing behaviour), `PROTOCOL.md` section,
  `PROTOCOL_CHANGELOG.md` entry.

## As built (2026-10-26)

Implemented on branch `wall`: core in `core/lib/src/wall.dart` (tests in
`core/test/wall_test.dart`), app in `app/lib/ui/wall_page.dart` and
`wall_section.dart`, user docs in `docs/WALL.md`, wire format in
`docs/PROTOCOL.md` (Walls). Where it differs from the above, or settles
something the above leaves open:

- **New friends and epochs.** Handing a new friend the current epoch's key
  would let them open every post of that epoch, earlier ones included. So
  when a friend who was not given the current key is about to get it while
  others were, a new epoch starts first. Each new friend therefore costs one
  key record per 63 friends on the next friends-only post.
- **Rotation** happens on the device where a friend was disconnected or
  blocked (`Node.setContactState`), and only if they were a friend. It
  publishes the new epoch's key to the owner alone; friends get it with the
  next post. Two devices starting the same epoch at once write two keys:
  posts use the record with the lower ID, readers try both.
- **A device without its person's keys** (linked later, not re-sent yet)
  refuses friends-only posts with an explanation rather than starting a
  conflicting epoch.
- **Batches** are at most 63 friends besides the owner and 128 devices in
  all, the object limits once the owner's own devices are counted.
- **Subscription cap.** Peers refuse an inventory with more than 256
  subscriptions, so friends' walls are followed automatically only while
  fewer than 224 spaces are followed, and following beyond 256 is refused.
  People with very many friends will not follow every friend's wall.
- **Sealing** binds the box to owner, epoch, kind and (for comments) post in
  the AEAD's associated data. A public comment on a sealed post, or a sealed
  one on a public post, is not shown.
- **Reshares**: a post whose embedded original fails verification is not
  shown at all (rather than shown without it).
- **Activity** lists friends' posts, and comments only on the person's own
  wall (comments elsewhere would be noise). Sealed ones are opened for their
  preview line; a post this device cannot open gets no row.
- **Unread**: `seen/<id>` marks on posts and comments; the Wall item in the
  navigation counts what others wrote in the loaded feed until it is opened.
- **App**: contact details are a bottom sheet without tabs, so "Posts" is a
  button there (and "Your posts" on the profile page) opening the wall as a
  page with Follow/Unfollow and Copy link. Post titles are supported by the
  API and shown, but the composer has no title field.
- **Not done**: deleting one's own comment on someone else's wall, likes on
  friends-only posts, syncing wall follows/unfollows between own devices
  (they are per device, like subscriptions), images.
