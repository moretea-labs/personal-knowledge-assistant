# Leafspan mind-map migration (Mac V1)

## Canonical data and supported import

Leafspan stores editable mind maps as Markdown outlines, with image and file assets in a relative
`attachments/` directory. A native third-party package is treated as a source,
not a second writable document. Imports always create a new Markdown file, and
the source package is never edited or deleted.

- **MindNode Classic**: read-only native binary-plist packages (schema versions 7 and 9)
  and bounded ZIP single-file documents containing `contents.xml` and optional
  `resources/`. Import node titles, hierarchy, plain-text note paragraphs and
  supported attached PNG images. Recognized type-3 built-in PDF clip-art stickers
  are presentation metadata: they are omitted from Markdown and remain in the
  untouched source package. Unknown attachment records fail the import rather
  than disappearing. Single-file archives are read in-process; no archive paths
  are extracted to disk. The ZIP reader accepts stored/DEFLATE
  entries, rejects encrypted/ZIP64 or invalid-CRC entries, caps archives at
  64 MiB and individual entries at 12 MiB; PNG resources remain capped at 5 MiB.
- **MindNode Next**: read-only `Contents.data` packages with verified
  `fileFormatVersion: 1`. Import node titles, hierarchy, plain-text node notes
  and node-bound PDF attachments as Markdown blockquotes and links. PDFs are
  copied into the same note-local attachments directory; Markdown remains the
  only navigation authority. Rich note styling, built-in stickers, layout and
  cross-connections remain in the untouched source package.
- **XMind**: read-only common ZIP-based `content.json` and legacy `content.xml`
  forms. Import topic hierarchy, multiple sheets, JSON plain-text topic notes,
  and legacy XML plain notes. ZIP decoding uses bounded in-process zlib, not
  `/usr/bin/unzip` or extraction to disk. Only stored and DEFLATE entries are
  recognized; encrypted archives, unsupported ZIP64 variants and invalid CRCs
  are rejected.
- **OPML**: existing interchange for text-based hierarchy.

## Data-preservation policy

Original native documents remain intact; a failed or unsupported import must
not claim to have migrated data. Next note text is escaped as literal Markdown;
PNG and PDF filenames are validated before any source read. Unreferenced assets
and symlinks are rejected. New notes use O_EXCL, and imported images/PDFs reuse
the same collision-safe workspace attachment writer.

The following are **not** yet full-fidelity imports or native round trips:
styles, geometry/branch placement, note rich typography, unsupported attachment
types, native task markers, cross-connections, embedded relationships and native
XMind export. Do not delete original MindNode/XMind documents after importing.

## Verification

Focused XCTest suites: `MindNodePackageTests`, `XMindPackageTests`,
`WorkspaceExternalRefreshTests`. The real 36-package MindNode Classic library
has a separate opt-in, read-only audit. A synthetic Classic SFF ZIP fixture
verifies hierarchy, PNG import and source immutability; a real exported SFF
sample is still needed for native-format acceptance. The official Next Product Launch sample
imports 15 node-bound PDFs as 15 Markdown links; the source package remains
unchanged. Run it with `LEAFSPAN_REAL_MINDNODE_NEXT_DIR=<path> swift test --filter MindNodePackageTests/testOfficialMindNodeNextSamplesImportTopicTreesAndPDFAssets`.
As of 2026-11-12, the Classic corpus contains 3,100 source nodes, 3,091 rendered
visible topics, 104 note-bearing nodes, and one PNG attachment. Nine source
nodes act only as untitled structure and do not render as standalone topics.

The four known XMind files in iCloud were dataless placeholders at the last
inspection, so their exact original structure has **not** been acceptance-tested.
Do not describe synthetic ZIP fixture tests as complete native compatibility.
