//! Friend relay (OurNet): reach a peer through a mutual friend's device when no direct path
//! works, as an iroh custom transport (docs/FRIEND_RELAY.md).
//!
//! A custom address `via(F, P)` means "peer P, through friend F". Packets for it travel as QUIC
//! datagrams on an iroh connection to F (ALPN `ournet/fwd/1`, a "link"); F checks that both ends
//! are its friends and re-sends them on its link to P, stamped with the sender. P's transport
//! yields them as coming from `via(F, sender)`, so replies take the same route. The inner
//! connection stays end-to-end QUIC/TLS between the two peers: F sees ids, sizes and timing,
//! never content, and the sender it stamps only picks the return route.
//!
//! Link datagrams start with a kind byte and the other end's 32-byte endpoint id:
//!
//! | kind | meaning (direction)                       | rest                          |
//! |------|-------------------------------------------|-------------------------------|
//! | 0    | forward to id (sender to F)               | packet                        |
//! | 1    | delivered from id (F to receiver)         | packet                        |
//! | 2    | forward to id, half of a packet           | frag id u16 BE, index u8, half |
//! | 3    | delivered from id, half of a packet       | frag id u16 BE, index u8, half |
//! | 4    | no route to id (F to sender)              | -                             |
//! | 5    | id is seen at this address (F to id)      | 4 or 6, IP bytes, port u16 BE |
//!
//! Kind 5 lets a device learn its public address without iroh's relays: each friend reports the
//! UDP address it sees a direct link come from. Addresses two friends agree on (same IP and
//! port, so the NAT maps one port for every destination) are given to iroh as external
//! addresses, which it advertises in holepunching; failing those, one friend's address is.
//! Reports of one IP at different ports mean a per-destination NAT, and single reports are then
//! not used. Addresses are withdrawn when the reports stop.
//!
//! A packet is split in two only when it does not fit the link's datagram size: QUIC Initials
//! are at least 1200 bytes, and a link whose path MTU discovery has not (or cannot) go past
//! 1200 carries about 1160. Unknown kinds are ignored, so later kinds are additive.
//!
//! Dart controls this through the `ournet_friend_relay_*` C functions at the end (the iroh_quic
//! Dart package is upstream's, so new controls cannot be FRB functions).

use std::{
    collections::{HashMap, HashSet},
    fmt, io,
    net::{IpAddr, SocketAddr},
    num::NonZeroUsize,
    sync::{
        atomic::{AtomicU16, AtomicU64, Ordering::Relaxed},
        Arc, Mutex, OnceLock, Weak,
    },
    task::{Context, Poll},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use bytes::{BufMut, Bytes, BytesMut};
use futures::StreamExt;
use iroh::{
    endpoint::{
        transports::{
            AddrKind, CustomEndpoint, CustomSender, CustomTransport, PathSelection,
            PathSelectionContext, PathSelectionData, PathSelector, RecvInfo, Transmit,
        },
        Builder, Connection, PathEvent,
    },
    Endpoint, EndpointAddr, EndpointId, TransportAddr,
};
use iroh_base::CustomAddr;
use tokio::sync::mpsc;

use crate::runtime::rt;

/// Not registered with iroh ("ONFR"); only OurNet peers use it.
pub const TRANSPORT_ID: u64 = 0x4f4e_4652;
pub const FWD_ALPN: &[u8] = b"ournet/fwd/1";

const KIND_FORWARD: u8 = 0;
const KIND_DELIVER: u8 = 1;
const KIND_FORWARD_HALF: u8 = 2;
const KIND_DELIVER_HALF: u8 = 3;
const KIND_NO_ROUTE: u8 = 4;
const KIND_SEEN_AT: u8 = 5;
/// Friend-reported addresses given to iroh at most.
const MAX_EXTERNAL: usize = 4;
const HEADER: usize = 33;
const HALF_HEADER: usize = HEADER + 3;

/// Friends offered per dial at most: each is a path iroh probes and keeps alive.
pub const MAX_ROUTES: usize = 2;
/// First halves awaiting their second at most.
const MAX_HALVES: usize = 256;

/// Timings, shortened by tests.
#[derive(Debug, Clone, Copy)]
pub struct Timings {
    /// A link with no datagrams either way for this long is closed.
    pub link_idle: Duration,
    /// Once a connection's direct path has been selected this long, its friend path is dropped.
    pub direct_stable: Duration,
    /// After "no route" from a friend, that friend is not used for that peer for this long.
    pub no_route: Duration,
    /// Links are dialled at most this often per friend.
    pub redial: Duration,
    /// An unpaired half is dropped after this long.
    pub half_ttl: Duration,
    /// How often idle links, stale halves and expired marks are swept.
    pub sweep: Duration,
    /// How often a friend repeats the address it sees a link come from.
    pub report_every: Duration,
    /// A friend's report counts for this long after it last arrived.
    pub report_ttl: Duration,
    /// Accept reported addresses that are not public: tests on loopback only.
    pub private_reports: bool,
}

impl Default for Timings {
    fn default() -> Self {
        Self {
            link_idle: Duration::from_secs(30),
            direct_stable: Duration::from_secs(10),
            no_route: Duration::from_secs(30),
            redial: Duration::from_secs(5),
            half_ttl: Duration::from_secs(2),
            sweep: Duration::from_secs(5),
            report_every: Duration::from_secs(30),
            report_ttl: Duration::from_secs(120),
            private_reports: false,
        }
    }
}

pub fn via(relay: EndpointId, peer: EndpointId) -> CustomAddr {
    let mut data = [0u8; 64];
    data[..32].copy_from_slice(relay.as_bytes());
    data[32..].copy_from_slice(peer.as_bytes());
    CustomAddr::from_parts(TRANSPORT_ID, &data)
}

pub fn parse_via(addr: &CustomAddr) -> Option<(EndpointId, EndpointId)> {
    if addr.id() != TRANSPORT_ID || addr.data().len() != 64 {
        return None;
    }
    let relay = EndpointId::from_bytes(addr.data()[..32].try_into().ok()?).ok()?;
    let peer = EndpointId::from_bytes(addr.data()[32..].try_into().ok()?).ok()?;
    Some((relay, peer))
}

fn id_at(d: &[u8]) -> Option<EndpointId> {
    EndpointId::from_bytes(d.get(1..HEADER)?.try_into().ok()?).ok()
}

/// What Dart decided: whether this device relays, for whom, and how much.
#[derive(Debug, Clone)]
struct Policy {
    /// Forward between friends (this device is eligible and the setting is on).
    relay: bool,
    /// This person's friends' devices and their own: who may link here, and whom this device
    /// forwards between when it relays.
    allow: HashSet<EndpointId>,
    /// Bytes per second forwarded for one sender; 0 = unlimited.
    rate: u64,
    /// Bytes per UTC day forwarded for one sender; 0 = unlimited.
    daily: u64,
}

impl Default for Policy {
    fn default() -> Self {
        Self {
            relay: false,
            allow: HashSet::new(),
            rate: 1 << 20,
            daily: 512 << 20,
        }
    }
}

/// Forwarding done for one sender.
#[derive(Debug)]
struct Meter {
    tokens: f64,
    refilled: Instant,
    day: u64,
    today: u64,
    total: u64,
}

fn utc_day() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() / 86_400)
        .unwrap_or(0)
}

