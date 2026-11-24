/// <reference types="node" />
import { existsSync, watch, type FSWatcher } from 'node:fs';
import type { PKSConfig } from '../types.js';

/** Coalesce filesystem bursts without losing changes during an index refresh. */
export class KnowledgeWatcher {
  private watchers: FSWatcher[] = [];
  private debounce?: ReturnType<typeof setTimeout>;
  private periodic?: ReturnType<typeof setInterval>;
  private active = false;
  private generation = 0;
  private refreshing = false;
  private queued = false;

  constructor(private cfg: PKSConfig, private onChange: () => Promise<unknown>) {}

  start() {
    if (this.active) return this;
    this.active = true;
    const generation = ++this.generation;
    const trigger = () => {
      if (!this.active || generation !== this.generation) return;
      clearTimeout(this.debounce);
      this.debounce = setTimeout(() => {
        this.debounce = undefined;
        if (this.active && generation === this.generation) void this.refresh();
      }, 750);
    };
    for (const source of this.cfg.sourceRoots.filter(x => x.enabled !== false)) {
      if (!existsSync(source.root)) continue;
      try {
        const watcher = watch(source.root, { recursive: true }, trigger);
        // Provider disappearance or permission changes fall back to periodic sync.
        watcher.on('error', () => watcher.close());
        this.watchers.push(watcher);
      } catch { /* unsupported or temporarily unavailable root */ }
    }
    this.periodic = setInterval(() => {
      if (this.active && generation === this.generation) void this.refresh();
    }, 5 * 60_000);
    this.periodic.unref?.();
    return this;
  }

  private async refresh(): Promise<void> {
    if (!this.active) return;
    if (this.refreshing) {
      this.queued = true;
      return;
    }
    this.refreshing = true;
    try {
      do {
        this.queued = false;
        try { await this.onChange(); } catch { /* retry on subsequent change or periodic sync */ }
      } while (this.active && this.queued);
    } finally {
      this.refreshing = false;
    }
  }

  stop() {
    this.active = false;
    ++this.generation;
    this.queued = false;
    clearTimeout(this.debounce);
    clearInterval(this.periodic);
    this.debounce = undefined;
    this.periodic = undefined;
    for (const watcher of this.watchers) {
      try { watcher.close(); } catch { /* already closed */ }
    }
    this.watchers = [];
  }
}
