#!/usr/bin/env bash
# Builds Nametag.app into ./build and signs it.
# Signs with your Developer ID if you have one, else Apple Development, so the Accessibility
# permission survives rebuilds. Override with CODESIGN_IDENTITY, or "-" for ad-hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Nametag"

APP=build/Nametag.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Nametag"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon: every size macOS asks for, from the 1024px master.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Resources/Icon/AppIcon-1024.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) Resources/Icon/AppIcon-1024.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Prefer Developer ID (needed to share the app), then Apple Development, then ad-hoc.
IDENTITIES="$(security find-identity -v -p codesigning)"
IDENTITY="${CODESIGN_IDENTITY:-$(awk -F'"' '/Developer ID Application/ {print $2; exit}' <<<"$IDENTITIES")}"
IDENTITY="${IDENTITY:-$(awk -F'"' '/Apple Development/ {print $2; exit}' <<<"$IDENTITIES")}"
TIMESTAMP=()
[[ "$IDENTITY" == Developer\ ID* ]] && TIMESTAMP=(--timestamp)
codesign --force --options runtime "${TIMESTAMP[@]}" --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed: ${IDENTITY:--})"
