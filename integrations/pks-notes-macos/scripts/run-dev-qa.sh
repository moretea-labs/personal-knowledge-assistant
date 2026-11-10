#!/bin/bash
set -euo pipefail

prepare_only=false
if [[ "${1:-}" == "--prepare-only" && $# -eq 1 ]]; then
    prepare_only=true
elif [[ $# -ne 0 ]]; then
    echo "Usage: $0 [--prepare-only]" >&2
    exit 64
fi

source_root="$(cd "$(dirname "$0")/.." && pwd)"
app="$HOME/Applications/PKS Notes QA Fixture.app"
fixture="$HOME/Library/Application Support/PKS Notes QA Fixture/Fixture Vault"
binary="$source_root/.build/debug/PKSNotes"
qa_executable="PKSNotesQAFixture"
qa_bundle_id="com.moretea.pks.notes.qa.fixture"
qa_display_name="PKS Notes QA Fixture"
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
cp "$binary" "$bundle/Contents/MacOS/$qa_executable"
chmod 755 "$bundle/Contents/MacOS/$qa_executable"
cp "$source_root/Resources/Info.plist" "$bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $qa_executable" "$bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $qa_bundle_id" "$bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $qa_display_name" "$bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $qa_display_name" "$bundle/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$bundle" >/dev/null
codesign --verify --deep --strict "$bundle"

# Update only the bundle with our exact QA identity; never touch the release
# app or another developer app that happens to use the same display name.
previous="$HOME/Applications/.PKS-Notes-QA-Fixture-previous.app"
if [[ -e "$app" ]]; then
    identity="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$identity" != "$qa_bundle_id" || -e "$previous" ]]; then
        echo "Refusing to overwrite an unidentified or non-atomic QA bundle." >&2
        exit 2
    fi
    if [[ "$prepare_only" == true ]]; then
        # Staging must never send GUI input or terminate an existing target.
        if pgrep -f "$app/Contents/MacOS/PKSNotes" >/dev/null \
            || pgrep -f "$app/Contents/MacOS/$qa_executable" >/dev/null; then
            echo "QA fixture app is running; prepare-only will not quit or replace it. No files changed." >&2
            exit 3
        fi
    else
        /usr/bin/osascript -e "tell application id \"$qa_bundle_id\" to quit" >/dev/null 2>&1 || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            if ! pgrep -f "$app/Contents/MacOS/PKSNotes" >/dev/null \
                && ! pgrep -f "$app/Contents/MacOS/$qa_executable" >/dev/null; then
                break
            fi
            sleep 0.5
        done
        if pgrep -f "$app/Contents/MacOS/PKSNotes" >/dev/null \
            || pgrep -f "$app/Contents/MacOS/$qa_executable" >/dev/null; then
            echo "QA fixture app is still running; close it before rebuilding. No files replaced." >&2
            exit 3
        fi
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

[Open the two-page PDF fixture](PDF-QA.pdf)

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
PKS_QA_PDF_OUTPUT="$fixture/PDF-QA.pdf" /usr/bin/swift - <<'SWIFT'
import AppKit
import PDFKit
import Foundation
import Darwin

func makePage(_ text: String) -> PDFPage? {
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
    view.string = text
    guard let source = PDFDocument(data: view.dataWithPDF(inside: view.bounds)),
          source.pageCount == 1 else {
        return nil
    }
    return source.page(at: 0)
}

guard let outputPath = ProcessInfo.processInfo.environment["PKS_QA_PDF_OUTPUT"],
      let firstPage = makePage("PKS PDF Fixture - Page 1\n\nImportant fact for source anchor."),
      let secondPage = makePage("PKS PDF Fixture - Page 2\n\nSecond page navigation fixture.") else {
    fputs("Unable to generate PKS Notes PDF fixture pages.\n", stderr)
    exit(1)
}
let document = PDFDocument()
document.insert(firstPage, at: 0)
document.insert(secondPage, at: 1)
let output = URL(fileURLWithPath: outputPath)
guard document.write(to: output),
      let readBack = PDFDocument(url: output),
      readBack.pageCount == 2,
      (readBack.string ?? "").contains("Important fact for source anchor"),
      (readBack.string ?? "").contains("Second page navigation fixture") else {
    fputs("Generated PKS Notes PDF fixture failed read-back verification.\n", stderr)
    exit(1)
}
print("Prepared searchable two-page PDF fixture: \(output.lastPathComponent)")
SWIFT
# The QA bundle can retain an old security-scoped bookmark from manual testing.
# NotesModel resolves bookmarks before PKSNotesWorkspace, so clear only the QA
# bookmark before pinning this run to the isolated fixture vault.
/usr/bin/defaults delete "$qa_bundle_id" PKSNotesWorkspaceBookmark >/dev/null 2>&1 || true
/usr/bin/defaults write "$qa_bundle_id" PKSNotesWorkspace -string "$fixture"
/usr/bin/defaults write "$qa_bundle_id" PKSNotesLastOpenedMarkdown -string "$fixture/Map QA.md"
if [[ "$prepare_only" == true ]]; then
    echo "Prepared signed fixture-only QA app without launching: $app"
else
    /usr/bin/open -a "$app" --args --pks-qa-pro
    echo "Launched signed fixture-only QA Debug app: $app"
fi
echo "QA workspace: $fixture"
