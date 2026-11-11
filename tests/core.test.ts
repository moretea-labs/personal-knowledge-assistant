// @ts-nocheck
import test from 'node:test';import assert from 'node:assert/strict';import { mkdtemp, mkdir, writeFile, readFile } from 'node:fs/promises';import { tmpdir } from 'node:os';import { join } from 'node:path';import { PKSService } from '../src/core/service.js';import type { PKSConfig } from '../src/types.js';
async function setup(){const root=await mkdtemp(join(tmpdir(),'pks-'));const docs=join(root,'docs');const managed=join(root,'managed');const data=join(root,'data');await mkdir(docs,{recursive:true});await mkdir(managed,{recursive:true});const cfg:PKSConfig={dataDir:data,managedStore:managed,port:0,host:'127.0.0.1',sourceRoots:[{id:'docs',type:'local',name:'Docs',root:docs},{id:'managed',type:'managed',name:'Managed',root:managed}],semantic:{provider:'hash',dimensions:128}};return{root,docs,managed,svc:await new PKSService(cfg).open()};}
test('indexes, searches, structures health and preserves provenance',async()=>{const x=await setup();await writeFile(join(x.docs,'lab-2026-07-10.md'),'# Lab\n肌酐 112 μmol/L\n胱抑素C 1.57 mg/L\n');await x.svc.sync();const r=await x.svc.search('肌酐');assert.ok(r.length);assert.match(r[0].uri,/lab-2026-07-10/);const rows=x.svc.db.db.prepare('select * from medical_observations order by observation_type').all() as any[];assert.equal(rows.length,2);assert.ok(rows.every(r=>r.source_document_id));assert.ok(rows.every(r=>r.observed_at==='2026-07-10')); x.svc.db.close();});
test('writes canonical markdown and can undo',async()=>{const x=await setup();await x.svc.sync();const m=await x.svc.writer.create({domain:'movies',title:'Dune',content:'Great world building.',structuredData:{type:'movie_watch',rating:4,watched_at:'2026-08-10',genres:['science fiction','drama']}});assert.match(await readFile(m.uri,'utf8'),/rating: 4/);const rs=await x.svc.search('Dune');assert.ok(rs.length);const mem=x.svc.memory.build('movies');assert.equal(mem.profile.count,1);await x.svc.writer.undo(m.mutationId);assert.equal((await x.svc.search('Dune')).length,0);assert.equal(x.svc.memory.get('movies').profile.count,0);x.svc.db.close();});
test('semantic hash search catches related Chinese character patterns',async()=>{const x=await setup();await writeFile(join(x.docs,'guitar.md'),'# 稳定性练习\n切换和弦时手提前离开，导致尾音 sustain 不足。');await x.svc.sync();const rs=await x.svc.search('和弦切换尾音太短');assert.ok(rs.length);assert.match(rs[0].title,/guitar/);x.svc.db.close();});

test('user health correction survives reindex',async()=>{const x=await setup();const p=join(x.docs,'2026-07-10-lab.md');await writeFile(p,'肌酐 172 μmol/L');await x.svc.sync();const row=x.svc.db.db.prepare("select * from medical_observations where observation_type='creatinine'").get() as any;x.svc.correctObservation({id:row.id,value:112,observedAt:'2026-07-10'});await writeFile(p,'肌酐 172 μmol/L\n# rescanned');await x.svc.sync();const rows=x.svc.db.db.prepare("select * from medical_observations where observation_type='creatinine'").all() as any[];assert.equal(rows.length,1);assert.equal(rows[0].value,112);assert.equal(rows[0].verified,1);x.svc.db.close();});
test('remote embedding provider speaks OpenAI-compatible protocol',async()=>{const { RemoteEmbeddingProvider }=await import('../src/core/embedding.js');const { createServer }=await import('node:http');const server=createServer(async(req,res)=>{let raw='';for await(const c of req)raw+=c;const body=JSON.parse(raw);assert.equal(body.model,'test-model');res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({data:[{embedding:[1,0,0]}]}));});await new Promise(r=>server.listen(0,'127.0.0.1',r));const port=(server.address() as any).port;const p=new RemoteEmbeddingProvider(`http://127.0.0.1:${port}/v1`,'test-model',3);assert.deepEqual(await p.embed('hello'),[1,0,0]);server.close();});

