# Scopes: one set of sections, filtered by who it is for

OurNet used to have two copies of most features: top-level Notes, Calendar,
Direct messages, Forums and Files, and inside each private group another
Conversation / Forum / Files / Notes / Calendar. Scopes replace the second
copy. There is one set of sections and a **scope** that says whose content
they show, much like a subreddit in Reddit or the calendar list in Google
Calendar.

## The model

Every object already has a space and an audience (see `PROTOCOL.md`). An
empty audience is public, a member list is a group or a conversation, and
just you is personal. A scope is a filter over that, so step 1 needed no
protocol change.

| Scope | What it shows |
|---|---|
| **All** | Everything the section can show. The default. |
| **Personal** | Content that isn't in a group and isn't public: your own things, plus what you share with individual friends (shared notes, direct messages, live location). |
| **A group** | That private group's content only. |
| **Public** | Public chats, forums and files. |

Direct messages count as Personal by the same rule as a note shared with one
friend: both belong to you and named people, not to a group or the public. A
separate "chat between my own devices" was considered and left out. Notes
already cover that, and it can be added as a Personal chat later if people
want it.

## Which sections allow which scopes

The table is `ScopedSection` in `core/lib/src/scopes.dart`. The app reads it for
navigation and empty states. Core code that writes or validates content
should check it too. The calendar does, refusing public events (see below).

| Section | Personal | Group | Public |
|---|---|---|---|
| Notes | ✓ | ✓ | – |
| Calendar | ✓ | ✓ | – |
| Chat | ✓ (direct messages) | ✓ | ✓ (public chats) |
| Forums | – | ✓ | ✓ |
| Files | ✓ (drive, attachments) | ✓ | ✓ |
| Maps | ✓ | – | – |
| Activity | ✓ | ✓ | ✓ |

