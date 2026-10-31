//! `irohdart-ffi` - owned flutter_rust_bridge wrapper around the iroh 1.0 P2P core.
//!
//! This crate is the single Rust dependency of the `iroh_quic` Flutter plugin. It depends on the
//! `iroh` crate directly and exposes a Dart-shaped surface through FRB.

#[cfg(target_os = "android")]
mod android;
pub mod api;
#[cfg(feature = "friend-relay")]
pub mod call_media;
mod frb_generated;
#[cfg(feature = "friend-relay")]
pub mod friend_relay;
mod runtime;
