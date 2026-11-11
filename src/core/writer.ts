// @ts-nocheck
import { join, resolve, relative, sep } from 'node:path';
import { readFile, stat, lstat } from 'node:fs/promises';
import type { PKSConfig, MutationResult } from '../types.js';
import { KnowledgeDB } from '../db/database.js';
import { atomicWrite, createExclusive, safeInside, ensureDir, removeIfExists } from '../util/fs.js';
import { id } from './ids.js';
import { Indexer } from './indexer.js';

function slug(s:string){return s.trim().replace(/[\\/:*?"<>|]/g,'-').replace(/\s+/g,'-').slice(0,100)||'note';}

export class KnowledgeWriter{
 constructor(private db:KnowledgeDB,private cfg:PKSConfig,private indexer:Indexer){}
 // Managed Store ownership is a filesystem boundary, not merely a path prefix.
 private async checkedManagedPath(candidate:string){
  const root=resolve(this.cfg.managedStore);
  const path=resolve(candidate);
  if(!safeInside(root,path))throw new Error('destination must stay inside managedStore');
  let current=root;
  for(const component of relative(root,path).split(sep).filter(Boolean)){
   current=join(current,component);
   try{
    if((await lstat(current)).isSymbolicLink())throw new Error('symbolic link path is not allowed in managedStore');
   }catch(error:any){
    if(error?.code!=='ENOENT')throw error;
   }
  }
  return path;
 }

 private invalidateMemory(){this.db.db.prepare('DELETE FROM memory_profiles').run();}
 private removeDerivedByUri(uri:string){
  const d=this.db.db.prepare('SELECT id FROM documents WHERE uri=?').get(uri) as any;if(!d)return;
  this.db.db.exec('BEGIN');
  try{
   this.db.db.prepare('DELETE FROM chunks_fts WHERE document_id=?').run(d.id);
   this.db.db.prepare('DELETE FROM chunks WHERE document_id=?').run(d.id);
   this.db.db.prepare('DELETE FROM structured_records WHERE source_document_id=?').run(d.id);
   this.db.db.prepare('DELETE FROM medical_observations WHERE source_document_id=?').run(d.id);
   this.db.db.prepare('DELETE FROM document_entities WHERE document_id=?').run(d.id);
   this.db.db.prepare("UPDATE documents SET deleted_at=?,index_status='deleted' WHERE id=?").run(new Date().toISOString(),d.id);
   this.db.db.exec('COMMIT');
  }catch(e){this.db.db.exec('ROLLBACK');throw e;}
 }

 async create(input:{content:string;domain?:string;title?:string;structuredData?:Record<string,unknown>;destination?:string;actor?:string;reason?:string}):Promise<MutationResult>{
  const domain=(input.domain||'Inbox').replace(/[^\p{L}\p{N}_ -]/gu,'').trim()||'Inbox';const title=input.title||new Date().toISOString().slice(0,10);
  const folder=input.destination?resolve(input.destination):join(this.cfg.managedStore,domain[0].toUpperCase()+domain.slice(1));
  await this.checkedManagedPath(folder);await ensureDir(folder);await this.checkedManagedPath(folder);
  const body=this.render(title,domain,input.content,input.structuredData);
  let path:string|undefined;
  for(let attempt=0;attempt<10000;attempt++){
   const candidate=join(folder,`${slug(title)}${attempt?'-'+(attempt+1):''}.md`);
   try{await createExclusive(candidate,body);path=candidate;break;}
   catch(error:any){if(error?.code!=='EEXIST')throw error;}
  }
  if(!path)throw new Error('No available filename for managed note');
  const s=await stat(path);
  await this.indexer.indexFile('managed','managed',path,s.mtime.toISOString(),s.birthtime.toISOString(),s.size);this.invalidateMemory();
  const mutationId=id();this.db.db.prepare('INSERT INTO mutations(id,actor,action,source,uri,before_json,after_json,timestamp,reason,reversible) VALUES(?,?,?,?,?,NULL,?,?,?,1)').run(mutationId,input.actor||'user','create','managed',path,JSON.stringify({content:body}),new Date().toISOString(),input.reason||'knowledge_write');
  return{mutationId,action:'create',uri:path,reversible:true};
 }

 async update(input:{uri:string;append?:string;replace?:string;actor?:string;reason?:string}):Promise<MutationResult>{
  const path=await this.checkedManagedPath(input.uri);
  const before=await readFile(path,'utf8');const after=input.replace!==undefined?input.replace:before+(input.append??'');await atomicWrite(path,after);const s=await stat(path);
  await this.indexer.indexFile('managed','managed',path,s.mtime.toISOString(),s.birthtime.toISOString(),s.size);this.invalidateMemory();
  const mutationId=id();this.db.db.prepare('INSERT INTO mutations(id,actor,action,source,uri,before_json,after_json,timestamp,reason,reversible) VALUES(?,?,?,?,?,?,?,?,?,1)').run(mutationId,input.actor||'user','update','managed',path,JSON.stringify({content:before}),JSON.stringify({content:after}),new Date().toISOString(),input.reason||'knowledge_update');
  return{mutationId,action:'update',uri:path,reversible:true};
 }

 async undo(mutationId:string){
  const m=this.db.db.prepare('SELECT * FROM mutations WHERE id=?').get(mutationId) as any;if(!m||m.undone_at)throw new Error('Mutation not found or already undone');await this.checkedManagedPath(m.uri);
  if(m.action==='create'){await removeIfExists(m.uri);this.removeDerivedByUri(m.uri);}
  else if(m.action==='update'){const b=JSON.parse(m.before_json||'{}');await atomicWrite(m.uri,b.content||'');const s=await stat(m.uri);await this.indexer.indexFile('managed','managed',m.uri,s.mtime.toISOString(),s.birthtime.toISOString(),s.size);}
  else throw new Error('Mutation is not undoable by standalone writer');
  this.db.db.prepare('UPDATE mutations SET undone_at=? WHERE id=?').run(new Date().toISOString(),mutationId);this.invalidateMemory();
  return{ok:true,mutationId};
 }

 private render(title:string,domain:string,content:string,data?:Record<string,unknown>){const fm:any={type:data?.type||domain.toLowerCase(),title,...data};const lines=['---',...Object.entries(fm).filter(([,v])=>v!==undefined).map(([k,v])=>`${k}: ${Array.isArray(v)?`[${v.join(', ')}]`:String(v)}`),'---','',`# ${title}`,'',content.trim(),''];return lines.join('\n');}
}
