# Leafspan Bug Bash — executable regression plan

- Version: 2.0
- Date: 2026-11-19
- Authority: GitHub Issue #44 (bug tracking); Issue #37 (product behavior and experience); Issue #36 (release gate)
- Canonical source: `feature/pks-notes-mac-storekit-20261107`
- Baseline source snapshot when this plan was authored: `8a8f65b57c3efe2cbca401a8b0f634b3992149ad` (local branch one commit ahead of origin; see the issue for current reconciliation)

> This is a test specification, not a pass report. Every case starts as **NOT RUN**. Existing source tests, a successful build, or an old screenshot do not establish that the current installed app passes.

## 1. Why this version is more detailed

The earlier inventory named feature areas and broad expected outcomes. It did not consistently provide reproducible starting state, concrete user actions, boundary data, failure paths, or the evidence required to close a defect. Version 2 turns the reported bugs into executable scenarios and adds adjacent regressions that commonly share the same state, rendering, asynchronous, file-authority, or layout boundaries.

This plan covers:

- all 13 user-reported bug families in #44;
- adjacent issues already observed in #37: cold Global Search stalls/cancellation, stale query publication, Mind Map blank/offscreen initial layout, dense connector rendering, deep keyboard traversal, iCloud dataless hydration, PDF source drag/click-back, and VoiceOver action discovery;
- end-to-end combinations where individually passing components can still fail when used together.

The goal is not to maximize the number of checks. A case is useful only if a tester can reproduce it, determine pass/fail without guessing, and attach evidence to the exact app build.

## 2. Test safety and identity

### 2.1 Only test against an isolated fixture Vault

- Create all disposable Markdown, PDF, image, folder, link, and Mind Map data under a fresh temporary test root, for example `$TMPDIR/Leafspan-BugBash-<run-id>/`.
- Do not point destructive tests at the user's real Vault, Desktop, Documents, Downloads, or personal iCloud Drive.
- Do not use real study notes or source PDFs for drag, rename, move, delete, conflict, or recovery tests.
- For iCloud tests, use a dedicated disposable test folder and wait for File Provider state to be observed. A local file is not a substitute for a dataless placeholder.
- Record the fixture generator/version and a manifest of relative paths, byte sizes, line counts, node counts, and SHA-256 values. Reset fixtures by recreating the temporary root, never by cleaning a user's workspace.

### 2.2 Exact application under test

- Canonical installed app: `~/Applications/Leafspan.app`.
- Expected bundle identifier: `com.moretea.pks.notes`.
- Do not create a second QA app, alternate bundle ID, or parallel app installation.
- Before a GUI run, record app version/build, bundle identifier, executable path, signing identity, macOS version, display scale/resolution, appearance, window dimensions, and exact source HEAD used to build it.
- Confirm the foreground app is the canonical bundle. A Dock icon, process name, or old screenshot alone is not sufficient identity evidence.
- If the installed app does not correspond to the source revision being tested, mark the GUI case **BLOCKED**; do not infer a pass from source tests.

### 2.3 Required run header

Every execution record must include:

| Field | Required value |
|---|---|
| Run ID | Unique run identifier and date/time |
| Source | Branch + full 40-character HEAD |
| Build | App version/build + bundle ID + executable identity |
| Environment | macOS version, display scale, Light/Dark, window size |
| Fixture | Fixture set ID + manifest/hash |
| Test | Case ID and attempt number |
| Result | NOT RUN / PASS / FAIL / BLOCKED / N/A |
| Actual | What happened, not a paraphrase of expected |
| Evidence | Screenshot/video, focused test output, relevant logs, timing samples |
| Defect link | Existing #44 item or a new linked defect; never create a duplicate issue for the same root cause |

### 2.4 Evidence levels are not interchangeable

- **UNIT:** deterministic logic or state transformation.
- **INTEGRATION:** filesystem, persistence, async task ordering, parser/index interaction, or real temporary files.
- **GUI:** actual pointer/keyboard interaction and visible native layout on the canonical installed app.
- **PERF:** instrumented cold/warm measurements on a declared fixture.
- **ACCESSIBILITY:** actual keyboard-only or VoiceOver traversal; accessibility tree inspection alone is not a complete traversal.
- **END-TO-END:** multiple real user steps across more than one feature boundary.

A case requiring GUI evidence cannot pass from a unit test. A GUI case requiring a drag cannot pass from a simulated callback if the user-visible drag gesture was not exercised.

### 2.5 Result and defect rules

- **PASS:** every listed expected result and required evidence layer passes on the same source/build/fixture.
- **FAIL:** any expected result is false, data is lost/changed unexpectedly, or the visible behavior is wrong.
- **BLOCKED:** the required app build, permission, provider, device input, or fixture cannot be safely obtained. State the exact blocker; do not downgrade the requirement.
- **N/A:** only when the case genuinely does not apply to the product build; explain why.
- A failure record includes shortest reproduction, expected/actual, first bad state, recovery behavior, severity, exact HEAD/build, evidence, and suspected source path. Mark the root cause as confirmed only after source/runtime evidence supports it.
- P0: data loss/overwrite, path escape, unauthorized external write, cross-Vault data exposure, or unrecoverable crash. P1: primary workflow blocked or incorrect. P2: recoverable polish/accessibility issue.
- Do not close a test because a related test passed. Do not close a Bug because the code compiles.

## 3. Controlled fixture sets

Use a small fixture first, then scale only for the relevant case.

| Fixture | Contents | Purpose |
|---|---|---|
| V-SMALL | 2 Vaults; 3 levels of folders; 50 Markdown files; duplicate basenames in different folders; 4 PDFs; 6 images | Navigation, isolation, links, file operations |
| V-UNICODE | Chinese/Japanese/English names, emoji, full-width punctuation, spaces, parentheses, `#`, `?`, combining characters | Paths, search, links, copy/open |
| V-LARGE | 1,500 files / about 323 directories, plus a declared 10k-file variant | File tree, index, search, lazy loading |
| MD-EDGE | LF and CRLF notes; single newline; blank paragraphs; hard breaks; lists; nested lists; blockquotes; tables; links; images; fenced code; CJK/IME text | Markdown semantics and editor behavior |
| MD-LONG | 50,000-line note, long paragraphs, many headings, code blocks, tables, links and images | Open, edit, render, scroll and search performance |
| MAP-EDGE | 9-level chain plus shallow sibling; long labels; mixed branch depth; multiple roots; 80 siblings | Keyboard, geometry, connector and viewport regressions |
| MAP-LARGE | 1,000-node Markdown-derived outline, including dense fan-outs and deep branches | Map layout, pan/zoom, rendering and memory |
| PDF-LOCAL | Valid 2-page and 100-page PDFs; searchable text; outline/bookmarks; selectable passages | Reader and source-citation flow |
| PDF-UNICODE | PDF in Chinese-named folders with reserved URL characters in the filename | Source URL encoding and anchor round-trip |
| PDF-ICLOUD | Disposable dataless PDF and Markdown placeholders in a dedicated iCloud test folder | Hydration, cancellation, retry and provider failure |
| FILE-EDGE | Same-name collision, read-only folder, symlink pointing outside Vault, deleted/moved external file | File authority and path safety |
| REL-GRAPH | A→B, B←A, multiple backlinks, duplicate link occurrences, broken target, same-title notes, unrelated notes | Relationship semantics and stale-link handling |

### 3.1 Deterministic fixture recipe

Use these names and sentinel strings so two testers can compare the same result set. The fixture generator may be a local script or manual setup, but it must produce this same manifest and record its own version.

**Vault isolation and search sentinels**

- Create `Vault-A` and `Vault-B`; each contains `Notes/Overview.md` and `Research/Target.md` at identical relative paths, but different bodies.
- `Vault-A/Notes/Overview.md` contains `vault-a-only-needle-2026`; `Vault-B/Notes/Overview.md` contains `vault-b-only-needle-2026`.
- Put `body-only-needle-2026` in the body of one note whose filename does not contain that token. Put `filename-only-needle-2026.md` in a different note whose body does not contain the token. Put `folder-only-needle-2026` in a directory name only.
- Create `Projects/Alpha/Meeting.md` and `Projects/Beta/Meeting.md` with distinct contents; these are the same-basename/path-disambiguation pair.
- V-UNICODE includes `论文/中文搜索词 (2026)#版本?.md`, one Japanese-named note, emoji in a filename, and a combining-character filename. Also create `吉他谱/夜的钢琴曲五.pdf` and `ye-de-gang-qin-qu-five.pdf` with binary-only placeholder bytes; the pinyin/Chinese filename query pair must find exactly these two files without reading PDF bodies. Use the same content across repeated runs.

**Markdown edge fixture**

