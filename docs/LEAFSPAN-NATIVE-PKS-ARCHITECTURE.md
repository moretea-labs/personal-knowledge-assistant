# PKS Dual-Runtime Architecture: Service and Embedded Leafspan

**Decision date:** 2026-11-23  
**Status:** Implemented architecture; release acceptance still has explicit remaining gates.

## Product rule

PKS has **one canonical retrieval/index core** and two deployment adapters:

1. **Local service mode** for Forge and other authorized host clients.
2. **Embedded Leafspan mode** for the distributed macOS app.

These are deployment modes, not separate search products. The Rust core owns search semantics and the embedded derived index. Transport, UI, permissions and lifecycle remain adapter responsibilities.

```text
                     Shared PKS contract
          search / index / finalize / versioned JSON
                            |
               +------------+------------+
               |                         |
        Local service adapter      Leafspan adapter
        Node + N-API addon         Swift actor + C ABI
        HTTP + Forge socket        in-process calls
               |                         |
               +----------+--------------+
                          |
                    Rust PKS Core
                          |
             SQLite + FTS5 + hash vectors
```

## Implemented runtime boundaries

### Local service / Forge host

The existing Node service remains the process and transport owner:

- HTTP API and Forge Unix-socket contracts remain unchanged.
- `PKSService` now defaults to the native Rust search engine.
- The native Node addon is built as `dist/native/pks.node`.
- `PKS_SEARCH_ENGINE=typescript` is an explicit diagnostic fallback only; there is no silent fallback from native to TypeScript.
- Service status exposes the selected search engine.
- The macOS installer rebuilds the JavaScript service from `package-lock.json` and source in an isolated temporary root, builds the native addon, validates the native module graph, and only then swaps the running service. It refuses dirty service-source installs before any service interruption.
- TypeScript still owns host-side source parsing, ingestion orchestration, watching, writes, and capabilities that are not part of Leafspan embedded indexing.

The source implementation is canonical-native. On 2026-11-24, exact clean source commit `672ebd56a35b3e057f91e5d95f41afe092ce6747` was rebuilt and installed through the canonical macOS installer. The restarted daemon reported `searchEngine: native` with the pre-install document/chunk counts preserved; HTTP and Forge Unix-socket health agreed, and `auto`, `metadata`, and `fts` search calls produced identical HTTP/socket result payloads by count and SHA-256 without exposing indexed content. The socket remained mode `0600` and the provider handshake succeeded. The earlier rollout failure was traced to stale/incomplete committed `dist`; the installer no longer treats repository `dist` as a deployment input.

### Embedded Leafspan

Leafspan contains no runtime dependency on the host PKS service:

- No `127.0.0.1:3217`, `/api/search`, or `/api/read` path remains in Leafspan source.
- No Node runtime, LaunchAgent, Forge install, helper daemon, login, or network request is required for embedded library search.
- Swift calls the same Rust core in-process through a narrow C ABI.
- The embedded database lives under Leafspan Application Support and is separate from the host PKS database.
- Leafspan never opens or writes `~/.pks`.

The active Leafspan workspace keeps its existing local Quick Open/body-search behavior. Additional library folders use embedded PKS indexing. Overlap with the active workspace is rejected to prevent duplicate indexing.

## Native core responsibilities

The Rust core currently implements:

- metadata retrieval
- FTS5 full-text retrieval
- automatic evidence fusion
- offline hash-vector semantic retrieval
- related-result evidence gating
- structured observation dispatch
- source/document/date filters
- verified aliases
- tags
- deferred and metadata-only states
- deterministic bounded results
- embedded database migration
- embedded document upsert
- chunking
- hash embeddings
- FTS projection
- source finalization/deletion
- incremental refresh

The embedded refresh path updates source/document metadata on every scan, but rebuilds chunks, FTS rows and embeddings only when content, title or indexability changes, or when a previously deleted document is restored.

## Leafspan ownership

Swift owns:

