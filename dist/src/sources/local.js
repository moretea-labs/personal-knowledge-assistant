// @ts-nocheck
import { readdir, stat } from 'node:fs/promises';
import { extname, join, resolve } from 'node:path';
import { supportedExtensions } from '../parsers/index.js';
const ignored = new Set(['.git', 'node_modules', '.Trash', '.cache', 'Library']);
export async function* walk(root, excludeRoots = []) {
    let ents;
    try {
        ents = await readdir(root, { withFileTypes: true });
    }
    catch {
        return;
    }
    const normalizedExcludes = excludeRoots.map(x => resolve(x));
    for (const e of ents) {
        // Source indexes user documents, not app/config metadata. Explicit source excludes cover sensitive non-hidden folders.
        if (ignored.has(e.name) || e.name.startsWith('.') || e.name.startsWith('.pks-'))
            continue;
        const p = join(root, e.name);
        const abs = resolve(p);
        if (normalizedExcludes.some(x => abs === x || abs.startsWith(x + '/')))
            continue;
        if (e.isSymbolicLink())
            continue;
        if (e.isDirectory()) {
            yield* walk(p, normalizedExcludes);
        }
        else if (e.isFile() && supportedExtensions.has(extname(e.name).toLowerCase())) {
            try {
                const s = await stat(p);
                yield { path: p, size: s.size, modifiedAt: s.mtime.toISOString(), createdAt: s.birthtime.toISOString() };
            }
            catch {
                // A directory scan should continue even if one entry disappears or becomes unavailable.
            }
        }
    }
}
