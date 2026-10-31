//! Call media over iroh (OurNet): the last-resort path for a call's WebRTC packets, for when ICE
//! finds no other (docs/CONNECTIVITY.md, piece 6).
//!
//! Each side runs a UDP *shim* on the device's own network address and gives it to its own
//! WebRTC as the peer's lowest-priority candidate (libwebrtc never sends to a loopback one).
//! Packets WebRTC sends to the shim travel as QUIC datagrams on an iroh connection to the peer
//! with ALPN `ournet/media/1`; the peer's shim hands them to its WebRTC socket. ICE, DTLS and
//! SRTP run through it unchanged, so the connection carries only WebRTC's encrypted packets, and
//! iroh picks its path as for any connection: direct, a friend, or a relay.
//!
//! The shim answers one WebRTC socket: the first to send from the shim's own address (another
//! once that one has been quiet for [`SOURCE_IDLE`]). Anything else is dropped, so other hosts
//! on the network cannot use it. Media connections are taken only from the peer of a running
//! shim, or briefly from a friend's device whose shim started first.
//!
//! Datagrams start with a kind byte:
//!
//! | kind | meaning           | rest                                   |
//! |------|-------------------|----------------------------------------|
//! | 0    | a whole packet    | packet                                 |
//! | 1    | half of a packet  | id u16 BE, index u8 (0 or 1), half     |
//! | 2    | keep-alive        | -                                      |
//!
//! A packet too large for one datagram (a relay path carries about 1160 bytes, RTP is up to
//! about 1200) goes as two halves; a half whose partner does not arrive is dropped.

use std::{
    collections::HashMap,
    io,
    net::{IpAddr, SocketAddr},
    sync::{
        atomic::{AtomicBool, AtomicU16, AtomicU64, Ordering::Relaxed},
        Arc, Mutex, Weak,
    },
    time::{Duration, Instant},
};

use bytes::{BufMut, Bytes, BytesMut};
use iroh::{endpoint::Connection, EndpointAddr, EndpointId};
use tokio::{net::UdpSocket, task::AbortHandle};

use crate::friend_relay::FriendRelay;
use crate::runtime::rt;

/// Not registered with iroh; only OurNet peers use it.
pub const MEDIA_ALPN: &[u8] = b"ournet/media/1";

const KIND_WHOLE: u8 = 0;
const KIND_HALF: u8 = 1;
const KIND_KEEPALIVE: u8 = 2;
const HALF_HEADER: usize = 4;

/// A WebRTC socket quiet this long may be replaced by another on the same address (an ICE
/// restart gathers new sockets).
pub const SOURCE_IDLE: Duration = Duration::from_secs(3);
/// How long a half waits for its partner.
const HALF_TTL: Duration = Duration::from_millis(500);
const MAX_HALVES: usize = 64;
/// The higher endpoint id waits this long for the lower one's connection before dialling too.
const DIAL_WAIT: Duration = Duration::from_secs(2);
const DIAL_TIMEOUT: Duration = Duration::from_secs(10);
const DIAL_BACKOFF_MAX: Duration = Duration::from_secs(30);
/// Keeps an otherwise idle media connection open while ICE uses another path, so it is ready
/// if that path fails.
const KEEPALIVE: Duration = Duration::from_secs(10);
/// Media connections accepted before the call's shim started are kept this long.
const WAITING_TTL: Duration = Duration::from_secs(30);
const MAX_CONNS: usize = 4;

/// A packet as one or two datagrams no larger than `max`, or `None` when it does not fit in
/// two (or is empty).
pub fn frame(packet: &[u8], max: usize, id: u16) -> Option<Vec<Bytes>> {
    if packet.is_empty() {
        return None;
    }
    if packet.len() < max {
        let mut b = BytesMut::with_capacity(1 + packet.len());
        b.put_u8(KIND_WHOLE);
        b.put_slice(packet);
        return Some(vec![b.freeze()]);
    }
    let first = packet.len().div_ceil(2);
    if HALF_HEADER + first > max {
        return None;
    }
    Some(
        [&packet[..first], &packet[first..]]
            .iter()
            .enumerate()
            .map(|(index, half)| {
                let mut b = BytesMut::with_capacity(HALF_HEADER + half.len());
                b.put_u8(KIND_HALF);
                b.put_u16(id);
                b.put_u8(index as u8);
                b.put_slice(half);
                b.freeze()
            })
            .collect(),
    )
}

