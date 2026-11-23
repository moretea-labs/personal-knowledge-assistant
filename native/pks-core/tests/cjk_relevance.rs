use pks_core::{PksHandle, SearchRequest};
use rusqlite::{Connection, params};
use std::time::{SystemTime, UNIX_EPOCH};

#[test]
fn multi_phrase_chinese_search_recovers_substrings_and_ranks_close_evidence_first() {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let path = std::env::temp_dir().join(format!(
        "pks-cjk-relevance-{}-{nonce}.sqlite",
        std::process::id()
    ));
    let db = Connection::open(&path).unwrap();
    db.execute_batch(
        "CREATE TABLE documents (id TEXT PRIMARY KEY, title TEXT, uri TEXT, source_id TEXT,
           source_type TEXT, document_type TEXT, modified_at TEXT, index_status TEXT,
           tags_json TEXT, deleted_at TEXT);
         CREATE TABLE corrections (target_id TEXT, field TEXT, new_value TEXT);
         CREATE TABLE chunks (id TEXT PRIMARY KEY, document_id TEXT, text TEXT,
           page INTEGER, heading_path TEXT);
         CREATE VIRTUAL TABLE chunks_fts USING fts5(
           chunk_id UNINDEXED, document_id UNINDEXED, title, text
         );",
    )
    .unwrap();

    let spaced = format!(
        "龟背竹换盆记录。\n{}\n最后讨论浇水。",
        "背景资料和其他说明。".repeat(32)
    );
    let entries = [
        (
            "exact",
            "Z-exact.md",
            "龟背竹 浇水计划：换盆后观察土壤湿度。".to_string(),
        ),
        (
            "near",
            "B-nearby.md",
            "龟背竹换盆后需要减少浇水。".to_string(),
        ),
        ("far", "A-scattered.md", spaced),
        (
            "other",
            "unrelated.md",
            "龟背竹换盆后需要观察光照。".to_string(),
        ),
    ];
    for (id, file, content) in &entries {
        let uri = format!("/synthetic/{file}");
        let chunk_id = format!("{id}-chunk");
        db.execute(
            "INSERT INTO documents VALUES (?1, 'Garden', ?2, 'garden', 'local', 'note', '2026-01-01', 'indexed', '[]', NULL)",
            params![id, uri],
        ).unwrap();
        db.execute(
            "INSERT INTO chunks (id, document_id, text) VALUES (?1, ?2, ?3)",
            params![chunk_id, id, content],
        )
        .unwrap();
        db.execute(
            "INSERT INTO chunks_fts VALUES (?1, ?2, 'Garden', ?3)",
            params![chunk_id, id, content],
        )
        .unwrap();
    }
    drop(db);
    let core = PksHandle::open(&path).unwrap();

    for mode in ["fts", "auto"] {
        let response = core
            .search(&SearchRequest {
                contract_version: Some(1),
                query: "龟背竹 浇水".into(),
                mode: Some(mode.into()),
                source: None,
                document_type: None,
                date_from: None,
                date_to: None,
                limit: Some(10),
                exclude_uri: None,
            })
            .unwrap();
        let ids: Vec<_> = response
            .results
            .iter()
            .map(|item| item.document_id.as_str())
            .collect();
        assert_eq!(ids, ["exact", "near", "far"], "mode={mode}");
        assert!(
            response.results[0].score > response.results[1].score,
            "mode={mode}"
        );
        assert!(
            response.results[1].score > response.results[2].score,
            "mode={mode}"
        );
        assert!(
            response
                .results
                .iter()
                .all(|r| r.snippet.contains("龟背竹")),
            "mode={mode}"
        );
    }
    drop(core);
    std::fs::remove_file(path).unwrap();
}
