// @ts-nocheck
import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { makeHandler } from '../src/api/router.js';

test('PKS HTTP surface is API-only and keeps Leafspan search available', async () => {
  const service = {
    status: () => ({ documents: 2, chunks: 5 }),
    search: async query => [{ title: 'Leafspan result', query }]
  };
  const server = createServer(makeHandler(service));
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  const baseURL = `http://127.0.0.1:${address.port}`;

  try {
    const root = await fetch(baseURL);
    assert.equal(root.status, 404);
    assert.deepEqual(await root.json(), { error: 'not_found' });

    const status = await fetch(`${baseURL}/api/status`);
    assert.equal(status.status, 200);
    assert.deepEqual(await status.json(), { documents: 2, chunks: 5 });

    const search = await fetch(`${baseURL}/api/search?q=needle`);
    assert.equal(search.status, 200);
    assert.deepEqual(await search.json(), [{ title: 'Leafspan result', query: 'needle' }]);
  } finally {
    await new Promise((resolve, reject) => {
      server.close(error => error ? reject(error) : resolve());
    });
  }
});
