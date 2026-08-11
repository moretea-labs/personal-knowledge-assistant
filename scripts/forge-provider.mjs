#!/usr/bin/env node
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import { loadConfig } from '../dist/src/config.js';
import { PKSService } from '../dist/src/core/service.js';
import { providerManifest, FORGE_ACTIONS } from '../dist/src/forge/contract.js';

const VERSION = '0.2.1';
const PLUGIN_ID = 'personal_knowledge';
const capabilities = ['knowledge.read', 'knowledge.write', 'knowledge.admin'];
function write(value) { process.stdout.write(`${JSON.stringify(value)}\n`); }
function ok(requestId, result) { write({ schemaVersion: 1, type: 'result', requestId, ok: true, result }); }
function fail(requestId, error) { write({ schemaVersion: 1, type: 'result', requestId, ok: false, error: { code: error?.code || 'PERSONAL_KNOWLEDGE_ACTION_FAILED', message: String(error?.message || error).slice(0, 1000), retryable: false } }); }
async function config() {
  const explicit = process.env.PKS_CONFIG;
  const canonical = join(homedir(), '.pks', 'config.json');
  return await loadConfig(explicit || (existsSync(canonical) ? canonical : undefined));
}
async function withService(fn) {
  const service = await new PKSService(await config()).open();
  try { return await fn(service); } finally { service.db.close(); }
}
async function execute(action, a = {}) {
  if (action === 'manifest') return { ...providerManifest(), provider: 'moretea-labs' };
  if (action === 'health') return await withService(async (service) => ({ state: 'ready', ...service.status(), warnings: [] }));
  if (!FORGE_ACTIONS.some((x) => x.actionId === action)) throw Object.assign(new Error(`Unknown action ${action}`), { code: 'PERSONAL_KNOWLEDGE_ACTION_UNKNOWN' });
  return await withService(async (service) => {
    switch (action) {
      case 'knowledge_search': return { results: await service.search(a.query || '', { mode: a.mode || 'auto', limit: a.limit || 12, documentType: a.document_type, source: a.source }) };
      case 'knowledge_read': return { result: await service.read(a.document_id, a.max_chars || 20000) };
      case 'knowledge_analyze': return { analysis: await service.analyze(a.question || '', a.domain || 'general') };
      case 'knowledge_mutate':
        if (a.operation === 'undo') return await service.writer.undo(a.mutation_id);
        if (a.operation === 'update') return await service.writer.update({ uri: a.uri, append: a.append, replace: a.replace, actor: 'forge' });
        return await service.writer.create({ content: a.content || '', title: a.title, domain: a.domain, structuredData: a.structured_data, actor: 'forge' });
      case 'knowledge_admin':
        if (a.operation === 'status') return { status: service.status() };
        if (a.operation === 'organization_plan') return { plan: service.organizationPlan() };
        if (a.operation === 'sources') return service.sources();
        if (a.operation === 'recent_changes') return { changes: service.recentChanges() };
        return { sync: await service.sync() };
    }
  });
}
write({ schemaVersion: 1, type: 'handshake', protocolVersion: 1, pluginId: PLUGIN_ID, helperVersion: VERSION, capabilities });
const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
let handled = false;
lines.on('line', async (line) => {
  if (handled || !line.trim()) return;
  handled = true;
  let message;
  try {
    message = JSON.parse(line);
    if (message?.schemaVersion !== 1 || message?.type !== 'execute' || typeof message?.requestId !== 'string') throw Object.assign(new Error('Invalid managed provider request.'), { code: 'PERSONAL_KNOWLEDGE_PROTOCOL_INVALID' });
    ok(message.requestId, await execute(message.actionId, message.input || {}));
  } catch (error) { fail(message?.requestId || 'unknown', error); }
  finally { lines.close(); }
});
