# Maps and live location

A map in the main navigation, with friends on it. Everything else a maps app
does (search, routing, layers) is the plan; this is what exists now and what
is deliberately not there yet.

## What it does today

- **Map** (Maps in the navigation): full-screen vector map, light and dark
  styles that follow the app theme (or are fixed in the layers sheet).
  Pan, pinch, rotate, double-tap zoom, long-press to drop a pin.
- **Friends on the map.** Each friend is a coloured disc with their initial at
  the place they last reported, faded when that is over three hours old. A
  strip of friend chips under the search bar flies to them; their card shows
  how long ago, which device, and how far from you, with Message, Directions
  and Copy.
- **Your position.** A blue dot with an accuracy circle (Android and Windows
  read it from the system). A computer with no location sensor shows where your
  phone last was, labelled with the phone's name.
- **Search** finds friends and saved places by name, note or emoji, and goes
  to typed coordinates. Address and venue search is not built yet.
- **Saved places.** Long-press, then Save: a name, any single emoji (⭐ by
  default), optional note and one or more lists. Saves are private by default.
  Saved opens a searchable list; Show on map displays one list with clustered
  markers. Hiding it does not delete anything. Deleting a list keeps its places.
- **Group lists.** Create a list for a group, then explicitly select that group
  when saving. Members organise lists and contribute pins; a pin's contributor
  and the group owner can edit or delete it. A list's creator and group owner
  can rename or delete it. Group notes are labelled as shared; a separate
  private note stays with you. Save a copy starts with empty notes.
- **Share a place.** The pin card sends a link to a chosen friend or group.
  It contains only name, emoji and coordinates and opens directly in Maps.
  Notes and list memberships are never included.
- **Directions** hands the destination to the system: any maps app on Android,
  the OpenStreetMap route planner in a browser on Windows.
- **Offline maps.** Every tile seen is kept (up to 256 MB, least recently used
  first). *Save visible area* downloads a region at the detail you choose and
  keeps it until deleted; a city is a few megabytes. Interrupted downloads
  resume. *Use the internet for maps* off means nothing is fetched.
- **Location sharing** (menu, or the people icon in the search bar): see who
  can see you and how much, choose each friend's level, pause, and grant
  permission.

## Location sharing: the rules

- **Per-friend levels.** Each friend is *Precise* (where you are, as you
  move), *Approximate* (your area, to within a few kilometres) or *Off*
  (nothing, exactly as when paused), and can be made *Precise for 1 hour*,
  after which they go back to the level they had. Tap a friend in *Location
  sharing* to choose. Accepting a friend request asks once, with Approximate
  chosen; dismissing it leaves Approximate. Friends you had before levels
  existed stay Precise, so upgrading changes nothing; friends added since
  (including through a request they accepted, or on an older build) are
  Approximate until you choose. A request you sent is not asked about when it
  is accepted: there is no point in the app where that is seen happening.
