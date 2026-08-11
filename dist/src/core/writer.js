// @ts-nocheck
import { join, resolve } from 'node:path';
import { readFile, stat } from 'node:fs/promises';
import { atomicWrite, fileExists, safeInside, ensureDir, removeIfExists } from '../util/fs.js';
import { id } from './ids.js';
function slug(s) { return s.trim().replace(/[\\/:*?"<>|]/g, '-').replace(/\s+/g, '-').slice(0, 100) || 'note'; }
export class KnowledgeWriter {
    db;
    cfg;
    indexer;
    constructor(db, cfg, indexer) {
        this.db = db;
        this.cfg = cfg;
        this.indexer = indexer;
    }
    invalidateMemory() { this.db.db.prepare('DELETE FROM memory_profiles').run(); }
    removeDerivedByUri(uri) {
        const d = this.db.db.prepare('SELECT id FROM documents WHERE uri=?').get(uri);
        if (!d)
            return;
        this.db.db.exec('BEGIN');
        try {
            this.db.db.prepare('DELETE FROM chunks_fts WHERE document_id=?').run(d.id);
            this.db.db.prepare('DELETE FROM chunks WHERE document_id=?').run(d.id);
            this.db.db.prepare('DELETE FROM structured_records WHERE source_document_id=?').run(d.id);
            this.db.db.prepare('DELETE FROM medical_observations WHERE source_document_id=?').run(d.id);
            this.db.db.prepare('DELETE FROM document_entities WHERE document_id=?').run(d.id);
            this.db.db.prepare("UPDATE documents SET deleted_at=?,index_status='deleted' WHERE id=?").run(new Date().toISOString(), d.id);
            this.db.db.exec('COMMIT');
        }
        catch (e) {
            this.db.db.exec('ROLLBACK');
            throw e;
        }
    }
    async create(input) {
        const domain = (input.domain || 'Inbox').replace(/[^\p{L}\p{N}_ -]/gu, '').trim() || 'Inbox';
        const title = input.title || new Date().toISOString().slice(0, 10);
        const folder = input.destination ? resolve(input.destination) : join(this.cfg.managedStore, domain[0].toUpperCase() + domain.slice(1));
        if (!safeInside(this.cfg.managedStore, folder))
            throw new Error('destination must stay inside managedStore');
        await ensureDir(folder);
        let path = join(folder, `${slug(title)}.md`);
        if (await fileExists(path))
            path = join(folder, `${slug(title)}-${Date.now()}.md`);
        const body = this.render(title, domain, input.content, input.structuredData);
        await atomicWrite(path, body);
        const s = await stat(path);
        await this.indexer.indexFile('managed', 'managed', path, s.mtime.toISOString(), s.birthtime.toISOString(), s.size);
        this.invalidateMemory();
        const mutationId = id();
        this.db.db.prepare('INSERT INTO mutations(id,actor,action,source,uri,before_json,after_json,timestamp,reason,reversible) VALUES(?,?,?,?,?,NULL,?,?,?,1)').run(mutationId, input.actor || 'user', 'create', 'managed', path, JSON.stringify({ content: body }), new Date().toISOString(), input.reason || 'knowledge_write');
        return { mutationId, action: 'create', uri: path, reversible: true };
    }
    async update(input) {
        const path = resolve(input.uri);
        if (!safeInside(this.cfg.managedStore, path))
            throw new Error('Standalone write only permits managedStore; use Forge local_system for external source mutation.');
        const before = await readFile(path, 'utf8');
        const after = input.replace !== undefined ? input.replace : before + (input.append ?? '');
        await atomicWrite(path, after);
        const s = await stat(path);
        await this.indexer.indexFile('managed', 'managed', path, s.mtime.toISOString(), s.birthtime.toISOString(), s.size);
        this.invalidateMemory();
        const mutationId = id();
        this.db.db.prepare('INSERT INTO mutations(id,actor,action,source,uri,before_json,after_json,timestamp,reason,reversible) VALUES(?,?,?,?,?,?,?,?,?,1)').run(mutationId, input.actor || 'user', 'update', 'managed', path, JSON.stringify({ content: before }), JSON.stringify({ content: after }), new Date().toISOString(), input.reason || 'knowledge_update');
        return { mutationId, action: 'update', uri: path, reversible: true };
    }
    async undo(mutationId) {
        const m = this.db.db.prepare('SELECT * FROM mutations WHERE id=?').get(mutationId);
        if (!m || m.undone_at)
            throw new Error('Mutation not found or already undone');
        if (m.action === 'create') {
            await removeIfExists(m.uri);
            this.removeDerivedByUri(m.uri);
        }
        else if (m.action === 'update') {
            const b = JSON.parse(m.before_json || '{}');
            await atomicWrite(m.uri, b.content || '');
            const s = await stat(m.uri);
            await this.indexer.indexFile('managed', 'managed', m.uri, s.mtime.toISOString(), s.birthtime.toISOString(), s.size);
        }
        else
            throw new Error('Mutation is not undoable by standalone writer');
        this.db.db.prepare('UPDATE mutations SET undone_at=? WHERE id=?').run(new Date().toISOString(), mutationId);
        this.invalidateMemory();
        return { ok: true, mutationId };
    }
    render(title, domain, content, data) { const fm = { type: data?.type || domain.toLowerCase(), title, ...data }; const lines = ['---', ...Object.entries(fm).filter(([, v]) => v !== undefined).map(([k, v]) => `${k}: ${Array.isArray(v) ? `[${v.join(', ')}]` : String(v)}`), '---', '', `# ${title}`, '', content.trim(), '']; return lines.join('\n'); }
}