#[derive(Default, Debug)]
pub struct Stats {
    /// Packets and bytes this device sent through friends.
    pub sent: AtomicU64,
    pub sent_bytes: AtomicU64,
    /// Packets and bytes delivered to this device through friends.
    pub received: AtomicU64,
    pub received_bytes: AtomicU64,
    /// Packets and bytes this device forwarded for friends.
    pub forwarded: AtomicU64,
    pub forwarded_bytes: AtomicU64,
    /// Packets split in two to fit a link.
    pub halved: AtomicU64,
    /// Forward requests refused: relaying off, or an end not a friend.
    pub denied: AtomicU64,
    /// Forward requests dropped by a sender's rate or daily limit.
    pub limited: AtomicU64,
    /// Packets dropped while a link was being dialled.
    pub no_link: AtomicU64,
    /// Packets too large even in halves, or refused by a link.
    pub dropped: AtomicU64,
    pub links_opened: AtomicU64,
    /// Address reports sent to and taken from friends.
    pub reports_sent: AtomicU64,
    pub reports_taken: AtomicU64,
}

type Packet = (CustomAddr, Bytes);
/// First halves by (link, other end, half id): when, which half, its bytes.
type Halves = HashMap<(EndpointId, EndpointId, u16), (Instant, u8, Bytes)>;

struct Link {
    conn: Connection,
    /// Whether the endpoint with the lower id dialled it: both ends keep that one of two
    /// crossing links.
    preferred: bool,
    active: Arc<AtomicU64>,
    /// The address last reported to this friend, and when.
    reported: Option<(SocketAddr, Instant)>,
}

/// Per-endpoint friend relay state, shared by the custom transport, the links and Dart.
pub struct FriendRelay {
    /// Set once bound; nothing reaches the relay before then.
    me: OnceLock<EndpointId>,
    timings: Timings,
    epoch: Instant,
    endpoint: OnceLock<Endpoint>,
    links: Mutex<HashMap<EndpointId, Link>>,
    dialled: Mutex<HashMap<EndpointId, Instant>>,
    policy: Mutex<Policy>,
    /// Friends Dart chose for reaching a peer, used when dialling it.
    routes: Mutex<HashMap<EndpointId, Vec<EndpointId>>>,
    /// (friend, peer) pairs a friend said it cannot reach, and when.
    no_route: Mutex<HashMap<(EndpointId, EndpointId), Instant>>,
    /// Peers with a stable direct path: connections watching it, by peer.
    direct: Mutex<HashMap<EndpointId, usize>>,
    meters: Mutex<HashMap<EndpointId, Meter>>,
    halves: Mutex<Halves>,
    next_half: AtomicU16,
    /// The address each friend last said it sees this device at, and when.
    seen_at: Mutex<HashMap<EndpointId, (SocketAddr, Instant)>>,
    /// Addresses given to iroh as external.
    external: Mutex<HashSet<SocketAddr>>,
    inbox_tx: mpsc::Sender<Packet>,
    inbox_rx: Mutex<Option<mpsc::Receiver<Packet>>>,
    local_addrs: n0_watcher::Watchable<Vec<CustomAddr>>,
    pub stats: Stats,
}

impl fmt::Debug for FriendRelay {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("FriendRelay")
            .field("me", &self.me.get())
            .finish_non_exhaustive()
    }
}

fn registry() -> &'static Mutex<HashMap<EndpointId, Weak<FriendRelay>>> {
    static R: OnceLock<Mutex<HashMap<EndpointId, Weak<FriendRelay>>>> = OnceLock::new();
    R.get_or_init(Default::default)
}

/// Adds the friend transport, the friend-aware path selector and the link ALPN to a builder.
/// Call [`FriendRelay::bound`] with the endpoint once bound.
pub fn install(
    builder: Builder,
    alpns: &mut Vec<Vec<u8>>,
    timings: Timings,
) -> (Builder, Arc<FriendRelay>) {
    let relay = FriendRelay::new(timings);
    if !alpns.iter().any(|a| a == FWD_ALPN) {
        alpns.push(FWD_ALPN.to_vec());
    }
    let builder = builder
        .add_custom_transport(Arc::new(FriendTransport(relay.clone())))
        .path_selector(Arc::new(FriendTierSelector));
    (builder, relay)
}

/// The relay of a bound endpoint, by its id.
pub fn find(id: &EndpointId) -> Option<Arc<FriendRelay>> {
    registry().lock().unwrap().get(id).and_then(Weak::upgrade)
}

impl FriendRelay {
    fn new(timings: Timings) -> Arc<Self> {
        let (tx, rx) = mpsc::channel(1024);
        Arc::new(Self {
            me: OnceLock::new(),
            timings,
            epoch: Instant::now(),
            endpoint: OnceLock::new(),
            links: Default::default(),
            dialled: Default::default(),
            policy: Default::default(),
            routes: Default::default(),
            no_route: Default::default(),
            direct: Default::default(),
            meters: Default::default(),
            halves: Default::default(),
            next_half: AtomicU16::new(0),
            seen_at: Default::default(),
            external: Default::default(),
            inbox_tx: tx,
            inbox_rx: Mutex::new(Some(rx)),
            local_addrs: n0_watcher::Watchable::new(Vec::new()),
            stats: Stats::default(),
        })
    }

