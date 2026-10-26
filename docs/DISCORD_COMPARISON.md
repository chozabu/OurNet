# OurNet and Discord compared

Review of 26 October 2026. Discord is where most friend groups and small
communities already are, so it is the app OurNet most often has to replace.
This records what Discord does, or does better, that someone switching would
miss, and leaves room for what we decide. Discord was not inspected as code;
statements about it are from how it is known to behave in use. Statements
about OurNet are from the docs and a search of `app` and `core`, not a full
audit: "none found" means a search turned up nothing.

## In short

Discord's strength is that its servers do the hard parts: voice that always
connects, history that is always there, a link that puts anyone into a
community in a browser in half a minute, and roles, bots and moderation built
on top. OurNet's strength is that there is no company in the middle: nobody
can ban a group or shut its server, private content is end-to-end encrypted,
and notes, calendar, maps, files, git and remote desktop live beside the chat.

The realistic target is the friend-group server, which is most real Discord
use, not the public community of thousands of strangers. For that target the
gaps that would send people back first are voice reliability and screen
share, a server-like container with channels, and how hard it is to get in.

## Area by area

### Voice and screen share
- **Discord:** voice channels anyone drops into, routed through Discord's
  media servers, so every pair can hear each other; dozens in one channel;
  "Go Live" streams a game or screen to the channel; push-to-talk on a
  global hotkey; per-person volume; server mute and deafen; join and leave
  sounds; the sidebar always shows who is in each voice channel.
