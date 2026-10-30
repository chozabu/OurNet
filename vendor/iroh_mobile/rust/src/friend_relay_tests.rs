//! Three in-process endpoints, A and C reaching each other through their mutual friend F.
//! Run with `cargo test --release friend_relay` (debug builds work, more slowly).

use std::{collections::HashSet, future::Future, sync::atomic::Ordering::Relaxed, time::Duration};

use iroh::{
    address_lookup::{EndpointData, EndpointInfo, MemoryLookup},
    endpoint::{presets, QuicTransportConfig},
    Endpoint, EndpointAddr, TransportAddr,
};

use super::*;

const APP: &[u8] = b"ournet/test";

fn run<F: Future>(f: F) -> F::Output {
    rt().block_on(f)
}

fn quick() -> Timings {
    Timings {
        link_idle: Duration::from_secs(3),
        direct_stable: Duration::from_secs(1),
        no_route: Duration::from_secs(30),
        redial: Duration::from_millis(500),
        half_ttl: Duration::from_secs(2),
        sweep: Duration::from_millis(250),
        report_every: Duration::from_secs(1),
        report_ttl: Duration::from_secs(3),
        private_reports: true,
    }
}

struct Node {
    ep: Endpoint,
    relay: Arc<FriendRelay>,
    lookup: MemoryLookup,
}

async fn node(binds: &[&str], timings: Timings, pmtud: bool) -> Node {
    let lookup = MemoryLookup::new();
    let mut alpns = vec![APP.to_vec()];
    let mut tc = QuicTransportConfig::builder();
    if !pmtud {
        tc = tc.mtu_discovery_config(None);
    }
    let mut b = Endpoint::builder(presets::Minimal)
        .transport_config(tc.build())
        .address_lookup(lookup.clone())
        .clear_ip_transports();
    for a in binds {
        b = b.bind_addr(*a).unwrap();
    }
    let (b, relay) = install(b, &mut alpns, timings);
    let ep = b.alpns(alpns).bind().await.unwrap();
    relay.bound(ep.clone());
    let accept_ep = ep.clone();
    let accept_relay = relay.clone();
    tokio::spawn(async move {
        while let Some(incoming) = accept_ep.accept().await {
            let relay = accept_relay.clone();
            tokio::spawn(async move {
                let Ok(conn) = incoming.await else { return };
                if conn.alpn() == FWD_ALPN {
                    relay.accept_link(conn);
                } else {
                    relay.watch(&conn);
                    serve(conn).await;
                }
            });
        }
    });
    Node { ep, relay, lookup }
}

/// Each bi stream is read to its end and answered with its length (u64 LE).
async fn serve(conn: Connection) {
    while let Ok((mut send, mut recv)) = conn.accept_bi().await {
        tokio::spawn(async move {
            let mut total = 0u64;
            while let Ok(Some(chunk)) = recv.read_chunk(usize::MAX).await {
                total += chunk.len() as u64;
            }
            let _ = send.write_all(&total.to_le_bytes()).await;
            let _ = send.finish();
        });
    }
}

async fn request(conn: &Connection, len: usize) -> anyhow::Result<u64> {
    let (mut send, mut recv) = conn.open_bi().await?;
    send.write_all(&vec![7u8; len]).await?;
    send.finish()?;
    let resp = recv.read_to_end(8).await?;
    Ok(u64::from_le_bytes(resp.as_slice().try_into()?))
}

impl Node {
    fn id(&self) -> EndpointId {
        self.ep.id()
    }

    /// Lets this node's lookup find `other` at its bound sockets (on loopback when bound to
    /// the unspecified address).
    fn knows(&self, other: &Node) {
        let data: EndpointData = other
            .ep
            .bound_sockets()
            .into_iter()
            .map(|mut s| {
                if s.ip().is_unspecified() {
                    s.set_ip(std::net::Ipv4Addr::LOCALHOST.into());
                }
                TransportAddr::Ip(s)
            })
            .collect();
        self.lookup
            .add_endpoint_info(EndpointInfo::from_parts(other.id(), data));
    }

    fn friends(&self, others: &[&Node]) {
        self.relay
            .set_allow(others.iter().map(|n| n.id()).collect());
    }

    /// Dials `other` with only the friend routes it was given.
    async fn dial_via(&self, other: &Node, friends: &[&Node]) -> anyhow::Result<Connection> {
        self.relay
            .set_routes(other.id(), friends.iter().map(|n| n.id()).collect());
        let mut addr = EndpointAddr::new(other.id());
        self.relay.add_routes(&mut addr);
        let conn =
            tokio::time::timeout(Duration::from_secs(8), self.ep.connect(addr, APP)).await??;
        self.relay.watch(&conn);
        Ok(conn)
    }

    fn links(&self) -> usize {
        self.relay.links.lock().unwrap().len()
    }
}

