// @ts-nocheck
import { createHash } from 'node:crypto';
import { mkdir, readFile, stat, writeFile, rename, rm } from 'node:fs/promises';
import { dirname, resolve, relative, isAbsolute, sep } from 'node:path';
export async function ensureDir(path) { await mkdir(path, { recursive: true }); }
export async function sha256File(path) {
    const buf = await readFile(path);
    return createHash('sha256').update(buf).digest('hex');
}
export function sha256Text(text) { return createHash('sha256').update(text).digest('hex'); }
export function safeInside(root, candidate) {
    const absRoot = resolve(root);
    const abs = resolve(candidate);
    const rel = relative(absRoot, abs);
    return rel === '' || (!rel.startsWith(`..${sep}`) && rel !== '..' && !isAbsolute(rel));
}
export async function atomicWrite(path, content) {
    await ensureDir(dirname(path));
    const tmp = `${path}.pks-tmp-${process.pid}-${Date.now()}`;
    await writeFile(tmp, content, 'utf8');
    await rename(tmp, path);
}
export async function fileExists(path) { try {
    await stat(path);
    return true;
}
catch {
    return false;
} }
export async function removeIfExists(path) { if (await fileExists(path))
    await rm(path, { force: true }); }
