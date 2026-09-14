# Native mobile integration

`iroh_mobile` contains Android integration, cargokit, and Rust sources from
https://github.com/snowpinelabs/iroh_dart at tag v1.0.3, commit
`3278040df0be9eb7b787034525998bd3a5800b95`. The Apache-2.0 license is retained.

The local pubspec registers Android only. Desktop uses the published
`iroh_quic` 1.0.3 package and verified prebuilt library, avoiding Rust builds.
Application logic does not live here. Upgrade the Dart binding, native binary,
mobile source and flutter_rust_bridge compatibility together.

The ignored `iroh_dart` directory is a temporary upstream reference checkout.