#[derive(Debug, PartialEq, Eq)]
pub enum Datagram {
    Whole(Bytes),
    Half { id: u16, index: u8, half: Bytes },
    KeepAlive,
}

/// Reads a media datagram; `None` for one this build does not know.
pub fn parse(d: Bytes) -> Option<Datagram> {
    match *d.first()? {
        KIND_WHOLE if d.len() > 1 => Some(Datagram::Whole(d.slice(1..))),
        KIND_HALF if d.len() > HALF_HEADER && d[3] < 2 => Some(Datagram::Half {
            id: u16::from_be_bytes([d[1], d[2]]),
            index: d[3],
            half: d.slice(HALF_HEADER..),
        }),
        KIND_KEEPALIVE => Some(Datagram::KeepAlive),
        _ => None,
    }
}

/// Halves waiting for their partners.
#[derive(Default, Debug)]
pub struct Halves {
    parts: HashMap<u16, (u8, Bytes, Instant)>,
    /// Halves dropped without their partner.
    pub dropped: u64,
}

impl Halves {
    /// Takes a half; returns the packet once both halves are here.
    pub fn take(&mut self, id: u16, index: u8, half: Bytes, now: Instant) -> Option<Bytes> {
        if let Some((other, first, _)) = self.parts.remove(&id) {
            if other != index {
                let (a, b) = if other == 0 {
                    (first, half)
                } else {
                    (half, first)
                };
                let mut joined = BytesMut::with_capacity(a.len() + b.len());
                joined.put_slice(&a);
                joined.put_slice(&b);
                return Some(joined.freeze());
            }
            // The same half twice: an id reused after its packet was lost.
            self.dropped += 1;
        }
        let before = self.parts.len();
        self.parts
            .retain(|_, (_, _, at)| now.duration_since(*at) < HALF_TTL);
        self.dropped += (before - self.parts.len()) as u64;
        if self.parts.len() >= MAX_HALVES {
            self.dropped += self.parts.len() as u64;
            self.parts.clear();
        }
        self.parts.insert(id, (index, half, now));
        None
    }
}

/// Whether a packet from `from` comes from the call's WebRTC socket: one on the shim's own
/// address `bound`, the first such to send, or a newer one once `learned` has been quiet for
/// [`SOURCE_IDLE`]. Updates `learned`.
pub fn source_ok(
    bound: IpAddr,
    learned: &mut Option<(SocketAddr, Instant)>,
    from: SocketAddr,
    now: Instant,
) -> bool {
    if from.ip() != bound {
        return false;
    }
    match learned {
        Some((addr, at)) if *addr != from && now.duration_since(*at) < SOURCE_IDLE => false,
        _ => {
            *learned = Some((from, now));
            true
        }
    }
}

#[derive(Default, Debug)]
pub struct Stats {
    /// WebRTC packets sent to the peer, and their bytes.
    pub sent: AtomicU64,
    pub sent_bytes: AtomicU64,
    /// WebRTC packets received from the peer, and their bytes.
    pub received: AtomicU64,
    pub received_bytes: AtomicU64,
    /// Packets sent as two halves.
    pub halved: AtomicU64,
    /// Packets too large for two datagrams, or sent while datagrams could not be.
    pub too_large: AtomicU64,
    /// Packets dropped because no media connection was up.
    pub no_connection: AtomicU64,
    /// Packets from a socket other than the call's WebRTC one.
    pub foreign: AtomicU64,
    /// Packets from the peer before WebRTC had sent anything to the shim.
    pub unlearned: AtomicU64,
    pub dials: AtomicU64,
    pub dial_failures: AtomicU64,
    pub accepted: AtomicU64,
    pub refused: AtomicU64,
}

/// One call's shim, for one peer.
struct Shim {
    peer: EndpointId,
    stats: Arc<Stats>,
    socket: Mutex<Option<(Arc<UdpSocket>, IpAddr, AbortHandle)>>,
    webrtc: Mutex<Option<(SocketAddr, Instant)>>,
    conns: Mutex<Vec<(Connection, AbortHandle)>>,
    halves: Mutex<Halves>,
    next_half: AtomicU16,
    stopped: AtomicBool,
    dialer: Mutex<Option<AbortHandle>>,
}

