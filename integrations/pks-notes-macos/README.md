# PKS Notes for macOS

A native SwiftUI Markdown editor integrated with the existing PKS knowledge-search service. It does not require a web account.

## Authority and boundaries

- Markdown files remain in the original user-selected directory (including iCloud Drive). No import, duplication, or secondary sync mechanism.
- PKS retains the single cross-source index; the client calls the local PKS HTTP search/read API at 127.0.0.1:3217.
- SilverBullet and Forge are not prerequisites for the editor. No Forge Runtime changes are made.
- Files outside the selected workspace are read-only PKS previews. Original files and their locations are never changed during search.

## Features

- Native Mac window; double-click the app or note title to zoom/restore, in addition to standard macOS title-bar controls; separate Notes and Search sidebar tabs
- Mixed-file folder navigation (Markdown, PDF and other regular files) with Chinese filenames; double-click folders or click chevrons to expand/collapse, use arrow keys to navigate the tree and Return to open files
- Direct one-click Edit, Split and Read controls (⌘1/⌘2/⌘3); default Edit mode avoids unnecessary parsing, and MarkdownUI 2.4.1 retains centered reading layout
- Native read-only PDFKit preview with zoom and text selection; other files use macOS default applications
- In-workspace Markdown links and images, with path containment checks
- PKS ranked cross-source search; view snippets and read out-of-workspace results without editing them
- Search result source labels with per-result ellipsis/right-click actions; Finder reveal, default app open, and path copy for local/managed files
- Duplicate PKS chunks are grouped per document while preserving ranked order; expand to see every matching section and its excerpt
- Search title/summary keywords are highlighted; click a match section to scroll the Markdown preview to its heading (or first matching heading section) without changing the source file
- Web-source browser/open-link actions; opaque URI fallback copies the source identifier without guessing a file path
- The note tree and current note header also offer file actions; missing files report a non-destructive error
- Native Save / Discard / Cancel when leaving a dirty note (including search, new note, workspace and quit); external PKS previews respect Discard, while stale results and save conflicts never overwrite current edits
- Cmd+N creates a Markdown note; Cmd+F focuses PKS search; Cmd+O selects the existing workspace; folder right-click offers New Note Here
- Markdown loads and preview parsing run off the main actor; Split mode debounces live updates by 320 ms, reuses parsed content when changing views, cancels superseded work and preserves the editor draft on errors
- Save via Cmd+S; protect unsaved edits and detect concurrent content changes before writing
- Create notes beside the selected note (or at the workspace root), or explicitly inside a folder via its context menu; note destinations are validated in-vault

## Development and installation

Requires macOS 14 or later with Swift/Xcode.

    cd integrations/pks-notes-macos
    swift test --jobs 4
    swift build -c release --jobs 4
    ./scripts/install-macos.sh
    open "$HOME/Applications/PKS Notes.app"

**First launch:** select the existing iCloud Drive folder `学习笔记管理` using **Choose Folder** (or the folder toolbar button) and click **Open** in the macOS folder picker. This is a one-time macOS file-access grant for this application, not a login and not a new sync service. The app retains the system security-scoped folder bookmark and reopens the same folder on subsequent launches. Until permission is granted, the app intentionally leaves the notes tree empty but PKS search remains available.

The canonical folder is `~/Library/Mobile Documents/com~apple~CloudDocs/学习笔记管理`. No source files are imported, relocated or copied. iCloud Drive handles synchronization. Do not bypass the native folder picker by writing the folder path to app preferences: that does not grant macOS permissions.

## Verification

The Swift tests cover Chinese PKS result decoding, mixed-file recursive folder browsing, native PDF navigation and unsaved-change guard, safe note names, symlink/traversal protection, in-workspace Markdown links/images, real temporary-file save and overwrite-conflict detection. Check the installed Mac window separately and ensure the local PKS service is running before using Search.

The app does not implement remote access or its own synchronization. Large or not-yet-downloaded iCloud items can still take time to open. Avoid simultaneous edits from multiple applications.
