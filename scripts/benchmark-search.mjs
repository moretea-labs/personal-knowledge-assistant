/**
 * Read-only PKS query benchmark. No source scans, imports, backups or writes.
 * Usage: PKS_BENCH_DB=/absolute/path/to/knowledge.db npm run benchmark:search
 */
import { DatabaseSync } from 'node:sqlite';
import { performance } from 'node:perf_hooks';
import { SearchEngine } from '../dist/src/core/search.js';
import { HashEmbeddingProvider } from '../dist/src/core/embedding.js';

const file = process.env.PKS_BENCH_DB;
if (!file || !file.startsWith('/')) {
  console.error('Set PKS_BENCH_DB to the absolute path of your existing knowledge.db');
  process.exitCode = 2;
} else {
  const db = new DatabaseSync(file, { readOnly: true });
  try {
    const provider = db.prepare(
      "SELECT embedding_provider id,COUNT(*) n FROM chunks WHERE embedding_provider LIKE 'hash-ngram-v1-%' GROUP BY embedding_provider ORDER BY n DESC LIMIT 1"
    ).get();
    if (!provider) throw new Error('No locally indexed hash embeddings for this benchmark');
    const dimensions = Number(provider.id.split('-').at(-1));
    const engine = new SearchEngine({ db }, new HashEmbeddingProvider(dimensions));
    const rows = [];
    for (const [query, mode] of [
      ['Markdown', 'auto'],
      ['Kafka', 'auto'],
      ['英语学习', 'auto'],
      ['和弦切换', 'auto'],
      ['和弦切换', 'semantic'],
      ['我的英语学习相关PDF在哪里', 'auto']
    ]) {
      const elapsed = [];
      let count = 0;
      for (let i = 0; i < 5; i++) {
        const begin = performance.now();
        const hits = await engine.search(query, { mode, limit: 12 });
        elapsed.push(Number((performance.now() - begin).toFixed(1)));
        count = hits.length;
      }
      const warm = elapsed.slice(1).sort((a, b) => a - b);
      rows.push({
        query, mode, results: count, firstMs: elapsed[0],
        warmMedianMs: Number(((warm[1] + warm[2]) / 2).toFixed(1))
      });
    }
    console.table(rows);
    console.log('This benchmark measures retrieval latency only; it prints no file contents or paths.');
  } finally {
    db.close();
  }
}
