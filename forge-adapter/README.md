# Forge external-provider integration

The current Forge runtime supports external controller-scoped plugins over bounded Unix-socket JSONL. PKS implements that protocol directly in `src/forge/socket-server.ts`; it does **not** require a first-party Forge core adapter.

Provider identity:
- plugin id: `personal_knowledge`
- provider: `pks`
- protocol: `1.0`
- scope: `controller`
- socket: default `~/.pks/forge.sock`

The daemon serves Forge methods `manifest`, `health`, and `execute` and exposes five product-level actions:
`knowledge_search`, `knowledge_read`, `knowledge_mutate`, `knowledge_analyze`, `knowledge_admin`.

Generate the trusted registration input with:

```bash
node dist/src/cli.js forge-registration --pks-config=$HOME/.pks/config.json
```

Current Forge source has `installExternalPluginRegistration(...)`, but the ChatGPT tool surface does not yet expose a dedicated external-plugin registration installer. Do not bypass the trusted registration store by copying arbitrary JSON into controller state; use the Forge registration authority when that install path is exposed, or a repo-local trusted invocation of that authority during development.

Physical moves/renames/deletes outside PKS managed storage are intentionally not implemented here. `knowledge_admin(operation=organization_plan)` produces proposals; ChatGPT should then use Forge `local_system` with authorized filesystem targets to execute approved moves.
