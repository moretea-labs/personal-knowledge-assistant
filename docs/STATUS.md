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

Seven automated tests currently pass:

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

Protocol integration is complete, but the PKS daemon exists in the ChatGPT sandbox, not on the user's Mac, so it is not claimed as installed/running there.

The current Forge source supports external Unix-socket providers, but the exposed ChatGPT/controller tool surface does not currently provide a trusted install/update/remove action for an `ExternalPluginRegistration`. PKS therefore emits the trusted registration input but does not bypass Forge authority by writing controller state directly.

A second Forge issue tracks provider-scoped resource claims because the current conservative `repo-state:write` claim would create false serialization for provider-local mutations.