    /// Registers the bound endpoint, for dialling links and for Dart's controls.
    pub fn bound(self: &Arc<Self>, endpoint: Endpoint) {
        let me = endpoint.id();
        let _ = self.me.set(me);
        let _ = self.endpoint.set(endpoint);
        registry().lock().unwrap().insert(me, Arc::downgrade(self));
        let weak = Arc::downgrade(self);
        let every = self.timings.sweep;
        rt().spawn(async move {
            loop {
                tokio::time::sleep(every).await;
                let Some(relay) = weak.upgrade() else { break };
                if relay.endpoint.get().is_none_or(|e| e.is_closed()) {
                    break;
                }
                relay.sweep();
            }
        });
    }

    /// Forgets the endpoint as it closes.
    pub fn closed(&self) {
        if let Some(me) = self.me.get() {
            let mut registry = registry().lock().unwrap();
            if registry
                .get(me)
                .is_some_and(|w| std::ptr::eq(w.as_ptr(), self))
            {
                registry.remove(me);
            }
        }
        for (_, link) in self.links.lock().unwrap().drain() {
            link.conn.close(0u32.into(), b"closing");
        }
    }

    fn now_ms(&self) -> u64 {
        self.epoch.elapsed().as_millis() as u64
    }

    pub fn set_policy(&self, relay: bool, rate: u64, daily: u64) {
        let mut policy = self.policy.lock().unwrap();
        policy.relay = relay;
        policy.rate = rate;
        policy.daily = daily;
    }

    /// Replaces the set of friends' devices; links to anyone no longer in it are closed.
    pub fn set_allow(&self, allow: HashSet<EndpointId>) {
        self.policy.lock().unwrap().allow = allow.clone();
        self.links.lock().unwrap().retain(|id, link| {
            let keep = allow.contains(id);
            if !keep {
                link.conn.close(0u32.into(), b"not a friend");
            }
            keep
        });
    }

    /// Sets the friends to offer when dialling `peer` (at most [`MAX_ROUTES`]), and starts
    /// linking to them so the link is up by the time iroh sends through it.
    pub fn set_routes(self: &Arc<Self>, peer: EndpointId, relays: Vec<EndpointId>) {
        let relays: Vec<_> = relays
            .into_iter()
            .filter(|r| Some(r) != self.me.get() && *r != peer)
            .take(MAX_ROUTES)
            .collect();
        for relay in &relays {
            self.ensure_link(*relay);
        }
        let mut routes = self.routes.lock().unwrap();
        if relays.is_empty() {
            routes.remove(&peer);
        } else {
            routes.insert(peer, relays);
        }
    }

    /// Adds `via(friend, peer)` for each friend chosen for this peer to a dial address.
    pub fn add_routes(&self, addr: &mut EndpointAddr) {
        let routes = self.routes.lock().unwrap();
        let Some(relays) = routes.get(&addr.id) else {
            return;
        };
        let no_route = self.no_route.lock().unwrap();
        for relay in relays {
            if no_route
                .get(&(*relay, addr.id))
                .is_some_and(|at| at.elapsed() < self.timings.no_route)
            {
                continue;
            }
            addr.addrs
                .insert(TransportAddr::Custom(via(*relay, addr.id)));
        }
    }

    fn allowed(&self, id: &EndpointId) -> bool {
        self.policy.lock().unwrap().allow.contains(id)
    }

    fn link(&self, id: &EndpointId) -> Option<(Connection, Arc<AtomicU64>)> {
        let links = self.links.lock().unwrap();
        let link = links.get(id)?;
        if link.conn.close_reason().is_some() {
            return None;
        }
        Some((link.conn.clone(), link.active.clone()))
    }

    /// Dials a link to `id` unless one is open or was dialled recently.
    fn ensure_link(self: &Arc<Self>, id: EndpointId) {
        if Some(&id) == self.me.get() || self.link(&id).is_some() {
            return;
        }
        {
            let mut dialled = self.dialled.lock().unwrap();
            if dialled
                .get(&id)
                .is_some_and(|at| at.elapsed() < self.timings.redial)
            {
                return;
            }
            dialled.insert(id, Instant::now());
        }
        let Some(endpoint) = self.endpoint.get().cloned() else {
            return;
        };
        let relay = self.clone();
        rt().spawn(async move {
            let dial = endpoint.connect(id, FWD_ALPN);
            if let Ok(Ok(conn)) = tokio::time::timeout(Duration::from_secs(10), dial).await {
                relay.attach(conn, true);
            }
        });
    }

    /// Takes an accepted link, if it is from a friend's device.
    pub fn accept_link(self: &Arc<Self>, conn: Connection) {
        if self.allowed(&conn.remote_id()) {
            self.attach(conn, false);
        } else {
            conn.close(0u32.into(), b"not a friend");
        }
    }

    /// Keeps a link (one per friend: of two crossing links, the one the lower id dialled) and
    /// reads its datagrams.
    fn attach(self: &Arc<Self>, conn: Connection, dialled_here: bool) {
        let remote = conn.remote_id();
        let Some(me) = self.me.get() else { return };
        let preferred = dialled_here == (*me < remote);
        let active = Arc::new(AtomicU64::new(self.now_ms()));
        {
            let mut links = self.links.lock().unwrap();
            if let Some(old) = links.get(&remote) {
                if old.conn.close_reason().is_none() && old.preferred && !preferred {
                    conn.close(0u32.into(), b"duplicate");
                    return;
                }
                old.conn.close(0u32.into(), b"duplicate");
            }
            links.insert(
                remote,
                Link {
                    conn: conn.clone(),
                    preferred,
                    active: active.clone(),
                    reported: None,
                },
            );
        }
        self.stats.links_opened.fetch_add(1, Relaxed);
        self.report_links();
        let relay = Arc::downgrade(self);
        rt().spawn(async move {
            while let Ok(d) = conn.read_datagram().await {
                let Some(relay) = relay.upgrade() else { break };
                // Address reports keep coming while a link is open: they are not use.
                if d.first() != Some(&KIND_SEEN_AT) {
                    active.store(relay.now_ms(), Relaxed);
                }
                relay.on_datagram(remote, d);
            }
            if let Some(relay) = relay.upgrade() {
                let mut links = relay.links.lock().unwrap();
                if links
                    .get(&remote)
                    .is_some_and(|l| l.conn.stable_id() == conn.stable_id())
                {
                    links.remove(&remote);
                }
            }
        });
    }

