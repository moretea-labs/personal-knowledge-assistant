// @ts-nocheck
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { PKSService } from '../src/core/service.js';
import { supportedExtensions } from '../src/parsers/index.js';
test('PKS indexes and searches Leafspan .markdown notes in its canonical FTS index', async () => {
    const root = await mkdtemp(join(tmpdir(), 'pks-markdown-alias-'));
    const docs = join(root, 'docs');
    const managed = join(root, 'managed');
    await mkdir(docs, { recursive: true });
    await mkdir(managed, { recursive: true });
    const note = join(docs, 'markdown-alias.markdown');
    await writeFile(note, '# Unified search\nThis unique phrase exists only inside the Markdown alias file.\n');
    const config = {
        dataDir: join(root, 'data'),
        managedStore: managed,
        port: 0,
        host: '127.0.0.1',
        sourceRoots: [{ id: 'docs', type: 'local', name: 'Docs', root: docs }],
        semantic: { provider: 'hash', dimensions: 64 }
    };
    const service = await new PKSService(config).open();
    try {
        assert.ok(supportedExtensions.has('.markdown'));
        await service.sync();
        const results = await service.search('unique phrase', { mode: 'fts', limit: 10 });
        assert.ok(results.some(result => result.uri === note));
        const document = service.db.db.prepare('SELECT index_status FROM documents WHERE uri=?').get(note);
        assert.equal(document?.index_status, 'indexed');
        const chunkCount = service.db.db.prepare('SELECT COUNT(*) n FROM chunks WHERE document_id=(SELECT id FROM documents WHERE uri=?)').get(note);
        assert.ok(Number(chunkCount?.n) > 0);
    }
    finally {
        service.db.close();
        await rm(root, { recursive: true, force: true });
    }
});