impl Shim {
    fn live(&self) -> Option<Connection> {
        let mut conns = self.conns.lock().unwrap();
        conns.retain(|(c, task)| {
            let keep = c.close_reason().is_none();
            if !keep {
                task.abort();
            }
            keep
        });
        conns.last().map(|(c, _)| c.clone())
    }

    /// Sends a packet from WebRTC to the peer.
    fn send(&self, packet: &[u8]) {
        let Some(conn) = self.live() else {
            self.stats.no_connection.fetch_add(1, Relaxed);
            return;
        };
        let max = conn.max_datagram_size().unwrap_or(0);
        let id = self.next_half.fetch_add(1, Relaxed);
        let Some(frames) = frame(packet, max, id) else {
            self.stats.too_large.fetch_add(1, Relaxed);
            return;
        };
        if frames.len() == 2 {
            self.stats.halved.fetch_add(1, Relaxed);
        }
        for f in frames {
            if conn.send_datagram(f).is_err() {
                self.stats.too_large.fetch_add(1, Relaxed);
                return;
            }
        }
        self.stats.sent.fetch_add(1, Relaxed);
        self.stats
            .sent_bytes
            .fetch_add(packet.len() as u64, Relaxed);
    }

    /// Hands a datagram from the peer to WebRTC.
    fn deliver(&self, d: Bytes) {
        let packet = match parse(d) {
            Some(Datagram::Whole(p)) => p,
            Some(Datagram::Half { id, index, half }) => {
                match self
                    .halves
                    .lock()
                    .unwrap()
                    .take(id, index, half, Instant::now())
                {
                    Some(p) => p,
                    None => return,
                }
            }
            _ => return,
        };
        let to = self.webrtc.lock().unwrap().map(|(a, _)| a);
        let socket = self
            .socket
            .lock()
            .unwrap()
            .as_ref()
            .map(|(s, _, _)| s.clone());
        let (Some(to), Some(socket)) = (to, socket) else {
            self.stats.unlearned.fetch_add(1, Relaxed);
            return;
        };
        if socket.try_send_to(&packet, to).is_ok() {
            self.stats.received.fetch_add(1, Relaxed);
            self.stats
                .received_bytes
                .fetch_add(packet.len() as u64, Relaxed);
        }
    }

    fn add_conn(self: &Arc<Self>, conn: Connection) {
        if self.stopped.load(Relaxed) {
            conn.close(0u32.into(), b"call ended");
            return;
        }
        let shim = Arc::downgrade(self);
        let reader = conn.clone();
        let task = rt().spawn(async move {
            while let Ok(d) = reader.read_datagram().await {
                let Some(shim) = shim.upgrade() else { break };
                shim.deliver(d);
            }
        });
        let mut conns = self.conns.lock().unwrap();
        conns.push((conn, task.abort_handle()));
        if conns.len() > MAX_CONNS {
            let (old, task) = conns.remove(0);
            old.close(0u32.into(), b"replaced");
            task.abort();
        }
    }

    /// Replaces the socket, forgetting the WebRTC socket learned on the old one.
    fn bind(self: &Arc<Self>, socket: UdpSocket, ip: IpAddr) {
        let socket = Arc::new(socket);
        let shim = Arc::downgrade(self);
        let pump = socket.clone();
        let task = rt().spawn(async move {
            let mut buf = vec![0u8; 2048];
            loop {
                let (n, from) = match pump.recv_from(&mut buf).await {
                    Ok(r) => r,
                    // Windows reports an earlier send's ICMP "port unreachable" here.
                    Err(e) if e.kind() == io::ErrorKind::ConnectionReset => continue,
                    Err(_) => {
                        tokio::time::sleep(Duration::from_millis(50)).await;
                        continue;
                    }
                };
                let Some(shim) = shim.upgrade() else { break };
                let ok = source_ok(ip, &mut shim.webrtc.lock().unwrap(), from, Instant::now());
                if ok {
                    shim.send(&buf[..n]);
                } else {
                    shim.stats.foreign.fetch_add(1, Relaxed);
                }
            }
        });
        *self.webrtc.lock().unwrap() = None;
        if let Some((_, _, old)) =
            self.socket
                .lock()
                .unwrap()
                .replace((socket, ip, task.abort_handle()))
        {
            old.abort();
        }
    }