- `MD-EDGE/soft-break.md`: two prose lines separated by exactly one newline; then a blank line; then a new paragraph. Expected search and preview distinguish the soft break from the paragraph boundary.
- Include a second paragraph with an explicit hard break made by two trailing spaces, a third using a backslash hard break, and a fourth using `<br>`. Do not normalize these markers when copying the fixture.
- Include nested bullet/ordered/task lists, a nested blockquote, a table, a link, an image reference, and a fenced Swift block containing blank lines and indentation.
- Include the same semantic note once with LF and once with CRLF. Record byte hashes before opening; after Read/Edit/Split tests, compare hashes when no edit was intended.
- `MD-LONG` must contain exactly 50,000 logical lines. Include a heading every 1,000 lines and unique markers at lines 1, 25,000 and 50,000 so first/middle/end navigation is unambiguous.

**Mind Map fixtures**

- `MAP-EDGE/deep.md`: one root, a nine-level nested list chain, and a shallow sibling after the deep branch. Add one long Chinese label and one long English label.
- Add a separate parent with exactly 80 direct children; child labels are unique and numbered `Child-001` through `Child-080`.
- `MAP-LARGE`: exactly 1,000 Markdown-derived nodes: 10 root headings × 9 child headings per root × 10 leaf headings per child (10 + 90 + 900). Number every node in its title. This gives repeatable depth, fan-out and node count.

**Relationships and file safety fixtures**

- `REL-GRAPH/A.md` links to B twice and C once; B links back to A; C links to A; D has no links. Add a second note with the same basename as B under another folder. Include one broken target.
- `FILE-EDGE/Outside/DoNotModify.md` is outside the Vault. Add a symlink inside the test Vault pointing to it; create a separate read-only directory for failed-write tests. Record the real canonical path of the outside file and its hash before the test.

**PDF fixtures**

- PDF-LOCAL 2-page file: page 1 contains `PDF-ANCHOR-ALPHA-2026`; page 2 contains `PDF-ANCHOR-BETA-2026`. The 100-page variant contains a unique `PDF-PAGE-NNN` marker on every page and a nested outline/bookmark tree.
- PDF-UNICODE lives at `论文/来源 (2026)#版本?.pdf`; use the same page markers and citation path round-trip as PDF-LOCAL.
- PDF-ICLOUD must be a real File Provider placeholder in a dedicated disposable iCloud test folder. Record its dataless/not-downloaded status before opening and its current/downloaded status after hydration. Never simulate this by renaming a local PDF.

**V-LARGE exact distribution**

- For the 1,500-file / 323-directory fixture, create the root plus 322 child directories named `D000`…`D321`. Put 5 uniquely named files in the first 210 directories (1,050 files), 4 in the remaining 112 directories (448 files), and 2 files in the root: exactly 1,500 files total.
- Each file has a unique filename token; a fixed subset of Markdown files contains body-only search markers. The 10k variant must have its own exact directory/file count and manifest; do not extrapolate its result from V-LARGE.

**Fixed search query set**

| Query | Intended match | Negative assertion |
|---|---|---|
| `filename-only-needle-2026` | One filename hit | No unrelated body-only hit |
| `folder-only-needle-2026` | Path/folder hit | Do not label it as a filename match |
| `body-only-needle-2026` | One Markdown body hit | Do not open a same-name file |
| `vault-a-only-needle-2026` | Vault A only | Zero results after switching to B |
| `vault-b-only-needle-2026` | Vault B only | Zero results after switching to A |
| `夜的钢琴曲` / `ye de gang qin qu` | Exactly `夜的钢琴曲五.pdf` and `ye-de-gang-qin-qu-five.pdf` | No PDF body reads and no unrelated result |
| `中文搜索词` | The fixed V-UNICODE note | No unrelated same-title result |

For every fixture, store the relative-path manifest, exact file count, byte/line/node/page counts and SHA-256 values. If the generated fixture differs, mark dependent cases BLOCKED or regenerate it; do not silently adjust expected results.

Fixture size is part of the test input. “Large” without a manifest is not reproducible. Never claim a 10k/50k result based on a smaller fixture.

## 4. Detailed executable cases

### A. Vault selection, isolation and restoration — VAULT

| ID / priority / layer | Setup | Steps | Pass criteria |
|---|---|---|---|
| VAULT-01 · P1 · GUI | V-SMALL; open Vault A and B, each with a note named `Overview.md`. | 1. Start in A. 2. Locate the Vault switch using the normal UI, without relying on a hidden test shortcut. 3. Switch to B. 4. Switch back to A. | Switch entry is discoverable; active Vault is always visible/identifiable; no restart or manual path editing is needed. |
| VAULT-02 · P0 · GUI+INTEGRATION | A and B contain same relative filenames but different content, Recent entries and Favorites. | 1. Open A/Overview. 2. Search for a unique A-only phrase. 3. Switch to B. 4. Search the same phrase and inspect tree/Recent/Favorites. | B shows only B-owned files and state. A's content, paths, search hits and favorites never leak into B. |
| VAULT-03 · P1 · GUI+PERSISTENCE | Both Vaults have expanded folders and a selected note. | 1. In A, expand two folders and scroll the tree. 2. Select a note and record its position. 3. Switch to B and change its tree state. 4. Return to A. | Each Vault restores its own valid selection/expansion/scroll state; B's state does not overwrite A's. |
| VAULT-04 · P0 · INTEGRATION+GUI | A note is open and dirty in A; B has a same-name note. | 1. Edit A's note without saving. 2. Switch Vault. 3. Inspect the active document and save affordance. 4. Reopen A and inspect both files. | A draft is never silently written to B. Switching either safely saves under the original A authority or clearly blocks/asks for resolution; no wrong-path write occurs. |
| VAULT-05 · P1 · GUI+INTEGRATION | Dedicated test Vault with revocable folder permission. | 1. Open and use the Vault. 2. Revoke its folder permission through macOS privacy controls while the app is closed. 3. Reopen Leafspan. 4. Restore permission and retry. | Permission loss is explicit and recoverable; no blank “empty Vault” state is presented as success; restored permission returns the same Vault without creating a duplicate. |
| VAULT-06 · P1 · GUI+PERSISTENCE | Test Vault can be moved or renamed. | 1. Close the app normally. 2. Move/rename the test root externally. 3. Reopen Leafspan. 4. Follow the recovery/reselect path. | Stale bookmark/path is detected; user can select the moved root; no unrelated folder is silently adopted. |
| VAULT-07 · P1 · INTEGRATION+GUI | A and B have different files; one open/search can be delayed using a controlled slow fixture. | 1. Start opening/searching A. 2. Switch A→B→A rapidly. 3. Wait for all delayed work to settle. | Only the currently selected Vault publishes results or document state. Late A/B callbacks cannot replace the winning Vault's content. |
| VAULT-08 · P1 · GUI | Empty Vault and read-only Vault fixtures. | 1. Open the empty Vault. 2. Use search/tree/create actions. 3. Open the read-only Vault. 4. Attempt a safe edit and save. | Empty state offers valid next actions; read-only state is clear; failed writes do not masquerade as saved and do not crash. |

### B. File tree, sidebar position and window geometry — TREE

| ID / priority / layer | Setup | Steps | Pass criteria |
|---|---|---|---|
| TREE-01 · P1 · GUI | V-SMALL; tree initially on its default side. | 1. Find the documented menu/shortcut for moving the tree to the opposite side. 2. Move it. 3. Move it back. | Both directions are discoverable; layout changes once without opening a duplicate window or losing the active document. |
| TREE-02 · P1 · GUI | Tree has nested expansion, selection, scroll offset and keyboard focus. | 1. Record these states. 2. Move tree left→right→left. 3. Use Up/Down/Return immediately after each move. | Selection, expansion, scroll and focus remain coherent; keyboard commands act on the visible tree, not a detached old pane. |
| TREE-03 · P1 · INTEGRATION+GUI | A folder contains 5 direct children and 5 nested levels below one child. | 1. Expand only the parent. 2. Observe loading. 3. Collapse it. 4. Reopen it. | Only required directories load; collapsed descendants do not trigger an unbounded recursive scan; reopening does not duplicate rows. |
| TREE-04 · P1 · GUI | Duplicate basenames in different folders. | 1. Navigate to each file via tree and Quick Open. 2. Inspect path/context labels. 3. Open each. | The selected path is unambiguous; opening one same-name result never opens another. |
| TREE-05 · P1 · INTEGRATION+GUI | External fixture folder can be changed while Leafspan is open. | 1. Add a file externally. 2. Rename another. 3. Delete a third. 4. Wait for refresh. | Only affected visible/materialized directories refresh; additions, renames and removals appear once; unrelated expanded subtrees remain intact. |
| TREE-06 · P1 · GUI | Deep folder tree and keyboard-only input available. | 1. Focus the tree. 2. Navigate with Up/Down. 3. Expand/collapse with the supported keys. 4. Open with Return. 5. Return focus to search/editor. | Focus order is deterministic; no skipped/duplicated rows; focus never disappears behind a sheet or toolbar. |
| TREE-07 · P2 · GUI | Window at normal, narrow and minimum supported sizes. | 1. Resize through each width. 2. Move tree to both sides. 3. Expand long Chinese and English filenames. | File names and selection indicators remain legible; truncation does not hide file identity; no controls overlap the document. |
| TREE-08 · P1 · GUI | Tree and inspector both visible. | 1. Open More and other tree/toolbar menus. 2. Dismiss with Escape and outside click. 3. Reopen after changing window size. | Menus anchor to the correct control, stay within the window, dismiss predictably and do not steal document focus after closing. |

