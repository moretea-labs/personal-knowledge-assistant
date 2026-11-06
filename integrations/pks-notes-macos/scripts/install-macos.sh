#!/bin/bash
set -euo pipefail
source_root="$(cd "$(dirname "$0")/.." && pwd)"
binary="$source_root/.build/release/PKSNotes"
icon="$source_root/Resources/AppIcon.icns"
if [[ ! -f "$icon" ]]; then
  echo "Generate the icon first: cd $source_root && swift scripts/generate-app-icon.swift" >&2
  exit 1
fi
if [[ ! -x "$binary" ]]; then
  echo "Build first: cd $source_root && swift build -c release" >&2
  exit 1
fi
destination="$HOME/Applications/PKS Notes.app"
staging="$HOME/Applications/.PKS-Notes-install.app"
mkdir -p "$HOME/Applications"
if [[ -d "$staging" ]]; then
  echo "Unexpected staging app already exists: $staging" >&2
  exit 2
fi
mkdir -p "$staging/Contents/MacOS" "$staging/Contents/Resources"
cp "$icon" "$staging/Contents/Resources/AppIcon.icns"
cp "$binary" "$staging/Contents/MacOS/PKSNotes"
chmod 755 "$staging/Contents/MacOS/PKSNotes"
cat > "$staging/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>PKSNotes</string>
    <key>CFBundleIdentifier</key><string>com.moretea.pks.notes</string>
    <key>CFBundleName</key><string>PKS Notes</string>
    <key>CFBundleDisplayName</key><string>PKS Notes</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppTransportSecurity</key>
    <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST
codesign --force --sign - --timestamp=none "$staging" >/dev/null
codesign --verify --deep --strict "$staging"
previous="$HOME/Applications/.PKS-Notes-previous.app"
if [[ -e "$previous" ]]; then
  echo "Unexpected previous staging app exists: $previous" >&2
  exit 3
fi
if [[ -e "$destination" ]]; then
  mv "$destination" "$previous"
fi
if mv "$staging" "$destination"; then
  if [[ -e "$previous" ]]; then rm -rf "$previous"; fi
else
  if [[ -e "$previous" ]]; then mv "$previous" "$destination"; fi
  exit 4
fi
echo "Installed: $destination"
