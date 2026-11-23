# Leafspan mind-map migration (Mac V1)

## Canonical data and supported import

Leafspan stores editable mind maps as Markdown outlines, with image assets in a relative
`attachments/` directory. A native third-party package is treated as a source,
not a second writable document. Imports always create a new Markdown file, and
the source package is never edited or deleted.

- **MindNode**: read-only native binary-plist packages (schema versions 7 and 9).
  Import node titles, hierarchy, plain-text note paragraphs, and supported
  attached PNG images. Images are copied into Leafspan's existing attachments
  directory before committing the Markdown. Preserve the original rich note
  styling and native layout **only in the untouched source package**.
- **XMind**: read-only common ZIP-based `content.json` and legacy `content.xml`
  forms. Import topic hierarchy, multiple sheets, JSON plain-text topic notes,
  and legacy XML plain notes. ZIP decoding uses bounded in-process zlib, not
  `/usr/bin/unzip` or extraction to disk. Only stored and DEFLATE entries are
  recognized; encrypted archives, unsupported ZIP64 variants and invalid CRCs
  are rejected.
- **OPML**: existing interchange for text-based hierarchy.

## Data-preservation policy

Original native documents remain intact; a failed or unsupported import must
not claim to have migrated data. PNG image filenames are validated before any
source read; no ZIP entry path is written to disk. New notes use O_EXCL, and
imported images reuse the existing workspace attachment writer.

The following are **not** yet full-fidelity imports or native round trips:
styles, geometry/branch placement, note rich typography, non-PNG attachments,
native task markers, cross-connections, embedded relationships and native
XMind export. Do not delete original MindNode/XMind documents after importing.

## Verification

Focused XCTest suites: `MindNodePackageTests`, `XMindPackageTests`,
`WorkspaceExternalRefreshTests`. The real 36-package MindNode library has
a separate opt-in, read-only import audit; use
`LEAFSPAN_REAL_MINDNODE_DIR=<path> swift test --filter MindNodePackageTests/testRealMindNodeLibraryMigratesNoteText`.
As of 2026-11-12, the corpus contains 3,100 source nodes, 3,091 rendered
visible topics, 104 note-bearing nodes, and one PNG attachment. Nine source
nodes act only as untitled structure and do not render as standalone topics.

The four known XMind files in iCloud were dataless placeholders at the last
inspection, so their exact original structure has **not** been acceptance-tested.
Do not describe synthetic ZIP fixture tests as complete native compatibility.
