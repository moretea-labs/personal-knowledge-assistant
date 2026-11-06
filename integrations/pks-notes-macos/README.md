# PKS Notes for macOS

A native SwiftUI Markdown editor integrated with the existing PKS knowledge-search service. It does not require a web account.

## Authority and boundaries

- Markdown files remain in the original user-selected directory (including iCloud Drive). No import, duplication, or secondary sync mechanism.
- PKS retains the single cross-source index; the client calls the local PKS HTTP search/read API at 127.0.0.1:3217.
- SilverBullet and Forge are not prerequisites for the editor. No Forge Runtime changes are made.
- Files outside the selected workspace are read-only PKS previews. Original files and their locations are never changed during search.

## Features

- Native continuous macOS work surface with a single flat title bar, generous document-first reading, comfortable 13-point file navigation and restrained search; direct Edit/Split/Read controls with gentle transitions and no stacked cards or custom shadows
- Mixed-file folder navigation (Markdown, PDF and other regular files) with Chinese filenames; file rows are readable and folder disclosure expansion is computed only when folder state or the file scan changes. Double-click/chevrons and keyboard navigation remain available. The last successfully opened Markdown note restores safely on next launch only if still present inside the chosen workspace.
- Direct one-click Edit, Split and Read controls (⌘1/⌘2/⌘3) in the native title bar; one window-owned parsed Markdown snapshot survives view switching, idle editing prepares the preview off the main thread, and long notes without cross-section reference definitions render lazily by heading to reduce first-layout overhead
- Four complete Markdown typography themes: System (native balanced), Paper (airy rounded editorial), Warm (serif long-form), Midnight (dense monospace technical). Each changes font family/size, heading proportions, line/paragraph spacing, list/quote/code/table styling and reading column width, not merely colors. Title bar 'Aa' opens a native inspector with live font-size, line-spacing and reading-width adjustments, persisted across launches and resettable. Theme and adjustments do not change Markdown source.
- Native read-only PDFKit preview with zoom and text selection; other files use macOS default applications
- In-workspace Markdown links and images, with path containment checks
- PKS ranked cross-source search; view snippets and read out-of-workspace results without editing them
- Search result source labels with per-result ellipsis/right-click actions; Finder reveal, default app open, and path copy for local/managed files
- Duplicate PKS chunks are grouped per document while preserving ranked order; expand to see every matching section and its excerpt
- Search title/summary keywords are highlighted; click a match section to scroll the Markdown preview to its heading (or first matching heading section) without changing the source file
- Web-source browser/open-link actions; opaque URI fallback copies the source identifier without guessing a file path
- The note tree and title-bar ellipsis menu offer contextual file actions; missing files report a non-destructive error
- Debounced local Markdown autosave after 650 ms of inactivity, and immediate flush on note switch / quit. Saving shows only a small toolbar progress indicator. An external-edit conflict preserves the draft and retains native Save / Discard / Cancel protection before leaving
- Cmd+P opens a native, keyboard-operated Quick Open palette across the already-scanned vault tree (filename and parent-folder matching); Cmd+N creates a note and enters Edit, Cmd+F focuses PKS search, Cmd+O selects the existing workspace, and folder right-click offers New Note Here
- Markdown loads and preview parsing run off main actor; only changed Split drafts are debounced (~260 ms), already-parsed content survives view/theme changes, and canceled stale tasks cannot replace newer drafts
- Cmd+S is still available for immediate saves; no persistent Save button or success banner, and concurrent external edits are checked before every write
- Create notes beside the selected note (or at the workspace root), or explicitly inside a folder via its context menu; note destinations are validated in-vault

## Development and installation

Requires macOS 14 or later with Swift/Xcode.

    cd integrations/pks-notes-macos
    swift test --jobs 4
    swift scripts/generate-app-icon.swift  # reproducible white/graphite icon; committed AppIcon.icns also ships ready to install
    swift build -c release --jobs 4
    ./scripts/install-macos.sh
    open "$HOME/Applications/PKS Notes.app"

**First launch:** select the existing iCloud Drive folder `学习笔记管理` using **Choose Folder** in the toolbar ellipsis menu and click **Open** in the macOS folder picker. This is a one-time macOS file-access grant for this application, not a login and not a new sync service. The app retains the system security-scoped folder bookmark and reopens the same folder on subsequent launches. Until permission is granted, the app intentionally leaves the notes tree empty but PKS search remains available.

The canonical folder is `~/Library/Mobile Documents/com~apple~CloudDocs/学习笔记管理`. No source files are imported, relocated or copied. iCloud Drive handles synchronization. Do not bypass the native folder picker by writing the folder path to app preferences: that does not grant macOS permissions.

The app bundle copies `Resources/AppIcon.icns` into `Contents/Resources` and declares `CFBundleIconFile=AppIcon`; the icon generator uses AppKit only (no external icon dependency).

## Verification

The Swift tests cover Chinese PKS result decoding, mixed-file browsing, native PDF navigation, autosave debounce/navigation flush and external-write safety, safe note names, traversal protection, Markdown links/images, real temporary-file save and conflict detection. Check the installed Mac window separately and ensure the local PKS service is running before using Search.

The app does not implement remote access or its own synchronization. Large or not-yet-downloaded iCloud items can still take time to open. Avoid simultaneous edits from multiple applications.
