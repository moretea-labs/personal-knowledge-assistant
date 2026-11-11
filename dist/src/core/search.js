export class SearchEngine {
    db;
    embeddings;
    // Derived, bounded in-process search acceleration only. SQLite remains canonical;
    // a write by this connection or another connection invalidates the snapshot.
    semanticCache = null;
    constructor(db, embeddings) {
        this.db = db;
        this.embeddings = embeddings;
    }
    async search(query, opts = {}) {
        const limit = Math.min(Math.max(opts.limit || 12, 1), 50);
        if (opts.mode === 'related')
            return this.related(query, limit, opts);
        if (opts.mode === 'structured' || looksStructured(query))
            return this.structured(query, limit);
        const metadata = this.metadata(query, Math.max(limit * 2, 20), opts);
        if (opts.mode === 'metadata')
            return metadata.slice(0, limit);
        // Locating a file is a catalog lookup, never an approximate content search.
        if ((opts.mode === undefined || opts.mode === 'auto') && isLocatorQuery(query))
            return metadata.slice(0, limit);
        const fts = this.fts(query, Math.max(limit * 3, 20), opts);
        if ((opts.mode === undefined || opts.mode === 'auto') && fts.length >= limit && metadata.length === 0)
            return fts.slice(0, limit);
        // A single-term query with enough literal FTS matches should not decode
        // thousands of vectors. Natural-language and low-recall queries still use
        // semantic evidence; explicit mode=semantic always computes it.
        const sufficientLiteral = (opts.mode === undefined || opts.mode === 'auto')
            && !/\s/u.test(query.trim()) && fts.length >= limit;
        const sem = (sufficientLiteral || opts.mode === 'fts' || query.trim().length < 2)
            ? [] : await this.semantic(query, Math.max(limit * 3, 20), opts);
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
    /** Related notes require multiple concrete content signals. Hash-vector proximity
     * alone (or one shared filename word) is not evidence of a relationship. */
    async related(query, limit, opts) {
        const keywords = relatedKeywords(query);
        if (keywords.length < 2)
            return [];
        const candidates = [...this.fts(keywords.slice(0, 12).join(' '), Math.max(40, limit * 6), opts),
            ...await this.semantic(query, Math.max(40, limit * 6), opts)];
        const ranked = new Map();
        for (const hit of candidates) {
            if (opts.excludeUri && hit.uri === opts.excludeUri)
                continue;
            const evidence = String(hit.title + ' ' + (hit.snippet || '')).normalize('NFKC').toLocaleLowerCase();
            const matches = keywords.filter(word => evidence.includes(word)).length;
            const coverage = matches / keywords.length;
            // Two independent signals and substantial coverage, not a fixed top-N filler.
            if (matches < 2 || coverage < 0.24)
                continue;
            const similarity = hit.reasons.includes('semantic_hash') ? hit.score / 0.82 : 0;
            const score = coverage * 0.8 + similarity * 0.2;
            const prior = ranked.get(hit.documentId);
            if (!prior || score > prior.score)
                ranked.set(hit.documentId, { ...hit, score, reasons: ['related_content', ...hit.reasons] });
        }
        return [...ranked.values()].sort((a, b) => b.score - a.score || a.title.localeCompare(b.title)).slice(0, limit);
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
        const pdfOnly = /\bpdf\b/i.test(query);
        const needle = normalizeCatalogText(locatorSubject(query).replace(/\bpdf\b/gi, ''));
        if (!needle)
            return [];
        const w = this.where(opts);
        const rows = this.db.db.prepare('SELECT d.id document_id,d.title,d.uri,d.source_type,d.document_type,d.modified_at,d.index_status,d.tags_json FROM documents d WHERE ' + w.sql).all(...w.args);
        // corrections is the existing higher-authority user-correction ledger; never duplicate aliases in derived documents.
        const aliases = new Map();
        for (const c of this.db.db.prepare("SELECT target_id,new_value FROM corrections WHERE field='search_aliases' ORDER BY rowid DESC").all()) {
            if (!aliases.has(c.target_id)) {
                try {
                    const names = JSON.parse(c.new_value);
                    aliases.set(c.target_id, Array.isArray(names) ? names : []);
                }
                catch {
                    aliases.set(c.target_id, []);
                }
            }
        }
        return rows.map(r => {
            if (pdfOnly && !String(r.uri).toLowerCase().endsWith('.pdf'))
                return null;
            const title = normalizeCatalogText(r.title);
            const path = normalizeCatalogText(r.uri);
            const known = (aliases.get(r.document_id) || []).map(normalizeCatalogText);
            const tagNames = JSON.parse(r.tags_json || '[]').map(normalizeCatalogText);
            const exactAlias = known.some(x => x === needle);
            const titleExact = title === needle || title.replace(/pdf$/, '') === needle;
            const titleContains = title.includes(needle);
            const aliasContains = known.some(x => x.includes(needle));
            const pathContains = path.includes(needle);
            const tagContains = tagNames.some(x => x.includes(needle));
            if (!(exactAlias || titleExact || titleContains || aliasContains || pathContains || tagContains))
                return null;
            const score = exactAlias ? 1.0 : titleExact ? 0.99 : titleContains ? 0.96 : aliasContains ? 0.95 : pathContains ? 0.88 : 0.72;
            return { documentId: r.document_id, title: r.title, uri: r.uri, sourceType: r.source_type, documentType: r.document_type, modifiedAt: r.modified_at, indexStatus: r.index_status,
                snippet: r.index_status === 'deferred' ? 'Cloud placeholder: filename/path known; PDF text not locally accessible.' :
                    r.index_status === 'metadata_only' ? 'PDF metadata only: no extractable native text.' : r.uri,
                score, reasons: [exactAlias || aliasContains ? 'verified_alias' : r.index_status === 'deferred' ? 'metadata_deferred' : 'metadata'] };
        }).filter(Boolean).sort((a, b) => b.score - a.score || String(a.title).localeCompare(String(b.title))).slice(0, limit);
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
        const key = JSON.stringify([this.embeddings.id, w.sql, w.args]);
        // total_changes covers same-connection indexing/mutations; data_version
        // covers commits from other SQLite connections. Neither changes the index.
        const localRevision = this.db.db.prepare('SELECT total_changes() n').get().n;
        const externalRevision = this.db.db.prepare('PRAGMA data_version').get().data_version;
        const revision = localRevision + ':' + externalRevision;
        let candidates = this.semanticCache?.key === key && this.semanticCache.revision === revision
            ? this.semanticCache.rows : null;
        if (!candidates) {
            const rows = this.db.db.prepare(`SELECT d.id document_id,c.id chunk_id,d.title,d.uri,d.source_type,d.document_type,d.modified_at,c.text,c.page,c.heading_path,c.embedding_json FROM chunks c JOIN documents d ON d.id=c.document_id WHERE c.embedding_json IS NOT NULL AND c.embedding_provider=? AND ${w.sql} ORDER BY d.modified_at DESC LIMIT 5000`).all(this.embeddings.id, ...w.args);
            let vectorBytes = 0;
            candidates = rows.map(r => {
                let parsed;
                try {
                    parsed = JSON.parse(r.embedding_json);
                }
                catch {
                    parsed = [];
                }
                const vector = Float32Array.from(Array.isArray(parsed) ? parsed : []);
                vectorBytes += vector.byteLength;
                const norm = Math.sqrt(vector.reduce((sum, value) => sum + value * value, 0)) || 1;
                const { embedding_json, ...data } = r;
                return { r: data, vector, norm };
            });
            // No persistent vector store or unbounded memoization: one view at a
            // time, with a fixed memory budget. Large remote vectors stay uncached.
            this.semanticCache = vectorBytes <= 12 * 1024 * 1024
                ? { key, revision, rows: candidates } : null;
        }
        const qNorm = Math.sqrt(q.reduce((sum, value) => sum + value * value, 0)) || 1;
        return candidates.map(({ r, vector, norm }) => {
            const n = Math.min(q.length, vector.length);
            let dot = 0;
            for (let i = 0; i < n; i++)
                dot += q[i] * vector[i];
            return { r, s: dot / (qNorm * norm) };
        }).filter(x => x.s > 0.12).sort((a, b) => b.s - a.s).slice(0, limit).map(x => ({
            documentId: x.r.document_id, chunkId: x.r.chunk_id, title: x.r.title, uri: x.r.uri,
            sourceType: x.r.source_type, documentType: x.r.document_type, modifiedAt: x.r.modified_at,
            snippet: snippet(x.r.text, query), score: x.s * 0.82, reasons: ['semantic_hash'],
            page: x.r.page ?? undefined, headingPath: x.r.heading_path ?? undefined
        }));
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
// Use concrete language-bearing terms, never generic UI vocabulary, to confirm
// related-note evidence. Chinese bigrams retain overlap without relying on FTS's
// word segmentation; this is a derived ranking rule, not another search index.
function relatedKeywords(query) {
    const ignore = new Set(['notes', 'note', 'markdown', 'about', 'with', 'from', 'this', 'that', 'your', 'the', 'and', 'for', 'are', 'was', 'into', 'page', '笔记', '内容', '相关', '关于', '我们', '这个', '以及']);
    const words = query.normalize('NFKC').toLocaleLowerCase().match(/[\p{L}\p{N}]+/gu) || [];
    const result = [];
    const seen = new Set();
    const add = (word) => { if (!ignore.has(word) && !seen.has(word)) {
        seen.add(word);
        result.push(word);
    } };
    for (const word of words) {
        if (/[\p{Script=Han}]/u.test(word)) {
            const chars = Array.from(word);
            for (let i = 0; i + 1 < chars.length; i++)
                add(chars[i] + chars[i + 1]);
        }
        else if (word.length >= 4) {
            add(word);
        }
        if (result.length >= 24)
            break;
    }
    return result.slice(0, 24);
}
// Recency/ordering words alone do not imply a health-structured query.
// Only route to the structured catalog for observation types it can answer.
function looksStructured(q) { return /(肌酐|胱抑素|cystatin|creatinine|他克莫司|tacrolimus)/i.test(q); }
function snippet(text, q) { const terms = q.toLowerCase().split(/\s+/).filter(Boolean); let pos = -1; for (const t of terms) {
    pos = text.toLowerCase().indexOf(t);
    if (pos >= 0)
        break;
} if (pos < 0)
    pos = 0; return text.slice(Math.max(0, pos - 100), Math.min(text.length, pos + 320)).replace(/\s+/g, ' ').trim(); }
/** File location questions require verified names/aliases and must not use fuzzy hash vectors. */
function isLocatorQuery(q) { return /(?:在哪里|在哪儿|在哪|放在哪里|路径|位置|查找|找到|找一下|文件|资料|电子书|pdf|where\s+(?:is|are)|locate|find\s+(?:my|the|a)|.{2,12}小绿书)/i.test(q) || /^[\p{L}\p{N}]{2,12}书$/u.test(q.trim()); }
function locatorSubject(q) {
    const cleaned = q.replace(/(?:请帮我|帮我|我的|在哪里|在哪儿|在哪|存放在|找到|查找|找一下|找找|找|位置|路径|相关的|相关|资料|文件|电子书|有没有|where\s+(?:is|are)|locate|find\s+(?:my|the|a))/gi, ' ').trim();
    return cleaned || q.trim();
}
function normalizeCatalogText(s) { return String(s || '').normalize('NFKC').toLocaleLowerCase().replace(/[^\p{L}\p{N}]+/gu, ''); }
