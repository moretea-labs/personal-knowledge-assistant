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

[PDF-QA.pdf · p. 2 (exact selection)](PDF-QA.pdf#page=2&rects=0.00817,0.94727,0.27472,0.01515&fp=c4ba16bb07821a13)

> Second page navigation fixture.

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

// Keep the exact-selection Markdown link tied to the actual generated PDF.
// If PDFKit's fixture layout changes, fail here instead of launching a QA app
// whose visible source anchor points at the wrong text or page region.
func fingerprint(for text: String) -> String? {
    let normalized = text
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
        .precomposedStringWithCanonicalMapping
    guard !normalized.isEmpty else { return nil }

    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in normalized.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return String(format: "%016llx", hash)
}

guard let secondPage = readBack.page(at: 1) else {
    fputs("Generated PKS Notes PDF fixture is missing page 2.\n", stderr)
    exit(1)
}
let pageBounds = secondPage.bounds(for: .cropBox)
let exactSelectionRect = CGRect(
    x: 0.00817 * pageBounds.width,
    y: 0.94727 * pageBounds.height,
    width: 0.27472 * pageBounds.width,
    height: 0.01515 * pageBounds.height
)
guard let exactSelection = secondPage.selection(for: exactSelectionRect),
      let selectedText = exactSelection.string?.trimmingCharacters(in: .whitespacesAndNewlines),
      selectedText == "Second page navigation fixture.",
      fingerprint(for: selectedText) == "c4ba16bb07821a13" else {
    fputs("Generated PKS Notes PDF fixture no longer matches the exact-selection Markdown anchor.\n", stderr)
    exit(1)
}

let markdownPath = output.deletingLastPathComponent().appendingPathComponent("Map QA.md")
guard let markdown = try? String(contentsOf: markdownPath, encoding: .utf8),
      markdown.contains("PDF-QA.pdf#page=2&rects=0.00817,0.94727,0.27472,0.01515&fp=c4ba16bb07821a13") else {
    fputs("PKS Notes Markdown fixture is missing its exact PDF source anchor.\n", stderr)
    exit(1)
}
print("Prepared searchable two-page PDF fixture with verified exact-selection anchor: \(output.lastPathComponent)")
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