fn selected(conn: &Connection) -> Option<TransportAddr> {
    conn.paths()
        .iter()
        .find(|p| p.is_selected())
        .map(|p| p.remote_addr().clone())
}

/// A on IPv4 loopback only, C on IPv6 loopback only, F on both: A and C can only meet via F.
async fn isolated(timings: Timings, pmtud: bool) -> (Node, Node, Node) {
    let a = node(&["127.0.0.1:0"], timings, pmtud).await;
    let f = node(&["127.0.0.1:0", "[::1]:0"], timings, pmtud).await;
    let c = node(&["[::1]:0"], timings, pmtud).await;
    a.knows(&f);
    c.knows(&f);
    f.knows(&a);
    f.knows(&c);
    a.friends(&[&f]);
    c.friends(&[&f]);
    f.friends(&[&a, &c]);
    f.relay.set_policy(true, 0, 0);
    (a, f, c)
}

#[test]
fn connects_through_a_friend_only() {
    run(async {
        let (a, f, c) = isolated(quick(), true).await;
        let conn = a.dial_via(&c, &[&f]).await.expect("dial via F");
        assert!(matches!(selected(&conn), Some(TransportAddr::Custom(_))));
        assert_eq!(request(&conn, 256 << 10).await.unwrap(), 256 << 10);
        assert!(f.relay.stats.forwarded_bytes.load(Relaxed) > 256 << 10);
        assert!(c.relay.stats.received.load(Relaxed) > 0);
        let json = f.relay.stats_json();
        assert!(json.contains(&hex(a.id().as_bytes())), "{json}");
        assert!(json.contains("\"relay\":true"), "{json}");
    });
}

#[test]
fn halves_packets_a_link_cannot_carry_whole() {
    run(async {
        // No path MTU discovery: links carry ~1160-byte datagrams, less than a QUIC Initial.
        let (a, f, c) = isolated(quick(), false).await;
        let conn = a.dial_via(&c, &[&f]).await.expect("dial via F in halves");
        assert_eq!(request(&conn, 64 << 10).await.unwrap(), 64 << 10);
        assert!(a.relay.stats.halved.load(Relaxed) > 0);
    });
}

#[test]
fn refuses_when_not_relaying_and_says_so() {
    run(async {
        let (a, f, c) = isolated(quick(), true).await;
        f.relay.set_policy(false, 0, 0);
        assert!(a.dial_via(&c, &[&f]).await.is_err());
        assert!(f.relay.stats.denied.load(Relaxed) > 0);
        assert!(f.relay.stats.forwarded.load(Relaxed) == 0);
        // A heard "no route" and stops offering F for C.
        let mut addr = EndpointAddr::new(c.id());
        a.relay.add_routes(&mut addr);
        assert!(addr.addrs.is_empty());
    });
}

#[test]
fn refuses_links_from_strangers() {
    run(async {
        let (a, f, c) = isolated(quick(), true).await;
        f.friends(&[&c]);
        assert!(a.dial_via(&c, &[&f]).await.is_err());
        assert_eq!(a.links(), 0);
        assert_eq!(f.relay.stats.forwarded.load(Relaxed), 0);
    });
}