    fn sweep(&self) {
        let now = self.now_ms();
        let idle = self.timings.link_idle.as_millis() as u64;
        self.links.lock().unwrap().retain(|_, link| {
            let live = link.conn.close_reason().is_none()
                && now.saturating_sub(link.active.load(Relaxed)) < idle;
            if !live {
                link.conn.close(0u32.into(), b"idle");
            }
            live
        });
        let ttl = self.timings.half_ttl;
        self.halves
            .lock()
            .unwrap()
            .retain(|_, (at, _, _)| at.elapsed() < ttl);
        let no_route = self.timings.no_route;
        self.no_route
            .lock()
            .unwrap()
            .retain(|_, at| at.elapsed() < no_route);
        let redial = self.timings.redial;
        self.dialled
            .lock()
            .unwrap()
            .retain(|_, at| at.elapsed() < redial);
        self.report_links();
        self.update_external();
    }

    /// Tells each friend with a direct link the address its link comes from, when that changed
    /// or [`Timings::report_every`] has passed.
    fn report_links(&self) {
        let every = self.timings.report_every;
        for (id, link) in self.links.lock().unwrap().iter_mut() {
            let seen = link
                .conn
                .paths()
                .iter()
                .find_map(|p| match p.remote_addr() {
                    TransportAddr::Ip(addr) if p.is_selected() => Some(*addr),
                    _ => None,
                });
            let Some(seen) = seen else { continue };
            if link
                .reported
                .is_some_and(|(addr, at)| addr == seen && at.elapsed() < every)
            {
                continue;
            }
            let mut b = BytesMut::with_capacity(HEADER + 19);
            b.put_u8(KIND_SEEN_AT);
            b.put_slice(id.as_bytes());
            match seen.ip() {
                IpAddr::V4(ip) => {
                    b.put_u8(4);
                    b.put_slice(&ip.octets());
                }
                IpAddr::V6(ip) => {
                    b.put_u8(6);
                    b.put_slice(&ip.octets());
                }
            }
            b.put_u16(seen.port());
            if link.conn.send_datagram(b.freeze()).is_ok() {
                link.reported = Some((seen, Instant::now()));
                self.stats.reports_sent.fetch_add(1, Relaxed);
            }
        }
    }

    /// Takes a friend's report of the address it sees this device at.
    fn seen_at(&self, from: EndpointId, d: &[u8]) {
        let rest = &d[HEADER..];
        let ip = match rest {
            [4, a, b, c, e, ..] if rest.len() == 7 => IpAddr::from([*a, *b, *c, *e]),
            [6, ..] if rest.len() == 19 => {
                IpAddr::from(<[u8; 16]>::try_from(&rest[1..17]).unwrap())
            }
            _ => return,
        };
        let port = u16::from_be_bytes([rest[rest.len() - 2], rest[rest.len() - 1]]);
        let addr = SocketAddr::new(ip, port);
        if port == 0 || !(self.timings.private_reports || public(&ip)) {
            return;
        }
        self.seen_at
            .lock()
            .unwrap()
            .insert(from, (addr, Instant::now()));
        self.stats.reports_taken.fetch_add(1, Relaxed);
        self.update_external();
    }

    /// Gives iroh the addresses [`choose_external`] picks from fresh reports, and withdraws
    /// the rest.
    fn update_external(&self) {
        let ttl = self.timings.report_ttl;
        let reports: Vec<(SocketAddr, Instant)> = {
            let mut seen_at = self.seen_at.lock().unwrap();
            seen_at.retain(|_, (_, at)| at.elapsed() < ttl);
            seen_at.values().copied().collect()
        };
        let agreed = choose_external(&reports);
        let (add, remove) = {
            let mut external = self.external.lock().unwrap();
            let add: Vec<_> = agreed.difference(&external).copied().collect();
            let remove: Vec<_> = external.difference(&agreed).copied().collect();
            *external = agreed;
            (add, remove)
        };
        if add.is_empty() && remove.is_empty() {
            return;
        }
        let Some(endpoint) = self.endpoint.get().cloned() else {
            return;
        };
        rt().spawn(async move {
            for addr in remove {
                endpoint.remove_external_addr(&addr).await;
            }
            for addr in add {
                endpoint.add_external_addr(addr).await;
            }
        });
    }

    /// Sends `data` to `other` on a link as one datagram, or as two halves when it does not
    /// fit. Returns whether it went.
    fn send_on(
        &self,
        conn: &Connection,
        whole: u8,
        half: u8,
        other: &EndpointId,
        data: &[u8],
    ) -> bool {
        let max = conn.max_datagram_size().unwrap_or(0);
        if HEADER + data.len() <= max {
            let mut b = BytesMut::with_capacity(HEADER + data.len());
            b.put_u8(whole);
            b.put_slice(other.as_bytes());
            b.put_slice(data);
            return conn.send_datagram(b.freeze()).is_ok();
        }
        let split = data.len().div_ceil(2);
        if HALF_HEADER + split > max {
            self.stats.dropped.fetch_add(1, Relaxed);
            return false;
        }
        let id = self.next_half.fetch_add(1, Relaxed);
        self.stats.halved.fetch_add(1, Relaxed);
        let mut sent = true;
        for (index, part) in data.chunks(split).enumerate() {
            sent &= self.send_half(conn, half, other, id, index as u8, part);
        }
        sent
    }

    fn send_half(
        &self,
        conn: &Connection,
        kind: u8,
        other: &EndpointId,
        id: u16,
        index: u8,
        part: &[u8],
    ) -> bool {
        let mut b = BytesMut::with_capacity(HALF_HEADER + part.len());
        b.put_u8(kind);
        b.put_slice(other.as_bytes());
        b.put_u16(id);
        b.put_u8(index);
        b.put_slice(part);
        conn.send_datagram(b.freeze()).is_ok()
    }

