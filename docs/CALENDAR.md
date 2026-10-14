# Calendar

A personal calendar, plus a private calendar for every group. Group events show
in the personal calendar too, with a switch for each group. It is built on what
OurNet already does: events are encrypted objects that sync like everything
else, dictation gives text and audio, and every event can be linked from a
chat, a forum post or a note.

## Where things are

- **Calendar** in the main navigation: the personal view. Its sidebar lists
  *My calendar* and each group with a checkbox and a colour. Unticking a group
  hides it here only (and silences its reminders on your devices); the choice
  follows you to your other devices.
- **Calendar** tab inside a group: that group's events alone. Everyone in the
  group sees and can change them.
- Chat, direct messages and forum composers have a calendar button that puts a
  link to an event into the message. A link shows as a card with the event's
  title and time and opens it. A link to an event you cannot read says so.

## What it does

| Google Calendar | OurNet |
| --- | --- |
| Day, week, month, year, schedule, 4-day views | Day, 3-day, week, month, year, schedule; `d w m y a 3` switch views, `t` today, `j`/`k` or `n`/`p` step, `c` create, `/` search |
| Click or drag empty time to create | Tap, or drag with a mouse / long-press and drag by touch |
| Drag to move, drag the bottom edge to resize | Same, snapped to 15 minutes; in the month view drag an event to another day |
| Swipe between periods | Swipe sideways by touch |
| Overlapping events side by side, now line, all-day strip | Yes; all-day strip collapses after three rows |
| Month view with bars across days, "+N more" | Yes; on a phone, dots with the chosen day listed below |
| Quick add ("Lunch with Sam tomorrow 1pm") | The title field reads dates, times, lengths and repeats and offers them, and applies them when you save |
| All-day and multi-day events | Yes |
| Repeat: daily, weekly (days), monthly (date, nth weekday, last weekday), yearly, custom, end on date or count | Yes. One record per series |
| Edit or delete "this event / this and following / all" | Yes. A single changed occurrence is a small override; two people changing different occurrences never conflict |
| Notifications, several per event, all-day at 9:00 | Yes, scheduled on each device for the next two weeks; your own reminders for a group event can replace the event's |
| Tell me when someone adds or moves an event | Yes, for group calendars (not for muted groups) |
| Invite guests, accept / maybe / decline | The group is the guest list: Yes / Maybe / No with who answered, for the whole series or one occurrence |
| Calendars list with colours, show/hide | Yes, colour per calendar and per event (the same eleven colours) |
| Busy / free | Yes |
| Location with map | Yes (opens a map search) |
| Description with links | Yes, with the chat formatting; links to other events become cards |
| Search | Titles, places, notes and voice-note transcripts, here and in Search |
| Undo after delete / move / edit | Yes |
| Import / export `.ics` | Yes: a whole calendar, or events from another calendar, including repeats, changed and removed occurrences, reminders |
| Week starts on, weekends, week numbers, default length and reminder | Yes |
| Share an event | A link, copied or sent into a chat; group events can be opened by the group's members |
| — | **Dictate** an event: speak "Lunch with Sam tomorrow at one" and the form fills in; or keep the words as notes. The recording is kept with the event, with its transcript |

## How it syncs

The same way as the rest. Events are `cal_event` objects; see
[PROTOCOL.md](PROTOCOL.md#calendar). Your calendar goes to your own devices
only. A group's goes to its members, and the group's owner republishes it for
people who join with history shared. Older builds keep and pass the objects on
without reading them. Reading is incremental: an insertion cursor takes in what
arrived, so opening, paging and refreshing cost the same on a calendar with ten
years of events as on a new one.

## Known gaps

- **Time zones.** Times are exact moments, shown in each person's own zone, so
  a call at 3pm in London is 10am in New York for the person there. What is
  missing is an event pinned to a zone: a repeating "9am London" will not follow
  London's clock change for someone elsewhere, and there is no second time zone
  column.
- A removed member's events stay in the group (the owner re-publishes them).
- **Subscribing to another calendar's feed** (a URL that updates itself) is not
  supported; import reads a file once.
- No Tasks, birthdays or holidays calendars, no working hours or out-of-office,
  no printing, no Android home-screen widget for events.
- Only voice notes can be attached to events, not files or photos.
- "Find a time" across people is not possible: members' personal calendars are
  private to them.
- With "share history" off, someone who joins a group sees only events written
  after they joined.
- Links to events open inside the app; the operating system does not hand
  `ournet://` links to OurNet yet.

## Working on it

- Model, rules and storage: `core/lib/src/calendar.dart` (events, index,
  edits), `recurrence.dart`, `quick_add.dart`, `ics.dart`. Tests:
  `core/test/calendar_test.dart`, `quick_add_test.dart`.
- Screens: `app/lib/ui/calendar_*.dart`, `event_*.dart`; state in
  `controllers/calendar_controller.dart`; reminders in
  `services/calendar_reminders.dart`. Tests: `app/test/calendar_test.dart`.
  `app/test/calendar_shots_test.dart` draws the screens to PNG files
  (`--dart-define=CALENDAR_SHOTS=<folder>`) for looking at layout.
- `integration_test/calendar_history_test.dart` is the profile-mode journey for
  a long calendar (open, page, switch views, events arriving while typing).
  `tool/check.ps1 -Performance` runs it.
- A refresh must stay proportional to what arrived: read through
  `Calendar.refresh()` and the in-memory index, never by scanning history.