All is always allowed. When a scope does not allow a section, the section
stays in the navigation (so it doesn't shift when the scope changes) and
explains why it's empty, with a button to show All. Making something
public later, say public events, means adding `public` to that row and
writing whatever rules it needs. It is not a change scattered across screens.

### Public calendars are refused

Calendars are private to you or a group. When reading, `Calendar` already
ignored any event with an empty audience. It now also refuses to write one,
checking the table, so a bug elsewhere can't publish a public event. Older
builds never create such events, so nothing changes on the wire.

## The scope header

The scoped sections (Notes, Calendar, Chat, Forums, Files, Maps) and every
plugin section show the scope in the app bar's title: the section's name,
small, over the scope. It is always visible, so a filter can't be forgotten.

- Tapping it opens the picker: All, Personal, Public, each group with its
  unread count and any call in progress, and Create group.
- In a group, it also shows members and sync status, plus buttons for mute,
  members and **group info** (ⓘ: who is in it, who can add people, sync,
  leaving). In Chat it adds voice and video call buttons, as a direct
  conversation's header does; the group's other sections do not start
  calls. A wide screen puts all of this in the app bar. A phone keeps the
  group's name there and puts the rest in a slim strip under it, hidden
  while typing in Notes.
- Group call banners and member add-requests show under it, in every section
  of that group.
- A plugin is told the scope through `on-open` (PLUGINS.md). One whose
  manifest leaves a scope out says it has nothing there and offers All.

- Outside All, a count on the header's arrow says how much is unread in
  other scopes: direct messages, the groups' chats and forums, and joined
  public chats, leaving out whatever the scope on screen shows. It reads the
  same cached counts as the navigation's badges, never history. The picker
  then shows which group it is in.

The side navigation and the phone drawer list only the sections. They used
to list the scopes too, as Google Calendar lists calendars, but the header is
always one tap away and the list crowded the sections out.

Sections without the header (Settings, Network, Search, Profile) ignore
the scope.

### Moving between scopes

- Changing the section keeps the scope: Calendar → Chat in "Family" shows
  Family's chat.
- Changing the scope keeps the section. Opening a group from a notification
  or from the group list goes to its Chat.
- Opening a group's chat or forum from a list in All opens it beside the
  list, as a direct conversation does. The scope stays All. The group's own
  bar above it has its settings, and "Show only this group" makes it the
  scope. On a phone it stacks over the list, with a back arrow.
- Opening a forum marks everything in it read, as opening a chat does
  (`Store.markSpaceSeen`). That includes posts the forum does not show:
  shared copies of posts it already has, posts it cannot read, and posts its
  owner removed. Counting those, without ever marking them, kept a badge up
  for good.
- Opening something from elsewhere (a notification, search, a link) switches
  to a scope that contains it. If the current scope already does, it stays.
  Otherwise the scope becomes that group, or All.
- Android back goes to Notes within the same scope, then from Notes to All,
  then leaves the app.
- The scope is remembered with the destination (`lastScope`): the app opens
  where it was left. A group left since opens in All.

### Writing

Composers write to the scope on screen: a group's notes go to the group,
Personal notes stay personal. In All, the note capture bar starts with a
destination picker (Personal, or any group), and its hint names the group
when one is picked. The event editor already has a calendar picker. Files go
to your drive. Group and public chats are written in by opening them.

## Public chats

Public chats are open, named conversations, like RetroShare's chat lobbies.
A chat is called by its name, and the name is the address (`chat:cooking`):
typing a name starts the chat or, if it exists, joins it. Nobody owns it.
Chats made before names keep their creator and address. Anyone can join. Wire format: "Public
chats" in `PROTOCOL.md`; code: `PublicChats` in core, and `public_chat.dart`
in the app.

- They are listed in Chat, under Public and among everything else in All.
  Under Public, "Friends follow" lists the chats friends are in, each with a
  count and a Join button (see "Finding public forums and chats"). Start or
  join one by name, or paste a link, from Chat's main button.
- **Inviting.** The chat menu's "Invite friends…" sends chosen friends a
  direct message with a chat link, and "Copy chat link" copies one. A chat
  link (`ournet://chat/<address>?name=…`) shows in any message, post or note
  as a chip with the chat's name. Tapping it joins the chat if need be, then
  opens it.
- **Moderation.** A chat with a creator lets them remove any message
  (long-press or right click, then "Remove from chat"), for everyone. A chat
  called by name has no owner and so no one to remove messages; anyone can
  block a sender from their details, which hides their messages everywhere.
  People who want moderation use a private group or a more specific name.
- **Notifications** are off per chat until "Notify me" is ticked in the chat
  menu: open chats can be busy. They go to their own quiet Android channel.
- Messages reach friends who joined the same chat, and their friends who
  joined, and so on, as forum posts do. Friends find chats through listings.
- Messages are signed by their author and not encrypted.
- A message carries the display name its sender chose. Nothing checks it,
  so it is shown beside the sender's key unless this device already knows a
  name for them.
- The list reads the newest 100 messages through the store's
  (kind, space, created) index, with "Show earlier messages" adding 100 at a
  time. Unread is counted the same way, from the time this device last read
  the chat.

Not done yet: replies, attachments, and slow-mode or posting limits.

## Finding public forums and chats

Following a public forum or chat used to be private, so the only way in was
an address someone sent. Now each person's devices tell their friends what
public forums and chats they follow (`Listings`, wire format in `PROTOCOL.md`).

- **On by default**, for every public forum and chat except the default
  "general". Settings has a switch for all of it, and each forum or chat's
  menu has "Show to friends in Browse" for that one.
- **Friends only.** A listing goes to the author's friends and is not passed
  on, so it cannot flood strangers, and the person who advertises is always
  someone you know. It also means the friend you find a forum through follows
  it, so its posts reach you once you join.
- **Browse.** Forums and Public chats show "Friends follow": the most followed
  few not yet joined, each with "3 friends", its description and Join, and
  "Browse all" for a searchable list that also takes a typed name.
- **Names are addresses.** A public forum is called by its name (`cooking`),
  so typing a name from "Start or join a forum" joins it or starts it. No one
  owns a name, so two groups can end up in one forum; they can use a more
  specific name or a private group. Private groups do not use names.
  `forum2:` forums from before names keep their owner and moderation. Owners
  can still remove posts there.
- **Links.** `ournet://forum/cooking`, `ournet://post/...` and
  `ournet://message/...` show as chips in any message, post or note, and join
  then open the thing. "Copy link" is in the forum menu, a post's menu and a
  chat message's menu. Links to notes and to messages in groups would work
  the same way but show as unavailable to people who cannot read them, as
  event links do; they are not built yet.

## Steps

1. **Done: UI only.** Scope state, header and picker, a sidebar and drawer
   list (since removed: see "The scope header"), sections drawn per scope, and the private group page folded into
   the sections. The old Private groups page remains as a plain list of
   groups, reached from the picker's "See all". The core section table and
   the calendar check are in place. There is no protocol change.
2. **Done: merged views in All.**
   - Chat lists direct messages, group chats and public chats together:
     pinned first, then by latest activity.
   - Forums lists the groups' private forums after the public ones.
   - Notes lists the notes of every group you are in among your own, each
     named with its group.

   - Files: group files are under Attachments, with their group named.
   - The navigation's Chat and Forums badges count what the scope shows.

   All of these read indexes, never history:
   - The newest item per group comes from `Store.latestIn`.
   - Unread counts start from a **read floor** per space, below which
     everything is read (`Node.roomReadFloor`, `Node.unreadSinceFloor`).
     Marking a group read moves its floor, and so does a count that finds
     nothing unread. Counting then reads only index rows above the floor,
     capped at 100 ("99+"), and is cached until data changes. A count that
     read every item in every group took about 5 ms per refresh with 1,000
     group messages on the reference PC; from the floor it is about 0.2 ms.
     Marking a group read walks back only to its floor (2.6 ms instead of
     16 ms).
   - Notes come from their per-group index (`Notes.summaries(groups:)`).

   Still to do here: the "All forums" discussion feed covers public forums
   only. An item's audience is fixed when it is published (sealed to
   members), so "move to a group" would mean copy and delete, and the UI
   would have to say so.
3. **Done: public chats** (above).
4. **Fill gaps where wanted:** group maps or live location, and channels
   within a group (below). These are additive kinds or fields.

## Open design questions

- **More than one chat in a group** (like Discord channels). A group's chat
  is its room's `room_item` stream. Channels would be an optional `channel`
  field on items (absent means the main chat). Older builds would show every
  channel merged into one, which is readable but noisy. Alternatively each
  channel could be its own space, sealed with the group key, which older
  builds would ignore. Either way the Chat section would list the group's
  channels where it lists conversations now. Group forums already cover
  topic threads, so channels earn their place only for live talk that
  should not be mixed.
