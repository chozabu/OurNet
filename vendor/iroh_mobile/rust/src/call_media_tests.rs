//! Halves, the source filter, and two in-process endpoints carrying RTP-sized packets between
//! their shims. Run with `cargo test --release call_media`.

use std::{future::Future, net::Ipv4Addr, time::Duration};

use iroh::{
    address_lookup::{EndpointData, EndpointInfo, MemoryLookup},
    endpoint::{presets, QuicTransportConfig},
    Endpoint, TransportAddr,
};

use super::*;
use crate::friend_relay::{install, Timings};

fn run<F: Future>(f: F) -> F::Output {
    rt().block_on(f)
}

#[test]
fn small_packets_go_whole() {
    let frames = frame(&[1, 2, 3], 1200, 7).unwrap();
    assert_eq!(frames.len(), 1);
    assert_eq!(
        parse(frames[0].clone()),
        Some(Datagram::Whole(Bytes::from_static(&[1, 2, 3])))
    );
    // Exactly fits: kind byte plus packet.
    assert_eq!(frame(&[0u8; 1199], 1200, 0).unwrap().len(), 1);
}

#[test]
fn large_packets_go_as_halves_and_join() {
    let packet: Vec<u8> = (0..1201u32).map(|i| i as u8).collect();
    let frames = frame(&packet, 1160, 42).unwrap();
    assert_eq!(frames.len(), 2);
    assert!(frames.iter().all(|f| f.len() <= 1160));
    let mut halves = Halves::default();
    let now = Instant::now();
    // Out of order still joins.
    let mut joined = None;
    for f in frames.iter().rev() {
        let Some(Datagram::Half { id, index, half }) = parse(f.clone()) else {
            panic!("not a half");
        };
        assert_eq!(id, 42);
        joined = halves.take(id, index, half, now);
    }
    assert_eq!(joined.unwrap().as_ref(), packet.as_slice());
    assert_eq!(halves.dropped, 0);
}

#[test]
fn too_large_or_empty_packets_are_refused() {
    assert!(frame(&[], 1200, 0).is_none());
    assert!(frame(&[0u8; 2000], 1000, 0).is_none());
    // No datagrams at all (the peer does not take them).
    assert!(frame(&[1], 0, 0).is_none());
}

#[test]
fn unknown_datagrams_are_ignored() {
    assert_eq!(parse(Bytes::new()), None);
    assert_eq!(parse(Bytes::from_static(&[0])), None);
    assert_eq!(parse(Bytes::from_static(&[1, 0, 0, 2, 9])), None);
    assert_eq!(parse(Bytes::from_static(&[9, 1, 2])), None);
    assert_eq!(parse(Bytes::from_static(&[2])), Some(Datagram::KeepAlive));
}

#[test]
fn incomplete_halves_are_dropped() {
    let mut halves = Halves::default();
    let t0 = Instant::now();
    assert!(halves.take(1, 0, Bytes::from_static(b"a"), t0).is_none());
    // Its partner is too late: the first half has expired when another arrives.
    let later = t0 + Duration::from_secs(1);
    assert!(halves.take(2, 0, Bytes::from_static(b"b"), later).is_none());
    assert_eq!(halves.dropped, 1);
    assert!(halves.take(1, 1, Bytes::from_static(b"c"), later).is_none());
    // The same half twice is not a packet.
    assert!(halves.take(2, 0, Bytes::from_static(b"b"), later).is_none());
    assert_eq!(halves.dropped, 2);
    // Many unpaired halves stay bounded.
    for id in 100..300 {
        halves.take(id, 0, Bytes::from_static(b"x"), later);
    }
    assert!(halves.parts.len() <= MAX_HALVES);
}

#[test]
fn only_the_webrtc_socket_is_answered() {
    let own: IpAddr = Ipv4Addr::new(192, 168, 1, 5).into();
    let webrtc = SocketAddr::new(own, 50000);
    let other_socket = SocketAddr::new(own, 50001);
    let neighbour = SocketAddr::new(Ipv4Addr::new(192, 168, 1, 6).into(), 50000);
    let mut learned = None;
    let t0 = Instant::now();
    // Another host on the network never gets in, even first.
    assert!(!source_ok(own, &mut learned, neighbour, t0));
    assert!(learned.is_none());
    assert!(source_ok(own, &mut learned, webrtc, t0));
    assert!(!source_ok(own, &mut learned, other_socket, t0));
    assert!(source_ok(
        own,
        &mut learned,
        webrtc,
        t0 + Duration::from_secs(2)
    ));
    // Once the first socket has been quiet a while, a new one (after an ICE restart) takes over.
    let later = t0 + Duration::from_secs(2) + SOURCE_IDLE;
    assert!(source_ok(own, &mut learned, other_socket, later));
    assert!(!source_ok(own, &mut learned, webrtc, later));
}

struct Node {
    ep: Endpoint,
    relay: Arc<FriendRelay>,
    lookup: MemoryLookup,
}

