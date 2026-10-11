#!/usr/bin/env bash
# Explicitly unnotarized GitHub preview. Never describe this as a trusted release.
set -euo pipefail
cd "$(dirname "$0")/.."

version="${APP_VERSION:?Set APP_VERSION to the release version}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid APP_VERSION" >&2; exit 1; }
app="$PWD/dist/MySecretary.app"
[[ -d "$app" ]] || { echo "Build the app first" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" == "$version" ]] || { echo "App version mismatch" >&2; exit 1; }
codesign --verify --strict --verbose=2 "$app"
# Guard against accidentally presenting a signed/notarized build as this preview.
signature_info="$(codesign -dv --verbose=4 "$app" 2>&1)"
[[ "$signature_info" == *'Signature=adhoc'* ]] || { echo "Preview must have an ad-hoc signature" >&2; exit 1; }
arch="$(uname -m)"
[[ "$arch" == arm64 || "$arch" == x86_64 ]] || { echo "Unsupported architecture: $arch" >&2; exit 1; }
lipo "$app/Contents/MacOS/MySecretary" -verify_arch "$arch" || { echo "App architecture mismatch" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
name="MySecretary-${version}-macOS-${arch}-UNNOTARIZED"
dmg="$PWD/dist/$name.dmg"
rm -f "$dmg" "$dmg.sha256"
mkdir "$work/volume"
ditto "$app" "$work/volume/MySecretary.app"
ln -s /Applications "$work/volume/Applications"
# A plain-text warning remains visible alongside the app inside the mounted DMG.
printf '%s\n' 'UNNOTARIZED PREVIEW / 未经 Apple 公证的预览版' '' \
  'Only install if you trust this repository and understand the risk.' \
  'macOS may block the first launch. Open System Settings > Privacy & Security' \
  'and choose Open Anyway for MySecretary after attempting to open it once.' \
  'This app is experimental; do not rely on it for important reminders.' \
  > "$work/volume/READ-ME-FIRST.txt"
hdiutil create -volname 'MySecretary UNNOTARIZED' -srcfolder "$work/volume" -format UDZO -ov "$dmg"
hdiutil verify "$dmg"
(cd dist && shasum -a 256 "$name.dmg" > "$name.dmg.sha256")
echo "UNNOTARIZED preview ready: $dmg"
