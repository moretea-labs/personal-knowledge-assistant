// Synthetic, self-cleaning filename-search benchmark; never reads user files.
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { performance } from 'node:perf_hooks';
import { KnowledgeDB } from '../dist/src/db/database.js';
import { SearchEngine } from '../dist/src/core/search.js';
import { HashEmbeddingProvider } from '../dist/src/core/embedding.js';

const directory = await mkdtemp(join(tmpdir(), 'pks-metadata-bench-'));
const db = await new KnowledgeDB(directory).open();
try {
  const now = '2026-11-12T00:00:00Z';
  db.db.prepare('INSERT INTO sources(id,type,name,root_uri,created_at,updated_at) VALUES(?,?,?,?,?,?)')
    .run('files', 'local', 'Files', '/synthetic', now, now);
  const insert = db.db.prepare(
    'INSERT INTO documents(id,source_id,source_type,uri,canonical_uri,title,created_at,modified_at,size,index_status,tags_json) VALUES(?,?,?,?,?,?,?,?,?,?,?)'
  );
  db.db.exec('BEGIN');
  for (let index = 0; index < 20000; index++) {
    const title = index % 127 === 0
      ? '预算清单-project-' + index + '.md'
      : 'notes-project-' + index + '.md';
    const path = '/synthetic/2026/project-' + (index % 29) + '/' + title;
    insert.run('doc' + index, 'files', 'local', path, path, title, now, now,
      300, 'metadata_only', index % 31 === 0 ? '["学习资料"]' : '[]');
  }
  db.db.exec('COMMIT');

  const engine = new SearchEngine(db, new HashEmbeddingProvider(256));
  const summary = [];
  for (const query of ['notes', '预算', '学习资料', 'notes-project-19999']) {
    const samples = [];
    let hits = 0;
    for (let index = 0; index < 36; index++) {
      const start = performance.now();
      const result = await engine.search(query, { mode: 'metadata', limit: 20 });
      if (index >= 6) samples.push(performance.now() - start);
      hits = result.length;
    }
    samples.sort((a, b) => a - b);
    summary.push({
      query, hits, p50Ms: Number(samples[14].toFixed(2)),
      p95Ms: Number(samples[28].toFixed(2))
    });
  }
  console.log(JSON.stringify({
    node: process.version, documents: 20000, mode: 'metadata',
    warmupQueries: 6, measuredQueries: 30, results: summary
  }, null, 2));
} finally {
  db.close();
  await rm(directory, { recursive: true, force: true });
}