    fn shutdown(&self) {
        self.stopped.store(true, Relaxed);
        if let Some(d) = self.dialer.lock().unwrap().take() {
            d.abort();
        }
        if let Some((_, _, pump)) = self.socket.lock().unwrap().take() {
            pump.abort();
        }
        for (conn, task) in self.conns.lock().unwrap().drain(..) {
            conn.close(0u32.into(), b"call ended");
            task.abort();
        }
    }
}

/// Per-endpoint call media state, owned by the endpoint's [`FriendRelay`].
#[derive(Default)]
pub struct CallMedia {
    relay: Weak<FriendRelay>,
    shims: Mutex<HashMap<EndpointId, Arc<Shim>>>,
    waiting: Mutex<HashMap<EndpointId, Vec<(Connection, Instant)>>>,
    pub stats: Arc<Stats>,
}

impl std::fmt::Debug for CallMedia {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CallMedia")
            .field("shims", &self.shims.lock().unwrap().len())
            .finish_non_exhaustive()
    }
}

impl CallMedia {
    pub fn new(relay: Weak<FriendRelay>) -> Self {
        Self {
            relay,
            ..Default::default()
        }
    }

    /// Starts (or rebinds) the shim for `peer` on `ip`, port chosen by the system, and returns
    /// the port. Rebinding keeps the media connection and forgets the WebRTC socket.
    pub fn start(self: &Arc<Self>, peer: EndpointId, ip: IpAddr) -> io::Result<u16> {
        let std_socket = std::net::UdpSocket::bind(SocketAddr::new(ip, 0))?;
        std_socket.set_nonblocking(true)?;
        let port = std_socket.local_addr()?.port();
        let _guard = rt().enter();
        let socket = UdpSocket::from_std(std_socket)?;
        let (shim, new) = {
            let mut shims = self.shims.lock().unwrap();
            match shims.get(&peer) {
                Some(s) => (s.clone(), false),
                None => {
                    let s = Arc::new(Shim {
                        peer,
                        stats: self.stats.clone(),
                        socket: Mutex::new(None),
                        webrtc: Mutex::new(None),
                        conns: Mutex::new(Vec::new()),
                        halves: Mutex::new(Halves::default()),
                        next_half: AtomicU16::new(0),
                        stopped: AtomicBool::new(false),
                        dialer: Mutex::new(None),
                    });
                    shims.insert(peer, s.clone());
                    (s, true)
                }
            }
        };
        shim.bind(socket, ip);
        if new {
            for (conn, _) in self
                .waiting
                .lock()
                .unwrap()
                .remove(&peer)
                .unwrap_or_default()
            {
                if conn.close_reason().is_none() {
                    shim.add_conn(conn);
                }
            }
            let task = rt().spawn(self.clone().dial(Arc::downgrade(&shim)));
            *shim.dialer.lock().unwrap() = Some(task.abort_handle());
        }
        Ok(port)
    }

    /// Stops the shim for `peer` and closes its media connections.
    pub fn stop(&self, peer: &EndpointId) -> bool {
        let shim = self.shims.lock().unwrap().remove(peer);
        if let Some(conns) = self.waiting.lock().unwrap().remove(peer) {
            for (c, _) in conns {
                c.close(0u32.into(), b"call ended");
            }
        }
        match shim {
            Some(s) => {
                s.shutdown();
                true
            }
            None => false,
        }
    }

    /// Stops every shim, as the endpoint closes.
    pub fn stop_all(&self) {
        let peers: Vec<_> = self.shims.lock().unwrap().keys().copied().collect();
        for p in peers {
            self.stop(&p);
        }
        self.waiting.lock().unwrap().clear();
    }