    /// Sends a packet for `via(relay, peer)`; drops it, as UDP would, when it cannot go.
    fn send(self: &Arc<Self>, relay: EndpointId, peer: EndpointId, data: &[u8]) {
        if self.direct.lock().unwrap().contains_key(&peer) {
            // A stable direct path: let the friend path idle out instead of keeping it alive.
            return;
        }
        if self
            .no_route
            .lock()
            .unwrap()
            .get(&(relay, peer))
            .is_some_and(|at| at.elapsed() < self.timings.no_route)
        {
            return;
        }
        let Some((conn, active)) = self.link(&relay) else {
            self.stats.no_link.fetch_add(1, Relaxed);
            self.ensure_link(relay);
            return;
        };
        if self.send_on(&conn, KIND_FORWARD, KIND_FORWARD_HALF, &peer, data) {
            active.store(self.now_ms(), Relaxed);
            self.stats.sent.fetch_add(1, Relaxed);
            self.stats.sent_bytes.fetch_add(data.len() as u64, Relaxed);
        } else {
            self.stats.dropped.fetch_add(1, Relaxed);
        }
    }

    /// Whether `from` may have `len` more bytes forwarded now; counts them if so.
    fn meter(&self, from: EndpointId, len: usize, rate: u64, daily: u64) -> bool {
        let mut meters = self.meters.lock().unwrap();
        let now = Instant::now();
        let day = utc_day();
        let burst = (rate.saturating_mul(2)).max(64 << 10) as f64;
        let m = meters.entry(from).or_insert(Meter {
            tokens: burst,
            refilled: now,
            day,
            today: 0,
            total: 0,
        });
        if m.day != day {
            m.day = day;
            m.today = 0;
        }
        if daily != 0 && m.today + len as u64 > daily {
            return false;
        }
        if rate != 0 {
            let dt = now.duration_since(m.refilled).as_secs_f64();
            m.tokens = (m.tokens + dt * rate as f64).min(burst);
            m.refilled = now;
            if m.tokens < len as f64 {
                return false;
            }
            m.tokens -= len as f64;
        }
        m.today += len as u64;
        m.total += len as u64;
        true
    }

    /// Restores what each sender had forwarded on UTC `day`, saved by Dart before a restart,
    /// so the daily limit holds across restarts. Ignored for any other day.
    pub fn seed_usage(&self, day: u64, usage: impl IntoIterator<Item = (EndpointId, u64)>) {
        if day != utc_day() {
            return;
        }
        let now = Instant::now();
        let mut meters = self.meters.lock().unwrap();
        for (id, bytes) in usage {
            let m = meters.entry(id).or_insert(Meter {
                tokens: 0.0,
                refilled: now,
                day,
                today: 0,
                total: 0,
            });
            if m.day == day {
                m.today = m.today.max(bytes);
                m.total = m.total.max(m.today);
            }
        }
    }

    fn deliver(&self, src: CustomAddr, data: Bytes) {
        let len = data.len() as u64;
        if self.inbox_tx.try_send((src, data)).is_ok() {
            self.stats.received.fetch_add(1, Relaxed);
            self.stats.received_bytes.fetch_add(len, Relaxed);
        } else {
            self.stats.dropped.fetch_add(1, Relaxed);
        }
    }

    fn on_datagram(self: &Arc<Self>, from: EndpointId, d: Bytes) {
        let Some(other) = id_at(&d) else { return };
        match d[0] {
            KIND_FORWARD | KIND_FORWARD_HALF => self.forward(from, other, d),
            KIND_DELIVER if d.len() > HEADER => {
                self.deliver(via(from, other), d.slice(HEADER..));
            }
            KIND_DELIVER_HALF if d.len() > HALF_HEADER => {
                let id = u16::from_be_bytes([d[HEADER], d[HEADER + 1]]);
                let index = d[HEADER + 2];
                if index > 1 {
                    return;
                }
                let part = d.slice(HALF_HEADER..);
                let key = (from, other, id);
                let mut halves = self.halves.lock().unwrap();
                match halves.remove(&key) {
                    Some((_, first_index, first)) if first_index != index => {
                        drop(halves);
                        let (a, b) = if first_index == 0 {
                            (first, part)
                        } else {
                            (part, first)
                        };
                        let mut whole = BytesMut::with_capacity(a.len() + b.len());
                        whole.put_slice(&a);
                        whole.put_slice(&b);
                        self.deliver(via(from, other), whole.freeze());
                    }
                    _ => {
                        if halves.len() < MAX_HALVES {
                            halves.insert(key, (Instant::now(), index, part));
                        }
                    }
                }
            }
            KIND_SEEN_AT if Some(&other) == self.me.get() => self.seen_at(from, &d),
            KIND_NO_ROUTE => {
                self.no_route
                    .lock()
                    .unwrap()
                    .insert((from, other), Instant::now());
            }
            _ => {}
        }
    }

    /// Forwards a packet (or half) from friend `from` to friend `to`.
    fn forward(self: &Arc<Self>, from: EndpointId, to: EndpointId, d: Bytes) {
        let (relay, rate, daily, both_friends) = {
            let p = self.policy.lock().unwrap();
            (
                p.relay,
                p.rate,
                p.daily,
                p.allow.contains(&from) && p.allow.contains(&to),
            )
        };
        if !relay || !both_friends || to == from || Some(&to) == self.me.get() {
            self.stats.denied.fetch_add(1, Relaxed);
            self.refuse(from, to);
            return;
        }
        let half = d[0] == KIND_FORWARD_HALF;
        let start = if half { HALF_HEADER } else { HEADER };
        if d.len() <= start {
            return;
        }
        let len = d.len() - start;
        if !self.meter(from, len, rate, daily) {
            self.stats.limited.fetch_add(1, Relaxed);
            return;
        }
        let Some((out, active)) = self.link(&to) else {
            self.stats.no_link.fetch_add(1, Relaxed);
            self.ensure_link(to);
            return;
        };
        let sent = if half {
            let id = u16::from_be_bytes([d[HEADER], d[HEADER + 1]]);
            let index = d[HEADER + 2];
            self.send_half(&out, KIND_DELIVER_HALF, &from, id, index, &d[start..])
        } else {
            self.send_on(&out, KIND_DELIVER, KIND_DELIVER_HALF, &from, &d[start..])
        };
        if sent {
            active.store(self.now_ms(), Relaxed);
            self.stats.forwarded.fetch_add(1, Relaxed);
            self.stats.forwarded_bytes.fetch_add(len as u64, Relaxed);
        } else {
            self.stats.dropped.fetch_add(1, Relaxed);
        }
    }