/// An endpoint on IPv4 loopback whose path MTU stays at QUIC's minimum, like a relay path.
async fn node() -> Node {
    let lookup = MemoryLookup::new();
    let mut alpns = vec![b"ournet/test".to_vec()];
    let tc = QuicTransportConfig::builder().mtu_discovery_config(None);
    let b = Endpoint::builder(presets::Minimal)
        .transport_config(tc.build())
        .address_lookup(lookup.clone())
        .clear_ip_transports()
        .bind_addr("127.0.0.1:0")
        .unwrap();
    let (b, relay) = install(b, &mut alpns, Timings::default());
    let ep = b.alpns(alpns).bind().await.unwrap();
    relay.bound(ep.clone());
    let accept_ep = ep.clone();
    let accept_relay = relay.clone();
    tokio::spawn(async move {
        while let Some(incoming) = accept_ep.accept().await {
            let relay = accept_relay.clone();
            tokio::spawn(async move {
                let Ok(conn) = incoming.await else { return };
                if conn.alpn() == MEDIA_ALPN {
                    relay.media().accept(conn);
                }
            });
        }
    });
    Node { ep, relay, lookup }
}

impl Node {
    fn knows(&self, other: &Node) {
        let data: EndpointData = other
            .ep
            .bound_sockets()
            .into_iter()
            .map(TransportAddr::Ip)
            .collect();
        self.lookup
            .add_endpoint_info(EndpointInfo::from_parts(other.ep.id(), data));
    }
}

async fn wait_for(what: &str, mut ok: impl FnMut() -> bool) {
    for _ in 0..200 {
        if ok() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("timed out waiting for {what}");
}

/// Sends `packet` from `from` to its shim until `to` receives it.
async fn exchange(from: &UdpSocket, shim: SocketAddr, to: &UdpSocket, packet: &[u8]) {
    let mut buf = [0u8; 2048];
    for _ in 0..100 {
        from.send_to(packet, shim).await.unwrap();
        let wait = Duration::from_millis(100);
        while let Ok(Ok((n, _))) = tokio::time::timeout(wait, to.recv_from(&mut buf)).await {
            if &buf[..n] == packet {
                return;
            }
        }
    }
    panic!("nothing arrived");
}

async fn socket() -> UdpSocket {
    UdpSocket::bind("127.0.0.1:0").await.unwrap()
}

#[test]
fn shims_carry_rtp_sized_packets_both_ways() {
    run(async {
        let a = node().await;
        let b = node().await;
        a.knows(&b);
        b.knows(&a);
        a.relay.set_allow([b.ep.id()].into());
        b.relay.set_allow([a.ep.id()].into());
        let loopback: IpAddr = Ipv4Addr::LOCALHOST.into();
        // B's shim starts first, as the callee's does; A's media connection is kept for it
        // either way.
        let port_b = b.relay.media().start(a.ep.id(), loopback).unwrap();
        let port_a = a.relay.media().start(b.ep.id(), loopback).unwrap();
        let shim_a = SocketAddr::new(loopback, port_a);
        let shim_b = SocketAddr::new(loopback, port_b);
        wait_for("media connection", || {
            a.relay.media().stats_json().contains("\"connected\":1")
                && b.relay.media().stats_json().contains("\"connected\":1")
        })
        .await;

        // Each side's "WebRTC" socket: what it sends to its own shim reaches the other.
        let wa = socket().await;
        let wb = socket().await;
        // B must have sent once for its shim to know where to deliver.
        wb.send_to(b"hello", shim_b).await.unwrap();
        exchange(&wa, shim_a, &wb, b"ice check").await;

        // RTP-sized: over the 1200-byte minimum path MTU, so it goes as two halves.
        let rtp: Vec<u8> = (0..1200u32).map(|i| (i * 7) as u8).collect();
        exchange(&wa, shim_a, &wb, &rtp).await;
        exchange(&wb, shim_b, &wa, &rtp).await;
        let stats = a.relay.media().stats_json();
        assert!(!stats.contains("\"halved\":0"), "{stats}");

        // Another socket on the same address is ignored while WebRTC's is active.
        let stranger = socket().await;
        stranger.send_to(b"spoof", shim_a).await.unwrap();
        wait_for("foreign packet counted", || {
            !a.relay.media().stats_json().contains("\"foreign\":0")
        })
        .await;

        // Rebinding keeps the connection and gives a new port.
        let moved = a.relay.media().start(b.ep.id(), loopback).unwrap();
        assert_ne!(moved, port_a);
        let shim_a = SocketAddr::new(loopback, moved);
        exchange(&wa, shim_a, &wb, b"after rebind").await;

        assert!(a.relay.media().stop(&b.ep.id()));
        assert!(b.relay.media().stop(&a.ep.id()));
        assert!(a.relay.media().stats_json().contains("\"shims\":0"));
        a.ep.close().await;
        b.ep.close().await;
    });
}

#[test]
fn media_connections_from_strangers_are_refused() {
    run(async {
        let a = node().await;
        let b = node().await;
        a.knows(&b);
        // B has no shim for A and A is not its friend.
        let conn = tokio::time::timeout(
            Duration::from_secs(5),
            a.ep.connect(EndpointAddr::new(b.ep.id()), MEDIA_ALPN),
        )
        .await
        .unwrap()
        .unwrap();
        tokio::time::timeout(Duration::from_secs(5), conn.closed())
            .await
            .unwrap();
        assert!(b.relay.media().stats_json().contains("\"refused\":1"));
        a.ep.close().await;
        b.ep.close().await;
    });
}
