# PKS Notes for macOS

A native SwiftUI Markdown editor integrated with the existing PKS knowledge-search service. It does not require a web account.

## Authority and boundaries

- Markdown files remain in the original user-selected directory (including iCloud Drive). No import, duplication, or secondary sync mechanism.
- PKS retains the single cross-source index; the client calls the local PKS HTTP search/read API at 127.0.0.1:3217.
- SilverBullet and Forge are not prerequisites for the editor. No Forge Runtime changes are made.
- Files outside the selected workspace are read-only PKS previews. Original files and their locations are never changed during search.

## Features

- Nulis-inspired native macOS workspace: compact branded sidebar with Quick Find, **icon-first All Notes / PKS Search / Quick Open navigation**, real FOLDERS section with the current iCloud workspace, and its existing lazy, keyboard-navigable file tree. The document and controls occupy **one native macOS titlebar**, with the document title and compact Edit / Split / Read icons (⌘1/⌘2/⌘3); there is no duplicate breadcrumb or secondary toolbar. No copied artwork, dashboard cards or decorative shadows.
- Mixed-file folder navigation (Markdown, PDF and other regular files) with Chinese filenames; folders and documents share the same 16pt disclosure and 18pt SF Symbol slots, compact 32pt rows and 16pt nested indentation. The single native toolbar contains context-sensitive Edit/Split/Read, the file actions menu and transient autosave progress. Finder reveal remains in the existing file actions menu. Appearance lives exclusively in the native application Settings window. Double-click, disclosure, keyboard movement and Return remain supported; only scan/expansion changes update visible rows. Last-opened Markdown safely restores inside the selected workspace.
- One native titlebar with compact icon-only Edit, Split and Read (⌘1/⌘2/⌘3); one window-owned parsed Markdown snapshot survives view switching, idle editing prepares the preview off the main thread, and long notes without cross-section reference definitions render lazily by heading to reduce first-layout overhead
- Five complete Markdown typography themes: System (native balanced), Paper (airy rounded editorial), Warm (serif long-form), Midnight (dense monospace technical), Graphite (Nulis-inspired dark modern sans-serif with warm accents). Each changes font family/size, heading proportions, line/paragraph spacing, list/quote/code/table styling and reading column width, not merely colors. **PKS Notes > Settings… (⌘,)** exposes Appearance & Typography, with live font-size, line-spacing and reading-width adjustments, persisted across launches and resettable; there is no appearance control in the working toolbar. Theme and adjustments do not change Markdown source.
- Native file management: right-click a vault note, PDF or folder (or use the current-file ellipsis) to **Rename…**, **Move to Folder…**, **Copy to Folder…** or **Move to Trash**. Files/folders can also be dragged directly onto a sidebar folder to move them. Rename/move/copy deny collisions, symlink escapes and recursive folder moves outside the selected workspace. Deletion uses **Finder Trash**, never permanent removal; folders require confirmation. **⌘Delete** works only while the folder tree has keyboard focus and never overrides the editor's text deletion. The active note and last-opened path are repaired after a move/rename.
- Markdown editing keeps native macOS undo/redo/cut/copy semantics and adds source-safe shortcuts: **⌘B** bold, **⌘I** italic, **⌘E** inline code, **⌘K** link, **⇧⌘1/2/3** headings, **⇧⌘8** bullet list and **⇧⌘9** task item. Standard **⌘V** still pastes text; when the clipboard contains an image, PKS Notes writes a collision-safe PNG into a note-local attachments directory and inserts the relative Markdown image reference at the current selection.
- The Markdown-backed **Mind Map** is a derived view, not a second document format: headings/lists become spatial parent/child nodes with curved connectors, collapse/expand, drag-to-reparent, keyboard selection, rename, safe leaf deletion, hierarchy promote/demote, zoom, trackpad magnification and **Fit to Window**. Node edits write back to the same Markdown draft and autosave path.
- **Mind map authoring / MindNode interoperability:** The titlebar More menu has **New Mind Map** for direct creation in the current folder; empty Markdown notes also offer **Create Mind Map**; Tab adds a child, Return adds a sibling, double-click renames a node; the toolbar imports version-9 MindNode Classic package files (.mindnode) **read-only**, imports/exports **OPML**, and exports full-map **PNG/PDF** through native macOS panels. Native import copies only titles/branches to a NEW Markdown note and explicitly reports that notes, images, tasks, style and connections are not preserved. An experimental **MindNode v9 native export** can clone a user-selected real v9 template into a NEW package; it fails on existing destination files or Markdown notes containing prose/non-outline content rather than silently discarding content. Original packages are never modified; malformed/unsupported formats fail closed. Native export has synthetic plist round-trip tests, but still needs real MindNode application opening tests. OPML is MindNode Classic/Next's officially supported interchange format. MindNode Next's distinct native format and real end-to-end MindNode v9 round-trip remain outstanding until verified with real application-created fixtures. Format research: masamitsu-konya/mindnode-mcp (MIT, schema version 9).

