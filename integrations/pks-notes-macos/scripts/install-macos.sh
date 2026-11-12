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
destination="$HOME/Applications/Leafspan.app"
staging="$HOME/Applications/.Leafspan-install.app"
mkdir -p "$HOME/Applications"
if [[ -d "$staging" ]]; then
  echo "Unexpected staging app already exists: $staging" >&2
  exit 2
fi
mkdir -p "$staging/Contents/MacOS" "$staging/Contents/Resources"
cp "$icon" "$staging/Contents/Resources/AppIcon.icns"
cp "$binary" "$staging/Contents/MacOS/PKSNotes"
chmod 755 "$staging/Contents/MacOS/PKSNotes"
cp "$source_root/Resources/Info.plist" "$staging/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$staging" >/dev/null
codesign --verify --deep --strict "$staging"
previous="$HOME/Applications/.Leafspan-previous.app"
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
