// @ts-nocheck
import { createRequire } from 'node:module';
import { isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { SearchMode, SearchResult } from '../types.js';

type SearchOptions = {
  mode?: SearchMode;
  source?: string;
  documentType?: string;
  dateFrom?: string;
  dateTo?: string;
  limit?: number;
  excludeUri?: string;
};

type NativeAddon = {
  openHandle?: (databasePath: string) => unknown;
  searchHandle?: (handle: unknown, requestJson: string) => string;
  searchHandleAsync?: (handle: unknown, requestJson: string) => Promise<string>;
  search(databasePath: string, requestJson: string): string;
  searchAsync?: (databasePath: string, requestJson: string) => Promise<string>;
};

type NativeSearchResponse = {
  contractVersion: number;
  results: SearchResult[];
};

export function defaultNativeAddonPath(): string {
  return fileURLToPath(new URL('../../native/pks.node', import.meta.url));
}

export class NativeSearchEngine {
  private readonly addon: NativeAddon;
  private readonly databasePath: string;
  private nativeHandle: unknown | undefined;

  constructor(
    dataDir: string,
    addonPath = process.env.PKS_NATIVE_ADDON_PATH ?? defaultNativeAddonPath()
  ) {
    const require = createRequire(import.meta.url);
    const resolvedAddonPath = isAbsolute(addonPath)
      ? addonPath
      : resolve(process.cwd(), addonPath);
    this.addon = require(resolvedAddonPath) as NativeAddon;
    if (!this.addon || typeof this.addon.search !== 'function') {
      throw new Error('PKS native addon does not export search(databasePath, requestJson)');
    }
    this.databasePath = join(dataDir, 'knowledge.db');
  }

  private persistentHandle(): unknown | undefined {
    if (
      !this.addon.openHandle ||
      (!this.addon.searchHandle && !this.addon.searchHandleAsync)
    ) {
      return undefined;
    }
    if (this.nativeHandle === undefined) {
      this.nativeHandle = this.addon.openHandle(this.databasePath);
    }
    return this.nativeHandle;
  }

  async search(query: string, options: SearchOptions = {}): Promise<SearchResult[]> {
    const request = JSON.stringify({
      contractVersion: 1,
      query,
      mode: options.mode ?? 'auto',
      source: options.source,
      documentType: options.documentType,
      dateFrom: options.dateFrom,
      dateTo: options.dateTo,
      limit: options.limit ?? 12,
      excludeUri: options.excludeUri
    });

    const handle = this.persistentHandle();
    let raw: string;
    if (handle !== undefined && this.addon.searchHandleAsync) {
      raw = await this.addon.searchHandleAsync(handle, request);
    } else if (handle !== undefined && this.addon.searchHandle) {
      raw = this.addon.searchHandle(handle, request);
    } else {
      const mode = options.mode ?? 'auto';
      raw = this.addon.searchAsync && mode !== 'fts'
        ? await this.addon.searchAsync(this.databasePath, request)
        : this.addon.search(this.databasePath, request);
    }
    const response = JSON.parse(raw) as NativeSearchResponse;

    if (response.contractVersion !== 1 || !Array.isArray(response.results)) {
      throw new Error('PKS native search returned an unsupported contract');
    }
    return response.results;
  }
}
