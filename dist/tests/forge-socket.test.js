// @ts-nocheck
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createConnection } from 'node:net';
import { PKSService } from '../src/core/service.js';
import { ForgeSocketServer } from '../src/forge/socket-server.js';
import { registrationInput, FORGE_ACTIONS } from '../src/forge/contract.js';
async function rpc(socketPath, method, params = {}) {
    const id = `t-${Math.random().toString(16).slice(2)}`;
    return await new Promise((resolve, reject) => {
        const s = createConnection({ path: socketPath });
        let buf = '';
        const timer = setTimeout(() => { s.destroy(); reject(new Error('timeout')); }, 3000);
        s.setEncoding('utf8');
        s.once('connect', () => s.write(JSON.stringify({ id, method, params }) + '\n'));
        s.on('data', (chunk) => { buf += chunk; const i = buf.indexOf('\n'); if (i < 0)
            return; clearTimeout(timer); s.destroy(); const r = JSON.parse(buf.slice(0, i)); if (r.id !== id)
            return reject(new Error('mismatched id')); resolve(r); });
        s.once('error', reject);
    });
}
async function setup() {
    const root = await mkdtemp(join(tmpdir(), 'pks-forge-'));
    const docs = join(root, 'docs'), managed = join(root, 'managed'), data = join(root, 'data'), socketPath = join(root, 'pks.sock');
    await mkdir(docs, { recursive: true });
    const svc = await new PKSService({ dataDir: data, managedStore: managed, port: 0, host: '127.0.0.1', sourceRoots: [{ id: 'docs', type: 'local', name: 'Docs', root: docs }, { id: 'managed', type: 'managed', name: 'Managed', root: managed }], semantic: { provider: 'hash', dimensions: 128 }, forge: { enabled: true, socketPath } }).open();
    const server = await new ForgeSocketServer(svc, socketPath).start();
    return { root, docs, managed, data, socketPath, svc, server };
}
test('Forge external-provider protocol exposes manifest, health, search and managed mutation', async () => {
    const x = await setup();
    try {
        await writeFile(join(x.docs, '2026-07-10-lab.md'), '# Lab\n肌酐 112 μmol/L\n');
        await x.svc.sync();
        const manifest = await rpc(x.socketPath, 'manifest');
        assert.equal(manifest.ok, true);
        assert.equal(manifest.result.id, 'personal_knowledge');
        assert.ok(manifest.result.actions.includes('knowledge_search'));
        const health = await rpc(x.socketPath, 'health');
        assert.equal(health.ok, true);
        assert.equal(health.result.state, 'ready');
        assert.equal(health.result.documents, 1);
        const search = await rpc(x.socketPath, 'execute', { action: 'knowledge_search', arguments: { query: '肌酐' } });
        assert.equal(search.ok, true);
        assert.ok(search.result.results.length >= 1);
        const create = await rpc(x.socketPath, 'execute', { action: 'knowledge_mutate', arguments: { operation: 'create', domain: 'movies', title: 'Arrival', content: 'Excellent.', structured_data: { type: 'movie_watch', rating: 5, watched_at: '2026-08-11' } } });
        assert.equal(create.ok, true);
        const analyze = await rpc(x.socketPath, 'execute', { action: 'knowledge_analyze', arguments: { domain: 'movies', question: '偏好' } });
        assert.equal(analyze.ok, true);
        assert.equal(analyze.result.analysis.memory.profile.count, 1);
    }
    finally {
        await x.server.stop();
        x.svc.db.close();
    }
});
test('Forge registration matches provider identity and keeps tool surface bounded', () => {
    const reg = registrationInput('/tmp/pks.sock', 'personal-knowledge-assistant');
    assert.equal(reg.pluginId, 'personal_knowledge');
    assert.equal(reg.providerPluginId, 'personal_knowledge');
    assert.equal(reg.protocolVersion, '1.0');
    assert.deepEqual(reg.actions.map((x) => x.actionId), FORGE_ACTIONS.map((x) => x.actionId));
    assert.equal(reg.actions.length, 5);
    assert.equal(reg.transport.kind, 'unix_socket_jsonl');
});
