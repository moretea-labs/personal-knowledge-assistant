#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
: "${PKS_NOTES_APP_SIGN_IDENTITY:?Set Mac App Distribution signing identity}"
: "${PKS_NOTES_INSTALLER_SIGN_IDENTITY:?Set Mac Installer Distribution signing identity}"
: "${PKS_NOTES_PROVISION_PROFILE:?Set Mac App Store provisioning profile path}"
test -f "$PKS_NOTES_PROVISION_PROFILE"
cd "$root"
swift build -c release --arch arm64
app="$root/.build/appstore/PKS Notes.app"
pkg="$root/.build/appstore/PKSNotes-macOS.pkg"
mkdir -p "$root/.build/appstore"
if [[ -e "$app" || -e "$pkg" ]]; then
  echo "Existing packaging output detected; clean artifacts deliberately first." >&2
  exit 2
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/.build/arm64-apple-macosx/release/PKSNotes" "$app/Contents/MacOS/PKSNotes"
cp "$root/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$PKS_NOTES_PROVISION_PROFILE" "$app/Contents/embedded.provisionprofile"
chmod 755 "$app/Contents/MacOS/PKSNotes"
codesign --force --timestamp --sign "$PKS_NOTES_APP_SIGN_IDENTITY" --entitlements "$root/Resources/MacAppStore.entitlements" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
productbuild --sign "$PKS_NOTES_INSTALLER_SIGN_IDENTITY" --component "$app" /Applications "$pkg"
echo "Mac App Store artifact: $pkg"
