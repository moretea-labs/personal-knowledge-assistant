# Personal Knowledge Assistant — Product Architecture

## Product boundary

PKS is an independent local-first personal context engine. Forge is a host/control-plane integration, not the business core.

```text
User-owned sources
  Local files / Obsidian / Notion / Managed Store
                 |
                 v
        Deterministic Data Plane
  source registry / parsers / SQLite / FTS5
  structured records / provenance / mutations
                 |
                 +------> AI Intelligence Plane
                 |        embeddings / hybrid search
                 |        domain analysis / memory views
                 v
        Local HTTP API + Web UI
                 |
                 +------> Forge Unix-socket provider
                          manifest / health / execute
```

## Canonical authority

PKS does not use one blanket source-of-truth rule. Authority is per object:

- Existing local file: the file is canonical.
- Obsidian content: Markdown is canonical.
- Notion content: the Notion object is canonical.
- PKS-created note/record: the managed Markdown file is canonical.
- SQLite document/chunk/entity/structured-record rows: derived/materialized views and rebuildable.
- Memory profiles: derived and rebuildable.
- User correction: explicit higher authority than automatic extraction and must survive reindex.
- Mutation/audit state: PKS system state.

This removes the common dual-write ambiguity where a database row and a Markdown note can silently disagree.

## Data plane

### Storage

SQLite holds the catalog, FTS5 index, chunks, structured records, health observations, entities, memory profiles, mutations, corrections and synchronization state. WAL mode is enabled.

### Indexing

A source scan compares metadata and content hashes. Changed content flows through parser -> chunker -> FTS -> embedding -> domain extraction -> entity extraction. Unchanged files skip parsing/embedding. Nested configured roots are excluded from parent scans to avoid duplicate indexing.

**Index correctness:** parsing and Embedding preparation complete before opening the SQLite write transaction; the transaction only commits the new document, chunks, FTS and derived records atomically. An unreadable source root or subtree makes the scan incomplete: keep previously indexed documents, report the error in `sync_state.last_error`, and resume ordinary pruning only after a complete scan. A genuinely removed file in a complete scan is tombstoned. Managed note creation uses exclusive file creation rather than a check-then-overwrite race; update/undo temporary paths have unique names.

### Parsers

Implemented:

- Markdown/text/JSON/CSV/TSV/YAML/HTML/log
- PDF native text through `pdftotext`
- DOCX/PPTX/XLSX lightweight OpenXML extraction through `unzip`

OCR is deliberately not a default. A future image/OCR parser should only run after native text extraction fails.

### Retrieval

`auto` uses deterministic routing first:

1. structured health query when the intent matches known observations;
2. FTS5 exact/full-text retrieval;
3. semantic retrieval only when FTS is insufficient;
4. fusion and bounded evidence output.

The bundled hash-ngram embedding is an offline fuzzy fallback, not a claim of true semantic understanding. A remote OpenAI-compatible embedding provider is implemented and can be configured without changing index/search contracts.

Explicit `metadata`, `fts`, and `semantic` modes return only the corresponding evidence source; `auto` retains the existing hybrid fusion. The dedicated `mode=related` search uses the same FTS/chunk and semantic candidates but requires multiple concrete overlaps in candidate content, ranks by term coverage, excludes the requesting document by `excludeUri` and returns at most one evidence-bearing hit per document. It intentionally returns fewer or no related items when evidence is weak; ordinary `auto` search behavior is unchanged. This does not introduce a second graph or index.

### Writes

Standalone PKS mutations are restricted to the managed canonical store. Create/update performs atomic file write -> reindex -> memory invalidation. Undo restores/removes the canonical file and removes or rebuilds derived data. Physical moves outside the managed store are not duplicated inside PKS; PKS generates organization proposals and Forge performs approved filesystem mutations.

## Domain extensions

### Health

Health extraction currently recognizes creatinine, cystatin C, hemoglobin, eGFR and tacrolimus trough-like values. Observations carry source document, source anchor, date, extraction method, confidence and verified state. Report dates prefer explicit filename/body dates over filesystem mtime. User corrections survive future indexing.

### Books and movies

Canonical Markdown frontmatter can materialize `BookRecord` / `MovieWatch` structured records. Memory profiles compute counts, ratings, genres and recent activity from structured records.

## Memory

Memory is a materialized evidence-backed view, never an independent truth source. Writes/reindex invalidate stale profiles so ChatGPT cannot receive a profile that predates a canonical mutation. Memory aggregation excludes documents tombstoned by a complete scan; only active canonical source evidence and independent user-owned corrections contribute.

## Notion

A source client implements official API search pagination and page/block reading, plus page creation/archive primitives. It is credential-gated and was not exercised against a real workspace in the sandbox.

## Runtime

- Local HTTP API and static Web UI.
- File watcher plus periodic reconciliation.
- Sync mutex prevents overlapping index runs.
- Environment variable overlays for sensitive remote credentials.
- macOS LaunchAgent installer.

## Forge integration

PKS is an external controller-scoped provider over Unix-socket JSONL. It implements Forge-compatible `manifest`, `health`, and `execute` methods and exposes only five high-level actions:

- `knowledge_search`
- `knowledge_read`
- `knowledge_mutate`
- `knowledge_analyze`
- `knowledge_admin`

The provider contract is in `src/forge/contract.ts`; transport implementation is in `src/forge/socket-server.ts`.

## Deliberate non-goals

- Password vault
- Elasticsearch / Kafka / graph database
- autonomous destructive file cleanup
- full Notion/Obsidian replacement
- silent bulk physical reorganization
- treating all chat text as permanent memory

### Finding files and PDF availability (2026-10-21)

File-location intent uses the existing SQLite document catalog (title, original URI, inferred topic tags and verified user aliases) before full-text retrieval. It does **not** use approximate hash vectors to claim a particular file is found. Normal knowledge questions still use the existing FTS/hybrid content search.

PDFs with no native text are `metadata_only`; inaccessible iCloud placeholders are `deferred`. Both remain discoverable by filename/path/verified alias, with an explicit `indexStatus`. The document read route uses indexed text chunks for PDF rather than decoding binary bytes as UTF-8. A placeholder is not a fully indexed PDF: content extraction needs the actual local bytes. This implementation does not download cloud files or introduce OCR.

Automatic topic tags such as `英语学习`, `雅思`, `词汇`, `语法`, `听力` and `口语` are derived from a PDF's canonical path and name during indexing. User-confirmed title aliases are higher-authority corrections in the existing `corrections` ledger (`field=search_aliases`, `new_value` JSON array). `knowledge_admin(operation=set_aliases, document_id=..., aliases=[...])` replaces a document's nickname set without modifying its PDF, preserving aliases across scans. **A nickname cannot be assigned to an unverified book.**

The source file is the physical authority; the document catalog, topic tags, and search rankings remain rebuildable. The user-alias correction ledger is already PKS's explicit higher-authority correction mechanism and is not a second document catalog.

Existing indexed files, including deferred cloud placeholders, receive deterministic path-derived catalog tag updates during ordinary incremental scans without native-text extraction or downloading the file. This keeps the single catalog current even when unchanged content is skipped.

The Forge managed-CLI installation manifest imports the single action/permission schema from `src/forge/contract.ts` (compiled distribution). The managed bridge `scripts/forge-provider.mjs` and the Unix-socket server delegate to the same `PKSService`. Updating source code alone is not a live provider deployment; the Forge plugin registration and lifecycle must observe the updated manifest.