### C. Read / Edit / Split / Mind Map mode ownership — VIEW

| ID / priority / layer | Setup | Steps | Pass criteria |
|---|---|---|---|
| VIEW-01 · P1 · GUI+PERSISTENCE | Note A in Read; note B in Edit. | 1. Set A to Read and B to Edit. 2. Switch A↔B several times. 3. Close/reopen each. | Mode is restored according to the product's per-document/per-view rule; one document's mode does not overwrite another's. |
| VIEW-02 · P1 · GUI | Note A in Read with known scroll position. | 1. Enter Mind Map. 2. Select a deep node. 3. Return to the note. | Previous Read mode and its reading position are restored; returning from Mind Map does not silently force Edit or Split. |
| VIEW-03 · P1 · GUI | Note A in Edit and note B in Split. | 1. Switch A→B→A. 2. Reopen A from search. 3. Return to B. | The correct prior mode is restored for each document; no cross-document mode bleed. |
| VIEW-04 · P1 · PERSISTENCE+GUI | A and B have different modes, cursors and scroll positions. | 1. Quit normally. 2. Relaunch. 3. Open A then B. | Restoration is deterministic and tied to the correct document; invalid/deleted targets recover without a blank window. |
| VIEW-05 · P1 · GUI | Stable note with visible toolbar and editor selection. | 1. Toggle Read/Edit/Split/Mind Map rapidly for 20 cycles. 2. Stop on each mode. 3. Continue typing and scrolling. | No stale mode, duplicate pane, blank frame, stuck spinner, lost selection or toolbar jump remains after settling. |
| VIEW-06 · P1 · GUI | Editor cursor, selected text, scroll anchor and keyboard focus are set. | 1. Switch modes. 2. Return. 3. Use typing, arrow keys, Undo and Outline navigation. | Focus and selection return to the intended document/editor; no keystroke goes to an invisible or previous document. |
| VIEW-07 · P1 · GUI+VIDEO | Normal/narrow window; Light/Dark; Reduce Motion on/off. | 1. Enter/exit Split repeatedly. 2. Resize during transition. 3. Open/close toolbar menus during transition. | Toolbar frame, baseline, content origin and hit targets remain stable; no visible flicker, jump, overlap or animation race. |

### D. Split view synchronization and layout — SPLIT

| ID / priority / layer | Setup | Steps | Pass criteria |
|---|---|---|---|
| SPLIT-01 · P1 · GUI+VIDEO | Same long note in both panes; headings and paragraph anchors are present. | 1. Scroll the left pane slowly. 2. Scroll the right pane. 3. Repeat in reverse direction. | Both panes synchronize by meaningful content anchors; neither direction is one-way; no continuous feedback loop. |
| SPLIT-02 · P1 · GUI | Two panes have unequal content heights due to wrapping, headings, lists and images. | 1. Scroll through matching headings. 2. Compare visible semantic anchors, not raw pixel offsets. | Equivalent content stays aligned even when block heights differ; no drift accumulates toward the end. |
| SPLIT-03 · P1 · GUI+INTEGRATION | Cursor is near the middle; both panes aligned to a later heading. | 1. Insert several paragraphs above the current anchor in Edit. 2. Wait for preview. 3. Continue scrolling. | The semantic anchor remains the same; the sync engine does not jump to the old absolute pixel offset. |
| SPLIT-04 · P1 · GUI+INTEGRATION | Both panes are aligned; editor is writable. | 1. Delete the current anchor heading. 2. Insert a new heading nearby. 3. Scroll both directions. | Missing anchors fall back to the nearest valid content position; no crash, oscillation or unrelated jump. |
| SPLIT-05 · P1 · GUI | One pane is at top, the other at bottom; one document is shorter. | 1. Scroll each to the end. 2. Scroll back to top. 3. Repeat with an empty note. | End-of-document and empty-pane states remain stable; a shorter pane does not force the longer pane into repeated jumps. |
| SPLIT-06 · P1 · GUI | Note includes large image, code block, table, blockquote and nested list. | 1. Scroll across each tall block. 2. Resize the window to change wrapping. | Anchor mapping survives variable-height blocks; no connector/scroll sync jumps to the wrong block. |
| SPLIT-07 · P1 · GUI | Font size, line spacing, theme and window width can change. | 1. Align panes. 2. Change one typography setting. 3. Resize. 4. Scroll again. | Layout remeasurement does not corrupt the anchor; sync remains correct after reflow. |
| SPLIT-08 · P1 · GUI+VIDEO | Long note and two visible scrollbars. | 1. Flick-scroll left. 2. Immediately flick-scroll right. 3. Alternate rapidly and stop mid-scroll. | No ping-pong, jitter, delayed reverse jump or runaway scroll task; final positions settle on the intended anchor. |

### E. Markdown editing, rendering and source integrity — MD

| ID / priority / layer | Setup | Steps | Pass criteria |
|---|---|---|---|
| MD-01 · P1 · GUI | MD-EDGE contains a paragraph with two ordinary lines separated by exactly one LF. | 1. Open in Edit. 2. Place cursor at end of line 1. 3. Press Enter once. 4. Switch to Read and Split. | The preview displays a visual line break; it does not merge the lines with a space; the source contains only the user's single newline. |
| MD-02 · P1 · GUI+INTEGRATION | MD-EDGE has two paragraphs separated by one blank line. | 1. Open in Read. 2. Compare paragraph spacing. 3. Switch Edit→Read→Split. | Blank line remains a paragraph boundary; the paragraph spacing is retained; no extra empty block is invented or removed. |
| MD-03 · P1 · GUI+INTEGRATION | Note contains two trailing spaces, backslash hard break and explicit `<br>`. | 1. Open Read. 2. Compare each hard break with MD-01. 3. Save/reopen. | Explicit hard-break semantics remain valid; no duplicate line break appears; source markers are preserved exactly. |
| MD-04 · P1 · GUI | Nested ordered, bullet and task lists contain single newlines. | 1. Open in Read. 2. Edit one item. 3. Press Enter at the end of an item. 4. Save/reopen. | List nesting, numbering and task state remain correct; soft breaks do not flatten list items or create unintended sibling items. |
| MD-05 · P1 · GUI | Blockquote with several lines and nested quote. | 1. Read the quote. 2. Edit one line. 3. Switch modes. | Quote line breaks and nesting remain visually correct; quote markers are not rewritten by preview. |
| MD-06 · P1 · GUI+INTEGRATION | Fenced code block with blank lines, indentation and mixed LF/CRLF. | 1. Open in Read. 2. Compare code line-by-line. 3. Edit an adjacent paragraph. 4. Save/reopen. | Code indentation and every line break are preserved; prose soft-break settings do not alter code blocks. |
| MD-07 · P1 · GUI | Chinese IME enabled; note contains Chinese/English mixed text. | 1. Start an IME composition. 2. Switch focus only after composition commits. 3. Type punctuation/emoji. 4. Undo once. | No partial composition is dropped, duplicated or committed into another pane; cursor and text remain correct. |
| MD-08 · P1 · GUI | Multiline plain text in clipboard, including blank lines and tabs. | 1. Place cursor mid-paragraph. 2. Paste. 3. Undo. 4. Redo. | Pasted line structure is predictable; no double escaping or normalization; Undo restores the exact prior source. |
| MD-09 · P1 · GUI | Clipboard contains an image and a rich-text selection. | 1. Paste into a note. 2. Save/reopen. 3. Click the inserted image/link. | Supported paste behavior is clear; attachment paths resolve within the Vault; no silent external write or broken image path. |
| MD-10 · P1 · GUI+INTEGRATION | Selection spans heading, emphasis, list and Unicode text. | 1. Apply formatting. 2. Undo. 3. Redo. 4. Save/reopen. | Selection range and UTF-16 offsets remain valid; formatting toggles once; no neighboring character or CJK grapheme is lost. |
| MD-11 · P1 · GUI+INTEGRATION | Note is dirty and autosave is enabled. | 1. Type a known marker. 2. Wait for autosave. 3. Switch note and return. 4. Relaunch. | Marker persists exactly once; UI does not claim saved before durable write completes; no extra writer overwrites the latest draft. |
| MD-12 · P0 · INTEGRATION+GUI | Note open and dirty; external process writes a different version to the same file. | 1. Keep Leafspan draft unsaved. 2. Change the file externally. 3. Trigger save. 4. Use recovery action. | Conflict is detected; original external content is not overwritten silently; draft remains recoverable; save-copy path is unique. |
| MD-13 · P0 · INTEGRATION+GUI | Open note is deleted or moved externally while dirty. | 1. Type a draft. 2. Delete/move the source file externally. 3. Trigger save and reopen. | No silent recreation at an unintended path; user is told the source disappeared; draft can be recovered without replacing another file. |
| MD-14 · P1 · PERF+GUI | MD-LONG (50,000 lines) with headings, tables, links and code blocks. | 1. Cold-open. 2. Switch Read/Edit/Split. 3. Scroll to top/middle/end. 4. Type near the middle. 5. Save/reopen. | No repeated whole-page flash, stale preview replacing newer text, visible dropped frames that block use, or source loss; capture timing and frame evidence. |

