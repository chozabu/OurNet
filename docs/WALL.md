# Wall

Your news, for your friends, with comments. The Wall is a place tied to a
*person* rather than a topic or a group: each person has one, their friends
see what they post there, and anyone can follow a public one.

Nothing ranks it. Posts come newest first, from people you chose: your
friends by default, and public walls you follow. A post only travels further
when someone shares it on their own wall.

## Where it is

- **Wall** in the navigation (under Activity) shows every wall you follow,
  merged, with a box at the top for posting on your own. The scope picker
  narrows it: **Personal** shows friends-only posts, **Public** public ones.
- **Posts** in a person's details (tap their name anywhere) opens their wall
  on its own, with **Follow** / **Following**. **Your posts** on your profile
  opens yours.
- Activity lists friends' posts ("Sam posted on their wall") and comments on
  your posts ("Jo and 2 more commented on your post"), a row per wall per day.

## Who sees a post

When you post you pick **Friends** (the default) or **Public**.

- **Friends**: your friends when you post. Someone who becomes your friend
  later sees what you post from then on, not your earlier friends-only posts.
  If you disconnect from or block a friend, they no longer see what you post
  to friends afterwards. What they already saw stays with them: OurNet cannot
  take back what has reached someone's device.
- **Public**: anyone who follows your wall, and anyone a friend shares it to.

People who follow your wall without being your friends carry your
friends-only posts for others but cannot read them. They can tell that you
posted, when, and roughly how long it was.

## Comments

Anyone who can read a post can comment on it, and reply to comments.
Comments on a friends-only post are readable by everyone who can read the
post, including friends of yours who are not friends with the commenter.
A post shows its last two comments; **Show all** opens the rest.

On your own wall you can hide any comment, and delete your posts (from the
post's menu). Hiding is for everyone, though people who already had the
comment on their device keep it there. You cannot remove your comments from
someone else's wall yet.

## Sharing and likes

**Share** puts a public post on your own wall, with a line from you above it,
publicly. The original keeps its author: it is shown as their post, checked
against their signature, inside yours. Sharing something that was itself a
share shares the original. Friends-only posts cannot be shared.

Public posts can be liked. Friends-only posts have no likes yet.

**Copy link** gives an `ournet://wall/…` link to the post (or, from a wall's
page, to the wall). It opens the wall, and offers to follow it. A link to a
friends-only post opens only for people who can read it.

## Following

You follow your friends' walls automatically, and your own. To stop seeing a
friend's posts, open their wall and tap **Following**; they are not told.
A public wall of someone who isn't your friend is followed by link or from
their details, and their posts reach you through friends who follow it too.

You can follow up to 256 walls, forums and chats in all; friends' walls are
followed automatically while you follow fewer than 224.

## Not yet

- A "friends and contacts" audience, custom audiences per post, and letting a
  new friend read earlier posts.
- Pictures and other attachments on posts.
- Likes on friends-only posts; removing your own comments elsewhere.
- Which walls you stopped following is kept per device, as are walls you
  follow by link.

How it works on the wire is in [PROTOCOL.md](PROTOCOL.md#walls); the design
note it was built from is [WALL_SPEC.md](WALL_SPEC.md).
