//! A private IPv4 network between this person's devices and friends they
//! allow, carried by OurNet's encrypted device-to-device links.
//!
//! Every device running it has an address in 10.77.0.0/16 worked out from
//! its device ID, so no one hands addresses out and every device agrees.
//! The host moves packets between the system's interface and this plugin's
//! thread; the plugin decides where each goes and sends it to that device
//! as a datagram. A packet is taken from a device only when it comes from
//! that device's own address and the device is allowed: one's own devices
//! always are, a friend's once allowed here.
//!
//! Each device has a page of its own: what passed between the two, and
//! checks of the path to it. A ping asks the other copy of this plugin how
//! it sees this device; the datagram test sends small and full-size probes
//! that it echoes; a system ping sends an ICMP echo through the other
//! device's interface, so its system answers. Probes are datagrams whose
//! first byte is 0, which no IPv4 packet has; versions before 0.2 refuse
//! them, and answer a ping with "not handled".

use std::collections::{BTreeMap, BTreeSet, HashMap};

use ournet_plugin::{json, store, timer, tun, ui, Context, Plugin, Value};

const SURFACE: &str = "Vpn";
const VERSION: &str = env!("CARGO_PKG_VERSION");
/// Datagrams carry at most 1100 bytes: the interface's packets fit them.
const MTU: u16 = 1100;
const NETWORK: &str = "10.77.0.0/16";

/// Timer tokens.
const REFRESH: u64 = 1;
const TICK: u64 = 2;
const PROBE: u64 = 3;

/// A device's page refreshes each second while someone looks at it, for at
/// most this long after it was opened or used.
const WATCH_MS: u64 = 5 * 60_000;

/// Datagram probes: first byte 0, then the operation and a sequence number.
const PROBE_PING: u8 = 1;
const PROBE_PONG: u8 = 2;
const PROBES: u16 = 10;
const PROBE_GAP_MS: u32 = 100;
const SMALL: usize = 64;
/// ICMP echoes for the system ping, and the ID they carry ("ON").
const ECHOES: u16 = 4;
const ECHO_GAP_MS: u32 = 500;
const ECHO_ID: u16 = 0x4f4e;
/// How long the last probe of a test may take to come back.
const PROBE_WAIT_MS: u32 = 2000;

/// The address a device has on the network.
fn address(device: &str) -> [u8; 4] {
    // FNV-1a: stable, and the same on every device.
    let mut h: u32 = 0x811c9dc5;
    for b in device.bytes() {
        h ^= b as u32;
        h = h.wrapping_mul(0x01000193);
    }
    [10, 77, 1 + (h % 254) as u8, 1 + ((h >> 8) % 254) as u8]
}

fn dotted(ip: [u8; 4]) -> String {
    format!("{}.{}.{}.{}", ip[0], ip[1], ip[2], ip[3])
}

fn bytes(n: u64) -> String {
    match n {
        0..=999 => format!("{n} B"),
        1000..=999_999 => format!("{:.1} KB", n as f64 / 1e3),
        1_000_000..=999_999_999 => format!("{:.1} MB", n as f64 / 1e6),
        _ => format!("{:.2} GB", n as f64 / 1e9),
    }
}

fn ago(now: u64, at: u64) -> String {
    let s = now.saturating_sub(at) / 1000;
    match s {
        0 => "just now".into(),
        1..=59 => format!("{s} s ago"),
        60..=3599 => format!("{} min ago", s / 60),
        _ => format!("{} h ago", s / 3600),
    }
}

/// The start of a long ID, enough to tell devices apart.
fn short(id: &str) -> String {
    let head: String = id.chars().take(12).collect();
    if head.len() < id.len() {
        format!("{head}…")
    } else {
        head
    }
}

struct Peer {
    person: String,
    device: String,
    name: String,
    online: bool,
}

/// What has passed between this device and one other, this session.
#[derive(Default)]
struct Stats {
    sent: u64,
    sent_bytes: u64,
    received: u64,
    received_bytes: u64,
    refused: u64,
    /// Packets for this device not sent: not allowed here, or failed.
    held: u64,
    last_sent: u64,
    last_received: u64,
    last_refusal: Option<&'static str>,
    last_error: Option<String>,
    /// For the page's rates: totals and time at its last refresh.
    mark: (u64, u64, u64),
    rate: (f64, f64),
}