### F. Quick Open and Global Search — SEARCH

| ID / priority / layer | Setup | Steps | Pass criteria |
|---|---|---|---|
| SEARCH-01 · P1 · PERF+GUI | Cold V-LARGE; full-vault index has not been warmed. | 1. Open Global Search. 2. Enter a filename known to the already-loaded tree. 3. Observe first results while full indexing continues. | Useful filename results appear before the cold full-vault scan finishes; input remains responsive; no second index is created. |
| SEARCH-02 · P1 · GUI+VIDEO | Query returns more than one page of results; later source results are delayed. | 1. Enter query. 2. Record first page order/selection/scroll. 3. Wait for later results. | New results append/merge without resetting the visible list, selection, scroll position or focus; duplicates are not introduced. |
| SEARCH-03 · P0 · INTEGRATION+GUI | Query A and query B return disjoint unique results; A can be delayed. | 1. Enter A. 2. Immediately replace with B. 3. Wait for A and B callbacks. | Only B results remain eligible for publication; no stale A row, count, snippet, loading state or selected item leaks into B. |
| SEARCH-04 · P1 · GUI+INTEGRATION | Search is actively scanning a slow fixture. | 1. Start search. 2. Cancel with visible Cancel. 3. Repeat with Escape. 4. Close the search window. | Cancellation stops unnecessary work promptly; UI exits loading; old callbacks cannot repopulate closed/replaced results. |
| SEARCH-05 · P1 · GUI | Vault has nested folders and multiple supported file types. | 1. Search all Vault. 2. Limit to one folder. 3. Select Markdown/PDF/image type filters. 4. Clear filters. | Scope and type filters compose predictably; clearing restores all results; labels indicate the source and scope. |
| SEARCH-06 · P1 · INTEGRATION+GUI | V-UNICODE includes filename-only, path-only and body-only terms. | 1. Search each unique term. 2. Compare result source, title and excerpt. 3. Open the result. | Filename, folder path and Markdown body matches are distinguishable and correct; excerpt belongs to the selected file. |
| SEARCH-07 · P1 · INTEGRATION+GUI | Chinese filename/body corpus includes known pinyin and typo pairs. | 1. Search exact Chinese. 2. Search pinyin. 3. Search a documented typo/fuzzy form. 4. Compare ranking. | Supported CJK/pinyin/fuzzy behavior is measured against a fixed corpus; ranking is stable and no unrelated result outranks an exact match without a documented rule. |
| SEARCH-08 · P1 · GUI | Use no-match query, offline state and a controlled source error. | 1. Search a nonexistent term. 2. Repeat with a search source unavailable. 3. Retry after recovery. | No-results differs from source failure; failure is visible and retryable; app does not spin indefinitely or claim complete results when a source failed. |
| SEARCH-09 · P1 · GUI | Search hits include Markdown, PDF, image and unsupported file. | 1. Open each supported result. 2. Open unsupported result. 3. Return to search. | Markdown/PDF/image open in Leafspan's native view; only unsupported formats use macOS default app; return preserves query and selected result. |
| SEARCH-10 · P1 · GUI | Search results include files in nested folders. | 1. Use “Open” on a file. 2. Use “Show in Finder”. 3. Open a folder result. | Open, reveal in Finder and open-folder actions are distinct and accurate; none silently substitutes for another. |
| SEARCH-11 · P1 · GUI | Result path includes Unicode, spaces and reserved characters. | 1. Copy path. 2. Paste into a text field and Finder path entry. 3. Copy filename separately. | Copied path/name is exact, untruncated and correctly escaped for its target; no wrong same-name path is copied. |
| SEARCH-12 · P1 · GUI | Search hit is in a long note with repeated phrases. | 1. Open the hit. 2. Inspect the highlighted/selected match. 3. Move to next/previous match. 4. Change note. | Navigation reaches the exact intended section/paragraph; repeated snippets are disambiguated; stale match navigation cannot jump in the next note. |

### G. Markdown-derived Mind Map — MAP

| ID / priority / layer | Setup | Steps | Pass criteria |
|---|---|---|---|
| MAP-01 · P1 · GUI+INTEGRATION | Note with one root and several children. | 1. Select a node. 2. Press Tab to create a child. 3. Rename it. 4. Save/reopen. | Node appears at the correct hierarchy level and persists in the same Markdown outline; no parallel graph-only node is created. |
| MAP-02 · P1 · GUI+INTEGRATION | Node with sibling nodes. | 1. Select a node. 2. Press Return to create a sibling. 3. Move it up/down. 4. Save/reopen. | Sibling order is correct and stable; Markdown preorder and visible map order agree. |
| MAP-03 · P1 · GUI | Node title is long and contains CJK/emoji. | 1. Double-click to edit. 2. Replace text. 3. Commit with Return and then cancel with Escape in a second attempt. | Inline edit is discoverable; commit/cancel semantics are distinct; no accidental duplicate node or lost character. |
| MAP-04 · P1 · GUI+INTEGRATION | Parent with two branches and a multi-line subtree. | 1. Drag a subtree under another parent. 2. Reorder within siblings. 3. Save/reopen. | Reparent and reorder produce the expected Markdown hierarchy; all descendant links/citations stay attached to their nodes. |
| MAP-05 · P0 · INTEGRATION+GUI | A→B→C hierarchy. | 1. Attempt to drag A under C. 2. Attempt to move a node into itself/descendant. | Cycles and self-parenting are rejected before write; source remains unchanged and UI gives a clear result. |
| MAP-06 · P0 · GUI+INTEGRATION | Parent with multiple descendants and linked citations. | 1. Delete one child. 2. Inspect confirmation/undo behavior. 3. Reopen. 4. Repeat for a parent with descendants. | Delete scope is explicit; unrelated siblings remain; subtree/link deletion follows product semantics; no silent mass deletion. |
| MAP-07 · P1 · GUI+PERSISTENCE | Several expanded and collapsed branches. | 1. Collapse one branch. 2. Collapse another. 3. Switch to Read/Edit. 4. Return and relaunch. | Collapse state follows the documented persistence rule; one branch's toggle does not collapse unrelated branches. |
| MAP-08 · P1 · GUI | MAP-EDGE nine-level chain plus a shallow sibling. | 1. Focus root. 2. Navigate to level 9 with child navigation. 3. Reverse to root. 4. Navigate to sibling. | Deepest node is reachable and reversible; sibling is not mistaken for a child; focus/selection remains visible and centered as required. |
| MAP-09 · P1 · GUI+VIDEO | One parent with 80 children. | 1. Open fully expanded. 2. Inspect shared trunk and each child spur. 3. Pan along the trunk. 4. Zoom in/out. | Connectors remain continuous, attached and non-overlapping; no missing segments or duplicated strokes; viewport culling does not remove the shared spine. |
| MAP-10 · P1 · PERF+GUI | MAP-LARGE (1,000 nodes), multiple roots and dense fan-outs. | 1. Cold-open. 2. Pan in four directions. 3. Zoom in/out repeatedly. 4. Collapse/expand branches. | No long main-thread stall or unusable frame freeze; connectors track nodes; selection and text remain crisp and attached. |
| MAP-11 · P1 · GUI | Mixed short/deep branches, long labels, narrow window and inspector closed/open. | 1. Cold-open at normal size. 2. Repeat at narrow size. 3. Open/close Node Details. 4. Inspect root and outer branches. | Initial map is not a large blank canvas; important nodes are not clipped/offscreen; cards are readable; optional details do not permanently consume the document width. |
| MAP-12 · P0 · END-TO-END | Nodes contain Markdown links and PDF source citations. | 1. Reparent a linked node. 2. Switch to Markdown. 3. Save/reopen. 4. Follow its source link. 5. Return from PDF. | Link and citation follow the same Markdown-owned node; exact source anchor still resolves; no second relationship store is introduced. |

