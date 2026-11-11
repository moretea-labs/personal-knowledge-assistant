export class MemoryBuilder {
    db;
    constructor(db) {
        this.db = db;
    }
    build(domain) {
        let profile = { domain }, evidence = [];
        if (domain === 'health') {
            const rows = this.db.db.prepare(`SELECT observation_type,COUNT(*) n,MIN(value) min,MAX(value) max,AVG(value) avg,MAX(observed_at) latest_date FROM medical_observations m JOIN documents d ON d.id=m.source_document_id WHERE d.deleted_at IS NULL GROUP BY m.observation_type`).all();
            profile.observations = rows;
            evidence = rows.map(x => ({ type: x.observation_type, count: x.n }));
        }
        else if (domain === 'movies' || domain === 'books') {
            const rows = this.db.db.prepare('SELECT sr.entity_key,sr.data_json,sr.observed_at,sr.source_document_id FROM structured_records sr LEFT JOIN documents d ON d.id=sr.source_document_id WHERE sr.domain=? AND (sr.source_document_id IS NULL OR (d.id IS NOT NULL AND d.deleted_at IS NULL)) ORDER BY sr.observed_at DESC').all(domain);
            const parsed = rows.map(r => ({ ...r, data: JSON.parse(r.data_json) }));
            const ratings = parsed.map(x => Number(x.data.rating)).filter(Number.isFinite);
            const genres = new Map();
            for (const x of parsed)
                for (const g of (x.data.genres || []))
                    genres.set(g, (genres.get(g) || 0) + 1);
            profile = { domain, count: parsed.length, averageRating: ratings.length ? ratings.reduce((a, b) => a + b, 0) / ratings.length : null, topGenres: [...genres.entries()].sort((a, b) => b[1] - a[1]).slice(0, 10), recent: parsed.slice(0, 10).map(x => ({ title: x.entity_key, rating: x.data.rating, date: x.observed_at })) };
            evidence = parsed.slice(0, 20).map(x => ({ documentId: x.source_document_id, title: x.entity_key }));
        }
        else {
            const n = this.db.db.prepare('SELECT COUNT(*) n FROM documents WHERE deleted_at IS NULL').get().n;
            profile = { domain: 'general', documents: n };
        }
        const now = new Date().toISOString();
        this.db.db.prepare(`INSERT INTO memory_profiles(domain,profile_json,evidence_json,generated_at) VALUES(?,?,?,?) ON CONFLICT(domain) DO UPDATE SET profile_json=excluded.profile_json,evidence_json=excluded.evidence_json,generated_at=excluded.generated_at`).run(domain, JSON.stringify(profile), JSON.stringify(evidence), now);
        return { profile, evidence, generatedAt: now };
    }
    get(domain) { const r = this.db.db.prepare('SELECT * FROM memory_profiles WHERE domain=?').get(domain); return r ? { profile: JSON.parse(r.profile_json), evidence: JSON.parse(r.evidence_json), generatedAt: r.generated_at } : this.build(domain); }
}