/// How the other device answered a ping, from the reply.
#[derive(Clone)]
struct Report {
    version: String,
    on: bool,
    address: String,
    allows: bool,
    received: u64,
    refused: u64,
    last_refusal: Option<String>,
}

#[derive(Default)]
struct Ping {
    /// Round trip, or why it failed.
    result: Option<Result<u64, String>>,
    /// None until a 0.2 reply; an older version answers "not handled".
    report: Option<Report>,
    older: bool,
    at: u64,
}

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
enum Test {
    Datagrams,
    System,
}

/// A test under way, or its outcome.
struct Probe {
    device: String,
    test: Test,
    /// Sequence number → (sent at, full size).
    out: HashMap<u16, (u64, bool)>,
    next: u16,
    sent: [u32; 2],
    back: [u32; 2],
    failed: u32,
    rtts: Vec<u64>,
    done: bool,
    /// The full check goes on to the system ping after the datagrams.
    then_system: bool,
}

impl Probe {
    fn new(device: &str, test: Test, then_system: bool) -> Probe {
        Probe {
            device: device.into(),
            test,
            out: HashMap::new(),
            next: 0,
            sent: [0; 2],
            back: [0; 2],
            failed: 0,
            rtts: Vec::new(),
            done: false,
            then_system,
        }
    }

    fn count(&self) -> u16 {
        match self.test {
            Test::Datagrams => PROBES,
            Test::System => ECHOES,
        }
    }

    fn rtt(&self) -> String {
        if self.rtts.is_empty() {
            return String::new();
        }
        let min = self.rtts.iter().min().unwrap();
        let max = self.rtts.iter().max().unwrap();
        let avg = self.rtts.iter().sum::<u64>() / self.rtts.len() as u64;
        format!(", {min}/{avg}/{max} ms min/avg/max")
    }

    fn summary(&self) -> String {
        let state = match (self.done, self.failed) {
            (false, _) => " (running)".to_string(),
            (true, 0) => String::new(),
            (true, n) => format!(", {n} could not be sent"),
        };
        match self.test {
            Test::Datagrams => format!(
                "small {}/{}, full size {}/{} back{}{state}",
                self.back[0],
                self.sent[0],
                self.back[1],
                self.sent[1],
                self.rtt()
            ),
            Test::System => format!("{}/{} answered{}{state}", self.back[0], self.sent[0], self.rtt()),
        }
    }
}

#[derive(Default)]
struct Vpn {
    me: String,
    device: String,
    on: bool,
    error: Option<String>,
    /// Address → peer, for devices that run this plugin.
    peers: BTreeMap<[u8; 4], Peer>,
    /// Friends whose devices may reach this one.
    allowed: BTreeSet<String>,
    sent: u64,
    received: u64,
    dropped: u64,
    /// Device → its traffic.
    stats: HashMap<String, Stats>,
    /// The device whose page is open, and until when it refreshes itself.
    selected: Option<String>,
    watch_until: u64,
    ticking: bool,
    /// Request ID → (device, sent at, part of a full check).
    pings: HashMap<u64, (String, u64, bool)>,
    /// Device → its last ping.
    ping: HashMap<String, Ping>,
    /// The last test of each kind per device, and the one under way.
    probes: HashMap<(String, Test), Probe>,
    running: Option<(String, Test)>,
}

impl Vpn {
    fn refresh(&mut self) {
        self.peers.clear();
        for c in ournet_plugin::contacts() {
            for d in c.devices.into_iter().filter(|d| d.has_plugin) {
                self.peers.insert(
                    address(&d.id),
                    Peer { person: c.person.clone(), device: d.id, name: d.name, online: d.online },
                );
            }
        }
    }

    fn allows(&self, peer: &Peer) -> bool {
        peer.person == self.me || self.allowed.contains(&peer.person)
    }

    fn peer(&self, device: &str) -> Option<(&[u8; 4], &Peer)> {
        self.peers.iter().find(|(_, p)| p.device == device)
    }

