export function extractEntities(text) { const out = []; const seen = new Set(); for (const m of text.matchAll(/\[\[([^\]|#]+)(?:#[^\]|]+)?(?:\|[^\]]+)?\]\]/g)) {
    push('DocumentReference', m[1].trim(), 'links_to', m[0], 1);
} for (const m of text.matchAll(/(^|\s)#([\p{L}\p{N}_/-]{2,80})/gu)) {
    push('Topic', m[2], 'tagged_with', m[0].trim(), 0.98);
} return out; function push(type, name, relation, anchor, confidence) { const k = `${type}|${name.toLowerCase()}|${relation}`; if (name && !seen.has(k)) {
    seen.add(k);
    out.push({ type, name, relation, anchor, confidence });
} } }
