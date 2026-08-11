// @ts-nocheck
export function parseFrontmatter(text) { if (!text.startsWith('---'))
    return {}; const end = text.indexOf('\n---', 3); if (end < 0)
    return {}; const obj = {}; for (const line of text.slice(3, end).split(/\r?\n/)) {
    const i = line.indexOf(':');
    if (i > 0)
        obj[line.slice(0, i).trim()] = line.slice(i + 1).trim().replace(/^['"]|['"]$/g, '');
} return obj; }
