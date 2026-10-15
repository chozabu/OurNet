# Activity

**Activity**, first in the main navigation, answers "what happened while I was
away?": forum posts, changes to shared notes and lists, calendar events, files
and new friends, with chat available as a filter. It is a way to get to
things, not a place to interact: each row opens the thing in its normal view.

## What a row is

One row per thing per day, so a burst of sync does not turn into a stream of
every object:

| Section | One row per | Reads like |
| --- | --- | --- |
| Posts | forum (public or a group's) per day | "Sam started a discussion", "Sam and Jo posted 4 times" |
| Notes | note per day; a group's lists, your inbox | "Jo changed “Packing list” · 7 edits" |
| Calendar | calendar per day | "Jo added or changed an event" |
| Files | group, drive or public space per day | "Sam shared 3 files", with a thumbnail |
| People | friend | "Ana is now a friend" |
| Chat (off by default) | conversation per day | "Sam sent 5 messages" |
| Plugins | thing a plugin's manifest names per day (a wiki page) | "Jo edited a wiki page · 3 times" |

The Chat list already shows unread conversations better than a feed could, so
the feed never shows one row per message.

Rows show who did it (up to two names and "N more"), up to two lines of what
was written, and where it happened. What you did on another of your devices
shows dimmed; what this device did is left out.

Tapping a row opens: the note; the discussion (one post) or the forum (several);
the event (one) or the calendar (several); the file in Files; the
conversation, public chat or group chat; a friend's conversation; the
plugin's page at that thing.

Plugins choose their rows in their manifests (`activity`, see "In search and
the activity feed" in PLUGINS.md); their arrivals are recorded from when the
plugin is installed.

## Order: arrival, not creation

Peers sync days late, so something written on Monday may arrive on Thursday.
Sorted by creation time it would land below what was already read and never be
seen. The feed is ordered by when things **arrived on this device**, grouped
under day headings, with a "Seen before" line where what had been seen when the
page opened begins.

Something created more than a week before it arrives is history, not news (a
new device's first sync, a group joined with its history shared). It is placed
at its creation time, so it does not flood today.

## Scope and filters

Activity is a scoped section (`ScopedSection.activity`, every scope): in All it
is everything; with a group picked it is that group's front page; Personal and
Public show their part. Section chips filter on top; which are off is saved
(`activityHidden`), with Chat off until switched on.

The navigation badge counts rows from others that arrived since the page was
last looked at, in the scope and filters on screen. Looking at the page marks
them seen (`activitySeen`, an arrival time).

## How it is built

- **Arrival index (core, `Store`).** A local table `arrivals(id, at)` is
  filled by a trigger on `objects` for the kinds the feed shows
  (`Store.activityKinds`). It holds object IDs and times only, never content,
  and is never synced. A row is removed with its object. On first creation it
  is filled from the last 30 days of those kinds, with creation times.
  Changing the kinds means a new trigger name (`arrival_added_N`).
- **`Activity` (core).** Reads arrivals newest first, a page at a time, and
  merges them into rows in memory. The first load reads back about 40 rows
  (at most 2,048 objects), "Show earlier" reads further, and `refresh` takes in
  only what arrived after its cursor. No history scan, no re-reading what is
  loaded: a refresh costs what arrived. Note titles come from
  `Notes.summary`, cached by Notes. New friends come from the time each
  person's first device was added (`device_added`; estimated times are never
  news).
- **App.** `activity.dart` (a part of `app.dart`) draws the page; a
  `CoalescedTask` refreshes the feed when objects of the feed's kinds arrive
  (`Node.onChangesTo`).

There is no protocol change: older builds and peers are unaffected.

## Known gaps

- An object that could not be read when it arrived (its key came later) is not
  revisited by the feed.
- Notes links (`ournet://`) do not exist yet, so a note row opens the note
  directly but cannot be shared as a link.
- No people events beyond new friends: joining or being added to a group,
  linked devices and sync events are not shown. Sync health has its own line.
- Calendar rows say "added or changed": telling the two apart would need the
  previous version of the event.
- No inline actions (reply, mark all read) by design for now.

## Tests

- `core/test/activity_test.dart`: merging, own-device exclusion, catching up
  and the seen count, group scoping with note titles, late history placed at
  its creation time, reading back.
- `app/test/activity_test.dart`: rows, the Chat filter, group scope, opening a
  discussion and coming back.
