export class SearchEngine {
    db;
    embeddings;
    // Derived, bounded in-process search acceleration only. SQLite remains canonical;
    // a write by this connection or another connection invalidates the snapshot.
    semanticCache = null;
    // One rebuildable, bounded catalog projection; SQLite + corrections remain
    // authoritative. Invalidate on local writes and other-connection commits.
    catalogCache = null;
    constructor(db, embeddings) {
        this.db = db;
        this.embeddings = embeddings;
    }
    async search(query, opts = {}) {
        const limit = Math.min(Math.max(opts.limit || 12, 1), 50);
        if (opts.mode === 'related')
            return this.related(query, limit, opts);
        if (opts.mode === 'metadata')
            return this.metadata(query, limit, opts);
        if (opts.mode === 'fts')
            return this.fts(query, limit, opts);
        if (opts.mode === 'semantic')
            return this.semantic(query, limit, opts);
        if (opts.mode === 'structured' || looksStructured(query))
            return this.structured(query, limit);
        const metadata = this.metadata(query, Math.max(limit * 2, 20), opts);
        // Locating a file is a catalog lookup, never an approximate content search.
        if ((opts.mode === undefined || opts.mode === 'auto') && isLocatorQuery(query))
            return metadata.slice(0, limit);
        const fts = this.fts(query, Math.max(limit * 3, 20), opts);
        if ((opts.mode === undefined || opts.mode === 'auto') && fts.length >= limit && metadata.length === 0)
            return fts.slice(0, limit);
        // Auto is deterministic catalog + full-text search. Hash-ngram similarity
        // remains explicit (mode=semantic) or evidence-gated (mode=related).
        const map = new Map();
        for (const r of fts) {
            const k = r.chunkId || r.documentId;
            const old = map.get(k);
            if (!old)
                map.set(k, r);
            else {
                old.score = Math.max(old.score, r.score);
                old.reasons = [...new Set([...old.reasons, ...r.reasons])];
                if (!old.snippet && r.snippet)
                    old.snippet = r.snippet;
            }
        }
        const firstChunkByDocument = new Map();
        for (const r of fts) {
            if (r.chunkId && !firstChunkByDocument.has(r.documentId)) {
                firstChunkByDocument.set(r.documentId, r.chunkId);
            }
        }
        for (const r of metadata) {
            const key = firstChunkByDocument.get(r.documentId);
            const direct = r.reasons.includes('verified_alias') || r.score >= 0.88;
            if (key && direct) {
                const old = map.get(key);
                map.set(key, {
                    ...old,
                    score: Math.max(old.score, r.score),
                    reasons: [...new Set([...r.reasons, ...old.reasons])]
                });
            }
            else if (!key) {
                map.set(`document:${r.documentId}`, r);
            }
        }
        const evidenceRank = (r) => {
            const direct = r.reasons.includes('verified_alias')
                || ((r.reasons.includes('metadata') || r.reasons.includes('metadata_deferred')) && r.score >= 0.88);
            if (direct)
                return 0;
            if (r.reasons.includes('full_text') || r.reasons.includes('literal_substring'))
                return 1;
            return 2;
        };
        return [...map.values()].sort((a, b) => {
            const evidence = evidenceRank(a) - evidenceRank(b);
            return evidence || b.score - a.score;
        }).slice(0, limit);
    }
    /** Related notes require multiple concrete content signals. Hash-vector proximity
     * alone (or one shared filename word) is not evidence of a relationship. */
    async related(query, limit, opts) {
        const keywords = relatedKeywords(query);
        const evidenceTerms = relatedEvidenceTerms(query);
        if (keywords.length < 2 || evidenceTerms.length < 2)
            return [];
        const candidates = [...this.fts(keywords.slice(0, 12).join(' '), Math.max(40, limit * 6), opts),
            ...await this.semantic(query, Math.max(40, limit * 6), opts)];
        const ranked = new Map();
        for (const hit of candidates) {
            if (opts.excludeUri && hit.uri === opts.excludeUri)
                continue;
            const evidence = String(hit.snippet || '').normalize('NFKC').toLocaleLowerCase();
            const matches = evidenceTerms.filter(word => evidence.includes(word)).length;
            const coverage = matches / evidenceTerms.length;
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
    catalogRows(w) {
        const key = JSON.stringify([w.sql, w.args]);
        const localRevision = this.db.db.prepare('SELECT total_changes() n').get().n;
        const externalRevision = this.db.db.prepare('PRAGMA data_version').get().data_version;
        const revision = localRevision + ':' + externalRevision;
        if (this.catalogCache?.key === key && this.catalogCache.revision === revision)
            return this.catalogCache.rows;
        // Read the authoritative alias ledger once per catalog revision.
        const aliases = new Map();
        for (const c of this.db.db.prepare("SELECT target_id,new_value FROM corrections WHERE field='search_aliases' ORDER BY rowid DESC").all()) {
            if (aliases.has(c.target_id))
                continue;
            try {
                const names = JSON.parse(c.new_value);
                aliases.set(c.target_id, Array.isArray(names) ? names.map(normalizeCatalogText) : []);
            }
            catch {
                aliases.set(c.target_id, []);
            }
        }
        const raw = this.db.db.prepare('SELECT d.id document_id,d.title,d.uri,d.source_type,d.document_type,d.modified_at,d.index_status,d.tags_json FROM documents d WHERE ' + w.sql).all(...w.args);
        let approxBytes = 0;
        const rows = raw.map(r => {
            const titleKey = normalizeCatalogText(r.title);
            const pathKey = normalizeCatalogText(r.uri);
            const names = aliases.get(r.document_id) || [];
            let tags = [];
            try {
                const parsed = JSON.parse(r.tags_json || '[]');
                tags = Array.isArray(parsed) ? parsed.map(normalizeCatalogText) : [];
            }
            catch { }
            approxBytes += 320 + 2 * (String(r.uri).length + String(r.title).length + names.join('').length + tags.join('').length);
            return { ...r, titleKey, pathKey, aliases: names, tags };
        });
        // Cache only one view and never retain an unbounded second catalog.
        this.catalogCache = approxBytes <= 32 * 1024 * 1024 ? { key, revision, rows } : null;
        return rows;
    }
    metadata(query, limit, opts) {
        const pdfOnly = /\bpdf\b/i.test(query);
        const needle = normalizeCatalogText(locatorSubject(query).replace(/\bpdf\b/gi, ''));
        if (!needle)
            return [];
        const rows = this.catalogRows(this.where(opts));
        const best = [];
        const compare = (a, b) => b.score - a.score || String(a.title).localeCompare(String(b.title));
        for (const r of rows) {
            if (pdfOnly && !String(r.uri).toLowerCase().endsWith('.pdf'))
                continue;
            const exactAlias = r.aliases.some((x) => x === needle);
            const titleExact = r.titleKey === needle || r.titleKey.replace(/pdf$/, '') === needle;
            const titlePrefix = r.titleKey.startsWith(needle);
            const titleContains = r.titleKey.includes(needle);
            const aliasContains = r.aliases.some((x) => x.includes(needle));
            const pathContains = r.pathKey.includes(needle);
            const tagContains = r.tags.some((x) => x.includes(needle));
            if (!(exactAlias || titleExact || titleContains || aliasContains || pathContains || tagContains))
                continue;
            // Prefer exact/prefix titles, but preserve verified aliases and paths.
            const score = exactAlias ? 1.0 : titleExact ? 0.99 : titlePrefix ? 0.975 : titleContains ? 0.96 : aliasContains ? 0.95 : pathContains ? 0.88 : 0.72;
            if (best.length >= limit) {
                const worst = best[best.length - 1];
                if (score < worst.score || (score === worst.score && String(r.title).localeCompare(String(worst.title)) >= 0))
                    continue;
            }
            const result = {
                documentId: r.document_id, title: r.title, uri: r.uri, sourceType: r.source_type,
                documentType: r.document_type, modifiedAt: r.modified_at, indexStatus: r.index_status,
                snippet: r.index_status === 'deferred' ? 'Cloud placeholder: filename/path known; PDF text not locally accessible.' :
                    r.index_status === 'metadata_only' ? (String(r.uri).toLowerCase().endsWith('.pdf') ? 'PDF metadata only: no extractable native text.' : 'File name only: content is not indexed.') : r.uri,
                score, reasons: [exactAlias || aliasContains ? 'verified_alias' : r.index_status === 'deferred' ? 'metadata_deferred' : 'metadata']
            };
            // Keep only the best K matches rather than sorting the entire catalog.
            let lo = 0, hi = best.length;
            while (lo < hi) {
                const mid = (lo + hi) >> 1;
                if (compare(result, best[mid]) < 0)
                    hi = mid;
                else
                    lo = mid + 1;
            }
            if (lo < limit) {
                best.splice(lo, 0, result);
                if (best.length > limit)
                    best.pop();
            }
        }
        return best;
    }
    fts(query, limit, opts) {
        const w = this.where(opts);
        const tokens = query.normalize('NFKC').toLocaleLowerCase().match(/\p{Script=Han}+|[\p{L}\p{N}]+/gu) || [];
        const safe = tokens.map((x) => `"${x.replace(/["']/g, '')}"`).join(' OR ');
        const coverageTerms = relatedKeywords(query);
        if (!safe || !coverageTerms.length)
            return [];
        const minimumCoverage = coverageTerms.length === 1 ? 1 : opts.mode === 'related'
            ? 2 : Math.max(2, Math.ceil(coverageTerms.length * 0.5));
        try {
            const candidateLimit = Math.min(200, Math.max(limit * 3, limit));
            const rows = this.db.db.prepare(`SELECT d.id document_id,c.id chunk_id,d.title,d.uri,d.source_type,d.document_type,d.modified_at,c.text,c.page,c.heading_path,bm25(chunks_fts) rank FROM chunks_fts JOIN chunks c ON c.id=chunks_fts.chunk_id JOIN documents d ON d.id=c.document_id WHERE chunks_fts MATCH ? AND ${w.sql} ORDER BY rank LIMIT ?`).all(safe, ...w.args, candidateLimit);
            const coverageByChunk = new Map(rows.map((r) => [r.chunk_id, String(r.text)]));
            const results = rows.map((r, i) => ({ documentId: r.document_id, chunkId: r.chunk_id, title: r.title, uri: r.uri, sourceType: r.source_type, documentType: r.document_type, modifiedAt: r.modified_at, snippet: snippet(r.text, query), score: 1 / (1 + i * 0.08), reasons: ['full_text'], page: r.page ?? undefined, headingPath: r.heading_path ?? undefined }));
            const rankResults = () => results.map((result, order) => {
                const evidence = (coverageByChunk.get(result.chunkId || '') || String(result.snippet || '')).normalize('NFKC').toLocaleLowerCase();
                const matches = coverageTerms.filter(term => evidence.includes(term)).length;
                return { result, order, matches };
            }).filter(candidate => candidate.matches >= minimumCoverage)
                .sort((a, b) => b.matches - a.matches || a.order - b.order);
            let ranked = rankResults();
            // unicode61 groups adjacent Han characters into longer tokens, so a
            // literal short Chinese substring can be absent from FTS5 results.
            // Run a bounded exact-content fallback only when needed; no extra index.
            const literal = query.trim().normalize('NFKC');
            if (ranked.length < limit && /^[\p{Script=Han}]{2,8}$/u.test(literal)) {
                const seen = new Set(rows.map(r => r.chunk_id));
                const extra = this.db.db.prepare(`SELECT d.id document_id,c.id chunk_id,d.title,d.uri,d.source_type,d.document_type,d.modified_at,c.text,c.page,c.heading_path
          FROM chunks c JOIN documents d ON d.id=c.document_id
          WHERE instr(c.text,?)>0 AND ${w.sql} ORDER BY d.modified_at DESC LIMIT ?`)
                    .all(literal, ...w.args, limit);
                for (const r of extra) {
                    if (seen.has(r.chunk_id))
                        continue;
                    seen.add(r.chunk_id);
                    coverageByChunk.set(r.chunk_id, String(r.text));
                    results.push({ documentId: r.document_id, chunkId: r.chunk_id, title: r.title, uri: r.uri,
                        sourceType: r.source_type, documentType: r.document_type, modifiedAt: r.modified_at,
                        snippet: snippet(r.text, literal), score: 0.82 / (1 + results.length * 0.08),
                        reasons: ['literal_substring'], page: r.page ?? undefined, headingPath: r.heading_path ?? undefined });
                }
            }
            ranked = rankResults();
            return ranked.slice(0, limit).map((candidate, index) => ({ ...candidate.result, score: 1 / (1 + index * 0.08) }));
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
// Use meaningful language-bearing terms for FTS candidate recall. Split Han runs
// into overlapping bigrams because SQLite unicode61 treats adjacent Han as one token;
// these bigrams are a query-time fallback, not a second index.
function relatedKeywords(query) {
    const ignore = new Set(['my', 'the', 'and', 'about', 'with', 'from', 'this', 'that', 'your', 'for', 'are', 'was', 'were', 'into', 'page', 'notes', 'note', 'markdown', 'file', 'files', 'folder', 'folders', 'document', 'documents', 'search', 'content', 'pdf', 'path', 'paths', 'location', 'where', 'find', 'locate', 'please', 'help', 'all', 'every', 'is', 'a', 'an', 'to', 'of', 'in', 'on', 'at', 'by', 'as', 'or', 'but', 'how', 'what', 'when', 'which', 'who', 'why', 'can', 'could', 'should', 'would', 'it', 'you', 'we', 'our', 'i', 'me', 'app', 'apps', 'ui', 'ux', '笔记', '内容', '相关', '关于', '我们', '这个', '以及']);
    const cleaned = query.normalize('NFKC').toLocaleLowerCase()
        .replace(/(?:请帮我|帮我|找一下|找找|找|我的|所有|全部|文件夹|文件|资料|笔记|相关|搜索|内容|文档|这个|那个|一个|在哪里|在哪儿|在哪|路径|位置|的|以及|与)/gu, ' ');
    const words = cleaned.match(/\p{Script=Han}+|[\p{L}\p{N}]+/gu) || [];
    const result = [];
    const seen = new Set();
    const add = (word) => { if (!ignore.has(word) && !seen.has(word)) {
        seen.add(word);
        result.push(word);
    } };
    for (const word of words) {
        if (/\p{Script=Han}/u.test(word)) {
            const chars = Array.from(word);
            for (let i = 0; i + 1 < chars.length; i++)
                add(chars[i] + chars[i + 1]);
        }
        else if (word.length >= 2) {
            add(word);
        }
        if (result.length >= 24)
            break;
    }
    return result.slice(0, 24);
}
// Related evidence is stricter than candidate recall: count actual word segments,
// not overlapping Han bigrams from one phrase as multiple independent signals.
function relatedEvidenceTerms(query) {
    const keywords = new Set(relatedKeywords(query));
    const segmenter = new Intl.Segmenter('zh-CN', { granularity: 'word' });
    const segments = [...segmenter.segment(query.normalize('NFKC').toLocaleLowerCase())];
    return [...new Set(segments
            .filter(part => part.isWordLike && part.segment.length >= 2)
            .map(part => part.segment)
            .filter(term => keywords.has(term)))].slice(0, 24);
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