test('Notion metadata snapshot indexes titles without a token and reconciles deletions',async()=>{const x=await setup();const snapshot=join(x.root,'notion-metadata.json');x.svc.cfg.notion={enabled:true,auth:'notion_snapshot',snapshotPath:snapshot,contentMode:'metadata',workspaceId:'workspace-test'};await writeFile(snapshot,JSON.stringify({schemaVersion:1,mode:'metadata',workspaceId:'workspace-test',workspaceName:'Test',fetchedAt:'2026-08-11T00:00:00Z',results:[{object:'page',id:'page-1',title:'Reading List',last_edited_time:'2026-08-10T00:00:00Z',url:'https://www.notion.so/page-1',parent:{type:'workspace',workspace:true}}]}));const first=await x.svc.sync();assert.equal(first.errors.length,0);const rs=await x.svc.search('Reading List');assert.equal(rs.length,1);assert.equal(rs[0].sourceType,'notion');const row=x.svc.db.db.prepare("select metadata_json from documents where uri='notion://page-1' and deleted_at is null").get() as any;assert.match(row.metadata_json,/metadata_snapshot/);await writeFile(snapshot,JSON.stringify({schemaVersion:1,mode:'metadata',workspaceId:'workspace-test',workspaceName:'Test',fetchedAt:'2026-08-11T01:00:00Z',results:[]}));await x.svc.sync();assert.equal((await x.svc.search('Reading List')).length,0);x.svc.db.close();});

test('file locating uses catalog and aliases, including metadata-only cloud PDFs',async()=>{
  const x=await setup();
  const pdf=join(x.docs,'English-Vocabulary-Handbook.pdf');
  await writeFile(pdf,'synthetic PDF with no native text');
  await writeFile(join(x.docs,'unrelated.md'),'# Utilities\nSome text about unrelated pages and a Spotify collection.');
  await x.svc.sync();
  const row=x.svc.db.db.prepare('SELECT id,index_status,tags_json FROM documents WHERE uri=?').get(pdf) as any;
  assert.equal(row.index_status,'metadata_only');
  assert.match(row.tags_json,/英语学习/);
  assert.deepEqual((await x.svc.search('韦氏小绿书')).map(x=>x.uri),[]);
  const name=await x.svc.search('English-Vocabulary-Handbook.pdf');
  assert.equal(name.length,1);assert.equal(name[0].uri,pdf);assert.equal(name[0].indexStatus,'metadata_only');
  assert.deepEqual(x.svc.setSearchAliases(row.id,['韦氏小绿书','The Green Vocabulary Book']).aliases,['韦氏小绿书','The Green Vocabulary Book']);
  const alias=await x.svc.search('韦氏小绿书');
  assert.equal(alias.length,1);assert.equal(alias[0].uri,pdf);assert.ok(alias[0].reasons.includes('verified_alias'));
  await x.svc.sync();
  assert.equal((await x.svc.search('韦氏小绿书')).length,1,'explicit aliases survive rebuild');
  x.svc.db.db.prepare("UPDATE documents SET index_status='deferred',content_hash=NULL WHERE id=?").run(row.id);
  const deferred=await x.svc.search('帮我找English-Vocabulary-Handbook.pdf在哪里');
  assert.equal(deferred.length,1);assert.equal(deferred[0].indexStatus,'deferred');
  assert.ok(deferred[0].snippet.includes('Cloud placeholder'));
  assert.deepEqual((await x.svc.search('我把不相关的韦氏资料放在哪里')).map(x=>x.uri),[]);
  assert.ok(x.svc.status().indexStatusCounts.some((s:any)=>s.status==='deferred'&&s.count>=1));
  x.svc.db.close();
});