- **Where levels live.** In your personal state (`note_self` registers, see
  [PROTOCOL.md](PROTOCOL.md#locations)), synced between your own devices and
  readable by nobody else. A friend is never told their level, and nothing on
  the wire marks a position as approximate beyond its large accuracy circle.
- **The sender enforces it.** Your primary device applies each friend's level
  as it sends; your own devices always get the precise position. Approximate
  is the centre of a fixed grid cell (rows of 0.05° latitude, about 5.6 km,
  cut into near-square columns), with an accuracy that covers the cell and no
  heading or speed. Every fix inside a cell gives the same point, so averaging
  many reveals nothing; a friend is sent a new one only when you change cell
  (after going 500 m past its edge, so walking along a boundary does not flip
  between two cells) or as the quarter-hourly heartbeat.
- **Lowering a level.** Making a Precise friend Approximate sends their
  devices the approximate place at once, replacing the precise one they held.
  Making a Precise friend Off does the same, once, and then sends nothing; this
  is the one way Off differs from a pause, which leaves the last precise place
  where it was. A position cannot be recalled: a device that was offline keeps
  the precise place it had until it next hears from you, and anything a friend
  saw or copied before is theirs.
- The global *Share my location with friends* switch pauses everyone and keeps
  each friend's level for when you share again. Removing or blocking a friend
  stops it for them too.
- **Live, not logged.** A position is sent over the encrypted connection to a
  device that is online. Each device keeps one row per person and replaces it.
  There is no trail, no history, and nothing is stored on anyone else's
  behalf: no relay holds a position.
- **Last known never expires.** A friend who goes offline stays where they were,
  with "Updated 3 h ago" so nobody mistakes it for now. A friend who reconnects
  is sent your current place when you next sync.
- **Who is sent a move.** Every friend (and own device) is sent each move,
  whether or not you have been in touch lately. A device that does not answer
  is tried again with the latest place after 30 seconds, doubling to 15
  minutes, for about an hour; after that it hears when it next syncs. Once a
  place has reached a device nothing is retried, so a still phone does not keep
  dialling friends who are away. (Until 0.2.14 only devices heard from in the
  last 10 minutes were sent anything, so a quiet day out showed you at home.)
- **Your devices.** Every device that can read a position tells your other
  devices where it is, and the map shows each of them (a badge with the
  device's name; the blue dot is always this device). Android reads its
  position (with the "stay connected" service so it continues in the
  background once location is allowed); Windows can too. A spare phone can
  stop doing this with *Show this device to my other devices*.
- **Primary device.** Only one device tells friends where you are, so a laptop
  left at home never overrides the phone in your pocket. It is chosen in
  *Location sharing* (*Your devices*, *Use for friends*) and syncs between your
  devices. A phone that finds none chosen, after syncing with your other
  devices, takes it once; it never takes it again, so a later choice sticks.
  Until one is chosen every device tells friends, as before. Pausing stops
  sending to friends only.
- The wire format and rollout are in [PROTOCOL.md](PROTOCOL.md#locations) and
  [PROTOCOL_CHANGELOG.md](PROTOCOL_CHANGELOG.md).

### What this does not do yet

- **Safety.** Pausing or turning a friend Off tells them nothing (they simply
  stop seeing updates), which is deliberate, because being asked "why did you
  stop sharing?" is how it gets used to control people. Not built yet: levels
  for a whole group at once, and a reminder of who can see you precisely.
- **Accountability link.** Using the shared position to back trust (for
  example, only people you share with can vouch for others) is a design
  question, not code.
- **Play Store.** Reading location from a foreground service needs the
  location permission declaration and a foreground-service declaration in
  Play Console before the next release. Background location with the app
  closed *and* the "stay connected" service off is not supported.
- The old Locations screen has been retired; its navigation ID opens Maps.
  Existing `location` records retain their original meaning and expiry.

## Saved-place design and boundaries

`Places.refresh()` projects only new map records using an insertion cursor.
Widgets read the in-memory projection, never decrypt history in row builders.
Access changes reproject map records only. Initial loading yields between
pages. Updates preserve search text, editor drafts and scroll positions.
Map markers are viewport-clustered outside a frame after camera movement,
with at most 200 clusters; overlapping pins can be selected from a list.

Private places and notes live in `_places`, encrypted to your own devices.
Group pins, lists and memberships live in the group's space. Each entity has
a stable ID and Lamport clock; higher clocks win, with signed object ID as
the deterministic tie-break. List links are separate registers, so organising
one list does not overwrite another. Removing a pin removes it from every
list in that scope; removing a membership or list leaves the pin saved.
The group owner's existing history-sharing and membership-change flows carry
current map records and tombstones forward. Removed members cannot write new
group content after learning the membership change; previously received data
cannot be erased from their devices.

The initial target is remembering places and planning together. Track
recording remains a separate future feature: explicit start/pause/finish,
visible recording state, private by default, sharing only after finishing,
bounded sampling and storage, and physical-device background/battery testing.
Venue/address search requires a provider and a deliberate policy for query
disclosure, caching, attribution and offline availability. No external search
service is silently enabled by saved places. Ratings, reviews, traffic and
in-app route planning are outside this change.

## Where the map comes from

Vector tiles from [OpenFreeMap](https://openfreemap.org) (OpenMapTiles
schema, OpenStreetMap data, no key). Styles are our own recolouring of its
"Liberty" style, bundled with icons so the map draws with no network
(`tool/map_style.dart` regenerates them). A tile request tells OpenFreeMap
roughly where you are looking, which is the one remote call the map makes; it
can be switched off. Attribution is shown on the map.

Tile storage is `<profile>-tiles.db` beside the profile database: public data,
large, safe to delete. Regions are the same file, flagged so the cache limit
never evicts them.

## Roadmap to a full maps app

In order of how much each depends on the one before it.

1. **Place search.** Offline first: names are already in the tiles
   (`place`, `poi`, `transportation_name`), so an index built from saved
   regions gives search with no server. Address search needs a geocoder; a
   self-hostable Photon/Nominatim, user-chosen, is the realistic option.
2. **Routing.** The decision that shapes everything. Options: an embedded
   engine (Valhalla or GraphHopper through FFI, offline, large) or a
   user-chosen server (OSRM/Valhalla/GraphHopper; the public demos are not for
   apps). Turn-by-turn needs the former for offline use. Until then Directions
   opens the system app.
3. **Layers.** Satellite is the hard one (no free global source with a licence
   that allows an app); terrain/hillshade and public transport overlays are
   possible from open data. Traffic has no open source of equivalent quality.
4. **Calendar/place links.** Saved places and group lists now exist. Events
   can already hold a place name; connecting them to saved pins is next.
5. **Group maps** (a group's members, trip plans, meeting points), building
   on the per-friend levels.
6. **Pack sharing between friends** over the file transfer, so one person
   downloads a region for everyone.
7. **Google Maps fidelity.** The first pass matches the layout (floating
   search pill, layers and location buttons, bottom card) and a similar
   palette. Exact parity needs place detail cards, photos, opening hours and
   reviews, which come from data OpenStreetMap does not have.

## Working on it

- `core/lib/src/locations.dart` (positions), `core/lib/src/map_tiles.dart`
  (tile store, regions); tests in `core/test/locations_test.dart`,
  `location_levels_test.dart` (levels, the hour's expiry, the grid) and
  `map_tiles_test.dart`. Levels are stored by `NoteState.locationLevel`.
- `transport/lib/src/network.dart`: the `position` request and `peerSeen`.
- `app/lib/services/location_share.dart` (reading, sending, receiving),
  `map_tiles.dart` (tile source, styles, downloads), `app/lib/ui/map_page.dart`
  and `map_settings.dart`. Tests in `app/test/location_share_test.dart`,
  `map_tiles_test.dart`, `map_page_test.dart`, `saved_places_test.dart`.
- `core/lib/src/places.dart` and `core/test/places_test.dart` cover saved
  places, privacy, permissions, offline conflicts and incremental refresh.
  `photo_scroll_test.dart` includes the saved-map history journey in
  `map_places_journey.dart` (600 places, 2,400 versions).
- Reading a tile is a small synchronous SQLite lookup from the tile provider,
  not from a widget build; it has not been measured on a long cache. Run
  `tool/check.ps1 -Performance` for the list, map and editor acceptance cases.
