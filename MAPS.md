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
- **Search** finds friends by name and goes to typed coordinates. Place search
  is not built yet.
- **Directions** hands the destination to the system: any maps app on Android,
  the OpenStreetMap route planner in a browser on Windows.
- **Offline maps.** Every tile seen is kept (up to 256 MB, least recently used
  first). *Save visible area* downloads a region at the detail you choose and
  keeps it until deleted; a city is a few megabytes. Interrupted downloads
  resume. *Use the internet for maps* off means nothing is fetched.
- **Location sharing** (menu, or the people icon in the search bar): see who
  can see you, pause, and grant permission.

## Location sharing: the rules

- On by default for every friend you have added, and your other devices. One
  switch pauses it. No per-friend settings yet; removing or blocking a friend
  stops it for them.
- **Live, not logged.** A position is sent over the encrypted connection to a
  device that is online. Each device keeps one row per person and replaces it.
  There is no trail, no history, and nothing is stored on anyone else's
  behalf: no relay holds a position.
- **Last known never expires.** A friend who goes offline stays where they were,
  with "Updated 3 h ago" so nobody mistakes it for now. A friend who reconnects
  is sent your current place when you next sync.
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

- **Safety.** Always-on sharing with everyone you add is a sharp tool. Pausing
  tells friends nothing (they simply stop seeing updates), which is deliberate,
  because being asked "why did you stop sharing?" is how it gets used to
  control people. Per-friend levels, "share for an hour", and fuzzed (city
  level) sharing are the obvious next controls.
- **Accountability link.** Using the shared position to back trust (for
  example, only people you share with can vouch for others) is a design
  question, not code.
- **Play Store.** Reading location from a foreground service needs the
  location permission declaration and a foreground-service declaration in
  Play Console before the next release. Background location with the app
  closed *and* the "stay connected" service off is not supported.
- The Locations page (a one-off coordinate share in a chat, an hour of expiry)
  is the older feature and still works separately.

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
4. **Saved places and lists**, as encrypted objects like notes, sharable with a
   group. Events in the calendar can already hold a place name: link them.
5. **Per-friend sharing controls**, then group maps (a group's members, trip
   plans, meeting points).
6. **Pack sharing between friends** over the file transfer, so one person
   downloads a region for everyone.
7. **Google Maps fidelity.** The first pass matches the layout (floating
   search pill, layers and location buttons, bottom card) and a similar
   palette. Exact parity needs place detail cards, photos, opening hours and
   reviews, which come from data OpenStreetMap does not have.

## Working on it

- `core/lib/src/locations.dart` (positions), `core/lib/src/map_tiles.dart`
  (tile store, regions); tests in `core/test/locations_test.dart` and
  `map_tiles_test.dart`.
- `transport/lib/src/network.dart`: the `position` request and `peerSeen`.
- `app/lib/services/location_share.dart` (reading, sending, receiving),
  `map_tiles.dart` (tile source, styles, downloads), `app/lib/ui/map_page.dart`
  and `map_settings.dart`. Tests in `app/test/location_share_test.dart`,
  `map_tiles_test.dart`, `map_page_test.dart`.
- Reading a tile is a small synchronous SQLite lookup from the tile provider,
  not from a widget build; it has not been measured on a long cache. Run
  `tool/check.ps1 -Performance` and add a map case before relying on it.