- The Relationships control shows three derived views without a second graph database: **Outgoing** Markdown/Wiki links, lazy **Backlinks** from the current workspace, and lazy **Related · PKS** results from the existing PKS index. All navigation reuses the same file/link opening authority.
- **Double-click a rendered Markdown preview to Edit**; use **⌘Return** to toggle Edit/Read in both directions. In Edit, double-click the blank page margin to Read, while a normal double-click on text retains native word selection. Existing ⌘1/⌘2/⌘3 reading modes still work and no extra toolbar was added.
- Native read-only PDFKit preview with zoom and text selection; other files use macOS default applications
- In-workspace Markdown links and images, with path containment checks
- PKS ranked cross-source search; view snippets and read out-of-workspace results without editing them
- Search result source labels with per-result ellipsis/right-click actions; Finder reveal, default app open, and path copy for local/managed files
- Duplicate PKS chunks are grouped per document while preserving ranked order; expand to see every matching section and its excerpt
- Search title/summary keywords are highlighted; click a match section to scroll the Markdown preview to its heading (or first matching heading section) without changing the source file
- Web-source browser/open-link actions; opaque URI fallback copies the source identifier without guessing a file path
- The note tree and title-bar ellipsis menu offer contextual file actions; missing files report a non-destructive error
- Debounced local Markdown autosave after 650 ms of inactivity, and immediate flush on note switch / quit. Saving shows only a small toolbar progress indicator. An external-edit conflict preserves the draft and retains native Save / Discard / Cancel protection before leaving
- ⌘P opens the existing native Quick Open palette; ⌘N or the sidebar New Note button **immediately creates a blank, focused editor**, generating collision-safe `Untitled.md`, `Untitled 2.md`, etc. without asking for a filename. The first typed content is saved by the existing autosave writer. ⌘F focuses PKS search, ⌘O selects the existing workspace, and folder right-click creates a blank note there.
- Markdown loads and preview parsing run off main actor; only changed Split drafts are debounced (~260 ms), already-parsed content survives view/theme changes, and canceled stale tasks cannot replace newer drafts
- Cmd+S is still available for immediate saves; no persistent Save button or success banner, and concurrent external edits are checked before every write
- Create notes beside the selected note (or at the workspace root), or explicitly inside a folder via its context menu; destinations are validated in-vault and exclusive file creation prevents overwrites. Empty new notes are already real `.md` files, so quit/switch never risks losing an in-memory-only unsaved note.

## Native design reference

The **Graphite** style follows [Nulis Notes Desktop Dark](https://dribbble.com/shots/19751267-Nulis-Notes-Desktop-App-Dark) by Rayfan Tio Saputro / Keitoto: charcoal editor canvas, darker navigation surface, editorial sans serif typography, restrained warm emphasis, simple macOS titlebar. The companion [Nulis light design](https://dribbble.com/shots/19726217-Nulis-Notes-Desktop-App) is a reference for light/dark consistency. The older light style is retained as another selectable preset. The second comparison is [Equal Desktop Notes App](https://dribbble.com/shots/24205265-Desktop-Notes-App) for text hierarchy. The earlier Bear/Panda light direction was explicitly rejected by user feedback. For Markdown and file-tree behavior, compare the open-source [MiaoYan](https://github.com/tw93/MiaoYan). This is an original SwiftUI implementation with the existing PKS source/renderer; no third-party brand assets, UI code or theme packages are imported.

Other UI research indexes: [Dribbble macOS UI](https://dribbble.com/search/macos-app-ui), [Mobbin](https://mobbin.com/), and [Collect UI](https://collectui.com/designs/mac-app-ui-design-inspiration) (this category currently has no designs to copy). Prefer shipped native product screenshots over unrelated dashboard or task manager mockups.

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