### H. Relationships — REL

| ID / priority / layer | Setup | Steps | Pass criteria |
|---|---|---|---|
| REL-01 · P1 · GUI | Current note A links to B and C. | 1. Open A's Relationships. 2. Inspect Outgoing. 3. Follow each entry. | Outgoing contains only links authored by A; each row explains target and source location; opening lands on the correct note/heading. |
| REL-02 · P1 · GUI+INTEGRATION | B and C link to A; D does not. | 1. Open A's Backlinks. 2. Open each source. 3. Add a link from D and refresh. | Backlinks list notes that point to A, not notes A points to; D appears only after its source change is indexed; duplicates follow the declared occurrence/grouping rule. |
| REL-03 · P1 · GUI | Library contains direct and related-but-not-direct material. | 1. Open Related · Library. 2. Inspect several rows. 3. Ask why each is related using the visible UI. | Related results are not mislabeled as direct links; relation reason/source is understandable; coverage and limitations are disclosed in product language. |
| REL-04 · P1 · GUI+INTEGRATION | Two notes share the same title in different folders. | 1. Link to each exact path. 2. Inspect Relationships. 3. Follow both. | Path identity, not title alone, selects the target; ambiguous titles are disambiguated; no wrong same-name note opens. |
| REL-05 · P1 · GUI+INTEGRATION | One valid and one broken link. | 1. Open the source note. 2. Inspect relationship state. 3. Use repair action on broken link. 4. Reopen. | Broken link is visible and distinguishable; repair is explicit; valid link remains unchanged; no silent link retargeting. |
| REL-06 · P0 · INTEGRATION+GUI | A is linked from multiple notes and one Mind Map node. | 1. Rename/move A within the Vault. 2. Inspect every source. 3. Follow links and reopen map. | Only references that should follow the moved target are updated; unrelated links are untouched; stale paths do not silently resolve to a same-name file. |
| REL-07 · P1 · INTEGRATION | REL-GRAPH includes A↔B cycles, repeated links and self-links. | 1. Open A, then B. 2. Switch relationship categories repeatedly. 3. Refresh after edits. | No infinite traversal, duplicated rows beyond the declared occurrence rule, or recursive UI freeze; category meaning remains stable. |
| REL-08 · P0 · GUI+INTEGRATION | External/read-only related content exists outside the active Vault. | 1. Open a related external item. 2. Attempt edit, rename, move and delete through every exposed action. | External preview remains read-only; no action writes outside the active Vault unless an explicit supported import/copy flow is chosen. |

### I. File-type routing and Finder drag/drop — OPEN / DROP

| ID / priority / layer | Setup | Steps | Pass criteria |
|---|---|---|---|
| OPEN-01 · P1 · GUI | Search/Quick Open hit for Markdown. | 1. Select the hit. 2. Press Return/double-click. 3. Return to search. | Markdown opens in Leafspan's editor/reader; the system default editor is not launched; query state is preserved. |
| OPEN-02 · P1 · GUI | Search hit for local PDF. | 1. Open the result. 2. Navigate a page. 3. Return to search. | PDF opens in Leafspan's PDF reader; correct file and page state are shown; no external app is used. |
| OPEN-03 · P1 · GUI | Search hit for a supported image. | 1. Open the result. 2. Zoom/fit if supported. 3. Return to search. | Image opens in the app's supported native viewer; unsupported image variants are handled explicitly rather than silently misrouted. |
| OPEN-04 · P1 · GUI | Search hit for a deliberately unsupported type. | 1. Open the result. 2. Observe the handoff. 3. Return to Leafspan. | Only unsupported types use the macOS default app; the UI communicates the handoff and retains Leafspan state. |
| OPEN-05 · P1 · GUI | Search results include a folder and a file inside it. | 1. Open the folder result. 2. Use Show in Finder on the file. 3. Use Open on the file. | Open-folder, reveal-in-Finder and open-file have distinct, correct outcomes; folder actions never masquerade as file preview. |
| DROP-01 · P1 · GUI | Clean temporary Markdown file in Finder. | 1. Drag it over the document canvas. 2. Observe valid-target feedback. 3. Drop. 4. Switch modes and return. | Supported Markdown opens in Leafspan; drag does not move/copy the source; current document ownership updates once. |
| DROP-02 · P1 · GUI | Temporary PDF and image files. | 1. Drag each into the document canvas. 2. Drop separately. 3. Open each result. | Supported PDF/image opens in its native Leafspan view; no external default-app launch; source files remain at original paths. |
| DROP-03 · P1 · GUI | Unsupported file, folder and multi-file selection. | 1. Drag each over valid and invalid targets. 2. Press Escape before drop. 3. Drop unsupported items. | Supported behavior or rejection is explicit; Escape cancels; no accidental move, copy, import or silent no-op occurs. |
| DROP-04 · P0 · GUI+INTEGRATION | Current Markdown note has an unsaved draft. | 1. Start a Finder drag. 2. Hover over the canvas. 3. Cancel once; repeat and drop another file. 4. Reopen the original note. | Drag hover/drop cannot overwrite or discard the draft; only the intended target opens; original file content remains unchanged. |

### J. PDF reading and evidence-linked study loop — PDF

| ID / priority / layer | Setup | Steps | Pass criteria |
|---|---|---|---|
| PDF-01 · P1 · GUI | PDF-LOCAL 2-page and 100-page files. | 1. Open each. 2. Navigate next/previous and jump to a page. 3. Zoom/fit width. 4. Close/reopen. | Page count, current page and zoom are correct; last position follows the persistence rule; invalid page input is rejected safely. |
| PDF-02 · P1 · INTEGRATION+GUI | PDF-ICLOUD contains a genuinely dataless placeholder. | 1. Open from tree. 2. Observe hydration progress. 3. Wait for current/downloaded state. 4. Navigate/search. | PDFKit parsing starts only after hydration; UI stays responsive; no false “corrupt PDF” error is shown for a not-yet-downloaded file. |
| PDF-03 · P1 · GUI+INTEGRATION | PDF has repeated search terms; query A can be delayed. | 1. Search A. 2. Replace with B. 3. Cancel B. 4. Wait for late A callbacks. | Only the latest query publishes matches; cancel clears active state; old matches cannot be selected after a query change. |
| PDF-04 · P0 · END-TO-END | PDF-LOCAL has a selectable paragraph; target Markdown note is disposable. | 1. Select a phrase in PDF. 2. Drag to a chosen Markdown cursor position. 3. Add a personal note if offered. 4. Save. | User's selected quote is inserted at the chosen position with canonical PDF path/page/anchor; PDF itself is not modified. |
| PDF-05 · P0 · END-TO-END | Complete PDF-04 and close both views. | 1. Quit normally. 2. Relaunch. 3. Open the Markdown citation. 4. Follow it to PDF. | The same PDF and page reopen; exact selection is restored when fingerprint/geometry validates; the action does not jump to a same-name PDF. |
| PDF-06 · P0 · INTEGRATION+GUI | Source PDF has moved or selected text fingerprint no longer matches. | 1. Move/replace the disposable PDF. 2. Follow the old citation. 3. Inspect fallback. | Stale exact anchor is never presented as valid; user receives a visible page-only or missing-source fallback; quote text remains recoverable. |
| PDF-07 · P1 · GUI+INTEGRATION | PDF has bookmarks including non-navigable group headings and nested destinations. | 1. Expand outline. 2. Select group heading. 3. Select a child destination. 4. Search and jump. | Hierarchy is readable; non-navigable headings do not navigate to a wrong page; child navigation reaches its exact destination. |
| PDF-08 · P0 · INTEGRATION+GUI | PDF-UNICODE includes Chinese directory/name and reserved characters. | 1. Create citation. 2. Save/reopen Markdown. 3. Follow link. 4. Move PDF within the Vault. | URL encoding round-trips CJK, spaces, parentheses, `#` and `?`; link relocation preserves the correct target and source anchor. |
| PDF-09 · P1 · ACCESSIBILITY+GUI | PDF has selected text and VoiceOver is enabled. | 1. Navigate to PDF selection. 2. Inspect available custom actions. 3. Invoke Add to Study Note and Copy Quote with Source. 4. Clear selection and retry. | Actions are announced and executable only for a valid selection; stale actions are rejected; actual VoiceOver traversal is recorded. |

### K. File operations, external changes and path safety — FILE

