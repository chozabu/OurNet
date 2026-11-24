#!/usr/bin/env bash
# Linux counterpart of tool/setup.ps1: fetches dependencies and builds OurNet's
# iroh binding where the Linux build bundles it.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
(cd "$root/app" && flutter pub get)
# Our iroh binding, not the upstream prebuilt one (see tool/build-iroh.sh).
"$root/tool/build-iroh.sh"
(cd "$root/core" && dart pub get)
(cd "$root/transport" && dart pub get)