- macOS folder selection
- security-scoped bookmark persistence/resolution
- app lifecycle
- cancellation
- filesystem enumeration
- UI and search presentation
- result merging/deduplication
- local workspace search

Rust owns:

- derived database schema
- document/chunk identity
- content hashing
- FTS/vector projections
- search/ranking semantics
- embedded derived-index lifecycle

Original user files remain canonical. The embedded SQLite database is rebuildable derived state.

## Additional library behavior

Users can manage additional search libraries from Global Search settings:

- add a security-scoped folder
- list granted folders
- refresh one source
- refresh all sources
- remove a source and purge its derived index
- see indexing status

Current content policy:

- `.md`, `.markdown`, and `.txt`: content indexed when UTF-8 and within the configured size bound.
- PDF in additional libraries: metadata-only for now.
- Active-workspace PDF behavior remains the existing Leafspan implementation.

The embedded library index currently refreshes on add/manual refresh. Continuous filesystem watching or automatic launch refresh is not yet claimed.

## Build and packaging

Leafspan links a generated `PKSCore.xcframework`.

The builder:

- rebuilds the Rust standard library for the deployment target using `build-std`
- builds both `arm64` and `x86_64`
- links against macOS 14 deployment targets
- verifies per-architecture link smoke binaries report `minos 14.0`
- creates a universal static library and XCFramework
- performs the build in temporary crate storage so Cargo/build-std cannot rewrite repository lockfiles

Both App Store packaging and the canonical local release/install path generate the native core before building Leafspan. A normal source-only SwiftPM checkout may still omit the generated binary target until the builder is run; release/install paths may not.

## Shared contract and parity evidence

The repository contains a privacy-safe language-neutral Golden Corpus used by TypeScript and Rust conformance runners.

Verified evidence to date includes:

- Rust native search unit/contract/CJK tests passing; explicit scale runs covered 10k and 50k documents.
- Rust embedded index lifecycle test passing.
- Embedded incremental test proves unchanged content preserves the existing chunk row and a title change refreshes FTS.
- Node service native-vs-TypeScript deterministic parity test passing.
- Swift embedded core/index/finalize tests passing.
- Swift embedded provider tests passing.
- Global Search regression suite passing after localhost removal.
- Search concurrency/local-first/superseded-query tests passing with provider injection.
- Universal `arm64+x86_64` PKSCore build completed with macOS `minos 14.0`.
- Leafspan production Swift build completed with PKSCore linked.
- Clean committed host-daemon install/restart completed from `672ebd5`; post-install HTTP/Forge-socket native search parity, socket permissions and provider handshake passed.

## Guardrails

- Do not ship an embedded Node server or hidden Node child process.
- Do not add an HTTP server inside Leafspan.
- Do not make Leafspan depend on Forge or the host PKS installation.
- Do not duplicate search/ranking algorithms in Swift.
- Do not point the sandboxed app at the host PKS database.
- Do not bypass security-scoped access.
- Do not index the active workspace a second time as an embedded library source.
- Do not treat a build as App Store, sandbox, signing, notarization, or clean-machine acceptance.

## Remaining acceptance gates

The architecture is implemented, but the following are still separate acceptance work:

1. **Clean-machine packaged acceptance:** verify Leafspan with no Node, no PKS LaunchAgent, no Forge and no port 3217 service.
2. **App Sandbox acceptance:** exercise persisted security-scoped bookmarks in the signed packaged app, including revoke/stale-bookmark recovery.
3. **Signing/notarization/App Store packaging:** validate the generated universal native core inside the final signed artifact.
4. **PDF content indexing for added libraries:** currently metadata-only; no claim of embedded PDF text extraction.
5. **Refresh lifecycle:** decide and verify launch/background/watcher policy beyond add/manual refresh.

## Source-of-truth principle

Runtime claims require executable evidence. Source compilation, release build, signed package, clean-machine launch, sandbox behavior, and live-daemon rollout are distinct acceptance levels and must not be reported as interchangeable.