| ID / priority / layer | Setup | Steps | Pass criteria |
|---|---|---|---|
| FILE-01 · P0 · GUI+INTEGRATION | Disposable note and folder. | 1. Create a note. 2. Rename it. 3. Move it into a nested folder. 4. Reopen all related links. | One canonical file is created/moved; title/path and navigation update; no duplicate or orphaned document appears. |
| FILE-02 · P0 · INTEGRATION+GUI | Several notes link to the file being moved. | 1. Move within Vault. 2. Inspect outgoing/backlinks and map. 3. Save/reopen. | References are repaired according to the canonical link rule; all affected notes remain readable; unrelated references do not change. |
| FILE-03 · P0 · GUI+INTEGRATION | Destination already contains same filename with different content. | 1. Copy/move a file into that folder. 2. Inspect collision handling. 3. Cancel and retry with a new name. | Collision is never silently overwritten; cancellation leaves both files unchanged; explicit rename creates one new file. |
| FILE-04 · P0 · GUI+INTEGRATION | Disposable file with backlinks and Recent/Favorite entries. | 1. Move to Trash using Leafspan. 2. Inspect tree/search/relationships. 3. Restore from Trash. | Trash is reversible; references and navigation show a missing/trash state accurately; restore returns the same file without duplicate identities. |
| FILE-05 · P0 · INTEGRATION | FILE-EDGE symlink points outside active Vault. | 1. Search through the Vault. 2. Attempt open, preview, move, rename and delete through the symlink. | Canonical-path boundary is enforced; no operation escapes the Vault or writes to the external target. |
| FILE-06 · P0 · INTEGRATION+GUI | Same note edited in Leafspan and external editor. | 1. Change both versions. 2. Save in Leafspan. 3. Trigger conflict resolution. 4. Reopen both files. | No last-writer-wins data loss; external version and Leafspan draft are both preserved until the user chooses a safe resolution. |
| FILE-07 · P1 · INTEGRATION+GUI | Rapid external create/rename/delete sequence in a loaded folder. | 1. Perform the sequence quickly. 2. Wait for filesystem events. 3. Collapse/reopen folder. | Event coalescing does not miss final filesystem truth; no duplicate rows; collapsed descendants remain lazy. |
| FILE-08 · P1 · INTEGRATION+GUI | iCloud placeholder hydration is interrupted or denied. | 1. Start opening a dataless file. 2. Disable network or revoke permission. 3. Retry after restoring conditions. | Failure is reported as hydration/permission failure, not parse corruption; retry is available; unrelated notes remain open and safe. |
| FILE-09 · P0 · END-TO-END | Several open notes, one dirty note, tree state and active Vault. | 1. Save all intended changes. 2. Quit normally. 3. Relaunch. 4. Reopen each note and Vault. | Persisted data, selected Vault, document identity and expected navigation state restore; no stale draft or previous Vault overwrites the current one. |

### L. Performance and stability — PERF

| ID / priority / layer | Setup | Steps | Pass criteria |
|---|---|---|---|
| PERF-01 · P1 · PERF | V-LARGE (1,500 files / about 323 directories) with manifest. | 1. Measure cold launch and tree first paint. 2. Expand a shallow folder. 3. Expand a deep folder. 4. Collapse and reopen. | Record P50/P95, main-thread work and file reads; collapsed descendants are not recursively scanned; UI remains responsive. |
| PERF-02 · P1 · PERF | Declared 10k-file Vault; repeatable storage and Spotlight conditions. | 1. Cold-launch. 2. Open tree. 3. Quick Open. 4. Global Search. 5. Repeat warm. | Record cold/warm timings separately; no fabricated extrapolation from V-LARGE; no whole-vault scan on every keystroke or folder toggle. |
| PERF-03 · P1 · PERF+GUI | MD-LONG 50,000 lines. | 1. Cold-open Read. 2. Switch to Edit/Split. 3. Scroll and type. 4. Save/reopen. | Capture first-frame, first-edit, scroll frame pacing and main-thread stalls; no visible full-view flashing or lost input. |
| PERF-04 · P1 · PERF+GUI | MAP-LARGE 1,000 nodes. | 1. Cold-open. 2. Pan/zoom. 3. Select distant nodes. 4. Expand/collapse. | Record initial layout, interaction latency, frame pacing and memory; no blank initial canvas, detached connectors or unusable main-thread stall. |
| PERF-05 · P1 · PERF | Fixed 1k local filename corpus and 1k Markdown-body corpus. | 1. Measure keystroke-to-feedback latency. 2. Measure first filename result. 3. Measure first body result. 4. Repeat cold/warm. | Compare with #37 targets: UI feedback P95 ≤50ms; 1k local filename first result ≤300ms; 1k Markdown body first result ≤800ms; main-thread single work slice ≤100ms. Record actuals, never mark targets as results. |
| PERF-06 · P1 · PERF+GUI | 10k/50k search result candidates with slow source callback. | 1. Type and replace queries. 2. Cancel. 3. Close window. 4. Observe CPU and result publication. | Cancelled work stops/settles promptly; stale-result pollution count is zero; UI remains interactive while results stream. |
| PERF-07 · P1 · STABILITY | V-LARGE, MD-LONG and MAP-LARGE; fixed 30-minute script of normal operations. | 1. Alternate search/open/edit/map/PDF. 2. Scroll and resize. 3. Leave idle between actions. 4. Inspect memory/CPU at intervals. | No monotonic unbounded memory/CPU growth, repeated full scans, stuck spinner, lost draft or degraded interaction after sustained use. |
| PERF-08 · P0 · STABILITY | Controlled failures: missing file, slow iCloud, source error, cancelled search, interrupted save, invalid PDF. | 1. Inject one failure at a time. 2. Observe recovery. 3. Retry. 4. Reopen affected file. | Each failure has a recoverable and truthful UI state; no crash/data loss; one failure does not poison unrelated features or future retries. |

### M. More menu, accessibility and visual consistency — MENU / A11Y

| ID / priority / layer | Setup | Steps | Pass criteria |
|---|---|---|---|
| MENU-01 · P2 · GUI | Open More from the main toolbar. | 1. Inspect all menu items. 2. Group by user intent. 3. Execute the primary/high-frequency action. | Related actions are grouped; primary actions have clear hierarchy; low-frequency actions do not compete visually with core editing/navigation. |
| MENU-02 · P1 · GUI | Menu includes reversible and destructive actions. | 1. Invoke a reversible action. 2. Invoke a destructive action on a disposable fixture. 3. Cancel destructive action. | Only dangerous irreversible actions require confirmation; cancellation has no side effect; reversible actions are not burdened by unnecessary dialogs. |
| MENU-03 · P2 · GUI+ACCESSIBILITY | Menu open; keyboard and VoiceOver available. | 1. Open with keyboard. 2. Move through items. 3. Invoke and dismiss. | Every item has a meaningful label and logical order; keyboard activation matches pointer activation; focus returns to the originating control. |
| MENU-04 · P2 · GUI | Normal/narrow window and Light/Dark. | 1. Open menu near each window edge. 2. Resize while open. 3. Dismiss/reopen. | Menu remains inside window, readable and aligned; no clipped rows, overlapping controls or excessive decorative backgrounds. |
| A11Y-01 · P1 · ACCESSIBILITY+GUI | Keyboard only; no pointer use. | 1. Navigate Vault/tree/search/editor/map. 2. Open/close menus and sheets. 3. Save and switch modes. | All primary workflows are reachable; focus order is logical; visible focus indicator is present; no keyboard trap. |
| A11Y-02 · P1 · ACCESSIBILITY+GUI | VoiceOver enabled. | 1. Traverse app navigation. 2. Search and open a result. 3. Edit a note. 4. Select a map node. | Controls expose meaningful names/roles/values; result and node identity is announced; state changes are spoken without relying on color alone. |
| A11Y-03 · P1 · ACCESSIBILITY+GUI | PDF selection, VoiceOver enabled. | 1. Navigate PDF. 2. Select text. 3. Locate and invoke custom quote actions. 4. Clear selection. | PDF quote actions are discoverable and valid; stale action is not invoked after selection clears. |
| A11Y-04 · P2 · GUI | Reduce Motion enabled. | 1. Switch Read/Edit/Split. 2. Open/close map and inspector. 3. Navigate anchors. | Motion is reduced without losing state/feedback; no abrupt layout jump replaces one animation problem with another. |
| A11Y-05 · P2 · GUI | Light and Dark appearance; normal and increased text size. | 1. Inspect tree, editor, preview, menus, search, map and PDF. 2. Increase text size. | Text and selected states remain legible; contrast and focus are adequate; no clipped content or color-only meaning. |
| A11Y-06 · P2 · GUI | Minimum supported window size and display scaling change. | 1. Resize to minimum. 2. Change display scaling if available. 3. Visit all primary workflows. | Primary actions remain reachable; controls do not overlap; scroll containers and sheets remain usable. |

