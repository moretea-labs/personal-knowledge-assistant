# Operations

## Build and test

```bash
npm run build
npm test
npm run demo
```

`dist/` is included in the distributed archive so the sandbox artifact can run without fetching packages.

## Configure

```bash
node dist/src/cli.js init --pks-config=./pks.config.json
```

Edit `sourceRoots`. Keep the managed root enabled. Optional environment variables:

```text
PKS_CONFIG
PKS_DATA_DIR
PKS_MANAGED_STORE
PKS_NOTION_TOKEN
PKS_EMBEDDING_ENDPOINT
PKS_EMBEDDING_MODEL
PKS_EMBEDDING_API_KEY
PKS_EMBEDDING_DIMENSIONS
```

## Index / query

```bash
node dist/src/cli.js sync --pks-config=./pks.config.json
node dist/src/cli.js search eventId --pks-config=./pks.config.json
node dist/src/cli.js memory health --pks-config=./pks.config.json
```

## Run local product

```bash
node dist/src/server.js --pks-config=./pks.config.json
```

Open `http://127.0.0.1:3217`.

## Generate Forge trusted registration input

```bash
node dist/src/cli.js forge-registration --pks-config=./pks.config.json
```

Do not manually write this JSON into Forge controller state. Install it through Forge's registration authority once the external-plugin install action is exposed.

## macOS daemon

```bash
./scripts/install-macos.sh
```

The canonical standalone installation is `~/.local/share/personal-knowledge-system` with the single user LaunchAgent `com.personal-knowledge.pks`. The installer updates this path in place, verifies HTTP readiness, and retains the previous compiled files for rollback. It does **not** create the older `personal-knowledge-assistant` installation or change Forge Runtime.

The standalone daemon and the Forge-managed `personal_knowledge` registration share the same SQLite authority but have separate lifecycle operations. Update the Forge external registration through its authorized `plugin_management.install_registration` action with the actual external-registration revision guard; do not write files under Forge controller state manually.
