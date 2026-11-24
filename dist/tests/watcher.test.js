/// <reference types="node" />
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { KnowledgeWatcher } from '../src/core/watcher.js';
async function fixture(t, onChange) {
    const root = await mkdtemp(join(tmpdir(), 'pks-watcher-'));
    const cfg = { sourceRoots: [{ id: 'local', name: 'Local', type: 'local', root }] };
    const watcher = new KnowledgeWatcher(cfg, onChange);
    t.after(async () => { watcher.stop(); await rm(root, { recursive: true, force: true }); });
    return { root, watcher };
}
async function until(predicate) {
    for (let attempt = 0; attempt < 100; attempt++) {
        if (predicate())
            return;
        await sleep(50);
    }
    assert.fail('watcher did not observe the filesystem change');
}
test('stop cancels a pending filesystem debounce', async (t) => {
    let calls = 0;
    const { root, watcher } = await fixture(t, async () => { calls++; });
    watcher.start();
    await writeFile(join(root, 'note.md'), 'first');
    await sleep(150);
    watcher.stop();
    await sleep(850);
    assert.equal(calls, 0, 'stopped watcher must not start a new sync');
});
test('changes during an in-flight refresh schedule exactly one follow-up', async (t) => {
    let calls = 0;
    let concurrent = 0;
    let peak = 0;
    let release;
    const first = new Promise(resolve => { release = resolve; });
    const { root, watcher } = await fixture(t, async () => {
        calls++;
        concurrent++;
        peak = Math.max(peak, concurrent);
        try {
            if (calls === 1)
                await first;
        }
        finally {
            concurrent--;
        }
    });
    t.after(() => release());
    watcher.start();
    await writeFile(join(root, 'note.md'), 'first');
    await until(() => calls === 1);
    await writeFile(join(root, 'note.md'), 'second');
    await writeFile(join(root, 'second.md'), 'third');
    await sleep(950);
    assert.equal(calls, 1, 'must not overlap a running refresh');
    release();
    await until(() => calls === 2);
    assert.equal(peak, 1);
    await sleep(850);
    assert.equal(calls, 2);
});
test('repeated start and stop/start do not retain old debounced work', async (t) => {
    let calls = 0;
    const { root, watcher } = await fixture(t, async () => { calls++; });
    assert.equal(watcher.start().start(), watcher);
    await writeFile(join(root, 'note.md'), 'first');
    await sleep(150);
    watcher.stop();
    watcher.start();
    await sleep(850);
    assert.equal(calls, 0);
    await writeFile(join(root, 'note.md'), 'second');
    await until(() => calls === 1);
    await sleep(850);
    assert.equal(calls, 1);
});
