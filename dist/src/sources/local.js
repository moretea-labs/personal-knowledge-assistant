// @ts-nocheck
import { readdir, stat } from 'node:fs/promises';
import { join, resolve } from 'node:path';
const ignored = new Set(['.git', 'node_modules', '.Trash', '.cache', 'Library']);
export async function* walk(root, excludeRoots = [], onScanError) {
    let ents;
    try {
        ents = await readdir(root, { withFileTypes: true });
    }
    catch (error) {
        onScanError?.(root, error);
        return;
    }
    const normalizedExcludes = excludeRoots.map(x => resolve(x));
    for (const e of ents) {
        // Catalog opted-in filenames; only supported formats are read for full-text indexing.
        if (ignored.has(e.name) || e.name.startsWith('.') || e.name.startsWith('.pks-'))
            continue;
        const p = join(root, e.name);
        const abs = resolve(p);
        if (normalizedExcludes.some(x => abs === x || abs.startsWith(x + '/')))
            continue;
        if (e.isSymbolicLink())
            continue;
        if (e.isDirectory()) {
            yield* walk(p, normalizedExcludes, onScanError);
        }
        else if (e.isFile()) {
            try {
                const s = await stat(p);
                yield { path: p, size: s.size, modifiedAt: s.mtime.toISOString(), createdAt: s.birthtime.toISOString() };
            }
            catch (error) {
                // A vanishing file is a normal deletion. An unreadable one makes
                // the scan incomplete and must not authorize catalog-wide pruning.
                if (error.code !== 'ENOENT')
                    onScanError?.(p, error);
            }
        }
    }
}
