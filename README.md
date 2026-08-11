# Personal Knowledge Assistant

A local-first personal context engine that indexes user-owned files, builds structured facts, supports safe canonical writes, exposes evidence-backed retrieval/memory, and integrates with Forge through a thin controller-scoped adapter.

## Run

```bash
npm run build
node dist/src/cli.js init --config=./pks.config.json
# edit roots in pks.config.json
node dist/src/cli.js sync --config=./pks.config.json
node dist/src/server.js --config=./pks.config.json
```

Open `http://127.0.0.1:3217`.

## Implemented product surfaces
- Local/Obsidian-compatible file sources and managed canonical store
- Incremental hash-based indexing
- Markdown/text/HTML/JSON/CSV, PDF native text (`pdftotext`), DOCX/PPTX/XLSX lightweight parsers
- SQLite catalog + FTS5 + offline approximate semantic hash vectors
- Hybrid retrieval, bounded reads, exact file locations
- Safe write/update inside managed store, mutation log and undo
- Health structured extraction/timeline with provenance and review queue
- Book/movie structured records from frontmatter
- Evidence-backed memory profiles
- Notion REST source client with incremental search/page sync and write primitives (live workspace acceptance requires credentials)
- Local web UI and HTTP API
- Forge controller-scoped Unix-socket external provider with 5 high-level actions

## Authority model
User-owned canonical sources remain authoritative. SQLite search indexes, embeddings, structured extractions and memory profiles are derived and rebuildable. User corrections are stored separately and must outrank future automatic extraction.


## Documentation

- `docs/ARCHITECTURE.md` — product/data/authority/Forge architecture
- `docs/STATUS.md` — implemented vs unverified vs production-hardening gaps
- `docs/OPERATIONS.md` — build, run, configuration and Forge registration
- `benchmarks/2026-08-11.json` — current synthetic baseline


## Forge plugin

Personal Knowledge Assistant is an independent local-first product with an official Forge provider. Forge users can install the integration without cloning this repository manually:

```bash
forge plugin install personal_knowledge
```

The plugin uses the same local data/config roots (`~/.pks`) for compatibility, while Forge owns provider installation, authorization, resource claims, and execution evidence.
