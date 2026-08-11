function tokens(text) { const lower = text.toLowerCase(); const seg = new Intl.Segmenter(undefined, { granularity: 'word' }); const words = [...seg.segment(lower)].filter(x => x.isWordLike).map(x => x.segment); const chars = [...lower.replace(/\s+/g, '')]; const grams = []; for (let i = 0; i < chars.length - 1 && grams.length < 1200; i++)
    grams.push(chars[i] + chars[i + 1]); return [...words.slice(0, 800), ...grams]; }
function hash(s) { let h = 2166136261; for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619);
} return h >>> 0; }
export class HashEmbeddingProvider {
    dimensions;
    id;
    constructor(dimensions = 256) {
        this.dimensions = dimensions;
        this.id = `hash-ngram-v1-${dimensions}`;
    }
    async embed(text) { const v = Array(this.dimensions).fill(0); for (const t of tokens(text)) {
        const h = hash(t), idx = h % this.dimensions;
        v[idx] += ((h >>> 8) & 1) ? 1 : -1;
    } const n = Math.sqrt(v.reduce((s, x) => s + x * x, 0)) || 1; return v.map(x => x / n); }
}
export class RemoteEmbeddingProvider {
    endpoint;
    model;
    dimensions;
    apiKey;
    id;
    constructor(endpoint, model, dimensions, apiKey) {
        this.endpoint = endpoint;
        this.model = model;
        this.dimensions = dimensions;
        this.apiKey = apiKey;
        this.id = `remote:${model}:${dimensions}`;
    }
    async embed(text) { const url = this.endpoint.replace(/\/$/, '') + (this.endpoint.endsWith('/embeddings') ? '' : '/embeddings'); const r = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json', ...(this.apiKey ? { authorization: `Bearer ${this.apiKey}` } : {}) }, body: JSON.stringify({ model: this.model, input: text, dimensions: this.dimensions }) }); if (!r.ok)
        throw new Error(`Embedding provider ${r.status}: ${await r.text()}`); const j = await r.json(); const v = j.data?.[0]?.embedding || j.embedding; if (!Array.isArray(v))
        throw new Error('Embedding provider returned no vector'); this.dimensions = v.length; this.id = `remote:${this.model}:${v.length}`; return v.map(Number); }
}
export function cosine(a, b) { let s = 0, aa = 0, bb = 0; const n = Math.min(a.length, b.length); for (let i = 0; i < n; i++) {
    s += a[i] * b[i];
    aa += a[i] * a[i];
    bb += b[i] * b[i];
} return s / ((Math.sqrt(aa) * Math.sqrt(bb)) || 1); }
