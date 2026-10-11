#!/usr/bin/env bash
# Package an already built, Developer-ID-signed .app for GitHub Releases.
set -euo pipefail
cd "$(dirname "$0")/.."

version="${APP_VERSION:?Set APP_VERSION to the release version}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid APP_VERSION" >&2; exit 1; }
: "${NOTARY_KEY_FILE:?Set NOTARY_KEY_FILE to an App Store Connect .p8 key path}"
: "${NOTARY_KEY_ID:?Set NOTARY_KEY_ID}"
: "${NOTARY_ISSUER_ID:?Set NOTARY_ISSUER_ID}"
app="$PWD/dist/MySecretary.app"
[[ -d "$app" ]] || { echo "Build the app first" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" == "$version" ]] || { echo "App version mismatch" >&2; exit 1; }
# Fail closed: ad-hoc builds cannot be submitted for distribution.
codesign --verify --strict --verbose=2 "$app"
identity="$(codesign -dv --verbose=4 "$app" 2>&1 | grep '^Authority=Developer ID Application:' | head -1 || true)"
[[ -n "$identity" ]] || { echo "App must have a Developer ID Application signature" >&2; exit 1; }
arch="$(uname -m)"
[[ "$arch" == arm64 || "$arch" == x86_64 ]] || { echo "Unsupported architecture: $arch" >&2; exit 1; }
lipo "$app/Contents/MacOS/MySecretary" -verify_arch "$arch" || { echo "App architecture mismatch" >&2; exit 1; }

notarize() {
  xcrun notarytool submit "$1" --key "$NOTARY_KEY_FILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# Notarize the app first and staple it so it works without an online ticket lookup.
ditto -c -k --keepParent "$app" "$work/MySecretary.zip"
notarize "$work/MySecretary.zip"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose "$app"

name="MySecretary-${version}-macOS-${arch}"
dmg="$PWD/dist/$name.dmg"
rm -f "$dmg"
mkdir "$work/volume"
ditto "$app" "$work/volume/MySecretary.app"
ln -s /Applications "$work/volume/Applications"
hdiutil create -volname 'MySecretary' -srcfolder "$work/volume" -format UDZO -ov "$dmg"
notarize "$dmg"
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
(cd dist && shasum -a 256 "$name.dmg" > "$name.dmg.sha256")
echo "Ready: $dmg ($identity)"
