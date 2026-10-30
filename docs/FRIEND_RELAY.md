# Friend relays

When two devices cannot reach each other directly, a device belonging to a
mutual friend can carry their traffic, in place of (or before) an iroh relay
server. This is item 4b of the connectivity plan
([CONNECTIVITY.md](CONNECTIVITY.md)). It is live only: nothing is stored, and
both ends must be online at the same time. The spike that settled the
approach is in `notes/spike-friend-relay.md` on the
`spike/friend-relay-transport` branch.

## How it works

- **Transport.** `vendor/iroh_mobile/rust/src/friend_relay.rs` is an iroh
  custom transport (iroh's `unstable-custom-transports`, behind the binding's
  `friend-relay` feature; iroh is pinned exactly because that API may change
  in any release). A custom address `via(F, P)` means "peer P through friend
  F". Packets for it go as QUIC datagrams on a *link*, an iroh connection to F
  with ALPN `ournet/fwd/1`. F re-sends them on its link to P, stamped with the
  sender, and P's transport yields them as coming from `via(F, sender)`. The
  inner connection is ordinary end-to-end QUIC/TLS between the two devices.
  The datagram format is in the module's header comment.
- **Halves.** A QUIC Initial is at least 1200 bytes, and a link whose path MTU
  discovery cannot go past 1200 carries about 1160. Packets that do not fit
  go as two halves, which the receiver joins.
- **Path choice.** `FriendTierSelector` is iroh's default selector with
  friend paths ranked between direct and relay: direct, then friend, then
  relay. iroh holepunches over the friend path just as it does over a relay,
  so a direct path usually opens within milliseconds. Once a direct path has
  been selected for 10 s, the transport stops carrying that peer's friend
  path and iroh abandons it when it idles (15 s): iroh 1.0 cannot close one
  path. Links with no datagrams for 30 s are closed.
- **Links.** A device dials links when Dart sets routes for a dial, and F
  dials its link to the target when the first packet for it arrives. Each end
  accepts links only from its friends' devices. `Endpoint.accept` takes links
  and never returns them to Dart. Of two crossing links, both ends keep the
  one the lower endpoint id dialled.

## Who relays

- **Eligibility** (`FriendRelayPolicy.decide` in
  `transport/lib/src/friend_relay.dart`). The setting `relayForFriends` is on
  by default for computers and off for phones. A device relays when the
  setting is on, the network is not metered, no battery or data saver is on,
  friends can reach it directly (it has a public address; any address in
  local mode), and, for computers, it is on mains power. Phones that opt in
  may relay on battery. `PeerNetwork.refreshFriendRelay` re-decides on start,
  every minute and when the setting changes. Conditions come from
  `app/lib/services/relay_conditions.dart`: `NativePower` (native/rust
  `power.rs`, which uses `GetSystemPowerStatus` and `INetworkCostManager` on
  Windows and sysfs on Linux) or the `ournet/device` channel's `power` method
  on Android.
- **Whom for.** F forwards only between devices it syncs with: its friends'
  and its own (`allowedPeer`). Both ends must be on that list, so F never
  carries traffic for strangers. When F will not forward (relaying off, or an
  end is not a friend), it answers "no route" and the sender stops offering F
  for that peer for 30 s.
- **Limits.** For each sender, F forwards at most 1 MiB/s (a 2 s burst) and
  512 MiB per UTC day. Packets over the limit are dropped, and the inner
  connection's congestion control slows down. Usage is counted in memory, so
  a restart resets the daily count.

## Advertising and dialling

- A relaying device lists the capability `friend_relay` in its sync messages.
  Peers ignore capabilities they do not know.
- `FriendRelayPolicy.routes` picks, for a target device, up to two devices
  that listed `friend_relay`, that this device syncs with, and that the
  target is (or is not known not to be) friends with, according to the public
  friend lists. Own devices always qualify. The most recently synced go
  first.
- Dial policy: friends are offered only when the last connection to the
  device ended through a relay or a friend, or dialling it has failed since.
  A device last reached directly is dialled directly, with relays behind, so
  friends are not asked to carry traffic that would go direct anyway. When
  friends are offered, iroh tries them and the relay together, and the
  selector prefers the friend.
- Path events show friend paths as `PathKind.friend` ("through a friend's
  device"). Connection counts gain `friend`.

## What people see

Settings has a "Relay for friends" switch, with its status (relaying, off, or
why it is paused) and what it exposes: the relaying device sees which of its
friends talk to each other, when, and how much, though never the content, and
friends who relay for you see the same about you. "Friend relay use" shows
what this device relayed today and for how many friends' devices, and what it
sent and received through friends.

## Native controls

The Dart side of iroh is upstream's `iroh_quic` package, so the controls are
plain C functions in the binding, called through `dart:ffi`
(`FriendRelayNative`). A library without them, such as an upstream build or
one without the feature, has no friend relays, and the setting says so.

| Function | Purpose |
|---|---|
| `ournet_friend_relay_abi()` | 1 while these functions are present |
| `ournet_friend_relay_policy(ep, relay, rate, daily)` | relay on/off and per-sender limits |
| `ournet_friend_relay_allow(ep, ids, n)` | friends' devices |
| `ournet_friend_relay_routes(ep, peer, ids, n)` | friends to offer when dialling `peer` |
| `ournet_friend_relay_stats(ep, out, cap)` | counters and per-sender usage as JSON |

`ep` is the endpoint's 32-byte id.

## Tests

- `cargo test --release friend_relay` in `vendor/iroh_mobile/rust` runs three
  in-process endpoints. The tests cover: connecting through a friend only;
  halves without path MTU discovery; refusing when not relaying (and "no
  route"); refusing links from strangers; moving to direct and then dropping
  the friend path and the links; per-sender limits; crossing links; and the
  path-event rendering Dart parses.
- `transport/test/friend_relay_test.dart`: the eligibility rules, and three
  `PeerNetwork`s where A syncs with C through F (and F, not relaying, is
  neither offered nor used).

## Known gaps

- Not yet tested across real NATs or on phones. The tests run on one machine.
- The daily usage count is lost on restart.
- Link setup relies on iroh knowing the friend's address, from address
  lookup (n0 and stored hints in internet mode) or an earlier connection in
  this run.
- macOS and iOS use upstream's library, so they have no friend relays.