test('English-learning catalog tags let PDF location queries find a source folder',async()=>{
  const x=await setup();
  const folder=join(x.docs,'雅思');await mkdir(folder,{recursive:true});
  const pdf=join(folder,'500-Real-English-Phrases.pdf');
  await writeFile(pdf,'PDF without native text');
  await x.svc.sync();
  const matches=await x.svc.search('我的英语学习相关PDF在哪里');
  assert.equal(matches.length,1);assert.equal(matches[0].uri,pdf);
  assert.equal(matches[0].indexStatus,'metadata_only');
  x.svc.db.close();
});

test('unchanged deferred PDF catalog refreshes topic tags without touching content',async()=>{
  const x=await setup();
  const folder=join(x.docs,'雅思');await mkdir(folder,{recursive:true});
  const pdf=join(folder,'Cambridge-English-Vocabulary.pdf');await writeFile(pdf,'cloud placeholder fixture');
  await x.svc.sync();
  const doc=x.svc.db.db.prepare('SELECT id FROM documents WHERE uri=?').get(pdf) as any;
  x.svc.db.db.prepare("UPDATE documents SET tags_json='[]',index_status='deferred',content_hash=NULL,last_indexed_at=? WHERE id=?").run(new Date().toISOString(),doc.id);
  const result=await x.svc.sync();
  assert.equal(result.indexed,0);
  const row=x.svc.db.db.prepare('SELECT index_status,tags_json FROM documents WHERE id=?').get(doc.id) as any;
  assert.equal(row.index_status,'deferred');
  assert.match(row.tags_json,/英语学习/);
  assert.match(row.tags_json,/雅思/);
  const found=await x.svc.search('我的英语学习相关PDF在哪里');
  assert.equal(found.length,1);assert.equal(found[0].uri,pdf);assert.equal(found[0].indexStatus,'deferred');
  x.svc.db.close();
});

test('semantic candidate reuse preserves ranking and invalidates on local/external DB writes',async()=>{
  const { DatabaseSync }=await import('node:sqlite');
  const x=await setup();
  const note=join(x.docs,'guitar-chord.md');
  await writeFile(note,'# Guitar practice\nChord switching technique and finger positioning.');
  await x.svc.sync();
  const q='guitar chord switching technique';
  const first=await x.svc.search(q,{mode:'semantic',limit:12});
  assert.ok(first.some((r:any)=>r.uri===note));
  const firstRevision=(x.svc.searcher as any).semanticCache?.revision;
  assert.ok(firstRevision,'small hash-vector index should be cached after first query');
  const repeated=await x.svc.search(q,{mode:'semantic',limit:12});
  assert.deepEqual(repeated.map((r:any)=>r.documentId),first.map((r:any)=>r.documentId));
  assert.equal((x.svc.searcher as any).semanticCache?.revision,firstRevision);

  // A separate database connection must invalidate the same derived cache.
  const other=new DatabaseSync(join(x.svc.cfg.dataDir,'knowledge.db'));
  other.prepare('UPDATE documents SET title=? WHERE uri=?').run('Externally Renamed Guitar Note',note);
  other.close();
  const external=await x.svc.search(q,{mode:'semantic',limit:12});
  assert.equal(external.find((r:any)=>r.uri===note)?.title,'Externally Renamed Guitar Note');
  const externalRevision=(x.svc.searcher as any).semanticCache?.revision;
  assert.notEqual(externalRevision,firstRevision);

  // The existing Indexer writes through our connection and invalidates too.
  const added=join(x.docs,'second-guitar.md');
  await writeFile(added,'# Guitar practice\nChord switching technique and finger positioning.');
  await x.svc.sync();
  const afterSync=await x.svc.search(q,{mode:'semantic',limit:20});
  assert.ok(afterSync.some((r:any)=>r.uri===added),'newly indexed document must appear without restarting PKS');
  assert.notEqual((x.svc.searcher as any).semanticCache?.revision,externalRevision);
  x.svc.db.close();
});