    fn state(&self, peer: &Peer) -> &'static str {
        match (self.allows(peer), peer.online) {
            (false, _) => "not allowed",
            (true, true) => "online",
            (true, false) => "offline",
        }
    }

    fn show(&mut self) {
        let peers: Vec<Value> = self
            .peers
            .iter()
            .map(|(ip, p)| {
                let own = p.person == self.me;
                let latency = match self.ping.get(&p.device).and_then(|r| r.result.clone()) {
                    Some(Ok(ms)) => format!("  {ms} ms"),
                    _ => String::new(),
                };
                json!({
                    "person": p.person,
                    "id": p.device,
                    "device": if p.name.is_empty() { "a device" } else { p.name.as_str() },
                    "ip": dotted(*ip),
                    "own": own,
                    "state": format!("{}{latency}", self.state(p)),
                    "allow": if self.allows(p) { "Allowed" } else { "Allow" },
                })
            })
            .collect();
        let status = match (&self.error, self.on) {
            (Some(e), _) => format!("Not running: {e}"),
            (None, true) => format!("On: {NETWORK} goes to your devices and allowed friends"),
            (None, false) => "Off".into(),
        };
        let mut data = json!({
            "action": if self.on { "Turn off" } else { "Turn on" },
            "status": status,
            "address": format!("This device: {}", dotted(address(&self.device))),
            "traffic": format!("{} packets sent · {} received · {} refused", self.sent, self.received, self.dropped),
            "nobody": peers.is_empty(),
            "peers": peers,
            "view": "list",
            "page": null,
        });
        if let Some(device) = self.selected.clone() {
            match self.detail(&device) {
                Some(page) => {
                    data["view"] = json!("device");
                    data["page"] = page;
                }
                None => self.selected = None,
            }
        }
        ui::update(SURFACE, &data);
    }

    /// The page of [device], or None when it is no longer listed.
    fn detail(&mut self, device: &str) -> Option<Value> {
        let now = ournet_plugin::now();
        let (ip, peer) = self.peer(device)?;
        let (ip, own, allows, state) = (*ip, peer.person == self.me, self.allows(peer), self.state(peer));
        let (person, name) = (peer.person.clone(), peer.name.clone());
        let online = peer.online;

        let s = self.stats.entry(device.to_string()).or_default();
        let last = |at: u64| if at == 0 { String::new() } else { format!(" · last {}", ago(now, at)) };
        let row = |label: &str, value: String| json!({ "label": label, "value": value });
        let mut link = vec![
            row("Address", dotted(ip)),
            row("Device", short(device)),
            row("Person", if own { "You".into() } else { short(&person) }),
            row(
                "Access",
                match (own, allows) {
                    (true, _) => "Your own device: always allowed".into(),
                    (false, true) => "Allowed: it may reach this device".into(),
                    (false, false) => "Not allowed: its packets are refused here".into(),
                },
            ),
            row("Seen", if online { "Heard from in the last 10 minutes".into() } else { "Not heard from lately".into() }),
        ];
        let traffic = vec![
            row("Sent", format!("{} packets · {}{}", s.sent, bytes(s.sent_bytes), last(s.last_sent))),
            row("Received", format!("{} packets · {}{}", s.received, bytes(s.received_bytes), last(s.last_received))),
            row("Now", format!("{}/s out · {}/s in", bytes(s.rate.0 as u64), bytes(s.rate.1 as u64))),
            row(
                "Refused",
                match s.last_refusal {
                    Some(why) if s.refused > 0 => format!("{} · last: {why}", s.refused),
                    _ => s.refused.to_string(),
                },
            ),
            row(
                "Not sent",
                match &s.last_error {
                    Some(e) if s.held > 0 => format!("{} · last: {e}", s.held),
                    _ => s.held.to_string(),
                },
            ),
        ];

        let ping = self.ping.get(device);
        if let Some(r) = ping.and_then(|p| p.report.clone()) {
            link.push(row(
                "Their side",
                format!(
                    "Friend network {} · {} · {} · it has {} of yours, refused {}{}",
                    r.version,
                    if r.on { "on" } else { "off" },
                    if r.allows { "allows you" } else { "does not allow you" },
                    r.received,
                    r.refused,
                    r.last_refusal.map(|w| format!(" (last: {w})")).unwrap_or_default(),
                ),
            ));
            if r.address != dotted(ip) {
                link.push(row("Their address", format!("{} (expected {})", r.address, dotted(ip))));
            }
        } else if ping.is_some_and(|p| p.older) {
            link.push(row("Their side", "An older Friend network: it does not answer checks".into()));
        }

        let mut checks = Vec::new();
        if let Some(p) = ping {
            checks.push(row(
                "Ping",
                match &p.result {
                    None => "waiting…".into(),
                    Some(Ok(ms)) => format!("{ms} ms, {}", ago(now, p.at)),
                    Some(Err(e)) => format!("failed: {e}"),
                },
            ));
        }
        for (test, label) in [(Test::Datagrams, "Datagrams"), (Test::System, "System ping")] {
            if let Some(p) = self.probes.get(&(device.to_string(), test)) {
                checks.push(row(label, p.summary()));
            }
        }
        let busy = self.running.is_some();
        let diagnosis = self.diagnose(device, own, allows);
        Some(json!({
            "id": device,
            "person": person,
            "own": own,
            "name": if name.is_empty() { "A device".to_string() } else { name },
            "state": state,
            "allow": if allows { "Stop allowing" } else { "Allow" },
            "link": link,
            "traffic": traffic,
            "checks": checks,
            "nochecks": checks.is_empty(),
            "busy": busy,
            "diagnosis": diagnosis,
        }))
    }

    /// What the checks so far say about reaching [device].
    fn diagnose(&self, device: &str, own: bool, allows: bool) -> String {
        if let Some(e) = &self.error {
            return format!("Friend network is not running here: {e}");
        }
        let ping = self.ping.get(device);
        if let Some(Some(Err(e))) = ping.map(|p| &p.result) {
            return format!("Its device could not be reached ({e}). It may be asleep, offline or not running OurNet.");
        }
        if !own && !allows {
            return "You have not allowed this friend: their packets are refused here.".into();
        }
        let Some(ping) = ping else {
            return "Run checks to see whether this device can be reached.".into();
        };
        if ping.result.is_none() {
            return "Checking…".into();
        }
        if ping.older {
            return "Reachable, but its Friend network is older and cannot be checked further.".into();
        }
        let report = ping.report.as_ref();
        if report.is_some_and(|r| !r.allows) {
            return "Reachable, but they have not allowed you: they refuse your packets.".into();
        }
        if report.is_some_and(|r| !r.on) {
            return "Reachable, but their Friend network is off.".into();
        }
        if !self.on {
            return "Reachable, but your Friend network is off.".into();
        }
        let last = |test: Test| self.probes.get(&(device.to_string(), test)).filter(|p| p.done);
        if let Some(p) = last(Test::Datagrams) {
            if p.back[0] == 0 && p.sent[0] > 0 {
                return "Reachable, but no datagrams came back: packets cannot cross this link.".into();
            }
            if p.back[1] == 0 && p.sent[1] > 0 {
                return format!("Small packets cross, but full-size ones ({MTU} bytes) are lost on this path.");
            }
        }
        if let Some(p) = last(Test::System) {
            if p.back[0] == 0 && p.sent[0] > 0 {
                return "Packets reach it, but its system did not answer ping: a firewall may block it (Windows does by default).".into();
            }
            return "Everything checks out.".into();
        }
        "Reachable.".into()
    }

    fn start(&mut self) {
        self.refresh();
        let ip = dotted(address(&self.device));
        match tun::open(&ip, 16, &[NETWORK.to_string()], MTU) {
            Ok(()) => {
                self.on = true;
                self.error = None;
                timer::set(REFRESH, 30_000);
            }
            Err(e) => {
                self.on = false;
                self.error = Some(e);
            }
        }
        let _ = store::set_json("on", &self.on);
    }

    fn stop(&mut self) {
        tun::close();
        self.on = false;
        timer::cancel(REFRESH);
        let _ = store::set_json("on", &false);
    }

    /// Keeps the open page refreshing for a while.
    fn watch(&mut self) {
        self.watch_until = ournet_plugin::now() + WATCH_MS;
        if self.selected.is_some() && !self.ticking {
            self.ticking = true;
            timer::set(TICK, 1000);
        }
    }

    fn ping(&mut self, device: &str, full: bool) {
        let id = ournet_plugin::send(device, br#"{"t":"ping"}"#);
        self.pings.insert(id, (device.to_string(), ournet_plugin::now(), full));
        let p = self.ping.entry(device.to_string()).or_default();
        p.result = None;
    }

    fn begin(&mut self, device: &str, test: Test, then_system: bool) {
        self.probes.insert((device.to_string(), test), Probe::new(device, test, then_system));
        self.running = Some((device.to_string(), test));
        self.step();
    }

    /// Sends the next probe of the test under way, or ends it.
    fn step(&mut self) {
        let mine = address(&self.device);
        let Some(key) = self.running.clone() else { return };
        let Some(p) = self.probes.get_mut(&key) else { return };
        if p.next >= p.count() {
            p.done = true;
            self.running = None;
            if p.test == Test::Datagrams && p.then_system && self.on && p.back[0] > 0 {
                self.begin(&key.0, Test::System, false);
            }
            return;
        }
        let seq = p.next;
        p.next += 1;
        let now = ournet_plugin::now();
        let (packet, big) = match p.test {
            Test::Datagrams => {
                let big = seq % 2 == 1;
                let mut d = vec![0u8; if big { MTU as usize } else { SMALL }];
                d[1] = PROBE_PING;
                d[2..4].copy_from_slice(&seq.to_be_bytes());
                (d, big)
            }
            Test::System => (echo(mine, address(&p.device), seq), false),
        };
        p.sent[big as usize] += 1;
        if ournet_plugin::datagram(&p.device, &packet).is_ok() {
            p.out.insert(seq, (now, big));
        } else {
            p.failed += 1;
        }
        let last = p.next >= p.count();
        let gap = match p.test {
            Test::Datagrams => PROBE_GAP_MS,
            Test::System => ECHO_GAP_MS,
        };
        timer::set(PROBE, if last { PROBE_WAIT_MS } else { gap });
    }

    /// Probe [seq] of a [test] came back from [device].
    fn back(&mut self, device: &str, test: Test, seq: u16) {
        let now = ournet_plugin::now();
        if let Some(p) = self.probes.get_mut(&(device.to_string(), test)) {
            if let Some((at, big)) = p.out.remove(&seq) {
                p.back[big as usize] += 1;
                p.rtts.push(now.saturating_sub(at));
            }
        }
    }

    fn refuse(&mut self, device: &str, why: &'static str) {
        self.dropped += 1;
        let s = self.stats.entry(device.to_string()).or_default();
        s.refused += 1;
        s.last_refusal = Some(why);
    }
}

