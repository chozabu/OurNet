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

use std::collections::{BTreeMap, BTreeSet};

use ournet_plugin::{json, store, timer, tun, ui, Context, Plugin, Value};

const SURFACE: &str = "Vpn";
/// Datagrams carry at most 1100 bytes: the interface's packets fit them.
const MTU: u16 = 1100;
const NETWORK: &str = "10.77.0.0/16";
const REFRESH: u64 = 1;

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

struct Peer {
    person: String,
    device: String,
    name: String,
    online: bool,
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

    fn show(&self) {
        let peers: Vec<Value> = self
            .peers
            .iter()
            .map(|(ip, p)| {
                let own = p.person == self.me;
                json!({
                    "person": p.person,
                    "device": if p.name.is_empty() { "a device" } else { p.name.as_str() },
                    "ip": dotted(*ip),
                    "own": own,
                    "state": match (self.allows(p), p.online) {
                        (false, _) => "not allowed",
                        (true, true) => "online",
                        (true, false) => "offline",
                    },
                    "allow": if self.allows(p) { "Allowed" } else { "Allow" },
                })
            })
            .collect();
        let status = match (&self.error, self.on) {
            (Some(e), _) => format!("Not running: {e}"),
            (None, true) => format!("On: {NETWORK} goes to your devices and allowed friends"),
            (None, false) => "Off".into(),
        };
        ui::update(
            SURFACE,
            &json!({
                "action": if self.on { "Turn off" } else { "Turn on" },
                "status": status,
                "address": format!("This device: {}", dotted(address(&self.device))),
                "traffic": format!("{} packets sent · {} received · {} refused", self.sent, self.received, self.dropped),
                "nobody": peers.is_empty(),
                "peers": peers,
            }),
        );
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
        self.show();
    }

    fn on_event(&mut self, _surface: &str, name: &str, args: Value) {
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
            _ => return,
        }
        self.show();
    }

    fn on_timer(&mut self, _token: u64) {
        // Devices join and leave: their addresses are learned again.
        self.refresh();
        self.show();
        if self.on {
            timer::set(REFRESH, 30_000);
        }
    }

    fn on_packet(&mut self, packet: &[u8]) {
        let Some((_, dst)) = ends(packet) else { return };
        match self.peers.get(&dst) {
            Some(peer) if self.allows(peer) => {
                if ournet_plugin::datagram(&peer.device, packet).is_ok() {
                    self.sent += 1;
                } else {
                    self.dropped += 1;
                }
            }
            _ => self.dropped += 1,
        }
    }

    fn on_datagram(&mut self, device: &str, data: &[u8]) {
        let mine = address(&self.device);
        let ok = self.on
            && ends(data).is_some_and(|(src, dst)| {
                dst == mine
                    && src == address(device)
                    && self.peers.get(&src).is_some_and(|p| p.device == device && self.allows(p))
            });
        if ok {
            tun::write(data);
            self.received += 1;
        } else {
            self.dropped += 1;
        }
    }
}

ournet_plugin::plugin!(Vpn);