### N. Cross-feature user journeys — JNY

| ID / priority / layer | Setup | Steps | Pass criteria |
|---|---|---|---|
| JNY-01 · P0 · END-TO-END | A and B Vaults with same-name notes and unique search terms. | 1. Open A. 2. Search/open A-only note. 3. Edit/save. 4. Switch to B. 5. Search same term. 6. Return to A. | Correct Vault and note remain authoritative at every step; no search, editor or Recent state crosses Vault boundaries. |
| JNY-02 · P1 · END-TO-END | Note with known mode, cursor, scroll and Mind Map nodes. | 1. Read→Mind Map→Read. 2. Edit→Split→Edit. 3. Switch to another note and back. 4. Relaunch. | Each view restores its own valid mode and state; toolbar/layout remain stable; no stale document owns keyboard focus. |
| JNY-03 · P1 · END-TO-END | Search results include file and folder hits. | 1. Search. 2. Open a supported file. 3. Return. 4. Reveal in Finder. 5. Open the folder result. | Each action has the correct distinct destination; query, selection and scroll survive return. |
| JNY-04 · P0 · END-TO-END | PDF-LOCAL plus disposable Markdown note with Mind Map outline. | 1. Select PDF passage. 2. Drag quote to Markdown. 3. Save/reopen. 4. Organize the same note as a map. 5. Follow citation back to PDF. | Quote, page, exact anchor and node relationship survive the entire loop; PDF remains immutable; no parallel data store. |
| JNY-05 · P0 · END-TO-END | REL-GRAPH plus Mind Map node. | 1. Create outgoing link. 2. Open backlink from target. 3. Rename/move target. 4. Return through relationship and map. | Outgoing/backlink/related semantics remain correct; path repair is accurate; no stale or ambiguous target opens. |
| JNY-06 · P0 · END-TO-END | Dirty Markdown draft and separate Finder file. | 1. Edit current note. 2. Drag another supported file into canvas. 3. Cancel. 4. Repeat and drop. 5. Reopen both. | Cancel/drop never loses or redirects the draft; source file is not moved; intended document opens exactly once. |
| JNY-07 · P0 · END-TO-END | Slow Global Search source and two disjoint queries. | 1. Search A. 2. Replace with B. 3. Cancel B. 4. Close window. 5. Reopen and search C. | Old A/B results cannot appear in C or a closed window; cancellation/loading state is accurate; no stale selection is activated. |
| JNY-08 · P0 · END-TO-END | Dedicated iCloud Vault with dataless Markdown/PDF and a disposable dirty draft. | 1. Start opening dataless file. 2. Interrupt network/permission. 3. Restore. 4. Retry. 5. Relaunch and inspect saved data. | Hydration failure is recoverable; draft and source remain safe; successful retry opens the correct file; no false corruption or silent data loss. |

## 5. Mapping to the user's reported bugs

| #44 item | Primary cases | Adjacent regression coverage |
|---|---|---|
| LS-B01 Vault switch entry/behavior | VAULT-01…08 | TREE, SEARCH, JNY-01 |
| LS-B02 tree left/right shortcut | TREE-01…02 | TREE-06…08, VIEW-06 |
| LS-B03 mode restoration | VIEW-01…06 | MAP-07…08, JNY-02 |
| LS-B04 toolbar jumps in Split | VIEW-07 | SPLIT-06…08, MENU-04 |
| LS-B05 More menu visual hierarchy | MENU-01…04 | A11Y-01…02 |
| LS-B06 Split scroll sync | SPLIT-01…08 | MD-14, JNY-02 |
| LS-B07 Relationships unclear | REL-01…08 | FILE-02, MAP-12, JNY-05 |
| LS-B08 large Mind Map lag/broken lines | MAP-08…11, PERF-04 | MAP-04…07, MAP-12 |
| LS-B09 supported files open externally | OPEN-01…05 | SEARCH-09…10, DROP-01…02 |
| LS-B10 Global Search lag/flash | SEARCH-01…12, PERF-02/05/06 | VAULT-07, JNY-07 |
| LS-B11 large Markdown flash/drop frames | MD-01…14, PERF-03 | SPLIT, VIEW, JNY-02 |
| LS-B12 Finder drag-to-open | DROP-01…04 | OPEN-01…05, JNY-06 |
| LS-B13 ordinary Enter merged in preview | MD-01…06 | MD-14, SPLIT-02/06 |

The adjacent #37 regressions are deliberately represented rather than treated as unrelated historical notes: cold Global Search, cancellation/stale callbacks, initial Mind Map viewport and connectors, nine-level navigation, iCloud hydration, PDF source anchors and VoiceOver actions all have explicit cases above.

## 6. Execution order and minimum evidence

1. **Safety first:** VAULT-02/04, MD-12/13, MAP-05/06, REL-06/08, FILE-03/05/06, PDF-04/05/06/08, DROP-04, JNY-01/04/06/08. Any P0 failure stops the affected write workflow until its root cause is understood.
2. **User-reported primary flows:** VAULT, TREE, VIEW, SPLIT, MD-01/02, SEARCH, MAP, REL, OPEN/DROP.
3. **Scale and resilience:** PERF, iCloud failure, long-running session, query cancellation and relaunch.
4. **Accessibility and polish:** MENU and A11Y after the primary interaction path is stable.

For every FAIL, attach:
- exact case ID, run ID, source HEAD and app build identity;
- fixture manifest/hash and the smallest deterministic reproduction;
- expected vs actual result and the first step at which they diverge;
- screenshot/video for visible layout, animation, drag/drop, focus or navigation failures;
- focused unit/integration output and relevant logs for data/async/performance failures;
- whether the defect is reproducible after a clean relaunch and with a fresh fixture;
- suspected common root cause and affected paths, clearly marked confirmed or unconfirmed.

Do not re-run all 130 cases after every small change. Re-run the failed case, its direct dependency cases, and the relevant cross-feature journey. Reuse evidence only when source HEAD, app build, fixture hash and environment are unchanged.

## 7. Performance measurement contract

The following are acceptance targets already recorded in #37, not measured results:

| Metric | Target | Measurement rule |
|---|---:|---|
| Search UI feedback | P95 ≤50 ms | Keystroke to first visible response, measured across fixed query set |
| 1k local filename first result | ≤300 ms | Cold and warm reported separately |
| 1k Markdown-body first result | ≤800 ms | Cold and warm reported separately |
| Main-thread single work slice during search | ≤100 ms | Instrumented; report maximum and P95 |
| Stale query result pollution | 0 | Count rows/state published by superseded generations |
| Map / Markdown interaction | No user-visible blocking stall | Report frame pacing, main-thread stalls, fixture size and hardware; do not invent a numeric target without a product decision |

Report at least 20 repeated samples for timing distributions where practical. Include median, P95, maximum, fixture size, cold/warm state, machine, macOS version and whether Spotlight/iCloud was involved. Do not compare unlike machines or fixtures as if they were the same test.

## 8. What this plan does not certify

- It does not certify that any case currently passes.
- It does not replace #37 product acceptance or #36 release/store/commercial gates.
- It does not authorize upload, App Store submission, publication, real purchases, or changes to user data.
- It does not claim that source-level tests prove native pointer/keyboard/VoiceOver behavior.
- It does not turn the future portable-diagram scope in #42 into current release work.
- It does not require a second app, duplicate index, alternate persistence authority, or parallel feature implementation.

## 9. Existing source-level regression coverage and remaining gaps

This is a **read-only inventory of test functions found in the current checkout**, not a claim that they were run in this turn. Several source/test files are dirty or owned by other Writers. Their current contents must not be treated as committed HEAD evidence; run a focused test against the exact accepted source revision before using it to close a case.

