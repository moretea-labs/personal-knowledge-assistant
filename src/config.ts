// @ts-nocheck
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { readFile } from 'node:fs/promises';
import type { PKSConfig } from './types.js';
import { ensureDir, fileExists, atomicWrite } from './util/fs.js';

export function defaultConfig(): PKSConfig {
  const home = homedir();
  return {
    dataDir: join(home, '.pks'),
    managedStore: join(home, 'Documents', 'Personal Knowledge'),
    port: 3217,
    host: '127.0.0.1',
    sourceRoots: [
      { id: 'documents', type: 'local', name: 'Documents', root: join(home, 'Documents'), enabled: true, exclude: [] },
      { id: 'managed', type: 'managed', name: 'Personal Knowledge', root: join(home, 'Documents', 'Personal Knowledge'), enabled: true }
    ],
    semantic: { provider: 'hash', dimensions: 256 },
    forge: { enabled: true, socketPath: join(home, '.pks', 'forge.sock') }
  };
}

export async function loadConfig(explicitPath?: string): Promise<PKSConfig> {
  const path = explicitPath ? resolve(explicitPath) : process.env.PKS_CONFIG;
  let cfg:PKSConfig = path && await fileExists(path) ? { ...defaultConfig(), ...JSON.parse(await readFile(path, 'utf8')) } : defaultConfig();
  if(process.env.PKS_DATA_DIR) cfg.dataDir=process.env.PKS_DATA_DIR; if(process.env.PKS_MANAGED_STORE) cfg.managedStore=process.env.PKS_MANAGED_STORE;
  if(process.env.PKS_NOTION_TOKEN){cfg.notion={...(cfg.notion||{}),enabled:true,auth:'token',token:process.env.PKS_NOTION_TOKEN};}
  if(process.env.PKS_EMBEDDING_ENDPOINT&&process.env.PKS_EMBEDDING_MODEL){cfg.semantic={provider:'remote',endpoint:process.env.PKS_EMBEDDING_ENDPOINT,model:process.env.PKS_EMBEDDING_MODEL,apiKey:process.env.PKS_EMBEDDING_API_KEY,dimensions:Number(process.env.PKS_EMBEDDING_DIMENSIONS||cfg.semantic?.dimensions||1536)};}
  const expand=(v:string|undefined)=>v?.startsWith('~/')?join(homedir(),v.slice(2)):v;cfg.dataDir=expand(cfg.dataDir)!;cfg.managedStore=expand(cfg.managedStore)!;cfg.sourceRoots=cfg.sourceRoots.map(x=>({...x,root:expand(x.root)!,exclude:(x.exclude||[]).map((p:string)=>expand(p)!)}));if(cfg.forge?.socketPath)cfg.forge.socketPath=expand(cfg.forge.socketPath);if(cfg.notion?.snapshotPath)cfg.notion.snapshotPath=expand(cfg.notion.snapshotPath);
  return cfg;
}
export async function initConfig(path: string, cfg = defaultConfig()) { await ensureDir(cfg.dataDir); await atomicWrite(path, JSON.stringify(cfg, null, 2)); return cfg; }
