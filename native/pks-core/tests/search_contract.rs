use pks_core::{PksHandle,SearchRequest};
use rusqlite::Connection;

#[test]
fn opens_database_read_only_and_returns_versioned_contract() {
    let path=std::env::temp_dir().join(format!("pks-core-{}.sqlite",std::process::id()));
    let _=std::fs::remove_file(&path);
    let db=Connection::open(&path).unwrap();
    db.execute_batch("CREATE TABLE documents(id TEXT PRIMARY KEY,title TEXT,uri TEXT,source_type TEXT,document_type TEXT,modified_at TEXT,index_status TEXT,deleted_at TEXT); CREATE TABLE chunks(id TEXT PRIMARY KEY,document_id TEXT,text TEXT,page INTEGER,heading_path TEXT); CREATE VIRTUAL TABLE chunks_fts USING fts5(chunk_id UNINDEXED,document_id UNINDEXED,title,text); INSERT INTO documents VALUES('d','Alpha','/alpha.md','local','note','2026-01-01','indexed',NULL); INSERT INTO chunks VALUES('c','d','alpha searchable body',NULL,NULL); INSERT INTO chunks_fts VALUES('c','d','Alpha','alpha searchable body');").unwrap();
    drop(db);
    let core=PksHandle::open(&path).unwrap();
    let result=core.search(&SearchRequest{contract_version:Some(1),query:"alpha".into(),mode:Some("auto".into()),source:None,document_type:None,date_from:None,date_to:None,limit:Some(10),exclude_uri:None}).unwrap();
    assert_eq!(result.contract_version,1);
    assert_eq!(result.results[0].document_id,"d");
    drop(core);
    let _=std::fs::remove_file(&path);
}