test('semantic source filters cannot reuse candidates from the wrong source',async()=>{
  const x=await setup();
  await writeFile(join(x.docs,'docs-chord.md'),'Chord switching practice and fine motor precision.');
  await mkdir(x.managed,{recursive:true});
  await writeFile(join(x.managed,'managed-chord.md'),'Chord switching practice and fine motor precision.');
  await x.svc.sync();
  const docsOnly=await x.svc.search('chord switching practice',{mode:'semantic',source:'docs',limit:15});
  assert.ok(docsOnly.length>0);
  assert.ok(docsOnly.every((r:any)=>r.uri.startsWith(x.docs+'/')));
  const managedOnly=await x.svc.search('chord switching practice',{mode:'semantic',source:'managed',limit:15});
  assert.ok(managedOnly.length>0);
  assert.ok(managedOnly.every((r:any)=>r.uri.startsWith(x.managed+'/')));
  x.svc.db.close();
});

test('single-term literal search avoids the full vector scan without disabling semantic queries',async()=>{
  const x=await setup();
  for(let i=0;i<16;i++){
    await writeFile(join(x.docs,`kafka-${i}.md`),`# Kafka ${i}\nKafka stream event processing and consumer notes ${i}.`);
  }
  await x.svc.sync();
  const literal=await x.svc.search('Kafka',{mode:'auto',limit:10});
  assert.equal(literal.length,10);
  assert.equal((x.svc.searcher as any).semanticCache,null,
    'sufficient FTS results must avoid loading all embedding vectors');

  // Explicit semantic mode continues to provide related conceptual evidence.
  const conceptual=await x.svc.search('Kafka event consumption',{mode:'semantic',limit:10});
  assert.ok(conceptual.length>0);
  assert.ok((x.svc.searcher as any).semanticCache);
  x.svc.db.close();
});

test('ordinary recent/latest search terms do not get routed to health-only structured retrieval',async()=>{
  const x=await setup();
  const p=join(x.docs,'最近读书笔记.md');
  await writeFile(p,'# 最近读书笔记\n这是一份最新英语学习和阅读记录。');
  await x.svc.sync();
  const recent=await x.svc.search('最近读书笔记');
  assert.ok(recent.some((r:any)=>r.uri===p));
  const latest=await x.svc.search('最新英语学习');
  assert.ok(latest.some((r:any)=>r.uri===p));
  const explicitStructured=await x.svc.search('最新英语学习',{mode:'structured'});
  assert.deepEqual(explicitStructured,[]);
  x.svc.db.close();
});


test('related suggestions require content evidence, exclude self and suppress generic collisions',async()=>{
  const x=await setup();
  const source=join(x.docs,'guitar-practice.md');
  const relevant=join(x.docs,'chord-finger-exercises.md');
  const noise=join(x.docs,'guitar-shopping.md');
  const unrelated=join(x.docs,'finance.md');
  await writeFile(source,'# Guitar practice\nChord switching and finger positioning exercises for smooth transitions.');
  await writeFile(relevant,'# Chord switching technique\nGuitar finger positioning exercises improve chord switching precision.');
  await writeFile(noise,'# Guitar price comparison\nGuitar accessories and retail store prices.');
  await writeFile(unrelated,'# Financial planning\nMonthly budget and banking transaction analysis.');
  await x.svc.sync();

  const query='Guitar chord switching finger positioning exercises';
  const results=await x.svc.search(query,{mode:'related',excludeUri:source,limit:8});
  assert.ok(results.some((r:any)=>r.uri===relevant),'strong overlapping evidence must survive');
  assert.ok(!results.some((r:any)=>r.uri===source),'the current file is not a recommendation');
  assert.ok(!results.some((r:any)=>r.uri===noise),'one shared topic word is insufficient');
  assert.ok(!results.some((r:any)=>r.uri===unrelated),'unrelated content must be omitted');
  assert.ok(results.every((r:any)=>r.reasons.includes('related_content')));
  assert.equal(new Set(results.map((r:any)=>r.documentId)).size,results.length);

  assert.deepEqual(await x.svc.search('notes about the page',{mode:'related'}),[],
    'generic note UI terms alone must not generate suggestions');
  x.svc.db.close();
});