/// The IPv4 source and destination of [packet], if it is one.
fn ends(packet: &[u8]) -> Option<([u8; 4], [u8; 4])> {
    if packet.len() < 20 || packet[0] >> 4 != 4 {
        return None;
    }
    let src = [packet[12], packet[13], packet[14], packet[15]];
    let dst = [packet[16], packet[17], packet[18], packet[19]];
    Some((src, dst))
}

/// The Internet checksum of [data].
fn checksum(data: &[u8]) -> u16 {
    let mut sum: u32 = 0;
    for pair in data.chunks(2) {
        let word = (pair[0] as u32) << 8 | *pair.get(1).unwrap_or(&0) as u32;
        sum += word;
    }
    while sum >> 16 != 0 {
        sum = (sum & 0xffff) + (sum >> 16);
    }
    !(sum as u16)
}

/// An ICMP echo request from [src] to [dst].
fn echo(src: [u8; 4], dst: [u8; 4], seq: u16) -> Vec<u8> {
    let mut icmp = vec![8, 0, 0, 0];
    icmp.extend_from_slice(&ECHO_ID.to_be_bytes());
    icmp.extend_from_slice(&seq.to_be_bytes());
    icmp.extend((0..32u8).map(|i| b'a' + i % 26));
    let c = checksum(&icmp);
    icmp[2..4].copy_from_slice(&c.to_be_bytes());
    let total = (20 + icmp.len()) as u16;
    let mut ip = vec![0x45, 0];
    ip.extend_from_slice(&total.to_be_bytes());
    ip.extend_from_slice(&seq.to_be_bytes());
    ip.extend_from_slice(&[0, 0, 64, 1, 0, 0]);
    ip.extend_from_slice(&src);
    ip.extend_from_slice(&dst);
    let c = checksum(&ip);
    ip[10..12].copy_from_slice(&c.to_be_bytes());
    ip.extend(icmp);
    ip
}

