#!/bin/sh
# Turns this checkout into the F-Droid build's sources: no Google libraries
# (Firebase, ML Kit, Play services location) and, with --plugins, no
# prebuilt binaries. Run before `flutter build apk --flavor fdroid`; the
# F-Droid recipe runs it in prebuild. It edits the checkout, so don't commit
# afterwards.
#
#   app/fdroid/prepare.sh [--plugins]
#
# --plugins rebuilds app/assets/plugins from plugins/ (needs the
# wasm32-unknown-unknown Rust target).
set -eu
app=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$app/.." && pwd)

# Dart: the same interfaces without the non-free plugins.
#   qr_scanner.dart       mobile_scanner (ML Kit)      -> flutter_zxing (zxing-cpp)
#   device_position.dart  geolocator (Play location)   -> DeviceLocation.kt channel
#   image_text.dart       ML Kit text recognition      -> left out
cp -R "$app/fdroid/lib/." "$app/lib/"

pubspec="$app/pubspec.yaml"
for package in google_mlkit_text_recognition mobile_scanner geolocator; do
  grep -q "^  $package:" "$pubspec" || { echo "$package is not in pubspec.yaml" >&2; exit 1; }
  sed -i "/^  $package:/d" "$pubspec"
done
sed -i 's/^dependencies:$/dependencies:\n  flutter_zxing: 3.1.1\n  permission_handler: 12.0.1/' "$pubspec"

# The packages app/assets/plugins ships; keep in step with it.
shipped="device-dashboard git js microblog pong remote-desktop remote-input tictactoe vpn wiki"
if [ "${1:-}" = "--plugins" ]; then
  mkdir -p "$app/assets/plugins"
  rm -f "$app"/assets/plugins/*.ournet-plugin
  (cd "$root/plugins" && cargo run -p pack --release)
  for id in $shipped; do cp "$root/plugins/dist/$id.ournet-plugin" "$app/assets/plugins/"; done
fi

cd "$app" && flutter pub get