test('related Chinese evidence distinguishes a specific topic from generic learning notes',async()=>{
  const x=await setup();
  const relevant=join(x.docs,'renal-diet.md');
  const noise=join(x.docs,'english-study.md');
  await writeFile(relevant,'# 慢性肾病饮食控制\n注意蛋白质摄入与钾磷管理，记录饮食控制方案。');
  await writeFile(noise,'# 学习笔记\n英语听力学习与阅读记录。');
  await x.svc.sync();
  const results=await x.svc.search('慢性肾病饮食控制蛋白质摄入',{mode:'related',limit:8});
  assert.ok(results.some((r:any)=>r.uri===relevant),'CJK content overlap must be usable');
  assert.ok(!results.some((r:any)=>r.uri===noise),'generic shared Chinese text is not evidence');
  x.svc.db.close();
});


test('indexing does not hold SQLite write transactions while awaiting embeddings',async()=>{
  const { DatabaseSync }=await import('node:sqlite');
  const { Indexer }=await import('../src/core/indexer.js');
  const { stat }=await import('node:fs/promises');
  const x=await setup();
  const source=join(x.docs,'delayed-embedding.md');
  await writeFile(source,'# Test\nStudy concepts with enough text to create an indexed chunk.');
  const st=await stat(source);
  for(const mode of ['local','virtual']){
    let started!:()=>void;
    let release!:()=>void;
    const begun=new Promise<void>(resolve=>{started=resolve;});
    const gate=new Promise<void>(resolve=>{release=resolve;});
    const embedder={id:'test-slow-embedding',dimensions:3,async embed(){started();await gate;return [1,0,0];}};
    const indexer=new Indexer(x.svc.db,x.svc.cfg,embedder);
    const pending=mode==='local'
      ?indexer.indexFile('docs','local',source,st.mtime.toISOString(),st.birthtime.toISOString(),st.size)
      :indexer.indexVirtualDocument('notion','notion','notion://slow-test','Slow indexing','Study concepts for indexing.',new Date().toISOString(),'slow-hash');
    await begun;
    const another=new DatabaseSync(join(x.svc.cfg.dataDir,'knowledge.db'));
    another.exec('PRAGMA busy_timeout=0');
    let concurrentError:unknown=null;
    try{
      another.prepare('INSERT INTO corrections(id,target_id,field,new_value,created_at) VALUES(?,?,?,?,?)')
        .run('concurrent-'+mode,'fixture','scan_probe','ok',new Date().toISOString());
    }catch(error){concurrentError=error;}
    finally{release();await pending;another.close();}
    assert.equal(concurrentError,null,mode+' indexing must not hold write lock during remote embedding');
  }
  x.svc.db.close();
});

test('unavailable source root does not delete previously indexed documents',async()=>{
  const { rename }=await import('node:fs/promises');
  const x=await setup();
  const path=join(x.docs,'existing-note.md');
  await writeFile(path,'# Canonical study note\nSource file content remains the authority.');
  await x.svc.sync();
  const before=x.svc.db.db.prepare('SELECT index_status FROM documents WHERE uri=? AND deleted_at IS NULL').get(path) as any;
  assert.equal(before?.index_status,'indexed');
  const offline=x.docs+'-temporarily-offline';
  await rename(x.docs,offline);
  try{
    const scan=await x.svc.sync();
    const after=x.svc.db.db.prepare('SELECT index_status,deleted_at FROM documents WHERE uri=?').get(path) as any;
    assert.equal(after?.deleted_at,null,'temporary source unavailability must not erase the catalog');
    assert.equal(after?.index_status,'indexed');
    assert.ok(scan.errors.some((error:any)=>error.path===x.docs),'incomplete scan must be visible');
    const failure=x.svc.db.db.prepare('SELECT last_error FROM sync_state WHERE source_id=?').get('docs') as any;
    assert.match(failure?.last_error||'',/temporarily-offline|docs|ENOENT/,'incomplete scan must retain a diagnosable source error');
  }finally{await rename(offline,x.docs);}
  await x.svc.sync();
  assert.ok(x.svc.db.db.prepare('SELECT id FROM documents WHERE uri=? AND deleted_at IS NULL').get(path));
  assert.equal((x.svc.db.db.prepare('SELECT last_error FROM sync_state WHERE source_id=?').get('docs') as any)?.last_error,null,'successful scan clears the source error');
  x.svc.db.close();
});