| Existing test file | Representative tests already present | Related Bug Bash cases | What this proves / does not prove |
|---|---|---|---|
| `GlobalSearchFeatureTests.swift` | `testSpotlightWorkspaceMarkdownAndPDFUseLeafspanOpenPath`; `testCancelImmediatelyClearsGlobalSearchLoadingState`; `testUnifiedResultsDeduplicateAndPreferFilenames`; `testSpotlightBatchRankingSharesOneCJKQueryKeyAcrossOneThousandCandidates` | SEARCH-05…09, SEARCH-12 | Search routing, ranking, CJK snippets and loading logic; not the full installed-app progressive-list animation, filter UI, Finder reveal or focus behavior. |
| `SearchConcurrencyTests.swift` | `testLocalResultsPublishBeforeSlowProviderAndWorkspaceChangeCancelsSearch`; `testSupersededSearchCannotOverwriteLatestResults`; `testQueryEditAndClearCancelPendingSearchWithoutStaleError`; `testGlobalSearchPublishesLoadedWorkspaceMatchesBeforeColdIndexCompletes` | SEARCH-01…04, SEARCH-08, VAULT-07, JNY-07 | Async cancellation, partial results and stale-publication guards; not proof that rows visually append without flashing. |
| `WorkspaceSearchTests.swift` | `testSearchRejectsSymlinkedFilesAndParentDirectories`; `testStandaloneContentSearchUsesAllTermsAndShowsMatchingExcerpt`; `testPinyinAndChineseQueriesFindEachOtherInFilenamesWithoutReadingBinary`; `testCurrentDraftSearchDoesNotWriteDraftToDisk`; `testCoverageDisclosesBudgetAndOversizedBodiesWhileKeepingFilenameMatches` | SEARCH-05…08, SEARCH-11, FILE-05, REL-08 | Search matching, excerpts, CJK/pinyin, path boundaries and draft authority; not complete result-list interaction or actual native open/reveal GUI. |
| `NoteNavigationStoreTests.swift` | `testRecentAndFavoritesAreWorkspaceScopedAndPathSafe`; `testRenameMoveAndTrashRebaseNavigationMetadata` | VAULT-02…04, VAULT-08, FILE-01/04, JNY-01 | Recent/Favorites workspace scoping and metadata rebasing; not the visible Vault switch entry, permission recovery or end-to-end switch UI. |
| `WorkspaceChromeTests.swift` | `testSplitPaneChromeKeepsHeadersCompactAndDistinct`; `testCompactWindowKeepsPDFAndNoteWidthInsteadOfForcingInlineInspector`; `testStudyPaneChromeSurfaceAdaptsToSystemAppearance` | TREE-07…08, VIEW-07, MENU-04 | Selected chrome geometry and appearance constraints; not actual tree left/right switching, Split synchronized scrolling or mode restoration. |
| `MarkdownEditingTests.swift` | `testListCommandsPreserveBlankCRLFLinesAndToggleBackExactly`; `testCodeBlockAndTableInsertionsPreserveCRLFLineEndings`; `testHeadingCommandPreservesFencedCodeWhileFormattingSurroundingLines`; `testDeferredEditorUndoResetPreservesNewUserEdit` | MD-03…10, MD-12 | Source transformations, CRLF, code/list/quote formatting and undo behavior; not the MarkdownUI preview's ordinary soft-break rendering. |
| `MindMapOutlineTests.swift` + `MindMapFunctionalShortcutsTests.swift` | `testFencedCodeIgnored`; `testAddSiblingOnHeadingCreatesSameLevelAfterItsWholeSection`; `testReturnCreatesTheCorrectSiblingOrHeadingChildAfterAttachedContent`; `testPDFCitationLinkStaysWithNodeWhenSubtreeReparented`; `testNodeStyleShortcutsUseNativeMacKeyBindingsWithoutHijackingTextInput` | MAP-01…03, MAP-06, MAP-08, MAP-12, MD-06 | Markdown outline semantics, keyboard transformation and source ownership; not actual canvas hit targets, focus visibility or drag gesture UX. |
| `MindMapDragTargetSafetyTests.swift` | `testDragDropReordersSiblingsBeforeAndAfterWholeSubtrees`; `testHeadingSectionsReorderAndRejectCyclesUnsupportedTargetsAndDepthOverflow` | MAP-04…06, FILE-02 | Reparent/reorder safety and cycle rejection; not native pointer-drag acceptance on the installed app. |
| `MindMapViewportTests.swift` + `MindMapLayoutDensityTests.swift` | `testLargeMapInitialFocusKeepsEveryNodeExpandedAndRootReadable`; `testConnectorCullingKeepsCrossingCurvesAndStrokeCaps`; `testVisibleNodeCullingTracksPanAndZoomAndPinsActiveNodes`; `testLongChineseAndEnglishTitlesGrowCardHeightWithoutOverlaps` | MAP-08…11, PERF-04 | Layout geometry, culling, connector queries and density; not a real 1k-node pan/zoom recording, full-map visual review or window-resize acceptance. |
| `WorkspaceBacklinksAvailabilityTests.swift` | `testPDFLinkedNotesReportUnreadableMarkdownWithoutHidingReadableBacklinks` | REL-02, REL-05, REL-08 | A narrow unreadable-source/backlink availability case; not the full Outgoing vs Backlinks vs Related · Library information architecture or “why related” explanation. |
| `PDFCitationDropFlowTests.swift` + `PDFSelectionDragGestureRecognizerTests.swift` | `testNativePDFCitationDropPersistsAndReopensExactAnchor`; `testSelectedPDFTextExposesVoiceOverQuoteAndCitationActions`; `testPDFCitationDropRejectsScrollbarsButAcceptsBlankEditorViewport`; `testPanBeginsAfterPointerMovementAndRetainsTheInitiatingEvent` | PDF-04…06, PDF-09 | Drop-flow contracts, exact-anchor persistence, custom action callbacks and gesture recognition; not a complete physical mouse-drag and VoiceOver traversal on the installed app. |
| `PDFSourceAnchorControllerTests.swift` + `PDFSearchFlowTests.swift` | `testPDFKitSelectionAnchorCapturesAndRestoresTheExactSelection`; `testStalePDFSelectionAnchorNeverSelectsDifferentText`; `testPDFPageReferenceFallsBackToPageOnlyLinkButKeepsSelectedQuote`; `testSearchHitEmptyQueryAndDocumentSwitchDoNotLeakOldResults` | PDF-01, PDF-03, PDF-05…08 | Anchor capture/restore, stale-anchor fallback and PDF search isolation; not complete PDF reading/outline/zoom UI acceptance. |
| `WorkspaceExternalRefreshTests.swift` + `WorkspaceLinkRelocationTests.swift` | `testRealFSEventNotificationForExternalFile`; `testRapidExternalCreateRenameDeleteSequenceConvergesToFilesystemTruth`; `testExternalModificationNeverOverwritesDirtyDraft`; `testRenameReportsAmbiguousIncomingBasenameWithoutGuessingTarget`; `testMovingPDFRewritesIncomingLinkAndPreservesExactSourceAnchor` | TREE-05, MD-12/13, FILE-01…07, REL-04…06 | External refresh, conflict safety, path ambiguity and relocation repair; not every Finder drag or permission-revocation interaction. |
| `RealICloudFileProviderAcceptanceTests.swift` | `testDatalessMarkdownRenameFolderCopyMoveAndPDFMovePreserveLinks`; `testUnreadableLastOpenedNoteKeepsRetryablePath` | VAULT-05/06, PDF-02, FILE-08, JNY-08 | Real File Provider dataless/error behavior for those scenarios; not a substitute for the complete installed-app recovery journey on every fixture. |

### Explicit gaps that must remain open until separately evidenced

1. **LS-B01 / LS-B02:** Vault switch entry and sidebar left/right shortcut are not established by the navigation-store/chrome unit tests. Require discoverability and pointer/keyboard GUI runs.
2. **LS-B03 / LS-B04 / LS-B06:** Per-document mode restoration, toolbar stability during repeated mode changes and bidirectional Split semantic-anchor synchronization require native GUI evidence; source geometry tests are insufficient.
3. **LS-B05:** More menu grouping, visual priority, dangerous-action treatment and dismissal/focus behavior require a visual and keyboard review.
4. **LS-B07:** Relationship categories and “why related” explanations need product/UI acceptance beyond the narrow unreadable-backlink test.
5. **LS-B09 / LS-B12:** Opening ordinary supported search hits in Leafspan and dropping a Finder file to open it are different from dropping a PDF quote into Markdown. Test both separately.
6. **LS-B10 / LS-B11 / LS-B13:** Search result append/no-flash, 50k-line preview responsiveness and single-Enter soft-break rendering must be verified in the actual preview/search UI. In particular, no current source-test name found in this inventory directly covers the LS-B13 MarkdownUI soft-break display mode.
7. **Performance and accessibility:** P95 targets, a 30-minute mixed session, actual VoiceOver traversal and real drag gestures require instrumented/installed-app evidence; logic tests cannot close them.

Use this inventory to reuse existing focused tests where their exact behavior matches a case, then add only the missing regression. Do not create duplicate tests merely because a Bug Bash ID exists.

## 10. Current status

- Specification authored against the user-reported #44 list and the adjacent #37 product/bug evidence.
- All 130 cases: **NOT RUN** until attached to a current installed-app build and controlled fixtures.
- Canonical document write is limited to this new file. Existing dirty source, icon, test, build-cache and other Writer-owned paths are out of scope and must remain untouched.
- A test case may be marked PASS only with evidence at its required level and exact source/build identity.
