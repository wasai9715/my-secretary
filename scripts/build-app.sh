#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

version="${APP_VERSION:-0.1.0}"
build_number="${APP_BUILD_NUMBER:-2}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "APP_VERSION must be major.minor.patch" >&2; exit 1; }
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || { echo "APP_BUILD_NUMBER must be a positive integer" >&2; exit 1; }

swift build -c release --product MySecretary
app="$PWD/dist/MySecretary.app"
# Avoid shipping leftover resources or signatures from previous builds.
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/MySecretary "$app/Contents/MacOS/MySecretary"
# SwiftPM resource bundles are not installed with the executable. Copy their
# processed resources into the standard signed app Resources directory.
cp .build/release/MySecretary_SecretaryCore.bundle/interpretation-prompt.txt "$app/Contents/Resources/interpretation-prompt.txt"
cp .build/release/MySecretary_SecretaryMac.bundle/management.html "$app/Contents/Resources/management.html"
cp Sources/SecretaryMac/Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp .build/release/MySecretary_SecretaryMac.bundle/MenuIcon.png "$app/Contents/Resources/MenuIcon.png"
plist="$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Clear dict' "$plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.mysecretary.mac' "$plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleName string MySecretary' "$plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string 我的秘书' "$plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' "$plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string MySecretary' "$plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$plist"
/usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "$plist"
/usr/libexec/PlistBuddy -c 'Add :NSHighResolutionCapable bool true' "$plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $version" "$plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $build_number" "$plist"

if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$app"
else
  # Local development only. Gatekeeper will not trust an ad-hoc signature.
  codesign --force --sign - "$app"
fi
codesign --verify --strict --verbose=2 "$app"
echo "Built $app ($version, build $build_number)"
