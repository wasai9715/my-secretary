#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product MySecretary
app="$PWD/dist/MySecretary.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/MySecretary "$app/Contents/MacOS/MySecretary"
# The installed app reads the packaged prompt from Resources, never from .build.
rm -rf "$app/MySecretary_SecretaryCore.bundle"
cp .build/release/MySecretary_SecretaryCore.bundle/interpretation-prompt.txt "$app/Contents/Resources/interpretation-prompt.txt"
/usr/libexec/PlistBuddy -c 'Clear dict' "$app/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.mysecretary.mac' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleName string MySecretary' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string MySecretary' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :NSHighResolutionCapable bool true' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleShortVersionString string 0.1.0' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleVersion string 1' "$app/Contents/Info.plist"
codesign --force --sign - "$app"
echo "Built $app"