    /// Takes an accepted media connection: for the peer's running shim, or kept for a shim
    /// about to start when it comes from a friend's device.
    pub fn accept(self: &Arc<Self>, conn: Connection) {
        let peer = conn.remote_id();
        let relay = self.relay.upgrade();
        if let Some(r) = &relay {
            r.watch(&conn);
        }
        let shim = self.shims.lock().unwrap().get(&peer).cloned();
        if let Some(shim) = shim {
            self.stats.accepted.fetch_add(1, Relaxed);
            shim.add_conn(conn);
            return;
        }
        if !relay.is_some_and(|r| r.allowed(&peer)) {
            self.stats.refused.fetch_add(1, Relaxed);
            conn.close(0u32.into(), b"no call");
            return;
        }
        self.stats.accepted.fetch_add(1, Relaxed);
        let mut waiting = self.waiting.lock().unwrap();
        waiting.retain(|_, list| {
            list.retain(|(c, at)| c.close_reason().is_none() && at.elapsed() < WAITING_TTL);
            !list.is_empty()
        });
        let list = waiting.entry(peer).or_default();
        list.push((conn, Instant::now()));
        if list.len() > MAX_CONNS {
            list.remove(0).0.close(0u32.into(), b"replaced");
        }
    }

    /// Keeps a media connection to the shim's peer: the lower endpoint id dials at once, the
    /// higher after [`DIAL_WAIT`] without one, so usually only one is made. Both read every
    /// connection, so a crossing pair is harmless.
    async fn dial(self: Arc<Self>, shim: Weak<Shim>) {
        let mut none_since = Instant::now();
        let mut keepalive = Instant::now();
        let mut backoff = Duration::from_secs(1);
        loop {
            let Some(s) = shim.upgrade() else { break };
            if s.stopped.load(Relaxed) {
                break;
            }
            if let Some(conn) = s.live() {
                none_since = Instant::now();
                backoff = Duration::from_secs(1);
                if keepalive.elapsed() >= KEEPALIVE {
                    keepalive = Instant::now();
                    let _ = conn.send_datagram(Bytes::from_static(&[KIND_KEEPALIVE]));
                }
                drop(s);
                tokio::time::sleep(Duration::from_millis(500)).await;
                continue;
            }
            let Some(relay) = self.relay.upgrade() else {
                break;
            };
            let Some(endpoint) = relay.endpoint() else {
                break;
            };
            let lower = endpoint.id().as_bytes() < s.peer.as_bytes();
            if !lower && none_since.elapsed() < DIAL_WAIT {
                drop(s);
                tokio::time::sleep(Duration::from_millis(250)).await;
                continue;
            }
            self.stats.dials.fetch_add(1, Relaxed);
            let mut addr = EndpointAddr::new(s.peer);
            relay.add_routes(&mut addr);
            drop(relay);
            let dial = endpoint.connect(addr, MEDIA_ALPN);
            match tokio::time::timeout(DIAL_TIMEOUT, dial).await {
                Ok(Ok(conn)) => {
                    if let Some(r) = self.relay.upgrade() {
                        r.watch(&conn);
                    }
                    s.add_conn(conn);
                }
                _ => {
                    self.stats.dial_failures.fetch_add(1, Relaxed);
                    drop(s);
                    tokio::time::sleep(backoff).await;
                    backoff = (backoff * 2).min(DIAL_BACKOFF_MAX);
                }
            }
        }
    }

    /// Counters, shims and media connections as JSON, for Dart.
    pub fn stats_json(&self) -> String {
        let s = &self.stats;
        let shims = self.shims.lock().unwrap();
        let mut conns = 0;
        let mut learned = 0;
        let mut incomplete = 0;
        let mut paths = Vec::new();
        for shim in shims.values() {
            if let Some(path) = shim.live().as_ref().and_then(selected_path) {
                let peer: String = shim
                    .peer
                    .as_bytes()
                    .iter()
                    .map(|b| format!("{b:02x}"))
                    .collect();
                paths.push(format!("\"{peer}\":{}", json_string(&path)));
            }
            conns += shim.live().map_or(0, |_| 1);
            learned += shim.webrtc.lock().unwrap().map_or(0, |_| 1);
            incomplete += shim.halves.lock().unwrap().dropped;
        }
        format!(
            concat!(
                "{{\"shims\":{},\"connected\":{},\"learned\":{},",
                "\"sent\":{},\"sentBytes\":{},\"received\":{},\"receivedBytes\":{},",
                "\"halved\":{},\"incomplete\":{},\"tooLarge\":{},\"noConnection\":{},",
                "\"foreign\":{},\"unlearned\":{},\"dials\":{},\"dialFailures\":{},",
                "\"accepted\":{},\"refused\":{},\"paths\":{{{}}}}}"
            ),
            shims.len(),
            conns,
            learned,
            s.sent.load(Relaxed),
            s.sent_bytes.load(Relaxed),
            s.received.load(Relaxed),
            s.received_bytes.load(Relaxed),
            s.halved.load(Relaxed),
            incomplete,
            s.too_large.load(Relaxed),
            s.no_connection.load(Relaxed),
            s.foreign.load(Relaxed),
            s.unlearned.load(Relaxed),
            s.dials.load(Relaxed),
            s.dial_failures.load(Relaxed),
            s.accepted.load(Relaxed),
            s.refused.load(Relaxed),
            paths.join(","),
        )
    }
}

