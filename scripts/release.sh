#!/usr/bin/env bash
# Builds a notarized Nametag-<version>.zip in ./build, ready to attach to a GitHub Release.
#
# One-time setup: store notarization credentials in your keychain under the profile "nametag-notary":
#   xcrun notarytool store-credentials nametag-notary --apple-id <you@example.com> --team-id <TEAMID>
# (it asks for an app-specific password from account.apple.com → Sign-In and Security).
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-nametag-notary}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
ZIP="build/Nametag-$VERSION.zip"

./scripts/build-app.sh
[[ "$(codesign -dv --verbose=2 build/Nametag.app 2>&1)" == *"Authority=Developer ID Application"* ]] \
  || { echo "Nametag.app isn't signed with a Developer ID certificate" >&2; exit 1; }

rm -f "$ZIP"
ditto -c -k --keepParent build/Nametag.app "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple build/Nametag.app

# Re-zip so the download carries the stapled ticket and opens offline too.
rm -f "$ZIP"
ditto -c -k --keepParent build/Nametag.app "$ZIP"
spctl -a -vv build/Nametag.app

echo
echo "$ZIP"
echo "sha256: $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
