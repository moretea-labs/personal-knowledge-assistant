// @ts-nocheck
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { PKSService } from '../src/core/service.js';
const addonPath = process.env.PKS_NATIVE_ADDON_PATH;
test('PKSService defaults to native search and matches the explicit TypeScript diagnostic baseline', {
    skip: !addonPath
}, async () => {
    const root = await mkdtemp(join(tmpdir(), 'pks-native-service-'));
    const docs = join(root, 'docs');
    const managed = join(root, 'managed');
    await mkdir(docs, { recursive: true });
    await mkdir(managed, { recursive: true });
    await writeFile(join(docs, 'Night Piano.md'), '# Night Piano\nNight piano practice with exact content.', 'utf8');
    await writeFile(join(docs, 'Practice.md'), '# Practice\nNight piano practice for a separate note.', 'utf8');
    const config = (dataName) => ({
        dataDir: join(root, dataName),
        managedStore: managed,
        port: 0,
        host: '127.0.0.1',
        sourceRoots: [{ id: 'docs', type: 'local', name: 'Docs', root: docs }],
        semantic: { provider: 'hash', dimensions: 128 }
    });
    const previousEngine = process.env.PKS_SEARCH_ENGINE;
    process.env.PKS_SEARCH_ENGINE = 'typescript';
    const baseline = await new PKSService(config('typescript-data')).open();
    delete process.env.PKS_SEARCH_ENGINE;
    const native = await new PKSService(config('native-data')).open();
    try {
        await baseline.sync();
        await native.sync();
        assert.equal(baseline.status().searchEngine, 'typescript');
        assert.equal(native.status().searchEngine, 'native');
        const options = { mode: 'auto', limit: 10 };
        const expected = await baseline.search('night piano', options);
        const actual = await native.search('night piano', options);
        const project = (results) => results.map(result => ({
            title: result.title,
            uri: result.uri,
            sourceType: result.sourceType,
            reasons: result.reasons
        }));
        assert.deepEqual(project(actual), project(expected));
        assert.ok(actual.some(result => result.reasons.includes('metadata')));
        assert.ok(actual.some(result => result.reasons.includes('full_text')));
    }
    finally {
        baseline.stopWatching();
        native.stopWatching();
        baseline.db.close();
        native.db.close();
        if (previousEngine === undefined)
            delete process.env.PKS_SEARCH_ENGINE;
        else
            process.env.PKS_SEARCH_ENGINE = previousEngine;
    }
});
