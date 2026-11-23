// @ts-nocheck
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { PKSService } from '../src/core/service.js';
import type { PKSConfig } from '../src/types.js';

const corpus = JSON.parse(await readFile(new URL('./fixtures/search-golden-v1.json', import.meta.url), 'utf8'));

test('PKS search contract golden corpus v1', async () => {
  assert.equal(corpus.schemaVersion, 1);
  assert.equal(corpus.contract, 'pks.search.golden.v1');
  const root = await mkdtemp(join(tmpdir(), 'pks-golden-'));
  const docs = join(root, 'docs');
  const managed = join(root, 'managed');
  await mkdir(docs, { recursive: true });
  await mkdir(managed, { recursive: true });
  const cfg: PKSConfig = {
    dataDir: join(root, 'data'), managedStore: managed, port: 0, host: '127.0.0.1',
    sourceRoots: [
      { id: 'docs', type: 'local', name: 'Docs', root: docs },
      { id: 'managed', type: 'managed', name: 'Managed', root: managed }
    ],
    semantic: { provider: 'hash', dimensions: 128 }
  };
  const service = await new PKSService(cfg).open();
  try {
    for (const doc of corpus.documents) {
      await writeFile(join(doc.source === 'managed' ? managed : docs, doc.file), doc.content, 'utf8');
    }
    await service.sync();
    for (const scenario of corpus.queries) {
      const results = await service.search(scenario.query, {
        mode: scenario.mode, source: scenario.source,
        excludeUri: scenario.excludeFile ? join(docs, scenario.excludeFile) : undefined,
        limit: 20
      });
      const files = results.map(result => result.uri.split('/').pop());
      if (scenario.expectedFiles) assert.deepEqual(files, scenario.expectedFiles, `golden case: ${scenario.id}`);
      if (scenario.expectedPrefixFiles) assert.deepEqual(files.slice(0, scenario.expectedPrefixFiles.length),
        scenario.expectedPrefixFiles, `golden ranking prefix: ${scenario.id}`);
      for (const reason of scenario.requiredReasons) {
        assert.ok(results.some(result => result.reasons.includes(reason)),
          `golden case ${scenario.id} must preserve reason ${reason}`);
      }
    }
  } finally { service.db.close(); }
});