    /// Tells `from` this device will not forward to `to`, so it stops trying.
    fn refuse(&self, from: EndpointId, to: EndpointId) {
        if let Some((conn, _)) = self.link(&from) {
            let mut b = BytesMut::with_capacity(HEADER);
            b.put_u8(KIND_NO_ROUTE);
            b.put_slice(to.as_bytes());
            let _ = conn.send_datagram(b.freeze());
        }
    }

    /// Drops a connection's friend paths once its direct path has stayed selected for
    /// [`Timings::direct_stable`], and offers them again if it loses that path. iroh 1.0 cannot
    /// close one path, so the transport stops carrying it and iroh abandons it when it idles.
    pub fn watch(self: &Arc<Self>, conn: &Connection) {
        let relay = Arc::downgrade(self);
        let stable = self.timings.direct_stable;
        let conn = conn.clone();
        rt().spawn(async move {
            let remote = conn.remote_id();
            let mut events = conn.path_events();
            let closed = conn.closed();
            tokio::pin!(closed);
            let direct_now = conn
                .paths()
                .iter()
                .any(|p| p.is_selected() && matches!(p.remote_addr(), TransportAddr::Ip(_)));
            let mut direct_since = direct_now.then(Instant::now);
            let mut marked = false;
            loop {
                let wait = match direct_since {
                    Some(since) if !marked => stable.saturating_sub(since.elapsed()),
                    _ => Duration::from_secs(3600),
                };
                tokio::select! {
                    _ = &mut closed => break,
                    event = events.next() => match event {
                        Some(PathEvent::Selected { remote_addr, .. }) => {
                            if matches!(remote_addr, TransportAddr::Ip(_)) {
                                direct_since.get_or_insert_with(Instant::now);
                            } else {
                                direct_since = None;
                                if marked {
                                    marked = false;
                                    if let Some(r) = relay.upgrade() { r.unmark_direct(remote) }
                                }
                            }
                        }
                        Some(_) => {}
                        None => break,
                    },
                    _ = tokio::time::sleep(wait), if direct_since.is_some() && !marked => {
                        let Some(r) = relay.upgrade() else { break };
                        r.mark_direct(remote);
                        marked = true;
                    }
                }
            }
            if marked {
                if let Some(r) = relay.upgrade() {
                    r.unmark_direct(remote);
                }
            }
        });
    }

    fn mark_direct(&self, peer: EndpointId) {
        *self.direct.lock().unwrap().entry(peer).or_insert(0) += 1;
    }

    fn unmark_direct(&self, peer: EndpointId) {
        let mut direct = self.direct.lock().unwrap();
        if let Some(n) = direct.get_mut(&peer) {
            *n -= 1;
            if *n == 0 {
                direct.remove(&peer);
            }
        }
    }

    /// Counters and per-sender forwarding as JSON, for Dart.
    pub fn stats_json(&self) -> String {
        let g = |a: &AtomicU64| a.load(Relaxed);
        let s = &self.stats;
        let day = utc_day();
        let senders: Vec<String> = self
            .meters
            .lock()
            .unwrap()
            .iter()
            .map(|(id, m)| {
                let today = if m.day == day { m.today } else { 0 };
                format!(
                    "\"{}\":{{\"today\":{today},\"total\":{}}}",
                    hex(id.as_bytes()),
                    m.total
                )
            })
            .collect();
        let links: Vec<String> = self
            .links
            .lock()
            .unwrap()
            .keys()
            .map(|id| format!("\"{}\"", hex(id.as_bytes())))
            .collect();
        let mut external: Vec<String> = self
            .external
            .lock()
            .unwrap()
            .iter()
            .map(|a| format!("\"{a}\""))
            .collect();
        external.sort();
        let policy = self.policy.lock().unwrap().clone();
        format!(
            "{{\"relay\":{},\"rate\":{},\"daily\":{},\"day\":{day},\"links\":[{}],\"senders\":{{{}}},\
             \"sent\":{},\"sentBytes\":{},\"received\":{},\"receivedBytes\":{},\
             \"forwarded\":{},\"forwardedBytes\":{},\"halved\":{},\"denied\":{},\
             \"limited\":{},\"noLink\":{},\"dropped\":{},\"linksOpened\":{},\
             \"reportsSent\":{},\"reportsTaken\":{},\"external\":[{}]}}",
            policy.relay,
            policy.rate,
            policy.daily,
            links.join(","),
            senders.join(","),
            g(&s.sent),
            g(&s.sent_bytes),
            g(&s.received),
            g(&s.received_bytes),
            g(&s.forwarded),
            g(&s.forwarded_bytes),
            g(&s.halved),
            g(&s.denied),
            g(&s.limited),
            g(&s.no_link),
            g(&s.dropped),
            g(&s.links_opened),
            g(&s.reports_sent),
            g(&s.reports_taken),
            external.join(","),
        )
    }
}

