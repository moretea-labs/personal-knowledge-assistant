import { KnowledgeDB } from '../db/database.js';
import { HashEmbeddingProvider, RemoteEmbeddingProvider } from './embedding.js';
import { Indexer } from './indexer.js';
import { SearchEngine } from './search.js';
import { KnowledgeWriter } from './writer.js';
import { MemoryBuilder } from './memory.js';
import { readFile } from 'node:fs/promises';
import crypto from 'node:crypto';
import { KnowledgeWatcher } from './watcher.js';
export class PKSService {
    cfg;
    syncPromise;
    watcher;
    db;
    embeddings;
    indexer;
    searcher;
    writer;
    memory;
    constructor(cfg) {
        this.cfg = cfg;
        this.db = new KnowledgeDB(cfg.dataDir);
        this.embeddings = (cfg.semantic?.provider === 'remote' && cfg.semantic.endpoint && cfg.semantic.model) ? new RemoteEmbeddingProvider(cfg.semantic.endpoint, cfg.semantic.model, cfg.semantic.dimensions || 1536, cfg.semantic.apiKey) : new HashEmbeddingProvider(cfg.semantic?.dimensions || 256);
        this.indexer = new Indexer(this.db, cfg, this.embeddings);
        this.searcher = new SearchEngine(this.db, this.embeddings);
        this.writer = new KnowledgeWriter(this.db, cfg, this.indexer);
        this.memory = new MemoryBuilder(this.db);
    }
    async open() { await this.db.open(); return this; }
    async sync() { if (this.syncPromise)
        return this.syncPromise; this.syncPromise = (async () => { const r = await this.indexer.syncAll(); this.memory.build('health'); this.memory.build('books'); this.memory.build('movies'); return r; })(); try {
        return await this.syncPromise;
    }
    finally {
        this.syncPromise = null;
    } }
    startWatching() { if (!this.watcher)
        this.watcher = new KnowledgeWatcher(this.cfg, () => this.sync()).start(); return this.watcher; }
    stopWatching() { this.watcher?.stop(); this.watcher = null; }
    async search(query, opts = {}) { return this.searcher.search(query, opts); }
    async read(documentId, maxChars = 20000) { const d = this.db.db.prepare('SELECT * FROM documents WHERE id=? AND deleted_at IS NULL').get(documentId); if (!d)
        return null; let content = ''; try {
        content = await readFile(d.uri, 'utf8');
    }
    catch {
        const chunks = this.db.db.prepare('SELECT text,page,heading_path FROM chunks WHERE document_id=? ORDER BY ordinal').all(documentId);
        content = chunks.map(x => x.text).join('\n\n');
    } return { document: d, content: content.slice(0, maxChars), truncated: content.length > maxChars }; }
    correctObservation(input) { const row = this.db.db.prepare('SELECT * FROM medical_observations WHERE id=?').get(input.id); if (!row)
        throw new Error('Observation not found'); const value = input.value ?? row.value, unit = input.unit ?? row.unit, date = input.observedAt ?? row.observed_at; this.db.db.prepare('UPDATE medical_observations SET value=?,unit=?,observed_at=?,verified=1,confidence=1,extraction_method=? WHERE id=?').run(value, unit, date, 'user_verified', input.id); this.db.db.prepare('INSERT INTO corrections(id,target_id,field,old_value,new_value,reason,created_at) VALUES(?,?,?,?,?,?,?)').run(crypto.randomUUID(), input.id, 'medical_observation', JSON.stringify({ value: row.value, unit: row.unit, observedAt: row.observed_at }), JSON.stringify({ value, unit, observedAt: date }), input.reason || 'user correction', new Date().toISOString()); this.memory.build('health'); return { ok: true, id: input.id, value, unit, observedAt: date, verified: true }; }
    organizationPlan() { const duplicates = this.db.db.prepare(`SELECT content_hash,COUNT(*) n,GROUP_CONCAT(uri,'||') uris FROM documents WHERE deleted_at IS NULL AND content_hash IS NOT NULL GROUP BY content_hash HAVING COUNT(*)>1 ORDER BY n DESC LIMIT 100`).all(); const unclassified = this.db.db.prepare(`SELECT id,title,uri,modified_at,index_status FROM documents WHERE deleted_at IS NULL AND document_type='generic' ORDER BY modified_at DESC LIMIT 100`).all(); const known = this.db.db.prepare(`SELECT id,title,uri,source_id,document_type FROM documents WHERE deleted_at IS NULL AND source_type='local' AND document_type!='generic' LIMIT 200`).all(); const local = this.db.db.prepare(`SELECT id,title,uri,index_status,size FROM documents WHERE deleted_at IS NULL AND source_type='local'`).all(); const deferredCount = local.filter(x => x.index_status === 'deferred').length; const root = String(this.cfg.sourceRoots.find(x => x.id === 'documents')?.root || '').replace(/\/$/, ''); const folderCounts = new Map(); const nameGroups = new Map(); for (const d of local) {
        const rel = root && d.uri.startsWith(root + '/') ? d.uri.slice(root.length + 1) : d.uri;
        const folder = rel.includes('/') ? rel.split('/')[0] : '(Documents root)';
        folderCounts.set(folder, (folderCounts.get(folder) || 0) + 1);
        const normalized = String(d.title).toLowerCase().replace(/\s*\(\d+\)(?=\.[^.]+$)/, '').replace(/\s+(copy|副本)(?=\.[^.]+$)/, '');
        const group = nameGroups.get(normalized) || [];
        group.push({ documentId: d.id, title: d.title, uri: d.uri, indexStatus: d.index_status, size: d.size });
        nameGroups.set(normalized, group);
    } const folderSummary = [...folderCounts.entries()].map(([folder, count]) => ({ folder, count })).sort((a, b) => b.count - a.count).slice(0, 50); const filenameDuplicateCandidates = [...nameGroups.values()].filter(x => x.length > 1).sort((a, b) => b.length - a.length).slice(0, 100).map(items => ({ normalizedTitle: String(items[0].title).replace(/\s*\(\d+\)(?=\.[^.]+$)/, ''), count: items.length, items })); const folders = { health_report: 'Health', book_note: 'Books', movie_record: 'Movies' }; const suggestedMoves = known.filter(x => folders[x.document_type]).map(x => ({ documentId: x.id, uri: x.uri, reason: `classified as ${x.document_type}`, suggestedFolder: folders[x.document_type] })); return { summary: { localDocuments: local.length, deferredCount, contentIndexedCount: local.length - deferredCount }, folderSummary, duplicateGroups: duplicates.map(x => ({ hash: x.content_hash, count: x.n, uris: String(x.uris).split('||') })), filenameDuplicateCandidates, unclassified, suggestedMoves, limitations: deferredCount ? ['Exact duplicate detection and content-based classification require local file content; deferred iCloud placeholders are metadata-only.'] : [], execution: 'proposal_only_use_forge_local_system_for_physical_moves' }; }
    sources() { return { sources: this.db.db.prepare('SELECT * FROM sources ORDER BY name').all(), syncState: this.db.db.prepare('SELECT * FROM sync_state ORDER BY source_id').all() }; }
    recentChanges(limit = 50) { return this.db.db.prepare('SELECT * FROM mutations ORDER BY timestamp DESC LIMIT ?').all(Math.min(limit, 200)); }
    entities(query = '', limit = 50) { return this.db.db.prepare(`SELECT e.*,COUNT(de.document_id) document_count FROM entities e LEFT JOIN document_entities de ON de.entity_id=e.id WHERE e.name LIKE ? GROUP BY e.id ORDER BY document_count DESC,e.name LIMIT ?`).all(`%${query}%`, Math.min(limit, 100)); }
    async analyze(question, domain = 'general') { if (domain === 'health') {
        const evidence = await this.search(question || 'health', { mode: 'structured', limit: 20 });
        return { domain, question, memory: this.memory.get('health'), evidence };
    } if (domain === 'movies' || domain === 'books') {
        return { domain, question, memory: this.memory.get(domain), evidence: await this.search(question || domain, { limit: 12 }) };
    } return { domain, question, evidence: await this.search(question, { limit: 20 }), memory: this.memory.get('general') }; }
    status() { const docs = this.db.db.prepare('SELECT COUNT(*) n FROM documents WHERE deleted_at IS NULL').get().n; const chunks = this.db.db.prepare('SELECT COUNT(*) n FROM chunks').get().n; const obs = this.db.db.prepare('SELECT COUNT(*) n FROM medical_observations').get().n; const muts = this.db.db.prepare('SELECT COUNT(*) n FROM mutations').get().n; return { documents: docs, chunks, medicalObservations: obs, mutations: muts, dataDir: this.cfg.dataDir, managedStore: this.cfg.managedStore, sources: this.cfg.sourceRoots }; }
}