test('memory excludes health and media evidence from documents removed in complete scans',async()=>{
  const { unlink }=await import('node:fs/promises');
  const x=await setup();
  const source=join(x.docs,'lab-2026-07-10.md');
  await writeFile(source,'# Labs\n肌酐 112 μmol/L\n胱抑素C 1.57 mg/L\n');
  const movie=join(x.docs,'movie.md');
  await writeFile(movie,'---\ntype: movie\ntitle: Cinema Evidence\nrating: 4\n---\n# Cinema Evidence');
  await x.svc.sync();
  assert.equal(x.svc.memory.get('movies').profile.count,1);
  const before=x.svc.memory.get('health');
  assert.ok(before.profile.observations.length>0,'original evidence should contribute to memory');
  await unlink(source);
  await x.svc.sync();
  const document=x.svc.db.db.prepare('SELECT deleted_at FROM documents WHERE uri=?').get(source) as any;
  assert.ok(document?.deleted_at,'complete scan should tombstone removed source');
  const after=x.svc.memory.get('health');
  assert.deepEqual(after.profile.observations,[],'deleted source must not remain in derived memory');
  assert.deepEqual(after.evidence,[],'deleted source must not persist as memory evidence');
  await unlink(movie);
  await x.svc.sync();
  assert.equal(x.svc.memory.get('movies').profile.count,0,'removed media source must not remain in memory');
  x.svc.db.close();
});


test('explicit search modes do not silently blend catalog, FTS and semantic evidence',async()=>{
  const x=await setup();
  const pdf=join(x.docs,'Exclusive-Catalog-PDF.pdf');
  const note=join(x.docs,'lexical-lesson.md');
  await writeFile(pdf,'synthetic PDF with no native text');
  await writeFile(note,'# Lexical relevance\nLexical relevance distinguishes related concepts from unrelated vocabulary.');
  await x.svc.sync();
  assert.ok((await x.svc.search('Exclusive-Catalog-PDF.pdf',{mode:'auto'}))
    .some((hit:any)=>hit.uri===pdf),'auto file locator should still use metadata');
  assert.ok(!(await x.svc.search('Exclusive-Catalog-PDF.pdf',{mode:'fts'}))
    .some((hit:any)=>hit.uri===pdf),'FTS must not promote metadata-only PDFs');
  assert.ok(!(await x.svc.search('Exclusive-Catalog-PDF.pdf',{mode:'semantic'}))
    .some((hit:any)=>hit.uri===pdf),'semantic must not promote metadata-only PDFs');
  const exact=await x.svc.search('lexical',{mode:'fts'});
  assert.ok(exact.length>0);
  assert.ok(exact.every((hit:any)=>hit.reasons.every((reason:string)=>reason==='full_text')));
  const conceptual=await x.svc.search('lexical relevance',{mode:'semantic'});
  assert.ok(conceptual.length>0);
  assert.ok(conceptual.every((hit:any)=>hit.reasons.every((reason:string)=>reason==='semantic_hash')));
  x.svc.db.close();
});


test('concurrent managed note creation preserves all original content without overwrites',async()=>{
  const x=await setup();
  const results=await Promise.allSettled(Array.from({length:8},(_,i)=>
    x.svc.writer.create({title:'Concurrent Study Note',domain:'Inbox',content:'Unique payload '+i})));
  const errors=results.filter((item:any)=>item.status==='rejected');
  assert.deepEqual(errors,[],'each concurrent new note must have its own canonical destination');
  const uris=results.map((item:any)=>item.value.uri);
  assert.equal(new Set(uris).size,8,'all created files must use distinct paths');
  const stored=await Promise.all(uris.map(uri=>readFile(uri,'utf8')));
  for(let i=0;i<8;i++)assert.ok(stored[i].includes('Unique payload '+i),'a newer create must never overwrite an earlier note');
  x.svc.db.close();
});
