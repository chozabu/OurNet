# Native mobile integration

`iroh_mobile` contains Android integration, cargokit, and Rust sources from
https://github.com/snowpinelabs/iroh_dart at tag v1.0.3, commit
`3278040df0be9eb7b787034525998bd3a5800b95`. The Apache-2.0 license is retained.

The local pubspec registers Android only. Desktop uses the published
`iroh_quic` 1.0.3 package and verified prebuilt library, avoiding Rust builds.
Application logic does not live here. Upgrade the Dart binding, native binary,
mobile source and flutter_rust_bridge compatibility together.

The ignored `iroh_dart` directory is a temporary upstream reference checkout.

# On-device speech

`whisper_cpp` contains the CPU sources of https://github.com/ggml-org/whisper.cpp
at tag v1.9.4, commit `927cfce34f31707e17f2bff35c349632fb9e2c3a`: the top-level
CMake files, `cmake/`, `include/`, `src/` and `ggml/` with only the CPU backend
(`ggml/src/ggml-cpu`). Examples, tests, bindings, models and GPU backends are
omitted. The MIT license is retained. `app/plugins/ournet_speech` builds it into
one static CPU-only library per platform; no model is bundled. Upgrade by
copying the same directories from a newer tag and re-running
`integration_test/voice_note_test.dart` on Windows and an Android device.
