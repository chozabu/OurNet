#!/usr/bin/env bash
# Linux counterpart of tool/build-iroh.ps1: builds OurNet's iroh binding
# (vendor/iroh_mobile/rust) and installs it where the app bundles it
# (app/native) and where iroh_quic finds it for `dart test` (its per-user
# library cache). Ours differs from the upstream prebuilt library: it relays
# through friends, carries call media, maps router ports (UPnP, NAT-PMP, PCP)
# and keeps n0's address lookup beside the app's (docs/CONNECTIVITY.md).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
case "$(uname -m)" in
  x86_64) triple=x86_64-unknown-linux-gnu ;;
  aarch64) triple=aarch64-unknown-linux-gnu ;;
  *) echo "No iroh build for $(uname -m)" >&2; exit 1 ;;
esac
(cd "$root/vendor/iroh_mobile/rust" && cargo build --release)
library="$root/vendor/iroh_mobile/rust/target/release/libirohdart_ffi.so"
# Skip unchanged copies, so a no-op build leaves the installed files alone.
install_library() {
  mkdir -p "$1"
  cmp -s "$library" "$1/libirohdart_ffi.so" || cp "$library" "$1/libirohdart_ffi.so"
}
install_library "$root/app/native"
install_library "${XDG_CACHE_HOME:-$HOME/.cache}/iroh_quic/v1.0.3/$triple"