/// The sequence number of [packet] if it is an answer to [echo].
fn echo_reply(packet: &[u8]) -> Option<u16> {
    let ihl = ((*packet.first()? & 0xf) as usize) * 4;
    let icmp = packet.get(ihl..ihl + 8)?;
    let ours = packet[9] == 1 && icmp[0] == 0 && icmp[4..6] == ECHO_ID.to_be_bytes();
    ours.then(|| u16::from_be_bytes([icmp[6], icmp[7]]))
}

impl Plugin for Vpn {
    fn init(&mut self) {
        self.me = ournet_plugin::me();
        self.device = ournet_plugin::this_device();
        self.allowed = store::get_json("allowed").unwrap_or_default();
        // It was on when the app last ran: on again.
        if store::get_json::<bool>("on").unwrap_or(false) {
            self.start();
        }
    }

    fn on_open(&mut self, _surface: &str, _context: Context) {
        self.refresh();
        self.watch();
        self.show();
    }

    fn on_event(&mut self, _surface: &str, name: &str, args: Value) {
        let device = args["device"].as_str().map(String::from);
        match name {
            "toggle" => {
                if self.on {
                    self.stop();
                } else {
                    self.start();
                }
            }
            "allow" => {
                if let Some(person) = args["person"].as_str() {
                    if !self.allowed.remove(person) {
                        self.allowed.insert(person.to_string());
                    }
                    let _ = store::set_json("allowed", &self.allowed);
                }
            }
            "open" => {
                self.selected = device;
                self.watch();
            }
            "back" => self.selected = None,
            "ping" => {
                if let Some(d) = device {
                    self.ping(&d, false);
                }
            }
            "check" => {
                if let Some(d) = device {
                    self.probes.retain(|(k, _), _| *k != d);
                    if self.running.as_ref().is_some_and(|(k, _)| *k == d) {
                        self.running = None;
                        timer::cancel(PROBE);
                    }
                    self.ping(&d, true);
                }
            }
            _ => return,
        }
        self.watch();
        self.show();
    }