/// The addresses to give iroh from friends' fresh reports (address, when): those two or more
/// friends agree on, up to [`MAX_EXTERNAL`]; or, when none agree, the most recent single
/// report. Reports of one IP at different ports show the NAT maps a port per destination, so
/// then no single report is used.
pub fn choose_external(reports: &[(SocketAddr, Instant)]) -> HashSet<SocketAddr> {
    let mut counts: HashMap<SocketAddr, (usize, Instant)> = HashMap::new();
    for (addr, at) in reports {
        let entry = counts.entry(*addr).or_insert((0, *at));
        entry.0 += 1;
        entry.1 = entry.1.max(*at);
    }
    let mut agreed: Vec<SocketAddr> = counts
        .iter()
        .filter(|(_, (n, _))| *n >= 2)
        .map(|(a, _)| *a)
        .collect();
    if !agreed.is_empty() {
        agreed.sort();
        agreed.truncate(MAX_EXTERNAL);
        return agreed.into_iter().collect();
    }
    let per_destination = counts.keys().any(|a| {
        counts
            .keys()
            .any(|b| a.ip() == b.ip() && a.port() != b.port())
    });
    if per_destination {
        return HashSet::new();
    }
    counts
        .into_iter()
        .max_by_key(|(_, (_, at))| *at)
        .map(|(a, _)| a)
        .into_iter()
        .collect()
}

/// Whether an address can be reached from the internet: not private, loopback, link-local,
/// shared (100.64/10), unique-local, multicast or unspecified.
fn public(ip: &IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            let [a, b, ..] = v4.octets();
            !(v4.is_private()
                || v4.is_loopback()
                || v4.is_link_local()
                || v4.is_unspecified()
                || v4.is_multicast()
                || v4.is_broadcast()
                || a == 0
                || a == 100 && (64..128).contains(&b))
        }
        IpAddr::V6(v6) => {
            if let Some(v4) = v6.to_ipv4_mapped() {
                return public(&IpAddr::V4(v4));
            }
            let first = v6.segments()[0];
            !(v6.is_loopback()
                || v6.is_unspecified()
                || v6.is_multicast()
                || first & 0xfe00 == 0xfc00
                || first & 0xffc0 == 0xfe80)
        }
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[derive(Debug)]
struct FriendTransport(Arc<FriendRelay>);

impl CustomTransport for FriendTransport {
    fn bind(&self) -> io::Result<Box<dyn CustomEndpoint>> {
        let rx = self
            .0
            .inbox_rx
            .lock()
            .unwrap()
            .take()
            .ok_or_else(|| io::Error::other("friend transport already bound"))?;
        Ok(Box::new(FriendEndpoint {
            relay: self.0.clone(),
            rx,
            pending: None,
        }))
    }
}

#[derive(Debug)]
struct FriendEndpoint {
    relay: Arc<FriendRelay>,
    rx: mpsc::Receiver<Packet>,
    /// A packet that did not fit the last batch's remaining buffers.
    pending: Option<Packet>,
}

impl CustomEndpoint for FriendEndpoint {
    fn watch_local_addrs(&self) -> n0_watcher::Direct<Vec<CustomAddr>> {
        self.relay.local_addrs.watch()
    }

    fn create_sender(&self) -> Arc<dyn CustomSender> {
        Arc::new(FriendSender(self.relay.clone()))
    }

    fn poll_recv(
        &mut self,
        cx: &mut Context,
        bufs: &mut [io::IoSliceMut<'_>],
        metas: &mut [noq_udp::RecvMeta],
        recv_infos: &mut [RecvInfo],
    ) -> Poll<io::Result<usize>> {
        let n = bufs.len().min(metas.len()).min(recv_infos.len());
        let mut count = 0;
        while count < n {
            let packet = match self.pending.take() {
                Some(p) => p,
                None => match self.rx.poll_recv(cx) {
                    Poll::Ready(Some(p)) => p,
                    Poll::Ready(None) if count == 0 => {
                        return Poll::Ready(Err(io::Error::other("friend relay closed")))
                    }
                    Poll::Ready(None) | Poll::Pending => break,
                },
            };
            let (src, data) = packet;
            if bufs[count].len() < data.len() {
                if count == 0 {
                    // Larger than any buffer iroh gives: unusable.
                    continue;
                }
                self.pending = Some((src, data));
                break;
            }
            bufs[count][..data.len()].copy_from_slice(&data);
            metas[count].len = data.len();
            metas[count].stride = data.len();
            recv_infos[count] = RecvInfo::new(src, None);
            count += 1;
        }
        if count == 0 {
            Poll::Pending
        } else {
            Poll::Ready(Ok(count))
        }
    }

    fn max_transmit_segments(&self) -> NonZeroUsize {
        NonZeroUsize::new(16).unwrap()
    }
}

#[derive(Debug)]
struct FriendSender(Arc<FriendRelay>);

impl CustomSender for FriendSender {
    fn is_valid_send_addr(&self, addr: &CustomAddr) -> bool {
        parse_via(addr).is_some()
    }

