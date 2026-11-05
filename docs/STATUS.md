# Implementation Status — 2026-08-11

## What is implemented and tested

- Local and Obsidian-compatible source indexing
- Managed canonical knowledge store
- Incremental content-hash indexing
- SQLite catalog, FTS5 and materialized structured data
- Hybrid search with exact FTS fast path
- Bounded document reads and exact URI/source provenance
- Create/update/undo with mutation log
- Correct deletion/reindex of derived state after undo
- Health extraction, timeline, source provenance and user correction persistence
- Book/movie structured records and memory profiles
- Entity extraction for Obsidian wikilinks/tags
- Duplicate detection, unclassified queue and move proposals
- Notion source/sync/write client implementation
- OpenAI-compatible remote embedding provider plus offline hash fallback
- File watching + periodic reconciliation + sync mutex
- HTTP API, local Web UI, CLI
- macOS LaunchAgent install script
- Forge Unix-socket provider and bounded 5-action tool surface

## Automated acceptance

Synthetic tests cover the original seven acceptance areas plus PDF catalog lookup, verified aliases, and incremental tag refresh. Validate with `npm run build && npm test`:

1. index/search/health provenance and report-date authority;
2. managed canonical write and complete undo cleanup;
3. offline Chinese fuzzy retrieval fallback;
4. user health correction survives reindex;
5. OpenAI-compatible remote embedding protocol;
6. Forge Unix-socket manifest/health/search/mutate/analyze flow;
7. Forge registration/provider identity and bounded action surface.

## Benchmark baseline

Sandbox Node v22.16.0, synthetic 1,000 Markdown documents:

- first index: ~1.99 s
- unchanged incremental rescan: ~52 ms
- exact FTS query: ~1.41 ms
- hash-semantic query: ~18.64 ms

These are local synthetic measurements, not a production SLA.

## Implemented but not live-credential verified

- Notion real-workspace synchronization/write: implementation exists; no user token was supplied to the sandbox.
- Remote production embedding endpoint: protocol tested against a local compatible server; no real provider credential was supplied.
- PDF/DOCX/XLSX/PPTX corpus quality: parser paths exist, but no representative private corpus has been acceptance-tested yet.

## Sandbox compromises to remove before production hardening

- npm dependency downloads timed out in the sandbox. Source is TypeScript but uses `// @ts-nocheck`, `strict:false`, and no local `@types/node`; restore strict typing when normal package installation is available.
- Runtime uses Node's built-in `node:sqlite` to keep the sandbox zero-dependency. Keep the DB adapter boundary so a bundled/stable SQLite binding can replace it if desired.
- Hash-ngram vectors are only an offline fuzzy fallback. Real semantic retrieval should use a configured embedding model.
- Vector cosine ranking currently scans at most 5,000 compatible chunks in JS; replace with a vector extension/index once real corpus benchmarks justify it.
- Office parsers are intentionally lightweight; production should use hardened parsers and fixtures for complex tables/relationships.

## Forge live-install status

As of 2026-10-21, Forge reported the live `personal_knowledge` provider healthy on the user's Mac (installed v0.2.1), with 2,110 documents and 3,228 chunks. Source-level improvements in this repository require local provider deployment/restart and separate live retrieval verification; build/tests alone do not constitute a live rollout.

The Forge controller now exposes a registered external provider and typed `knowledge_search`/`knowledge_admin` actions. Update the provider using its authorized lifecycle, not by writing Forge controller state directly.

Some `knowledge_admin` actions still serialize on the broad `repo-state:write` resource; use sequential admin actions until resource scopes are corrected through Forge's authoritative provider contract.

## 2026-10-21 — PDF file discovery P0

- Verified live PKS Documents catalog: 961 local documents, 334 with indexable content and 627 `deferred` cloud placeholders (65.2%). These counts reflect a point-in-time audit, not a claim that remote content was downloaded.
- Root cause: `auto` returned unrelated low-score `semantic_hash` hits for “韦氏小绿书”, despite searching for a file location; no verified alias record existed.
- Implemented: locator-specific catalog ranking, explicit alias-correction API, deterministic English-learning PDF tags, `metadata_only` state for PDFs with no extracted text, index-status counts, PDF indexed-chunk reads, and regression tests.
- Limitation: a book with an unknown filename and no verified alias cannot be reliably located by its nickname; iCloud source bytes must become accessible before native text extraction or OCR can index the body.
- Acceptance: run `npm run build && npm test` against the committed implementation; live daemon rollout requires deploying/restarting the provider and checking its reported version.

The 2026-10-21 changes advance the source package to v0.2.2. The official Forge external-provider registration must be updated with version/revision guarding and then probed separately; a source-only build does not update an installed v0.2.1 package.


## 2026-11-06 — PKS search reliability and query performance

- Source v0.2.2 work is consolidated in the existing Issue #1 Work branch. The original dirty Mac checkout and active v0.2.1 provider remain untouched until a separately verified rollout.
- Live catalog used for the read-only benchmark: **2,743 documents / 6,566 chunks**, compatible hash provider `hash-ngram-v1-256`. Existing standalone HTTP service uses the older installed build.
- Before optimisation, repeated live HTTP queries measured roughly **7–13 ms** for well-covered literal terms and **74–80 ms** for queries entering hash-semantic retrieval. In a separate read-only source-engine benchmark on the same SQLite database, repeated explicit semantic searches were ~120–135 ms before and ~10–13 ms after vector candidate reuse. Host load, query mode and cold starts affect timing; these are measurements, not a latency SLA.
- Added **one bounded, ephemeral semantic candidate view** (up to 12 MiB of vector payload) invalidated by SQLite `total_changes()` (same writer) and `PRAGMA data_version` (other writers). SQLite remains the only index authority; no on-disk cache or duplicate corpus.
- A single-term query with sufficient literal FTS matches no longer scans 5,000 vectors; lower-recall and explicit `mode=semantic` searches retain semantic candidate ranking.
- Ordinary `最近` / `最新` terms no longer enter health-only structured retrieval and return empty results. Only recognized observation terms use that structured path automatically.
- Synthetic regression tests cover locator and verified-alias truth, cloud-deferred and metadata-only PDFs, source filtering, local/external database change invalidation, literal fast path and ordinary recency queries. **15/15 Node tests pass**.
- Repeatable read-only query latency check: `PKS_BENCH_DB=/path/to/knowledge.db npm run benchmark:search`. The benchmark prints no private source content or locations. Do not confuse this source test with deployment to the active Mac daemon or Forge's installed package.