    fn on_request(&mut self, device: &str, payload: &[u8]) -> Result<Vec<u8>, String> {
        let request: Value = ournet_plugin::serde_json::from_slice(payload).map_err(|_| "not handled")?;
        if request["t"] != "ping" {
            return Err("not handled".into());
        }
        let allows = self.peer(device).is_some_and(|(_, p)| self.allows(p));
        let s = self.stats.get(device);
        let reply = json!({
            "v": VERSION,
            "on": self.on,
            "address": dotted(address(&self.device)),
            "allows": allows,
            "received": s.map_or(0, |s| s.received),
            "refused": s.map_or(0, |s| s.refused),
            "refusal": s.and_then(|s| s.last_refusal),
        });
        Ok(reply.to_string().into_bytes())
    }

    fn on_reply(&mut self, id: u64, reply: Result<Vec<u8>, String>) {
        let Some((device, at, full)) = self.pings.remove(&id) else { return };
        let now = ournet_plugin::now();
        let p = self.ping.entry(device.clone()).or_default();
        p.at = now;
        p.older = false;
        p.report = None;
        match reply {
            Ok(body) => {
                p.result = Some(Ok(now.saturating_sub(at)));
                let v: Value = ournet_plugin::serde_json::from_slice(&body).unwrap_or(Value::Null);
                let text = |k: &str| v[k].as_str().unwrap_or_default().to_string();
                p.report = Some(Report {
                    version: text("v"),
                    on: v["on"] == true,
                    address: text("address"),
                    allows: v["allows"] == true,
                    received: v["received"].as_u64().unwrap_or(0),
                    refused: v["refused"].as_u64().unwrap_or(0),
                    last_refusal: v["refusal"].as_str().map(String::from),
                });
            }
            // An older version: reachable, but it has no checks.
            Err(e) if e.contains("not handled") => {
                p.result = Some(Ok(now.saturating_sub(at)));
                p.older = true;
            }
            Err(e) => p.result = Some(Err(e)),
        }
        let go_on = full && p.report.as_ref().is_some_and(|r| r.on) && matches!(p.result, Some(Ok(_)));
        if go_on && self.running.is_none() {
            self.begin(&device, Test::Datagrams, true);
        }
        if self.selected.as_deref() == Some(device.as_str()) {
            self.show();
        }
    }

