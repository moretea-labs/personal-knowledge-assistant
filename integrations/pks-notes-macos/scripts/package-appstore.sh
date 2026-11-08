#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
: "${PKS_NOTES_APP_SIGN_IDENTITY:?Set Mac App Distribution signing identity}"
: "${PKS_NOTES_INSTALLER_SIGN_IDENTITY:?Set Mac Installer Distribution signing identity}"
: "${PKS_NOTES_PROVISION_PROFILE:?Set Mac App Store provisioning profile path}"

profile="$PKS_NOTES_PROVISION_PROFILE"
test -f "$profile"

info="$root/Resources/Info.plist"
entitlements="$root/Resources/MacAppStore.entitlements"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info")"
category="$(/usr/libexec/PlistBuddy -c 'Print :LSApplicationCategoryType' "$info")"
[[ "$bundle_id" == "com.moretea.pks.notes" ]]
[[ -n "$version" && -n "$build" ]]
[[ "$category" == "public.app-category.productivity" ]]

profile_plist="$(/usr/bin/mktemp -t pks-notes-profile)"
effective_entitlements="$(/usr/bin/mktemp -t pks-notes-effective-entitlements)"
signed_entitlements="$(/usr/bin/mktemp -t pks-notes-entitlements)"
trap '/bin/rm -f "$profile_plist" "$effective_entitlements" "$signed_entitlements"' EXIT

/usr/bin/security cms -D -i "$profile" > "$profile_plist"
/usr/bin/plutil -lint "$profile_plist" >/dev/null

profile_team="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$profile_plist")"
profile_app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$profile_plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$profile_plist")"
profile_expiration="$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$profile_plist")"
profile_platforms="$(/usr/libexec/PlistBuddy -c 'Print :Platform' "$profile_plist")"

if [[ "$profile_platforms" != *"OSX"* && "$profile_platforms" != *"macOS"* ]]; then
  echo "Provisioning profile is not a macOS profile: $profile_platforms" >&2
  exit 3
fi
if [[ "$profile_app_id" != "$profile_team.$bundle_id" ]]; then
  echo "Provisioning profile app identifier mismatch: expected $profile_team.$bundle_id, got $profile_app_id" >&2
  exit 4
fi
cp "$entitlements" "$effective_entitlements"
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $profile_app_id" "$effective_entitlements"
/usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $profile_team" "$effective_entitlements"
/usr/bin/plutil -lint "$effective_entitlements" >/dev/null

if ! /usr/bin/python3 - "$profile_plist" <<'PY'
import datetime
import plistlib
import sys

with open(sys.argv[1], "rb") as stream:
    expiry = plistlib.load(stream)["ExpirationDate"]
if expiry.tzinfo is None:
    expiry = expiry.replace(tzinfo=datetime.timezone.utc)
raise SystemExit(0 if expiry > datetime.datetime.now(datetime.timezone.utc) else 1)
PY
then
  echo "Provisioning profile is expired: $profile_expiration" >&2
  exit 5
fi

app="$root/.build/appstore/PKS Notes.app"
pkg="$root/.build/appstore/PKSNotes-macOS.pkg"
mkdir -p "$root/.build/appstore"
if [[ -e "$app" || -e "$pkg" ]]; then
  echo "Existing packaging output detected; clean artifacts deliberately first." >&2
  exit 6
fi

cd "$root"
swift build -c release --arch arm64
release_bin="$(swift build -c release --arch arm64 --show-bin-path)"

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$release_bin/PKSNotes" "$app/Contents/MacOS/PKSNotes"
cp "$root/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp "$info" "$app/Contents/Info.plist"
cp "$profile" "$app/Contents/embedded.provisionprofile"
chmod 755 "$app/Contents/MacOS/PKSNotes"

codesign --force --timestamp --sign "$PKS_NOTES_APP_SIGN_IDENTITY" \
  --entitlements "$effective_entitlements" "$app"
codesign --verify --deep --strict --verbose=2 "$app"

signed_team="$(codesign -dv --verbose=4 "$app" 2>&1 | /usr/bin/sed -nE 's/^TeamIdentifier=(.*)$/\1/p')"
if [[ "$signed_team" != "$profile_team" ]]; then
  echo "Signed app TeamIdentifier mismatch: profile=$profile_team app=${signed_team:-none}" >&2
  exit 7
fi

codesign -d --entitlements :- "$app" > "$signed_entitlements" 2>/dev/null
signed_app_id="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "$signed_entitlements" 2>/dev/null || true)"
signed_entitlement_team="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "$signed_entitlements" 2>/dev/null || true)"
if [[ "$signed_app_id" != "$profile_app_id" || "$signed_entitlement_team" != "$profile_team" ]]; then
  echo "Signed application identity entitlements do not match provisioning profile." >&2
  exit 8
fi

for key in \
  com.apple.security.app-sandbox \
  com.apple.security.files.bookmarks.app-scope \
  com.apple.security.files.user-selected.read-write \
  com.apple.security.network.client
do
  value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$signed_entitlements" 2>/dev/null || true)"
  if [[ "$value" != "true" ]]; then
    echo "Signed app is missing required entitlement $key" >&2
    exit 9
  fi
done

productbuild --sign "$PKS_NOTES_INSTALLER_SIGN_IDENTITY" --component "$app" /Applications "$pkg"
/usr/sbin/pkgutil --check-signature "$pkg"

echo "Mac App Store artifact: $pkg"
echo "Bundle: $bundle_id $version ($build)"
echo "Team: $profile_team"
