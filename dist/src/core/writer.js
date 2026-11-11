// @ts-nocheck
import { join, resolve, relative, sep } from 'node:path';
import { readFile, stat, lstat } from 'node:fs/promises';
import { atomicWrite, createExclusive, safeInside, ensureDir, removeIfExists } from '../util/fs.js';
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
    mutationTail = Promise.resolve();
    async serializeMutation(operation) {
        const previous = this.mutationTail;
        let release;
        this.mutationTail = new Promise(resolve => { release = resolve; });
        await previous;
        try {
            return await operation();
        }
        finally {
            release();
        }
    }
    async withCanonicalWrite(apply) {
        await this.db.beginWrite();
        try {
            const result = await apply();
            this.db.db.exec('COMMIT');
            return result;
        }
        catch (error) {
            this.db.db.exec('ROLLBACK');
            throw error;
        }
    }
    // Managed Store ownership is a filesystem boundary, not merely a path prefix.
    async checkedManagedPath(candidate) {
        const root = resolve(this.cfg.managedStore);
        const path = resolve(candidate);
        if (!safeInside(root, path))
            throw new Error('destination must stay inside managedStore');
        let current = root;
        for (const component of relative(root, path).split(sep).filter(Boolean)) {
            current = join(current, component);
            try {
                if ((await lstat(current)).isSymbolicLink())
                    throw new Error('symbolic link path is not allowed in managedStore');
            }
            catch (error) {
                if (error?.code !== 'ENOENT')
                    throw error;
            }
        }
        return path;
    }
    invalidateMemory() { this.db.db.prepare('DELETE FROM memory_profiles').run(); }
    removeDerivedByUri(uri) {
        const d = this.db.db.prepare('SELECT id FROM documents WHERE uri=?').get(uri);
        if (!d)
            return;
        // Called only within withCanonicalWrite: the same SQLite transaction owns
        // both source tombstones and derived evidence removal.
        this.db.db.prepare('DELETE FROM chunks_fts WHERE document_id=?').run(d.id);
        this.db.db.prepare('DELETE FROM chunks WHERE document_id=?').run(d.id);
        this.db.db.prepare('DELETE FROM structured_records WHERE source_document_id=?').run(d.id);
        this.db.db.prepare('DELETE FROM medical_observations WHERE source_document_id=?').run(d.id);
        this.db.db.prepare('DELETE FROM document_entities WHERE document_id=?').run(d.id);
        this.db.db.prepare("UPDATE documents SET deleted_at=?,index_status='deleted' WHERE id=?").run(new Date().toISOString(), d.id);
    }
    async create(input) {
        return this.serializeMutation(async () => {
            const domain = (input.domain || 'Inbox').replace(/[^\p{L}\p{N}_ -]/gu, '').trim() || 'Inbox';
            const title = input.title || new Date().toISOString().slice(0, 10);
            const folder = input.destination ? resolve(input.destination) : join(this.cfg.managedStore, domain[0].toUpperCase() + domain.slice(1));
            const body = this.render(title, domain, input.content, input.structuredData);
            const result = await this.withCanonicalWrite(async () => {
                await this.checkedManagedPath(folder);
                await ensureDir(folder);
                await this.checkedManagedPath(folder);
                let path;
                for (let attempt = 0; attempt < 10000; attempt++) {
                    const candidate = join(folder, `${slug(title)}${attempt ? '-' + (attempt + 1) : ''}.md`);
                    try {
                        await createExclusive(candidate, body);
                        path = candidate;
                        break;
                    }
                    catch (error) {
                        if (error?.code !== 'EEXIST')
                            throw error;
                    }
                }
                if (!path)
                    throw new Error('No available filename for managed note');
                const stats = await stat(path);
                const mutationId = id();
                this.db.db.prepare('INSERT INTO mutations(id,actor,action,source,uri,before_json,after_json,timestamp,reason,reversible) VALUES(?,?,?,?,?,NULL,?,?,?,1)').run(mutationId, input.actor || 'user', 'create', 'managed', path, JSON.stringify({ content: body }), new Date().toISOString(), input.reason || 'knowledge_write');
                return { path, mutationId, stats };
            });
            await this.indexer.indexFile('managed', 'managed', result.path, result.stats.mtime.toISOString(), result.stats.birthtime.toISOString(), result.stats.size, undefined, result.mutationId);
            this.invalidateMemory();
            return { mutationId: result.mutationId, action: 'create', uri: result.path, reversible: true };
        });
    }
    async update(input) {
        return this.serializeMutation(async () => {
            const path = await this.checkedManagedPath(input.uri);
            const result = await this.withCanonicalWrite(async () => {
                await this.checkedManagedPath(path);
                const before = await readFile(path, 'utf8');
                const after = input.replace !== undefined ? input.replace : before + (input.append ?? '');
                await this.checkedManagedPath(path);
                await atomicWrite(path, after);
                const stats = await stat(path);
                const mutationId = id();
                this.db.db.prepare('INSERT INTO mutations(id,actor,action,source,uri,before_json,after_json,timestamp,reason,reversible) VALUES(?,?,?,?,?,?,?,?,?,1)').run(mutationId, input.actor || 'user', 'update', 'managed', path, JSON.stringify({ content: before }), JSON.stringify({ content: after }), new Date().toISOString(), input.reason || 'knowledge_update');
                return { mutationId, stats };
            });
            await this.indexer.indexFile('managed', 'managed', path, result.stats.mtime.toISOString(), result.stats.birthtime.toISOString(), result.stats.size, undefined, result.mutationId);
            this.invalidateMemory();
            return { mutationId: result.mutationId, action: 'update', uri: path, reversible: true };
        });
    }
    async undo(mutationId) {
        return this.serializeMutation(async () => {
            const result = await this.withCanonicalWrite(async () => {
                const m = this.db.db.prepare('SELECT * FROM mutations WHERE id=?').get(mutationId);
                if (!m || m.undone_at)
                    throw new Error('Mutation not found or already undone');
                const path = await this.checkedManagedPath(m.uri);
                let stats;
                if (m.action === 'create') {
                    const created = JSON.parse(m.after_json || '{}');
                    const current = await readFile(path, 'utf8');
                    if (current !== created.content)
                        throw new Error('Cannot undo create: managed note changed after this mutation');
                    await this.checkedManagedPath(path);
                    await removeIfExists(path);
                    this.removeDerivedByUri(path);
                }
                else if (m.action === 'update') {
                    const before = JSON.parse(m.before_json || '{}');
                    const after = JSON.parse(m.after_json || '{}');
                    const current = await readFile(path, 'utf8');
                    if (current !== after.content)
                        throw new Error('Cannot undo update: managed note changed after this mutation');
                    await this.checkedManagedPath(path);
                    await atomicWrite(path, before.content || '');
                    stats = await stat(path);
                }
                else
                    throw new Error('Mutation is not undoable by standalone writer');
                this.db.db.prepare('UPDATE mutations SET undone_at=? WHERE id=?').run(new Date().toISOString(), mutationId);
                const active = this.db.db.prepare('SELECT id FROM mutations WHERE uri=? AND undone_at IS NULL ORDER BY rowid DESC LIMIT 1').get(path);
                return { action: m.action, path, stats, activeMutationId: active?.id ?? '' };
            });
            if (result.action === 'update') {
                await this.indexer.indexFile('managed', 'managed', result.path, result.stats.mtime.toISOString(), result.stats.birthtime.toISOString(), result.stats.size, undefined, result.activeMutationId);
            }
            this.invalidateMemory();
            return { ok: true, mutationId };
        });
    }
    render(title, domain, content, data) { const fm = { type: data?.type || domain.toLowerCase(), title, ...data }; const lines = ['---', ...Object.entries(fm).filter(([, v]) => v !== undefined).map(([k, v]) => `${k}: ${Array.isArray(v) ? `[${v.join(', ')}]` : String(v)}`), '---', '', `# ${title}`, '', content.trim(), '']; return lines.join('\n'); }
}
