import { cosine } from './embedding.js';
export class SearchEngine {
    db;
    embeddings;
    constructor(db, embeddings) {
        this.db = db;
        this.embeddings = embeddings;
    }
    async search(query, opts = {}) {
        const limit = Math.min(Math.max(opts.limit || 12, 1), 50);
        if (opts.mode === 'structured' || looksStructured(query))
            return this.structured(query, limit);
        const metadata = this.metadata(query, Math.max(limit * 2, 20), opts);
        if (opts.mode === 'metadata')
            return metadata.slice(0, limit);
        const fts = this.fts(query, Math.max(limit * 3, 20), opts);
        if ((opts.mode === undefined || opts.mode === 'auto') && fts.length >= limit && metadata.length === 0)
            return fts.slice(0, limit);
        const sem = (opts.mode === 'fts' || query.trim().length < 2) ? [] : await this.semantic(query, Math.max(limit * 3, 20), opts);
        const map = new Map();
        for (const r of [...fts, ...sem]) {
            const k = r.chunkId || r.documentId;
            const old = map.get(k);
            if (!old)
                map.set(k, r);
            else {
                old.score = Math.max(old.score, r.score) + Math.min(old.score, r.score) * 0.35;
                old.reasons = [...new Set([...old.reasons, ...r.reasons])];
                if (!old.snippet && r.snippet)
                    old.snippet = r.snippet;
            }
        }
        const representedDocuments = new Set([...map.values()].map(r => r.documentId));
        for (const r of metadata) {
            if (representedDocuments.has(r.documentId))
                continue;
            map.set(`document:${r.documentId}`, r);
        }
        return [...map.values()].sort((a, b) => b.score - a.score).slice(0, limit);
    }
    where(opts) {
        const parts = ['d.deleted_at IS NULL'];
        const args = [];
        if (opts.source) {
            parts.push('d.source_id=?');
            args.push(opts.source);
        }
        if (opts.documentType) {
            parts.push('d.document_type=?');
            args.push(opts.documentType);
        }
        if (opts.dateFrom) {
            parts.push('d.modified_at>=?');
            args.push(opts.dateFrom);
        }
        if (opts.dateTo) {
            parts.push('d.modified_at<=?');
            args.push(opts.dateTo);
        }
        return { sql: parts.join(' AND '), args };
    }
    metadata(query, limit, opts) {
        const q = query.trim().toLowerCase();
        if (!q)
            return [];
        const w = this.where(opts);
        const rows = this.db.db.prepare(`SELECT d.id document_id,d.title,d.uri,d.source_type,d.document_type,d.modified_at,d.index_status,d.metadata_json FROM documents d WHERE ${w.sql} AND (lower(d.title) LIKE ? OR lower(d.uri) LIKE ?) ORDER BY CASE WHEN lower(d.title)=? THEN 0 WHEN lower(d.title) LIKE ? THEN 1 ELSE 2 END,d.modified_at DESC LIMIT ?`).all(...w.args, `%${q}%`, `%${q}%`, q, `${q}%`, limit);
        return rows.map((r, i) => ({
            documentId: r.document_id,
            title: r.title,
            uri: r.uri,
            sourceType: r.source_type,
            documentType: r.document_type,
            modifiedAt: r.modified_at,
            snippet: r.index_status === 'deferred' ? 'Cloud/offline placeholder: metadata is indexed; content will be indexed when locally available.' : r.uri,
            score: Math.max(0.72, 0.98 - i * 0.015),
            reasons: [r.index_status === 'deferred' ? 'metadata_deferred' : 'metadata']
        }));
    }
    fts(query, limit, opts) {
        const w = this.where(opts);
        const safe = query.replace(/["']/g, ' ').trim().split(/\s+/).filter(Boolean).map((x) => `"${x.replace(/"/g, '')}"`).join(' OR ');
        if (!safe)
            return [];
        try {
            const rows = this.db.db.prepare(`SELECT d.id document_id,c.id chunk_id,d.title,d.uri,d.source_type,d.document_type,d.modified_at,c.text,c.page,c.heading_path,bm25(chunks_fts) rank FROM chunks_fts JOIN chunks c ON c.id=chunks_fts.chunk_id JOIN documents d ON d.id=c.document_id WHERE chunks_fts MATCH ? AND ${w.sql} ORDER BY rank LIMIT ?`).all(safe, ...w.args, limit);
            return rows.map((r, i) => ({ documentId: r.document_id, chunkId: r.chunk_id, title: r.title, uri: r.uri, sourceType: r.source_type, documentType: r.document_type, modifiedAt: r.modified_at, snippet: snippet(r.text, query), score: 1 / (1 + i * 0.08), reasons: ['full_text'], page: r.page ?? undefined, headingPath: r.heading_path ?? undefined }));
        }
        catch {
            return [];
        }
    }
    async semantic(query, limit, opts) {
        let q;
        try {
            q = await this.embeddings.embed(query);
        }
        catch {
            return [];
        }
        const w = this.where(opts);
        const rows = this.db.db.prepare(`SELECT d.id document_id,c.id chunk_id,d.title,d.uri,d.source_type,d.document_type,d.modified_at,c.text,c.page,c.heading_path,c.embedding_json FROM chunks c JOIN documents d ON d.id=c.document_id WHERE c.embedding_json IS NOT NULL AND c.embedding_provider=? AND ${w.sql} ORDER BY d.modified_at DESC LIMIT 5000`).all(this.embeddings.id, ...w.args);
        return rows.map(r => ({ r, s: cosine(q, JSON.parse(r.embedding_json || '[]')) })).filter(x => x.s > 0.12).sort((a, b) => b.s - a.s).slice(0, limit).map(x => ({ documentId: x.r.document_id, chunkId: x.r.chunk_id, title: x.r.title, uri: x.r.uri, sourceType: x.r.source_type, documentType: x.r.document_type, modifiedAt: x.r.modified_at, snippet: snippet(x.r.text, query), score: x.s * 0.82, reasons: ['semantic_hash'], page: x.r.page ?? undefined, headingPath: x.r.heading_path ?? undefined }));
    }
    structured(query, limit) {
        const q = query.toLowerCase();
        const type = q.includes('胱抑素') || q.includes('cystatin') ? 'cystatin_c' : q.includes('肌酐') || q.includes('creatinine') ? 'creatinine' : q.includes('他克莫司') || q.includes('tacrolimus') ? 'tacrolimus_trough' : undefined;
        if (!type)
            return [];
        const rows = this.db.db.prepare(`SELECT m.*,d.title,d.uri,d.source_type FROM medical_observations m JOIN documents d ON d.id=m.source_document_id WHERE m.observation_type=? AND d.deleted_at IS NULL ORDER BY m.observed_at DESC LIMIT ?`).all(type, limit);
        return rows.map((r, i) => ({ documentId: r.source_document_id, title: r.title, uri: r.uri, sourceType: r.source_type, documentType: 'health_report', modifiedAt: r.observed_at, snippet: `${r.observation_type}: ${r.value}${r.unit ? ' ' + r.unit : ''} (${r.observed_at || 'date unknown'})`, score: 1 - i * 0.02, reasons: ['structured_health'] }));
    }
}
function looksStructured(q) { return /(最近|最新|最高|最低|趋势|肌酐|胱抑素|cystatin|creatinine|他克莫司|tacrolimus)/i.test(q); }
function snippet(text, q) { const terms = q.toLowerCase().split(/\s+/).filter(Boolean); let pos = -1; for (const t of terms) {
    pos = text.toLowerCase().indexOf(t);
    if (pos >= 0)
        break;
} if (pos < 0)
    pos = 0; return text.slice(Math.max(0, pos - 100), Math.min(text.length, pos + 320)).replace(/\s+/g, ' ').trim(); }
