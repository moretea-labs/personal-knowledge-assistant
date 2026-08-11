// @ts-nocheck
import { createServer } from 'node:net';
import { unlink, chmod } from 'node:fs/promises';
import { dirname } from 'node:path';
import { ensureDir, fileExists } from '../util/fs.js';
import { providerManifest, FORGE_ACTIONS } from './contract.js';
export class ForgeSocketServer {
    service;
    socketPath;
    server;
    constructor(service, socketPath) {
        this.service = service;
        this.socketPath = socketPath;
    }
    async start() { await ensureDir(dirname(this.socketPath)); if (await fileExists(this.socketPath))
        await unlink(this.socketPath); this.server = createServer(s => this.handleSocket(s)); await new Promise((resolve, reject) => { this.server.once('error', reject); this.server.listen(this.socketPath, () => resolve(null)); }); await chmod(this.socketPath, 0o600); return this; }
    async stop() { if (!this.server)
        return; await new Promise(r => this.server.close(() => r(null))); this.server = undefined; if (await fileExists(this.socketPath))
        await unlink(this.socketPath).catch(() => { }); }
    handleSocket(socket) { let buf = ''; let bytes = 0; socket.setEncoding('utf8'); socket.on('data', (chunk) => { bytes += Buffer.byteLength(chunk); if (bytes > 1048576) {
        socket.destroy();
        return;
    } buf += chunk; let i; while ((i = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, i);
        buf = buf.slice(i + 1);
        if (line.trim())
            this.handleLine(socket, line).catch(() => { });
    } }); }
    async handleLine(socket, line) { let req; try {
        req = JSON.parse(line);
    }
    catch {
        return this.reply(socket, 'unknown', false, null, { code: 'PKS_PROTOCOL_ERROR', message: 'Invalid JSON', retryable: false });
    } const id = typeof req.id === 'string' ? req.id : 'unknown'; try {
        let result;
        switch (req.method) {
            case 'handshake':
            case 'manifest':
                result = providerManifest();
                break;
            case 'health': {
                const s = this.service.status();
                result = { state: 'ready', documents: s.documents, chunks: s.chunks, medicalObservations: s.medicalObservations, dataDir: s.dataDir, managedStore: s.managedStore, socketPath: this.socketPath, warnings: [] };
                break;
            }
            case 'execute':
                result = await this.execute(req.params?.action, req.params?.arguments || {});
                break;
            default: throw Object.assign(new Error(`Unsupported method ${req.method}`), { code: 'PKS_METHOD_UNSUPPORTED' });
        }
        this.reply(socket, id, true, result);
    }
    catch (e) {
        this.reply(socket, id, false, null, { code: e?.code || 'PKS_ACTION_FAILED', message: String(e?.message || e).slice(0, 1000), retryable: false });
    } }
    async execute(action, a) { if (!FORGE_ACTIONS.some(x => x.actionId === action))
        throw Object.assign(new Error(`Unknown action ${action}`), { code: 'PKS_ACTION_UNKNOWN' }); switch (action) {
        case 'knowledge_search': return { results: await this.service.search(a.query || '', { mode: a.mode || 'auto', limit: a.limit || 12, documentType: a.document_type, source: a.source }) };
        case 'knowledge_read': return { result: await this.service.read(a.document_id, a.max_chars || 20000) };
        case 'knowledge_analyze': return { analysis: await this.service.analyze(a.question || '', a.domain || 'general') };
        case 'knowledge_mutate':
            if (a.operation === 'undo')
                return this.service.writer.undo(a.mutation_id);
            if (a.operation === 'update')
                return this.service.writer.update({ uri: a.uri, append: a.append, replace: a.replace, actor: 'forge' });
            return this.service.writer.create({ content: a.content || '', title: a.title, domain: a.domain, structuredData: a.structured_data, actor: 'forge' });
        case 'knowledge_admin':
            if (a.operation === 'status')
                return { status: this.service.status() };
            if (a.operation === 'organization_plan')
                return { plan: this.service.organizationPlan() };
            if (a.operation === 'sources')
                return this.service.sources();
            if (a.operation === 'recent_changes')
                return { changes: this.service.recentChanges() };
            return { sync: await this.service.sync() };
    } }
    reply(socket, id, ok, result, error) { socket.write(JSON.stringify(ok ? { id, ok: true, result } : { id, ok: false, error }) + '\n'); }
}