#[test]
fn moves_to_direct_then_drops_the_friend_path_and_link() {
    run(async {
        let t = quick();
        let a = node(&["127.0.0.1:0"], t, true).await;
        let f = node(&["127.0.0.1:0"], t, true).await;
        let c = node(&["127.0.0.1:0"], t, true).await;
        // A and C only know of F; holepunching through F finds the direct path.
        a.knows(&f);
        c.knows(&f);
        f.knows(&a);
        f.knows(&c);
        a.friends(&[&f]);
        c.friends(&[&f]);
        f.friends(&[&a, &c]);
        f.relay.set_policy(true, 0, 0);
        let conn = a.dial_via(&c, &[&f]).await.expect("dial via F");
        let start = Instant::now();
        while !matches!(selected(&conn), Some(TransportAddr::Ip(_))) {
            assert!(start.elapsed() < Duration::from_secs(3), "no direct path");
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        // Friend path: abandoned once direct is stable and the path idles (15 s in iroh);
        // then the link idles out.
        let start = Instant::now();
        loop {
            request(&conn, 1).await.unwrap();
            let friend_path = conn
                .paths()
                .iter()
                .any(|p| matches!(p.remote_addr(), TransportAddr::Custom(_)));
            if !friend_path && a.links() == 0 && c.links() == 0 {
                break;
            }
            assert!(
                start.elapsed() < Duration::from_secs(30),
                "friend path {friend_path}, links A {} C {}",
                a.links(),
                c.links()
            );
            tokio::time::sleep(Duration::from_millis(500)).await;
        }
        assert!(matches!(selected(&conn), Some(TransportAddr::Ip(_))));
    });
}

#[test]
fn limits_each_sender() {
    run(async {
        let (a, f, c) = isolated(quick(), true).await;
        let conn = a.dial_via(&c, &[&f]).await.expect("dial via F");
        // 64 KiB/s with a 128 KiB burst: 512 KiB takes several seconds.
        f.relay.set_policy(true, 64 << 10, 0);
        let start = Instant::now();
        assert_eq!(request(&conn, 512 << 10).await.unwrap(), 512 << 10);
        assert!(
            start.elapsed() > Duration::from_secs(3),
            "{:?}",
            start.elapsed()
        );
        assert!(f.relay.stats.limited.load(Relaxed) > 0);
        // A daily allowance already spent: nothing more goes through.
        f.relay.set_policy(true, 0, 1 << 20);
        let more = tokio::time::timeout(Duration::from_secs(5), request(&conn, 2 << 20)).await;
        assert!(more.is_err() || more.unwrap().is_err());
    });
}

#[test]
fn restores_todays_usage_only() {
    run(async {
        let (a, f, c) = isolated(quick(), true).await;
        f.relay.set_policy(true, 0, 1 << 20);
        let today = utc_day();
        f.relay.seed_usage(today - 1, [(c.id(), 1 << 20)]);
        f.relay.seed_usage(today, [(a.id(), 1 << 20)]);
        let json = f.relay.stats_json();
        assert!(json.contains(&format!("\"day\":{today}")), "{json}");
        assert!(!json.contains(&hex(c.id().as_bytes())), "{json}");
        // A's allowance for today is already spent.
        let conn = a.dial_via(&c, &[&f]).await;
        assert!(conn.is_err());
        assert!(f.relay.stats.limited.load(Relaxed) > 0);
    });
}

#[test]
fn keeps_one_of_two_crossing_links() {
    run(async {
        let t = quick();
        let a = node(&["127.0.0.1:0"], t, true).await;
        let f = node(&["127.0.0.1:0"], t, true).await;
        a.knows(&f);
        f.knows(&a);
        a.friends(&[&f]);
        f.friends(&[&a]);
        a.relay.ensure_link(f.id());
        f.relay.ensure_link(a.id());
        let start = Instant::now();
        loop {
            let (la, lf) = (a.relay.link(&f.id()), f.relay.link(&a.id()));
            if let (Some((ca, _)), Some((cf, _))) = (&la, &lf) {
                // Both ends keep the same connection (its ids are per side, so compare
                // which side dialled it).
                let a_dialled = ca.side().is_client();
                let f_dialled = cf.side().is_client();
                if a_dialled != f_dialled && start.elapsed() > Duration::from_secs(1) {
                    break;
                }
            }
            assert!(
                start.elapsed() < Duration::from_secs(5),
                "links did not settle"
            );
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    });
}

/// The loopback address a node bound to 0.0.0.0 is seen at by friends on loopback. iroh does
/// not advertise loopback while the machine has another interface, so only friends' reports
/// tell anyone about it.
fn seen_at(n: &Node) -> std::net::SocketAddr {
    let port = n.ep.bound_sockets()[0].port();
    std::net::SocketAddr::new(std::net::Ipv4Addr::LOCALHOST.into(), port)
}

fn external(n: &Node) -> HashSet<std::net::SocketAddr> {
    n.relay.external.lock().unwrap().clone()
}

fn advertised(n: &Node, addr: std::net::SocketAddr) -> bool {
    n.ep.addr().ip_addrs().any(|a| *a == addr)
}

async fn until(what: &str, mut check: impl FnMut() -> bool) {
    let start = Instant::now();
    while !check() {
        assert!(start.elapsed() < Duration::from_secs(10), "{what}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

#[test]
fn learns_its_address_from_two_friends_and_holepunches_to_it() {
    run(async {
        let t = quick();
        let a = node(&["0.0.0.0:0"], t, true).await;
        let f1 = node(&["127.0.0.1:0"], t, true).await;
        let f2 = node(&["127.0.0.1:0"], t, true).await;
        let c = node(&["0.0.0.0:0"], t, true).await;
        for f in [&f1, &f2] {
            a.knows(f);
            c.knows(f);
            f.knows(&a);
            f.knows(&c);
            f.friends(&[&a, &c]);
            f.relay.set_policy(true, 0, 0);
        }
        a.friends(&[&f1, &f2]);
        c.friends(&[&f1, &f2]);
        let (a_at, c_at) = (seen_at(&a), seen_at(&c));
        assert!(
            !advertised(&a, a_at) && !advertised(&c, c_at),
            "loopback already advertised"
        );

        let conn = a.dial_via(&c, &[&f1, &f2]).await.expect("dial via friends");
        let opened = Arc::new(Mutex::new(Vec::new()));
        {
            let opened = opened.clone();
            let mut events = conn.path_events();
            tokio::spawn(async move {
                while let Some(e) = events.next().await {
                    if let PathEvent::Opened { remote_addr, .. } = e {
                        opened.lock().unwrap().push(remote_addr);
                    }
                }
            });
        }
        // Both friends report; A and C each take the address they agree on, and iroh
        // advertises it.
        until("A's address agreed", || external(&a).contains(&a_at)).await;
        until("C's address agreed", || external(&c).contains(&c_at)).await;
        until("A advertises it", || advertised(&a, a_at)).await;
        until("C advertises it", || advertised(&c, c_at)).await;
        // Holepunching reaches C at the address only its friends told it.
        let reached = |conn: &Connection| {
            conn.paths()
                .iter()
                .any(|p| matches!(p.remote_addr(), TransportAddr::Ip(x) if *x == c_at))
                || opened
                    .lock()
                    .unwrap()
                    .iter()
                    .any(|a| matches!(a, TransportAddr::Ip(x) if *x == c_at))
        };
        let start = Instant::now();
        while !reached(&conn) {
            let paths: Vec<_> = conn
                .paths()
                .iter()
                .map(|p| p.remote_addr().clone())
                .collect();
            assert!(
                start.elapsed() < Duration::from_secs(10),
                "no path to {c_at}; paths {paths:?}, opened {:?}, C advertises {:?}",
                opened.lock().unwrap(),
                c.ep.addr()
            );
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        until("a direct path selected", || {
            matches!(selected(&conn), Some(TransportAddr::Ip(_)))
        })
        .await;
        assert_eq!(request(&conn, 64 << 10).await.unwrap(), 64 << 10);
        assert!(f1.relay.stats.reports_sent.load(Relaxed) > 0);
        assert!(a.relay.stats_json().contains(&format!("\"{a_at}\"")));

        // One friend gone: the address is no longer agreed, and is withdrawn.
        f2.relay.closed();
        f2.ep.close().await;
        until("A withdraws it", || {
            external(&a).is_empty() && !advertised(&a, a_at)
        })
        .await;
    });
}

#[test]
fn one_friends_report_is_not_enough() {
    run(async {
        let t = quick();
        let a = node(&["0.0.0.0:0"], t, true).await;
        let f = node(&["127.0.0.1:0"], t, true).await;
        let c = node(&["0.0.0.0:0"], t, true).await;
        a.knows(&f);
        c.knows(&f);
        f.knows(&a);
        f.knows(&c);
        a.friends(&[&f]);
        c.friends(&[&f]);
        f.friends(&[&a, &c]);
        f.relay.set_policy(true, 0, 0);
        let _conn = a.dial_via(&c, &[&f]).await.expect("dial via F");
        until("a report", || a.relay.stats.reports_taken.load(Relaxed) > 0).await;
        tokio::time::sleep(Duration::from_secs(1)).await;
        assert!(external(&a).is_empty());
        assert!(!advertised(&a, seen_at(&a)));
    });
}

#[test]
fn only_public_reports_count_outside_tests() {
    let p = |s: &str| public(&s.parse().unwrap());
    assert!(p("81.2.3.4"));
    assert!(p("2001:db8::1"));
    for s in [
        "10.0.0.1",
        "192.168.1.1",
        "172.16.0.1",
        "100.64.0.1",
        "127.0.0.1",
        "169.254.1.1",
        "0.0.0.0",
        "224.0.0.1",
        "::1",
        "fe80::1",
        "fd00::1",
        "::ffff:10.0.0.1",
    ] {
        assert!(!p(s), "{s}");
    }
}

#[test]
fn ranks_direct_then_friend_then_relay() {
    assert_eq!(tier(&AddrKind::IpV4), 0);
    assert_eq!(tier(&AddrKind::IpV6), 0);
    assert_eq!(tier(&AddrKind::Custom(TRANSPORT_ID)), 1);
    assert_eq!(tier(&AddrKind::Relay), 2);
    assert_eq!(tier(&AddrKind::Custom(0x20)), 0);
}

#[test]
fn addresses_round_trip() {
    let a = iroh::SecretKey::from([1u8; 32]).public();
    let b = iroh::SecretKey::from([2u8; 32]).public();
    assert_eq!(parse_via(&via(a, b)), Some((a, b)));
    assert_eq!(parse_via(&CustomAddr::from_parts(0x20, &[0; 64])), None);
}

#[test]
fn debug_format_dart_parses() {
    let a = iroh::SecretKey::from([1u8; 32]).public();
    let addr = TransportAddr::Custom(via(a, a));
    let text = format!("{addr:?}");
    // transport/lib/src/peer_path.dart reads this rendering from path events.
    let hex = hex(a.as_bytes());
    assert_eq!(
        text,
        format!("Custom(CustomAddr {{ id: 1330529874, data: [{hex}{hex}] }})")
    );
}
