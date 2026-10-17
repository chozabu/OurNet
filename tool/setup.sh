#!/usr/bin/env bash
# Linux counterpart of tool/setup.ps1: fetches dependencies and installs the
# signed iroh library (verified by iroh_quic:setup) where the Linux build
# bundles it.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root/app"
flutter pub get
dart run iroh_quic:setup --force
case "$(uname -m)" in
  x86_64) triple=x86_64-unknown-linux-gnu ;;
  aarch64) triple=aarch64-unknown-linux-gnu ;;
  *) echo "No iroh library for $(uname -m)" >&2; exit 1 ;;
esac
mkdir -p native
cp "${XDG_CACHE_HOME:-$HOME/.cache}/iroh_quic/v1.0.3/$triple/libirohdart_ffi.so" native/
(cd "$root/core" && dart pub get)
(cd "$root/transport" && dart pub get)