    fn on_timer(&mut self, token: u64) {
        match token {
            REFRESH => {
                // Devices join and leave: their addresses are learned again.
                self.refresh();
                self.show();
                if self.on {
                    timer::set(REFRESH, 30_000);
                }
            }
            TICK => {
                let now = ournet_plugin::now();
                for s in self.stats.values_mut() {
                    let (at, out, inn) = s.mark;
                    if at > 0 && now > at {
                        let secs = (now - at) as f64 / 1000.0;
                        s.rate = ((s.sent_bytes - out) as f64 / secs, (s.received_bytes - inn) as f64 / secs);
                    }
                    s.mark = (now, s.sent_bytes, s.received_bytes);
                }
                self.ticking = self.selected.is_some() && now < self.watch_until;
                if self.ticking {
                    self.show();
                    timer::set(TICK, 1000);
                }
            }
            PROBE => {
                self.step();
                if self.selected.is_some() {
                    self.show();
                }
            }
            _ => {}
        }
    }

    fn on_packet(&mut self, packet: &[u8]) {
        let Some((_, dst)) = ends(packet) else { return };
        let Some(peer) = self.peers.get(&dst) else {
            self.dropped += 1;
            return;
        };
        let (device, allowed) = (peer.device.clone(), self.allows(peer));
        let s = self.stats.entry(device.clone()).or_default();
        if !allowed {
            s.held += 1;
            s.last_error = Some("you have not allowed them".into());
            self.dropped += 1;
            return;
        }
        match ournet_plugin::datagram(&device, packet) {
            Ok(()) => {
                self.sent += 1;
                s.sent += 1;
                s.sent_bytes += packet.len() as u64;
                s.last_sent = ournet_plugin::now();
            }
            Err(e) => {
                self.dropped += 1;
                s.held += 1;
                s.last_error = Some(e);
            }
        }
    }

    fn on_datagram(&mut self, device: &str, data: &[u8]) {
        // Probes: answered for any device that runs this plugin.
        if data.len() >= 4 && data[0] == 0 {
            let seq = u16::from_be_bytes([data[2], data[3]]);
            match data[1] {
                PROBE_PING if self.peer(device).is_some() => {
                    let mut pong = data.to_vec();
                    pong[1] = PROBE_PONG;
                    let _ = ournet_plugin::datagram(device, &pong);
                }
                PROBE_PONG => self.back(device, Test::Datagrams, seq),
                _ => {}
            }
            return;
        }
        let mine = address(&self.device);
        let Some((src, dst)) = ends(data) else {
            return self.refuse(device, "not an IPv4 packet");
        };
        let why = if !self.on {
            Some("the network is off here")
        } else if dst != mine {
            Some("addressed to another device")
        } else if src != address(device) {
            Some("from an address not its own")
        } else if !self.peers.get(&src).is_some_and(|p| p.device == device) {
            Some("from a device not known here")
        } else if !self.peers.get(&src).is_some_and(|p| self.allows(p)) {
            Some("not allowed")
        } else {
            None
        };
        if let Some(why) = why {
            return self.refuse(device, why);
        }
        // An answer to this device's system ping: it is not for the system.
        let probing = self
            .probes
            .get(&(device.to_string(), Test::System))
            .is_some_and(|p| !p.out.is_empty());
        if let Some(seq) = echo_reply(data).filter(|_| probing) {
            self.back(device, Test::System, seq);
        } else {
            tun::write(data);
        }
        self.received += 1;
        let s = self.stats.entry(device.to_string()).or_default();
        s.received += 1;
        s.received_bytes += data.len() as u64;
        s.last_received = ournet_plugin::now();
    }
}

ournet_plugin::plugin!(Vpn);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn echo_has_valid_checksums() {
        let p = echo([10, 77, 1, 2], [10, 77, 3, 4], 7);
        assert_eq!(checksum(&p[..20]), 0);
        assert_eq!(checksum(&p[20..]), 0);
        assert_eq!(ends(&p), Some(([10, 77, 1, 2], [10, 77, 3, 4])));
        // The reply a system sends: type 0, same ID and sequence.
        let mut reply = p.clone();
        reply[20] = 0;
        assert_eq!(echo_reply(&reply), Some(7));
        assert_eq!(echo_reply(&p), None);
    }
}
