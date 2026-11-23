use pks_core::{EmbeddedDocumentRequest, FinalizeSourceRequest, PksHandle, SearchRequest};
use rusqlite::{Connection, params};
use std::fs;

fn document(uri: &str, title: &str, text: Option<&str>) -> EmbeddedDocumentRequest {
    EmbeddedDocumentRequest {
        contract_version: Some(1),
        source_id: "library".into(),
        source_type: "local".into(),
        source_name: Some("Library".into()),
        root_uri: Some("/library".into()),
        uri: uri.into(),
        title: title.into(),
        text: text.map(str::to_string),
        created_at: Some("2026-11-23T00:00:00Z".into()),
        modified_at: Some("2026-11-23T01:00:00Z".into()),
        document_type: Some("note".into()),
        tags: vec![],
        index_status: None,
    }
}

#[test]
fn embedded_index_is_searchable_incremental_and_deletes_unseen_documents() {
    let root = std::env::temp_dir().join(format!("pks-embedded-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    let path = root.join("knowledge.db");
    let mut core = PksHandle::open_embedded(&path).unwrap();

    let first = core
        .index_embedded_document(&document(
            "/library/Alpha.md",
            "Alpha",
            Some("# Alpha\nNative embedded search body"),
        ))
        .unwrap();
    assert!(first.changed);
    assert_eq!(first.index_status, "indexed");

    let second = core
        .index_embedded_document(&document(
            "/library/Beta.md",
            "Beta",
            Some("# Beta\nRelated search content"),
        ))
        .unwrap();
    assert!(second.changed);

    let search = core
        .search(&SearchRequest {
            contract_version: Some(1),
            query: "embedded search".into(),
            mode: Some("auto".into()),
            source: Some("library".into()),
            document_type: None,
            date_from: None,
            date_to: None,
            limit: Some(10),
            exclude_uri: None,
        })
        .unwrap();
    assert_eq!(search.results[0].title, "Alpha");
    assert!(
        search.results[0]
            .reasons
            .iter()
            .any(|reason| reason == "full_text")
    );

    let probe = Connection::open(&path).unwrap();
    let rowid_before: i64 = probe
        .query_row(
            "SELECT rowid FROM chunks WHERE document_id=?1",
            params![first.document_id],
            |row| row.get(0),
        )
        .unwrap();
    drop(probe);

    let unchanged = core
        .index_embedded_document(&document(
            "/library/Alpha.md",
            "Alpha",
            Some("# Alpha\nNative embedded search body"),
        ))
        .unwrap();
    assert!(!unchanged.changed);

    let probe = Connection::open(&path).unwrap();
    let rowid_after: i64 = probe
        .query_row(
            "SELECT rowid FROM chunks WHERE document_id=?1",
            params![unchanged.document_id],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(
        rowid_after, rowid_before,
        "unchanged content must not rebuild chunks"
    );
    drop(probe);

    let renamed = core
        .index_embedded_document(&document(
            "/library/Alpha.md",
            "Alpha Renamed",
            Some("# Alpha\nNative embedded search body"),
        ))
        .unwrap();
    assert!(renamed.changed);
    let probe = Connection::open(&path).unwrap();
    let (renamed_rowid, fts_title): (i64, String) = probe
        .query_row(
            "SELECT c.rowid,f.title FROM chunks c JOIN chunks_fts f ON f.chunk_id=c.id WHERE c.document_id=?1",
            params![renamed.document_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_ne!(
        renamed_rowid, rowid_before,
        "title changes must refresh FTS"
    );
    assert_eq!(fts_title, "Alpha Renamed");
    drop(probe);

    let metadata = core
        .index_embedded_document(&document("/library/Manual.pdf", "Manual.pdf", None))
        .unwrap();
    assert_eq!(metadata.index_status, "metadata_only");
    let found = core
        .search(&SearchRequest {
            contract_version: Some(1),
            query: "Manual PDF".into(),
            mode: Some("metadata".into()),
            source: Some("library".into()),
            document_type: None,
            date_from: None,
            date_to: None,
            limit: Some(10),
            exclude_uri: None,
        })
        .unwrap();
    assert_eq!(
        found.results[0].index_status.as_deref(),
        Some("metadata_only")
    );

    let finalized = core
        .finalize_embedded_source(&FinalizeSourceRequest {
            contract_version: Some(1),
            source_id: "library".into(),
            seen_uris: vec!["/library/Alpha.md".into(), "/library/Manual.pdf".into()],
        })
        .unwrap();
    assert_eq!(finalized.deleted, 1);

    let beta = core
        .search(&SearchRequest {
            contract_version: Some(1),
            query: "Beta".into(),
            mode: Some("metadata".into()),
            source: Some("library".into()),
            document_type: None,
            date_from: None,
            date_to: None,
            limit: Some(10),
            exclude_uri: None,
        })
        .unwrap();
    assert!(beta.results.is_empty());

    drop(core);
    let _ = fs::remove_dir_all(root);
}
