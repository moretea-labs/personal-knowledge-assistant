use pks_core::{PksHandle, SearchRequest};
use rusqlite::{params, Connection};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

const QUERY: &str = "龟背竹 浇水";
const RESULT_LIMIT: usize = 20;
const WARMUP_RUNS: usize = 3;
const MEASURED_RUNS: usize = 25;

fn synthetic_database(document_count: usize) -> std::path::PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let path = std::env::temp_dir().join(format!(
        "pks-cjk-scale-{}-{document_count}-{nonce}.sqlite",
        std::process::id()
    ));

    let mut db = Connection::open(&path).unwrap();
    db.execute_batch(
        "PRAGMA journal_mode=OFF;
         PRAGMA synchronous=OFF;
         CREATE TABLE documents (
           id TEXT PRIMARY KEY, title TEXT, uri TEXT, source_id TEXT,
           source_type TEXT, document_type TEXT, modified_at TEXT,
           index_status TEXT, tags_json TEXT, deleted_at TEXT
         );
         CREATE TABLE corrections (target_id TEXT, field TEXT, new_value TEXT);
         CREATE TABLE chunks (
           id TEXT PRIMARY KEY, document_id TEXT, text TEXT, page INTEGER,
           heading_path TEXT, embedding_json TEXT, embedding_provider TEXT,
           embedding_dim INTEGER
         );
         CREATE VIRTUAL TABLE chunks_fts USING fts5(
           chunk_id UNINDEXED, document_id UNINDEXED, title, text
         );",
    )
    .unwrap();

    let tx = db.transaction().unwrap();
    {
        let mut document = tx
            .prepare(
                "INSERT INTO documents VALUES (
                   ?1, ?2, ?3, 'garden', 'local', 'note',
                   '2026-01-01', 'indexed', '[]', NULL
                 )",
            )
            .unwrap();
        let mut chunk = tx
            .prepare(
                "INSERT INTO chunks (id, document_id, text)
                 VALUES (?1, ?2, ?3)",
            )
            .unwrap();
        let mut fts = tx
            .prepare("INSERT INTO chunks_fts VALUES (?1, ?2, ?3, ?4)")
            .unwrap();

        for index in 0..document_count {
            let id = format!("doc-{index:05}");
            let title = format!("Garden note {index:05}");
            let uri = format!("/synthetic/garden/{index:05}.md");
            let chunk_id = format!("{id}-chunk");
            let body = if index == 0 {
                "龟背竹 浇水计划：换盆后观察土壤湿度。"
            } else if index < RESULT_LIMIT {
                // Continuous Han text is one unicode61 token; the query's two
                // phrases are recovered by the bounded literal-substring pass.
                "龟背竹换盆后需要减少浇水，持续观察土壤湿度。"
            } else if index % 2 == 0 {
                "龟背竹换盆后观察光照和叶片。"
            } else {
                "绿萝浇水后观察土壤湿度。"
            };

            document.execute(params![id, title, uri]).unwrap();
            chunk.execute(params![chunk_id, id, body]).unwrap();
            fts.execute(params![chunk_id, id, title, body]).unwrap();
        }
    }
    let fts_matches: i64 = tx
        .query_row(
            "SELECT COUNT(*) FROM chunks_fts WHERE chunks_fts MATCH ?1",
            params!["\"龟背竹\" OR \"浇水\""],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(
        fts_matches, 1,
        "the fixture must exercise the literal-substring fallback"
    );
    tx.commit().unwrap();
    drop(db);

    path
}

fn percentile(sorted: &[f64], percentile: usize) -> f64 {
    let rank = (sorted.len() * percentile).div_ceil(100).max(1);
    sorted[rank - 1]
}

fn measure(core: &PksHandle, mode: &str, document_count: usize) {
    let request = SearchRequest {
        contract_version: Some(1),
        query: QUERY.into(),
        mode: Some(mode.into()),
        source: None,
        document_type: None,
        date_from: None,
        date_to: None,
        limit: Some(RESULT_LIMIT),
        exclude_uri: None,
    };

    for _ in 0..WARMUP_RUNS {
        let response = core.search(&request).unwrap();
        assert_eq!(response.results.len(), RESULT_LIMIT);
    }

    let mut samples = Vec::with_capacity(MEASURED_RUNS);
    for _ in 0..MEASURED_RUNS {
        let started = Instant::now();
        let response = core.search(&request).unwrap();
        samples.push(started.elapsed().as_secs_f64() * 1_000.0);

        assert_eq!(response.results.len(), RESULT_LIMIT);
        assert!(response
            .results
            .iter()
            .any(|hit| hit.document_id == "doc-00001"));
        assert!(response.results.iter().all(|hit| {
            hit.snippet.contains("龟背竹")
                && (hit.reasons.iter().any(|reason| reason == "full_text")
                    || hit
                        .reasons
                        .iter()
                        .any(|reason| reason == "literal_substring"))
        }));
    }

    samples.sort_by(f64::total_cmp);
    println!(
        "CJK_SCALE_BENCHMARK documents={document_count} mode={mode} \
         runs={MEASURED_RUNS} p50_ms={:.3} p95_ms={:.3} max_ms={:.3}",
        percentile(&samples, 50),
        percentile(&samples, 95),
        samples[samples.len() - 1]
    );
}

#[test]
#[ignore = "manual synthetic scale benchmark; run with --ignored --nocapture"]
fn cjk_fallback_latency_at_ten_and_fifty_thousand_documents() {
    for document_count in [10_000, 50_000] {
        let path = synthetic_database(document_count);
        let database_bytes = std::fs::metadata(&path).unwrap().len();
        let core = PksHandle::open(&path).unwrap();

        for mode in ["fts", "auto"] {
            measure(&core, mode, document_count);
        }

        drop(core);
        std::fs::remove_file(&path).unwrap();
        println!("CJK_SCALE_DATABASE documents={document_count} bytes={database_bytes}");
    }
}
