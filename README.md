# Personal Knowledge Assistant

<p align="center"><strong>Local-first personal context engine with an official Forge provider.</strong></p>
<p align="center"><a href="https://github.com/moretea-labs/forge">Forge</a> · <a href="docs/ARCHITECTURE.md">Architecture</a> · <a href="docs/OPERATIONS.md">Operations</a> · <a href="docs/STATUS.md">Status</a> · <a href="SUPPORT.md">Support</a></p>
<p align="center"><img alt="CI" src="https://github.com/moretea-labs/personal-knowledge-assistant/actions/workflows/ci.yml/badge.svg"> <img alt="Release" src="https://img.shields.io/github/v/release/moretea-labs/personal-knowledge-assistant?sort=semver"> <img alt="Node" src="https://img.shields.io/badge/Node.js-20%2B-green"> <img alt="License" src="https://img.shields.io/github/license/moretea-labs/personal-knowledge-assistant"></p>

Personal Knowledge Assistant (PKA) indexes **user-owned local knowledge**, preserves provenance, builds rebuildable search/structured-memory projections, and supports bounded canonical writes. It is designed for personal files, Obsidian-compatible folders, managed notes, and optional external sources such as Notion without making the derived database the source of truth.

## Install through Forge

```bash
forge plugin install personal_knowledge
forge plugin list --refresh
```

Forge owns trusted provider installation, authorization, resource claims, and execution evidence. PKA owns knowledge ingestion, retrieval, structured extraction, memory, safe-write behavior, and its independent release lifecycle.

## What it provides

- local and Obsidian-compatible file sources;
- incremental content-hash indexing;
- Markdown/text/HTML/JSON/CSV plus lightweight PDF, DOCX, PPTX, and XLSX extraction;
- SQLite catalog + FTS5 + offline approximate semantic hash vectors;
- hybrid retrieval with bounded reads and exact source locations;
- managed canonical write/update, mutation log, and undo;
- structured health extraction/timeline with provenance and review queue;
- book/movie records from frontmatter;
- evidence-backed memory profiles;
- optional Notion incremental sync and write primitives;
- local web UI and HTTP API;
- five high-level Forge actions over the provider boundary.

## Authority and privacy model

User-owned files and managed canonical notes remain authoritative. SQLite indexes, embeddings, structured extractions, and memory profiles are **derived and rebuildable**. User corrections are stored separately and outrank later automatic extraction.

PKA is local-first by default. External-source credentials are configuration secrets and must never be committed. The public repository contains no personal source roots, documents, or tokens.

## Run standalone

```bash
npm ci
npm run build
node dist/src/cli.js init --pks-config=./pks.config.json
# edit source roots in pks.config.json
node dist/src/cli.js sync --pks-config=./pks.config.json
node dist/src/server.js --pks-config=./pks.config.json
```

Open `http://127.0.0.1:3217`.

Default compatibility state remains under `~/.pks`; configuration can override data and managed-store locations.

## Verify

```bash
npm ci
npm run build
npm test
```

The current synthetic benchmark baseline is tracked at [`benchmarks/2026-08-11.json`](benchmarks/2026-08-11.json). Benchmark results are evidence for the recorded fixture, not a universal retrieval-quality claim.

## Forge provider

The official plugin identity is `personal_knowledge`. The provider uses a bounded managed-process JSONL protocol and exposes high-level search, read, analyze, mutate, and administration actions. Forge remains the policy and execution authority.

See the [Architecture](docs/ARCHITECTURE.md), [Operations](docs/OPERATIONS.md), [Status](docs/STATUS.md), and Forge [Plugin Management guide](https://github.com/moretea-labs/forge/blob/main/docs/forge-plugin-management.md).

## Project

Current release: `v0.2.1`. Use Issues for reproducible PKA defects and product-specific feature requests. Cross-product Forge questions belong in [Forge Discussions](https://github.com/moretea-labs/forge/discussions). Security reports should use GitHub Private Vulnerability Reporting; see [SECURITY.md](SECURITY.md).

Licensed under the [MIT License](LICENSE).