/// The path a media connection uses, in iroh's debug rendering (as path events give it to
/// Dart): `Ip(..)`, `Relay(..)` or a friend relay's custom address.
fn selected_path(conn: &Connection) -> Option<String> {
    conn.paths()
        .iter()
        .find(|p| p.is_selected())
        .map(|p| format!("{:?}", p.remote_addr()))
}

fn json_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

// --- C functions for Dart -------------------------------------------------------------------

unsafe fn media_for(endpoint: *const u8) -> Option<Arc<CallMedia>> {
    if endpoint.is_null() {
        return None;
    }
    let id = EndpointId::from_bytes(&*(endpoint as *const [u8; 32])).ok()?;
    Some(crate::friend_relay::find(&id)?.media())
}

unsafe fn peer_from(peer: *const u8) -> Option<EndpointId> {
    if peer.is_null() {
        return None;
    }
    EndpointId::from_bytes(&*(peer as *const [u8; 32])).ok()
}

/// Present in libraries with call media over iroh; the version of these functions.
#[no_mangle]
pub extern "C" fn ournet_call_media_abi() -> u32 {
    1
}

/// Starts the call shim for `peer` on the IP address given as `ip_len` UTF-8 bytes, or rebinds
/// a running one there. Returns the shim's UDP port, or -1 (unknown endpoint, bad address, or
/// the address cannot be bound).
///
/// # Safety
/// `endpoint` and `peer` point to 32 readable bytes, `ip` to `ip_len`.
#[no_mangle]
pub unsafe extern "C" fn ournet_call_media_start(
    endpoint: *const u8,
    peer: *const u8,
    ip: *const u8,
    ip_len: usize,
) -> i32 {
    let (Some(media), Some(peer)) = (media_for(endpoint), peer_from(peer)) else {
        return -1;
    };
    if ip.is_null() {
        return -1;
    }
    let Some(ip) = std::str::from_utf8(std::slice::from_raw_parts(ip, ip_len))
        .ok()
        .and_then(|s| s.parse::<IpAddr>().ok())
    else {
        return -1;
    };
    media.start(peer, ip).map_or(-1, i32::from)
}

/// Stops the call shim for `peer`. Returns 0, or -1 when there was none.
///
/// # Safety
/// `endpoint` and `peer` point to 32 readable bytes.
#[no_mangle]
pub unsafe extern "C" fn ournet_call_media_stop(endpoint: *const u8, peer: *const u8) -> i32 {
    let (Some(media), Some(peer)) = (media_for(endpoint), peer_from(peer)) else {
        return -1;
    };
    let _guard = rt().enter();
    if media.stop(&peer) {
        0
    } else {
        -1
    }
}

/// Writes the call media counters as UTF-8 JSON into `out` and returns their length; nothing is
/// written when that exceeds `capacity`. -1 for an unknown endpoint.
///
/// # Safety
/// `endpoint` points to 32 readable bytes, `out` to `capacity` writable ones.
#[no_mangle]
pub unsafe extern "C" fn ournet_call_media_stats(
    endpoint: *const u8,
    out: *mut u8,
    capacity: usize,
) -> isize {
    let Some(media) = media_for(endpoint) else {
        return -1;
    };
    let json = media.stats_json();
    if json.len() <= capacity && !out.is_null() {
        std::ptr::copy_nonoverlapping(json.as_ptr(), out, json.len());
    }
    json.len() as isize
}

#[cfg(test)]
#[path = "call_media_tests.rs"]
mod tests;
