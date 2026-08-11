# Contributing

Contributions are welcome. Preserve the authority model: user-owned canonical sources remain authoritative; indexes, embeddings, extraction, and memory stay derived and rebuildable.

## Development

```bash
npm ci
npm run build
npm test
```

Use synthetic fixtures in tests. Do not commit personal documents, real source roots, Notion tokens, embedding credentials, local SQLite databases, or `~/.pks` state. Changes to canonical-write, privacy, extraction provenance, provider contracts, or credential handling require focused tests and documentation.
