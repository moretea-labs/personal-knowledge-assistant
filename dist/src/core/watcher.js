// @ts-nocheck
import { watch } from 'node:fs';
import { existsSync } from 'node:fs';
export class KnowledgeWatcher {
    cfg;
    onChange;
    watchers = [];
    timer;
    periodic;
    constructor(cfg, onChange) {
        this.cfg = cfg;
        this.onChange = onChange;
    }
    start() { let debounce; const trigger = () => { clearTimeout(debounce); debounce = setTimeout(() => this.onChange().catch(() => { }), 750); }; for (const s of this.cfg.sourceRoots.filter(x => x.enabled !== false)) {
        if (!existsSync(s.root))
            continue;
        try {
            this.watchers.push(watch(s.root, { recursive: true }, trigger));
        }
        catch { }
    } this.periodic = setInterval(() => this.onChange().catch(() => { }), 5 * 60_000); this.periodic.unref?.(); return this; }
    stop() { for (const w of this.watchers)
        try {
            w.close();
        }
        catch { } this.watchers = []; if (this.periodic)
        clearInterval(this.periodic); }
}
