#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(fileURLToPath(import.meta.url));
execFileSync('npm', ['install', '--ignore-scripts'], { cwd: root, stdio: 'inherit' });
execFileSync('npm', ['run', 'build'], { cwd: root, stdio: 'inherit' });
const helperPath = resolve(root, 'scripts/forge-provider.mjs');
const nodeLocator = process.platform === 'win32' ? 'where.exe' : 'which';
const nodeExecutable = String(execFileSync(nodeLocator, ['node'], { encoding: 'utf8' })).split(/\r?\n/).map((value) => value.trim()).find(Boolean);
if (!nodeExecutable) throw new Error('Personal Knowledge Assistant requires Node.js >=22.5.0.');
const read = { scope:'knowledge.read', mode:'read', description:'Search, read, and analyze user-owned indexed personal knowledge.', granted:true, required:true };
const write = { scope:'knowledge.write', mode:'write', description:'Create or update only managed canonical personal knowledge.', granted:true, required:false };
const admin = { scope:'knowledge.admin', mode:'write', description:'Synchronize configured sources and manage the local knowledge index.', granted:true, required:false };
const writeClaim = [{ resource:'repo-state', mode:'write' }];
const actions = [
 {actionId:'knowledge_search',title:'Search personal knowledge',description:'Search indexed personal sources and return bounded evidence with canonical locations.',readOnly:true,risk:'readonly',confirmation:'none',defaultTimeoutMs:15000,cancellable:true,idempotent:true,scopes:['knowledge.read'],resourceClaims:[],argumentsSchema:{type:'object',properties:{query:{type:'string'},limit:{type:'number'},document_type:{type:'string'},source:{type:'string'},mode:{enum:['auto','fts','semantic','metadata','structured']}},required:['query'],additionalProperties:false}},
 {actionId:'knowledge_read',title:'Read personal knowledge',description:'Read one bounded indexed document by stable document id.',readOnly:true,risk:'readonly',confirmation:'none',defaultTimeoutMs:15000,cancellable:true,idempotent:true,scopes:['knowledge.read'],resourceClaims:[],argumentsSchema:{type:'object',properties:{document_id:{type:'string'},max_chars:{type:'number'}},required:['document_id'],additionalProperties:false}},
 {actionId:'knowledge_mutate',title:'Mutate personal knowledge',description:'Create/update canonical managed knowledge or undo a prior mutation.',readOnly:false,risk:'workspace_write',confirmation:'authorization',defaultTimeoutMs:30000,cancellable:true,idempotent:false,scopes:['knowledge.write'],resourceClaims:writeClaim,argumentsSchema:{type:'object',properties:{operation:{enum:['create','update','undo']},content:{type:'string'},title:{type:'string'},domain:{type:'string'},uri:{type:'string'},append:{type:'string'},replace:{type:'string'},mutation_id:{type:'string'},structured_data:{type:'object'}},required:['operation'],additionalProperties:false}},
 {actionId:'knowledge_analyze',title:'Analyze personal knowledge',description:'Return structured domain analysis, memory profile and evidence for reasoning.',readOnly:true,risk:'readonly',confirmation:'none',defaultTimeoutMs:30000,cancellable:true,idempotent:true,scopes:['knowledge.read'],resourceClaims:[],argumentsSchema:{type:'object',properties:{domain:{type:'string'},question:{type:'string'}},required:['domain'],additionalProperties:false}},
 {actionId:'knowledge_admin',title:'Manage personal knowledge index',description:'Read status, synchronize sources, or create a proposal-only physical organization plan.',readOnly:false,risk:'workspace_write',confirmation:'authorization',defaultTimeoutMs:120000,cancellable:true,idempotent:true,scopes:['knowledge.admin'],resourceClaims:writeClaim,argumentsSchema:{type:'object',properties:{operation:{enum:['sync','status','organization_plan','sources','recent_changes']}},required:['operation'],additionalProperties:false}}
];
const registration = {
 pluginId:'personal_knowledge',providerPluginId:'personal_knowledge',displayName:'Personal Knowledge Assistant',provider:'moretea-labs',pluginVersion:'0.2.1',protocolVersion:'1.0',scope:'controller',enabled:true,
 transport:{kind:'managed_cli_json',runtimeExecutable:nodeExecutable,helperPath,cwd:root,maxRequestBytes:1048576,maxResponseBytes:4194304,healthTimeoutMs:5000,actionTimeoutMs:120000},
 permissions:[read,write,admin],
 capabilities:[
  {capabilityId:'knowledge.read',title:'Personal knowledge reads',description:'Search, read, and analyze indexed user-owned knowledge.',scopes:['knowledge.read'],actions:['knowledge_search','knowledge_read','knowledge_analyze']},
  {capabilityId:'knowledge.write',title:'Personal knowledge writes',description:'Create, update, or undo managed canonical knowledge.',scopes:['knowledge.write'],actions:['knowledge_mutate']},
  {capabilityId:'knowledge.admin',title:'Personal knowledge administration',description:'Synchronize sources and inspect or plan knowledge organization.',scopes:['knowledge.admin'],actions:['knowledge_admin']}
 ],
 actions,
 legacyIdentities:['personal-knowledge-system','Personal Knowledge System','pks']
};
process.stdout.write(`${JSON.stringify({schemaVersion:1,registration})}\n`);
