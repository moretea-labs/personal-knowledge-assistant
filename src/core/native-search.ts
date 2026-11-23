// @ts-nocheck
import { createRequire } from 'node:module';
import { join } from 'node:path';
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
  search(databasePath: string, requestJson: string): string;
};

type NativeSearchResponse = {
  contractVersion: number;
  results: SearchResult[];
};

export class NativeSearchEngine {
  private readonly addon: NativeAddon;
  private readonly databasePath: string;

  constructor(dataDir: string, addonPath = process.env.PKS_NATIVE_ADDON_PATH) {
    if (!addonPath) {
      throw new Error('PKS_NATIVE_ADDON_PATH is required when PKS_SEARCH_ENGINE=native');
    }
    const require = createRequire(import.meta.url);
    this.addon = require(addonPath) as NativeAddon;
    if (!this.addon || typeof this.addon.search !== 'function') {
      throw new Error('PKS native addon does not export search(databasePath, requestJson)');
    }
    this.databasePath = join(dataDir, 'knowledge.db');
  }

  async search(query: string, options: SearchOptions = {}): Promise<SearchResult[]> {
    const response = JSON.parse(this.addon.search(this.databasePath, JSON.stringify({
      contractVersion: 1,
      query,
      mode: options.mode ?? 'auto',
      source: options.source,
      documentType: options.documentType,
      dateFrom: options.dateFrom,
      dateTo: options.dateTo,
      limit: options.limit ?? 12,
      excludeUri: options.excludeUri
    }))) as NativeSearchResponse;

    if (response.contractVersion !== 1 || !Array.isArray(response.results)) {
      throw new Error('PKS native search returned an unsupported contract');
    }
    return response.results;
  }
}
