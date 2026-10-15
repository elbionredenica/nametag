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

# App icon: compiled from the Icon Composer file into Assets.car (macOS 26 style, shaped by the
# system) plus AppIcon.icns for older macOS versions.
xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 13.0 --app-icon AppIcon \
  --output-partial-info-plist "$(mktemp -d)/partial.plist" >/dev/null

# Prefer Developer ID (needed to share the app), then Apple Development, then ad-hoc.
IDENTITIES="$(security find-identity -v -p codesigning)"
IDENTITY="${CODESIGN_IDENTITY:-$(awk -F'"' '/Developer ID Application/ {print $2; exit}' <<<"$IDENTITIES")}"
IDENTITY="${IDENTITY:-$(awk -F'"' '/Apple Development/ {print $2; exit}' <<<"$IDENTITIES")}"
TIMESTAMP=()
[[ "$IDENTITY" == Developer\ ID* ]] && TIMESTAMP=(--timestamp)
codesign --force --options runtime "${TIMESTAMP[@]}" --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed: ${IDENTITY:--})"
