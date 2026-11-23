use pks_core::{hash_embedding, PksHandle, SearchRequest};
use rusqlite::{params, Connection};
use serde_json::Value;
use std::path::Path;

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

#[test]
fn shared_golden_corpus_conforms_to_native_search_modes() {
    let corpus:Value=serde_json::from_str(include_str!("../../../tests/fixtures/search-golden-v1.json")).unwrap();
    let root=std::env::temp_dir().join(format!("pks-golden-native-{}",std::process::id()));
    let docs=root.join("docs");
    let managed=root.join("managed");
    std::fs::create_dir_all(&docs).unwrap();
    std::fs::create_dir_all(&managed).unwrap();
    let db_path=root.join("golden.sqlite");
    let db=Connection::open(&db_path).unwrap();
    db.execute_batch("CREATE TABLE documents(id TEXT PRIMARY KEY,title TEXT,uri TEXT,source_type TEXT,document_type TEXT,modified_at TEXT,index_status TEXT,deleted_at TEXT); CREATE TABLE chunks(id TEXT PRIMARY KEY,document_id TEXT,text TEXT,page INTEGER,heading_path TEXT,embedding_json TEXT,embedding_provider TEXT,embedding_dim INTEGER); CREATE VIRTUAL TABLE chunks_fts USING fts5(chunk_id UNINDEXED,document_id UNINDEXED,title,text);").unwrap();
    for (index,doc) in corpus["documents"].as_array().unwrap().iter().enumerate() {
        let id=doc["id"].as_str().unwrap();
        let source=doc["source"].as_str().unwrap();
        let title=doc["title"].as_str().unwrap();
        let file=doc["file"].as_str().unwrap();
        let raw=doc["content"].as_str().unwrap();
        let body=raw.lines().filter(|line|{
            let trimmed=line.trim_start();
            let count=trimmed.chars().take_while(|c|*c=='#').count();
            !(1..=6).contains(&count)||trimmed.chars().nth(count).is_none_or(|c|!c.is_whitespace())
        }).collect::<Vec<_>>().join("\\n").trim().to_string();
        let folder=if source=="managed" {&managed} else {&docs};
        let uri=folder.join(file);
        let uri=uri.to_string_lossy().to_string();
        let chunk_id=format!("{id}-chunk");
        let vector=hash_embedding(&body,128);
        db.execute("INSERT INTO documents VALUES(?1,?2,?3,?4,'note',?5,'indexed',NULL)",
            params![id,title,uri,source,format!("2026-01-{:02}",index+1)]).unwrap();
        db.execute("INSERT INTO chunks(id,document_id,text,embedding_json,embedding_provider,embedding_dim) VALUES(?1,?2,?3,?4,'hash-ngram-v1-128',128)",
            params![chunk_id,id,body,serde_json::to_string(&vector).unwrap()]).unwrap();
        db.execute("INSERT INTO chunks_fts VALUES(?1,?2,?3,?4)",params![chunk_id,id,title,body]).unwrap();
    }
    drop(db);
    let core=PksHandle::open(&db_path).unwrap();
    for scenario in corpus["queries"].as_array().unwrap() {
        let query=scenario["query"].as_str().unwrap();
        let mode=scenario["mode"].as_str().unwrap();
        let source=scenario.get("source").and_then(Value::as_str).map(str::to_string);
        let exclude_uri=scenario.get("excludeFile").and_then(Value::as_str).map(|file|docs.join(file).to_string_lossy().to_string());
        let result=core.search(&SearchRequest{contract_version:Some(1),query:query.into(),mode:Some(mode.into()),source,document_type:None,date_from:None,date_to:None,limit:Some(20),exclude_uri}).unwrap();
        let files=result.results.iter().map(|r|Path::new(&r.uri).file_name().unwrap().to_string_lossy().to_string()).collect::<Vec<_>>();
        if let Some(expected)=scenario.get("expectedFiles").and_then(Value::as_array) {
            let expected=expected.iter().map(|v|v.as_str().unwrap().to_string()).collect::<Vec<_>>();
            assert_eq!(files,expected,"golden case {}",scenario["id"]);
        }
        if let Some(prefix)=scenario.get("expectedPrefixFiles").and_then(Value::as_array) {
            let prefix=prefix.iter().map(|v|v.as_str().unwrap().to_string()).collect::<Vec<_>>();
            assert_eq!(&files[..prefix.len().min(files.len())],prefix.as_slice(),"golden ranking {}",scenario["id"]);
        }
        if let Some(expected)=scenario.get("expectedContainsFiles").and_then(Value::as_array) {
            for item in expected {
                let file=item.as_str().unwrap();
                assert!(files.iter().any(|candidate|candidate==file),
                    "golden candidates {} must include {}",scenario["id"],file);
            }
        }
        for reason in scenario["requiredReasons"].as_array().unwrap() {
            let reason=reason.as_str().unwrap();
            assert!(result.results.iter().any(|r|r.reasons.iter().any(|item|item==reason)),
                "golden case {} requires reason {}",scenario["id"],reason);
        }
    }
    drop(core);
    let _=std::fs::remove_dir_all(root);
}