- **OurNet:** a call per group in the manner of a voice channel (nobody is
  rung; it exists while anyone is in it), a WebRTC mesh of at most 8 devices
  with a host that keeps the roster, healing on network changes, noise
  suppression. See [MESSAGING.md](MESSAGING.md#group-calls).
- **Discord far ahead.** Two devices both behind carrier-grade NAT cannot
  hear each other ("Cannot connect"), since there is no TURN and no media
  over iroh yet. There is no notification when a call starts, no screen
  share in calls (remote desktop is separate and limited to one's own
  devices), and no push-to-talk found. For a gaming group this area decides
  whether they stay.

### Servers and channels
- **Discord:** a server is one place with many text and voice channels in
  categories, one invite and one member list.
- **OurNet:** each private group has its own chat, forum, notes, calendar and
  call, and its own membership (up to 64 members). A community today is a set
  of separate groups.
- **Discord ahead** on structure. OurNet's single group is richer than one
  Discord channel; what is missing is the container.

### Roles, permissions and moderation
- **Discord:** roles with colours and permissions, per-channel overrides,
  moderators who delete messages, time out, kick and ban, slowmode, an audit
  log, AutoMod.
- **OurNet:** a group owner; members can add people by request; group forum
  posts can only be hidden for oneself or the author blocked. Public
  `forum2:` forums are owner-moderated.
- **Discord far ahead.** Beyond about ten people somebody needs moderator
  powers. OurNet's signed objects suit this well: moderation actions could be
  signed and visible to members, which Discord's are not.

### Chat
- **Discord:** @mentions of a person, a role, @everyone; per-channel
  notification levels (all, mentions only, none); unread markers and "jump
  to unread"; typing indicators; pins; threads; search with filters; link
  embeds; markdown with code blocks and spoilers; custom emoji, stickers and
  a GIF picker.
- **OurNet:** group chat with replies, reactions, edits, removal and paging,
  voice messages with on-device transcripts, delivery and read receipts in
  1:1 chat, the Activity feed. Open items from the group chat work: typing
  indicators, group unread counts and notifications (still the old `seen/`
  marker), forward, multi-select, in-chat search, and a pending-send bubble
  with retry. No mentions found.
- **Discord ahead.** Mentions matter most, because Discord users mute busy
  channels and rely on being notified only when mentioned. Emoji, stickers
  and GIFs look trivial but are much of the culture.

### Presence
- **Discord:** online, idle, do not disturb, invisible; custom status;
  "Playing X"; a member list showing who is around.
- **OurNet:** none found beyond who is in a call.
- **Discord ahead.** Some of this is a privacy choice, but with none a group
  feels empty.

### Bots and integrations
- **Discord:** a large bot ecosystem (music, moderation, reminders, game
  stats, polls), slash commands, and incoming webhooks that post GitHub, CI
  or RSS updates into a channel.
- **OurNet:** WASM and JavaScript plugins ([PLUGINS.md](PLUGINS.md),
  [SCRIPTING.md](SCRIPTING.md)) that run on the user's own device, git over
  OurNet, a headless CLI node, polls as voting with delegation.
- **Discord ahead.** Plugins are the right base, but a bot must be always on
  and act as a member. Webhooks need something reachable from the internet.

### Getting in
- **Discord:** an invite link opens in a browser and the newcomer is
  chatting in about thirty seconds with no install; the app is on Windows,
  macOS, Linux, Android and iOS.
- **OurNet:** expiring invites, QR codes, connecting through friend chains
  and member add-requests, all inside the app; the app comes from a
  direct-link-only Microsoft Store listing or Play internal testing; Linux
  builds as a Flatpak but is not validated in everyday use; no macOS or iOS.
- **Discord far ahead.** For many friend groups one iPhone user decides the
  matter.

### Availability and history
- **Discord:** every message is on Discord's servers: years of history on
  any device, at once, whether or not anyone else is online.
- **OurNet:** history lives on members' devices; friend relays, push wake,
  background sync and history sharing with new members cover much of it, but
  messages still depend on some holder being reachable.
- **Discord ahead**, by design. OurNet's answer is holders and own relays
  ([CONNECTIVITY.md](CONNECTIVITY.md)), never a central mailbox.

### Public communities
- **Discord:** servers of thousands of strangers, server discovery, vanity
  invite links.
- **OurNet:** groups up to 64 members; public forums and chats found through
  friends' adverts ([SCOPES.md](SCOPES.md)); posts travel only through
  friends who follow them.
- **Discord far ahead.** Chasing this would work against accountability over
  anonymity; see the decisions below.

### Where OurNet is ahead
No company can ban, scan, sell or shut down a group. Private content is
end-to-end encrypted and works on a LAN with no internet. Per-hop provenance
shows how everything arrived. Multi-device sync with recovery, shared notes,
calendars, maps with live location, a private drive, voting with delegation,
git and remote desktop sit beside the chat. No Nitro: large uploads and good
call quality are not a paid tier.

## Where each is ahead

**Discord:** voice that always connects, large calls and screen streaming;
servers with channels; roles and moderation; mentions and notification
control; presence; bots and webhooks; joining from a browser link; every
platform; history always available; public communities.

**OurNet:** no central operator; encryption; offline and LAN use;
provenance; own-device sync and recovery; everyday apps beside the chat;
plugins that run locally; no paid tier.

## Ideas from Discord

### 1. Voice reliability
Relay media for pairs that cannot reach each other: the call host first, as
MESSAGING.md plans, then call media over iroh. Notify group members when a
call starts (per group, mutable). Push-to-talk with a global hotkey on
desktop, per-person volume, join and leave sounds.

### 2. Screen share in group calls
Share a screen or window into the group call, reusing the remote desktop
capture and encoding where it fits, with bitrate cut as the mesh fills.
Possibly limited to one sharer at a time.

### 3. Spaces with channels
A container holding several text and voice channels with one membership and
one invite, built on the existing group keys and rooms. A single group stays
as it is and is a Space with one channel.

### 4. Moderator roles
Owner-delegated moderators who can remove messages, remove members and set
slowmode, with each action a signed object members can see. The scoped
moderation idea in [RETROSHARE_COMPARISON.md](RETROSHARE_COMPARISON.md#5-reputation)
is the same mechanism for forums.

### 5. Mentions and notification levels
@person, @here or @everyone in group chat, carried as a field older builds
ignore; per-group notification levels (all, mentions, none); group unread
counts and notifications replacing the `seen/` marker.

### 6. Presence
Online, away and do-not-disturb with a short custom status, shared with
friends only and off by choice.

### 7. Bots as members
A headless identity on the CLI node that runs plugins, joins groups as a
member and has an accountable owner shown on its profile. Incoming webhooks
through an own relay or the bot's node.

### 8. Joining without the app
An invite link that opens a page explaining OurNet and leading to the right
store, carrying the invite through installation. Then iOS and macOS.

### 9. Chat polish
Pins, typing indicators, link previews, markdown with code blocks and
spoilers, an emoji and GIF picker, in-chat search.

## Decisions

To fill in.

### Target: friend groups or public communities

### 1. Voice reliability

### 2. Screen share in group calls

### 3. Spaces with channels

### 4. Moderator roles

### 5. Mentions and notification levels

### 6. Presence

### 7. Bots as members

### 8. Joining without the app

### 9. Chat polish

### Order of work