    fn poll_send(
        &self,
        _cx: &mut Context,
        dst: &CustomAddr,
        _src: Option<&CustomAddr>,
        transmit: &Transmit<'_>,
    ) -> Poll<io::Result<()>> {
        let Some((relay, peer)) = parse_via(dst) else {
            return Poll::Ready(Err(io::Error::other("not a friend relay address")));
        };
        let segment = transmit
            .segment_size
            .unwrap_or(transmit.contents.len())
            .max(1);
        for packet in transmit.contents.chunks(segment) {
            self.0.send(relay, peer, packet);
        }
        Poll::Ready(Ok(()))
    }
}

/// iroh's default path selection with friend paths between direct and relay: direct paths
/// (IPv6 given 3 ms) first, then friend relays, then iroh relays; the lowest round trip within
/// a tier, switching only for a 5 ms gain. iroh's own selector is crate-private, so this copies
/// it; without the friend tier it would rank friend paths with direct ones, and as iroh only
/// re-selects when paths open or close, a friend path that measured faster when the direct one
/// opened would keep the connection for good.
#[derive(Debug, Default)]
pub struct FriendTierSelector;

const IPV6_RTT_ADVANTAGE: Duration = Duration::from_millis(3);
const RTT_SWITCHING_MIN: Duration = Duration::from_millis(5);

/// 0 direct (and other custom transports, as iroh ranks them), 1 friend relay, 2 iroh relay.
pub fn tier(kind: &AddrKind) -> u8 {
    match kind {
        AddrKind::Custom(TRANSPORT_ID) => 1,
        AddrKind::Relay => 2,
        _ => 0,
    }
}

fn sort_key(psd: &PathSelectionData<'_>, rtt: Duration) -> (u8, i128) {
    let kind = psd.network_path().addr_kind();
    let mut biased = rtt.as_nanos() as i128;
    if kind == AddrKind::IpV6 {
        biased -= IPV6_RTT_ADVANTAGE.as_nanos() as i128;
    }
    (tier(&kind), biased)
}

impl PathSelector for FriendTierSelector {
    fn select(&self, ctx: &PathSelectionContext<'_>) -> PathSelection {
        let current = ctx.current();
        let mut best: Option<(PathSelectionData<'_>, (u8, i128))> = None;
        let mut current_key: Option<(u8, i128)> = None;
        for psd in ctx.paths() {
            let Some(stats) = psd.stats() else { continue };
            let key = sort_key(&psd, stats.rtt);
            if Some(psd.network_path()) == current && current_key.is_none_or(|c| key < c) {
                current_key = Some(key);
            }
            if best.as_ref().is_none_or(|(_, b)| key < *b) {
                best = Some((psd, key));
            }
        }
        let mut selection = PathSelection::none();
        let Some((best, (best_tier, best_rtt))) = best else {
            return selection;
        };
        match current_key {
            Some((tier, rtt))
                if tier == best_tier && best_rtt + RTT_SWITCHING_MIN.as_nanos() as i128 > rtt => {}
            _ => selection.set(&best),
        }
        selection
    }
}

// --- C functions for Dart -------------------------------------------------------------------

unsafe fn id_from(ptr: *const u8) -> Option<EndpointId> {
    if ptr.is_null() {
        return None;
    }
    let bytes: &[u8; 32] = &*(ptr as *const [u8; 32]);
    EndpointId::from_bytes(bytes).ok()
}

unsafe fn ids_from(ptr: *const u8, count: usize) -> Vec<EndpointId> {
    if ptr.is_null() || count == 0 {
        return Vec::new();
    }
    std::slice::from_raw_parts(ptr, count * 32)
        .chunks_exact(32)
        .filter_map(|c| EndpointId::from_bytes(c.try_into().ok()?).ok())
        .collect()
}

unsafe fn relay_for(endpoint: *const u8) -> Option<Arc<FriendRelay>> {
    find(&id_from(endpoint)?)
}

/// Present in libraries with friend relays; the version of these functions.
#[no_mangle]
pub extern "C" fn ournet_friend_relay_abi() -> u32 {
    1
}

/// Sets whether the endpoint (by its 32-byte id) relays for friends, and the per-sender limits
/// in bytes per second and per UTC day (0 = unlimited). Returns 0, or -1 for an unknown
/// endpoint.
///
/// # Safety
/// `endpoint` points to 32 readable bytes.
#[no_mangle]
pub unsafe extern "C" fn ournet_friend_relay_policy(
    endpoint: *const u8,
    relay: u32,
    rate: u64,
    daily: u64,
) -> i32 {
    let Some(r) = relay_for(endpoint) else {
        return -1;
    };
    r.set_policy(relay != 0, rate, daily);
    0
}

/// Replaces the friends' devices (`count` 32-byte ids): who may link to this endpoint and whom
/// it forwards between.
///
/// # Safety
/// `endpoint` points to 32 readable bytes, `ids` to `count * 32`.
#[no_mangle]
pub unsafe extern "C" fn ournet_friend_relay_allow(
    endpoint: *const u8,
    ids: *const u8,
    count: usize,
) -> i32 {
    let Some(r) = relay_for(endpoint) else {
        return -1;
    };
    r.set_allow(ids_from(ids, count).into_iter().collect());
    0
}

/// Sets the friends (`count` 32-byte ids, at most 2 used) offered when dialling `peer`, and
/// starts linking to them. Zero clears them.
///
/// # Safety
/// `endpoint` and `peer` point to 32 readable bytes, `relays` to `count * 32`.
#[no_mangle]
pub unsafe extern "C" fn ournet_friend_relay_routes(
    endpoint: *const u8,
    peer: *const u8,
    relays: *const u8,
    count: usize,
) -> i32 {
    let Some(r) = relay_for(endpoint) else {
        return -1;
    };
    let Some(peer) = id_from(peer) else {
        return -1;
    };
    let _guard = rt().enter();
    r.set_routes(peer, ids_from(relays, count));
    0
}

/// Restores per-sender usage for UTC `day` (days since 1970): `count` 32-byte ids and as many
/// byte counts. Ignored unless `day` is today. Returns 0, or -1 for an unknown endpoint.
///
/// # Safety
/// `endpoint` points to 32 readable bytes, `ids` to `count * 32` and `bytes` to `count` u64s.
#[no_mangle]
pub unsafe extern "C" fn ournet_friend_relay_usage(
    endpoint: *const u8,
    day: u64,
    ids: *const u8,
    bytes: *const u64,
    count: usize,
) -> i32 {
    let Some(r) = relay_for(endpoint) else {
        return -1;
    };
    if count > 0 && (ids.is_null() || bytes.is_null()) {
        return -1;
    }
    let ids = std::slice::from_raw_parts(ids, count * 32);
    let bytes = std::slice::from_raw_parts(bytes, count);
    let usage = ids
        .chunks_exact(32)
        .zip(bytes)
        .filter_map(|(id, b)| Some((EndpointId::from_bytes(id.try_into().ok()?).ok()?, *b)));
    r.seed_usage(day, usage.collect::<Vec<_>>());
    0
}

/// Writes the endpoint's friend relay counters as UTF-8 JSON into `out` and returns their
/// length; nothing is written when that exceeds `capacity`. -1 for an unknown endpoint.
///
/// # Safety
/// `endpoint` points to 32 readable bytes, `out` to `capacity` writable ones.
#[no_mangle]
pub unsafe extern "C" fn ournet_friend_relay_stats(
    endpoint: *const u8,
    out: *mut u8,
    capacity: usize,
) -> isize {
    let Some(r) = relay_for(endpoint) else {
        return -1;
    };
    let json = r.stats_json();
    if json.len() <= capacity && !out.is_null() {
        std::ptr::copy_nonoverlapping(json.as_ptr(), out, json.len());
    }
    json.len() as isize
}

#[cfg(test)]
#[path = "friend_relay_tests.rs"]
mod tests;
