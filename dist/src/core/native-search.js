// @ts-nocheck
import { createRequire } from 'node:module';
import { isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
export function defaultNativeAddonPath() {
    return fileURLToPath(new URL('../../native/pks.node', import.meta.url));
}
export class NativeSearchEngine {
    addon;
    databasePath;
    nativeHandle;
    constructor(dataDir, addonPath = process.env.PKS_NATIVE_ADDON_PATH ?? defaultNativeAddonPath()) {
        const require = createRequire(import.meta.url);
        const resolvedAddonPath = isAbsolute(addonPath)
            ? addonPath
            : resolve(process.cwd(), addonPath);
        this.addon = require(resolvedAddonPath);
        if (!this.addon || typeof this.addon.search !== 'function') {
            throw new Error('PKS native addon does not export search(databasePath, requestJson)');
        }
        this.databasePath = join(dataDir, 'knowledge.db');
    }
    persistentHandle() {
        if (!this.addon.openHandle ||
            (!this.addon.searchHandle && !this.addon.searchHandleAsync)) {
            return undefined;
        }
        if (this.nativeHandle === undefined) {
            this.nativeHandle = this.addon.openHandle(this.databasePath);
        }
        return this.nativeHandle;
    }
    async search(query, options = {}) {
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
        let raw;
        if (handle !== undefined && this.addon.searchHandleAsync) {
            raw = await this.addon.searchHandleAsync(handle, request);
        }
        else if (handle !== undefined && this.addon.searchHandle) {
            raw = this.addon.searchHandle(handle, request);
        }
        else {
            const mode = options.mode ?? 'auto';
            raw = this.addon.searchAsync && mode !== 'fts'
                ? await this.addon.searchAsync(this.databasePath, request)
                : this.addon.search(this.databasePath, request);
        }
        const response = JSON.parse(raw);
        if (response.contractVersion !== 1 || !Array.isArray(response.results)) {
            throw new Error('PKS native search returned an unsupported contract');
        }
        return response.results;
    }
}
