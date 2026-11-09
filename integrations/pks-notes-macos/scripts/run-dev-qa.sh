#!/bin/bash
set -euo pipefail

source_root="$(cd "$(dirname "$0")/.." && pwd)"
app="$HOME/Applications/PKS Notes QA.app"
fixture="$HOME/Library/Application Support/PKS Notes QA/Fixture Vault"
binary="$source_root/.build/debug/PKSNotes"
icon="$source_root/Resources/AppIcon.icns"

cd "$source_root"
swift build -c debug --jobs 2 -q

# Separate bundle identity and preferences; never replace the release app,
# change production entitlements, or modify an existing user workspace.
mkdir -p "$fixture" "$HOME/Applications"

staging="$(mktemp -d /tmp/pks-notes-qa.XXXXXX)"
trap 'rm -rf "$staging"' EXIT
bundle="$staging/PKS Notes QA.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$icon" "$bundle/Contents/Resources/AppIcon.icns"
cp "$binary" "$bundle/Contents/MacOS/PKSNotes"
chmod 755 "$bundle/Contents/MacOS/PKSNotes"
cp "$source_root/Resources/Info.plist" "$bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.moretea.pks.notes.qa' "$bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName PKS Notes QA' "$bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName PKS Notes QA' "$bundle/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$bundle" >/dev/null
codesign --verify --deep --strict "$bundle"

# Update only the bundle with our exact QA identity; never touch the release
# app or another developer app that happens to use the same display name.
previous="$HOME/Applications/.PKS-Notes-QA-previous.app"
if [[ -e "$app" ]]; then
    identity="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$identity" != "com.moretea.pks.notes.qa" || -e "$previous" ]]; then
        echo "Refusing to overwrite an unidentified or non-atomic QA bundle." >&2
        exit 2
    fi
    /usr/bin/osascript -e 'tell application id "com.moretea.pks.notes.qa" to quit' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if ! pgrep -f "$app/Contents/MacOS/PKSNotes" >/dev/null; then break; fi
        sleep 0.5
    done
    if pgrep -f "$app/Contents/MacOS/PKSNotes" >/dev/null; then
        echo "QA app is still running; close it before rebuilding. No files replaced." >&2
        exit 3
    fi
    mv "$app" "$previous"
fi
if mv "$bundle" "$app"; then
    if [[ -e "$previous" ]]; then rm -rf "$previous"; fi
else
    if [[ -e "$previous" ]]; then mv "$previous" "$app"; fi
    exit 4
fi

# This script owns its disposable fixture baseline. Rewrite it only after the
# previous QA process is confirmed stopped, so an old in-memory document cannot
# save over the fresh baseline during termination.
cat > "$fixture/Map QA.md" <<'NOTE'
# Mind Map QA
- [ ] Review the introduction
  - **Bold priority**
  - *Italic context*
  - [ ] Read [Research](Research.md)
- [x] Finished the setup
- A long Chinese node used to verify that spatial layout cards can show complete multi-line titles without overlapping their neighboring branches, even in compact mode and dark mode
- Another branch
  - Child one
  - Child two
NOTE
printf '# Research\nThis is an isolated local QA note.\n' > "$fixture/Research.md"
# The QA bundle can retain an old security-scoped bookmark from manual testing.
# NotesModel resolves bookmarks before PKSNotesWorkspace, so clear only the QA
# bookmark before pinning this run to the isolated fixture vault.
/usr/bin/defaults delete com.moretea.pks.notes.qa PKSNotesWorkspaceBookmark >/dev/null 2>&1 || true
/usr/bin/defaults write com.moretea.pks.notes.qa PKSNotesWorkspace -string "$fixture"
/usr/bin/defaults write com.moretea.pks.notes.qa PKSNotesLastOpenedMarkdown -string "$fixture/Map QA.md"
/usr/bin/open -n -a "$app" --args --pks-qa-pro
echo "Launched signed QA Debug app: $app"
echo "QA workspace: $fixture"
