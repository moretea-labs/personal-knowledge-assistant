// @ts-nocheck
import { DatabaseSync } from 'node:sqlite';
import { join } from 'node:path';
import { ensureDir } from '../util/fs.js';

export class KnowledgeDB {
  db!: DatabaseSync;
  constructor(public dataDir: string) {}
  async open() {
    await ensureDir(this.dataDir);
    this.db = new DatabaseSync(join(this.dataDir, 'knowledge.db'));
    this.db.exec('PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON; PRAGMA temp_store=MEMORY;');
    this.migrate();
    return this;
  }
  migrate() {
    this.db.exec(`
CREATE TABLE IF NOT EXISTS sources(id TEXT PRIMARY KEY,type TEXT NOT NULL,name TEXT NOT NULL,root_uri TEXT NOT NULL,config_json TEXT NOT NULL DEFAULT '{}',enabled INTEGER NOT NULL DEFAULT 1,created_at TEXT NOT NULL,updated_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS documents(id TEXT PRIMARY KEY,source_id TEXT NOT NULL,source_type TEXT NOT NULL,uri TEXT NOT NULL UNIQUE,canonical_uri TEXT NOT NULL,title TEXT NOT NULL,mime_type TEXT,created_at TEXT,modified_at TEXT,content_hash TEXT,size INTEGER,language TEXT,document_type TEXT,sensitivity TEXT DEFAULT 'normal',tags_json TEXT DEFAULT '[]',index_status TEXT NOT NULL DEFAULT 'pending',last_indexed_at TEXT,deleted_at TEXT,metadata_json TEXT DEFAULT '{}');
CREATE INDEX IF NOT EXISTS idx_documents_source ON documents(source_id, deleted_at);
CREATE INDEX IF NOT EXISTS idx_documents_type_date ON documents(document_type, modified_at);
CREATE TABLE IF NOT EXISTS chunks(id TEXT PRIMARY KEY,document_id TEXT NOT NULL,ordinal INTEGER NOT NULL,text TEXT NOT NULL,start_offset INTEGER,end_offset INTEGER,page INTEGER,heading_path TEXT,embedding_json TEXT,embedding_provider TEXT,embedding_dim INTEGER,content_hash TEXT NOT NULL,FOREIGN KEY(document_id) REFERENCES documents(id) ON DELETE CASCADE);
CREATE INDEX IF NOT EXISTS idx_chunks_document ON chunks(document_id,ordinal);
CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(chunk_id UNINDEXED, document_id UNINDEXED, title, text, tokenize='unicode61 remove_diacritics 2');
CREATE TABLE IF NOT EXISTS entities(id TEXT PRIMARY KEY,type TEXT NOT NULL,name TEXT NOT NULL,normalized_name TEXT NOT NULL,metadata_json TEXT DEFAULT '{}',created_at TEXT NOT NULL,updated_at TEXT NOT NULL);
CREATE UNIQUE INDEX IF NOT EXISTS idx_entities_type_name ON entities(type,normalized_name);
CREATE TABLE IF NOT EXISTS document_entities(document_id TEXT NOT NULL,entity_id TEXT NOT NULL,relation TEXT NOT NULL,source_anchor TEXT,confidence REAL NOT NULL,PRIMARY KEY(document_id,entity_id,relation));
CREATE INDEX IF NOT EXISTS idx_document_entities_entity ON document_entities(entity_id);
CREATE TABLE IF NOT EXISTS structured_records(id TEXT PRIMARY KEY,domain TEXT NOT NULL,record_type TEXT NOT NULL,entity_key TEXT NOT NULL,data_json TEXT NOT NULL,source_document_id TEXT,authority TEXT NOT NULL,confidence REAL NOT NULL,observed_at TEXT,created_at TEXT NOT NULL,updated_at TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS idx_records_domain_key ON structured_records(domain,entity_key,observed_at);
CREATE TABLE IF NOT EXISTS medical_observations(id TEXT PRIMARY KEY,observation_type TEXT NOT NULL,value REAL NOT NULL,unit TEXT,observed_at TEXT,source_document_id TEXT NOT NULL,source_anchor TEXT,extraction_method TEXT NOT NULL,confidence REAL NOT NULL,verified INTEGER NOT NULL DEFAULT 0,created_at TEXT NOT NULL,FOREIGN KEY(source_document_id) REFERENCES documents(id) ON DELETE CASCADE);
CREATE INDEX IF NOT EXISTS idx_medical_type_date ON medical_observations(observation_type,observed_at);
CREATE TABLE IF NOT EXISTS memory_profiles(domain TEXT PRIMARY KEY,profile_json TEXT NOT NULL,evidence_json TEXT NOT NULL,generated_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS mutations(id TEXT PRIMARY KEY,actor TEXT NOT NULL,action TEXT NOT NULL,source TEXT NOT NULL,uri TEXT NOT NULL,before_json TEXT,after_json TEXT,timestamp TEXT NOT NULL,reason TEXT,reversible INTEGER NOT NULL,undone_at TEXT);
CREATE TABLE IF NOT EXISTS corrections(id TEXT PRIMARY KEY,target_id TEXT NOT NULL,field TEXT NOT NULL,old_value TEXT,new_value TEXT NOT NULL,reason TEXT,created_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS sync_state(source_id TEXT PRIMARY KEY,cursor TEXT,last_scan_at TEXT,last_error TEXT,stats_json TEXT DEFAULT '{}');
CREATE TABLE IF NOT EXISTS collections(id TEXT PRIMARY KEY,name TEXT NOT NULL UNIQUE,description TEXT,created_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS document_collections(document_id TEXT NOT NULL,collection_id TEXT NOT NULL,PRIMARY KEY(document_id,collection_id));
`);
    for(const sql of ["ALTER TABLE chunks ADD COLUMN embedding_provider TEXT","ALTER TABLE chunks ADD COLUMN embedding_dim INTEGER"]){try{this.db.exec(sql);}catch{}}
  }
  close() { this.db?.close(); }
}
