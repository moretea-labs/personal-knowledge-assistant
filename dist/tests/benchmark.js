// @ts-nocheck
import { rm, mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { performance } from 'node:perf_hooks';
import { PKSService } from '../src/core/service.js';
const root = '/mnt/data/pks-bench';
await rm(root, { recursive: true, force: true });
await mkdir(join(root, 'docs'), { recursive: true });
for (let i = 0; i < 1000; i++) {
    const topic = i % 20 === 0 ? 'Kafka eventId 消费日志 troubleshooting' : 'project architecture notes';
    await writeFile(join(root, 'docs', `note-${i}.md`), `# Note ${i}\n${topic}\nThis is personal knowledge document number ${i}. ${'context '.repeat(30)}`);
}
const cfg = { dataDir: join(root, 'data'), managedStore: join(root, 'managed'), port: 0, host: '127.0.0.1', sourceRoots: [{ id: 'docs', type: 'local', name: 'Docs', root: join(root, 'docs') }, { id: 'managed', type: 'managed', name: 'Managed', root: join(root, 'managed') }], semantic: { provider: 'hash', dimensions: 128 } };
const svc = await new PKSService(cfg).open();
let t = performance.now();
const first = await svc.sync();
const firstMs = performance.now() - t;
t = performance.now();
const second = await svc.sync();
const secondMs = performance.now() - t;
t = performance.now();
const exact = await svc.search('eventId');
const exactMs = performance.now() - t;
t = performance.now();
const semantic = await svc.search('Kafka消费不到消息');
const semanticMs = performance.now() - t;
console.log(JSON.stringify({ first, firstMs: Math.round(firstMs), second, secondMs: Math.round(secondMs), exactMs: Number(exactMs.toFixed(2)), semanticMs: Number(semanticMs.toFixed(2)), exactTop: exact[0]?.title, semanticTop: semantic[0]?.title }, null, 2));
svc.db.close();
