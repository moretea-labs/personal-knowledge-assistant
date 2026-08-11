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

### Writes

Standalone PKS mutations are restricted to the managed canonical store. Create/update performs atomic file write -> reindex -> memory invalidation. Undo restores/removes the canonical file and removes or rebuilds derived data. Physical moves outside the managed store are not duplicated inside PKS; PKS generates organization proposals and Forge performs approved filesystem mutations.

## Domain extensions

### Health

Health extraction currently recognizes creatinine, cystatin C, hemoglobin, eGFR and tacrolimus trough-like values. Observations carry source document, source anchor, date, extraction method, confidence and verified state. Report dates prefer explicit filename/body dates over filesystem mtime. User corrections survive future indexing.

### Books and movies

Canonical Markdown frontmatter can materialize `BookRecord` / `MovieWatch` structured records. Memory profiles compute counts, ratings, genres and recent activity from structured records.

## Memory

Memory is a materialized evidence-backed view, never an independent truth source. Writes/reindex invalidate stale profiles so ChatGPT cannot receive a profile that predates a canonical mutation.

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
