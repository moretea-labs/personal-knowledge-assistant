// @ts-nocheck
export type SourceType = 'local' | 'obsidian' | 'notion' | 'managed';
export type SearchMode = 'auto' | 'fts' | 'semantic' | 'metadata' | 'structured';

export interface SourceRootConfig {
  id: string;
  type: SourceType;
  name: string;
  root: string;
  enabled?: boolean;
  /** Absolute paths or paths relative to root that must never be indexed. */
  exclude?: string[];
}

export interface PKSConfig {
  dataDir: string;
  managedStore: string;
  port: number;
  host: string;
  sourceRoots: SourceRootConfig[];
  notion?: {
    token?: string;
    enabled?: boolean;
    auth?: 'token' | 'notion_snapshot';
    workspaceId?: string;
    snapshotPath?: string;
    contentMode?: 'metadata' | 'full';
    defaultParentPageId?: string;
  };
  semantic?: { provider: 'hash' | 'remote'; endpoint?: string; apiKey?: string; model?: string; dimensions?: number };
  forge?: { enabled?: boolean; socketPath?: string };
}

export interface ParsedSection { heading?: string; text: string; page?: number; startOffset?: number; endOffset?: number; }
export interface ParsedDocument { text: string; sections: ParsedSection[]; metadata: Record<string, unknown>; }

export interface SearchResult {
  documentId: string;
  chunkId?: string;
  title: string;
  uri: string;
  sourceType: string;
  documentType?: string;
  modifiedAt?: string;
  snippet: string;
  score: number;
  reasons: string[];
  page?: number;
  headingPath?: string;
}

export interface MutationResult { mutationId: string; action: string; uri: string; reversible: boolean; }
export interface DomainExtraction { records?: StructuredRecordInput[]; observations?: MedicalObservationInput[]; tags?: string[]; documentType?: string; }
export interface StructuredRecordInput { domain: string; recordType: string; entityKey: string; data: Record<string, unknown>; authority?: string; confidence?: number; observedAt?: string; }
export interface MedicalObservationInput { observationType: string; value: number; unit?: string; observedAt?: string; sourceAnchor?: string; extractionMethod?: string; confidence?: number; }
