#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { FORGE_ACTIONS, FORGE_PERMISSIONS, FORGE_PLUGIN_VERSION } from './dist/src/forge/contract.js';

const root = dirname(fileURLToPath(import.meta.url));
execFileSync('npm', ['install', '--ignore-scripts'], { cwd: root, stdio: 'inherit' });
execFileSync('npm', ['run', 'build'], { cwd: root, stdio: 'inherit' });
const helperPath = resolve(root, 'scripts/forge-provider.mjs');
const nodeLocator = process.platform === 'win32' ? 'where.exe' : 'which';
const nodeExecutable = String(execFileSync(nodeLocator, ['node'], { encoding: 'utf8' })).split(/\r?\n/).map((value) => value.trim()).find(Boolean);
if (!nodeExecutable) throw new Error('Personal Knowledge Assistant requires Node.js >=22.5.0.');
const actions = FORGE_ACTIONS;
const registration = {
 pluginId:'personal_knowledge',providerPluginId:'personal_knowledge',displayName:'Personal Knowledge Assistant',provider:'moretea-labs',pluginVersion:FORGE_PLUGIN_VERSION,protocolVersion:'1.0',scope:'controller',enabled:true,
 transport:{kind:'managed_cli_json',runtimeExecutable:nodeExecutable,helperPath,cwd:root,maxRequestBytes:1048576,maxResponseBytes:4194304,healthTimeoutMs:5000,actionTimeoutMs:120000},
 permissions:FORGE_PERMISSIONS,
 capabilities:[
  {capabilityId:'knowledge.read',title:'Personal knowledge reads',description:'Search, read, and analyze indexed user-owned knowledge.',scopes:['knowledge.read'],actions:['knowledge_search','knowledge_read','knowledge_analyze']},
  {capabilityId:'knowledge.write',title:'Personal knowledge writes',description:'Create, update, or undo managed canonical knowledge.',scopes:['knowledge.write'],actions:['knowledge_mutate']},
  {capabilityId:'knowledge.admin',title:'Personal knowledge administration',description:'Synchronize sources and inspect or plan knowledge organization.',scopes:['knowledge.admin'],actions:['knowledge_admin']}
 ],
 actions,
 legacyIdentities:['personal-knowledge-system','Personal Knowledge System','pks']
};
process.stdout.write(`${JSON.stringify({schemaVersion:1,registration})}\n`);
