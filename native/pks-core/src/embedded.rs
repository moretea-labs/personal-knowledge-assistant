use crate::{CONTRACT_VERSION, PksHandle, hash_embedding};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::HashSet,
    ffi::{CStr, CString, c_char},
    path::Path,
    ptr,
    time::Duration,
};

const EMBEDDING_DIMENSIONS: usize = 256;
const CHUNK_MAX_CHARS: usize = 1_800;
const CHUNK_OVERLAP_CHARS: usize = 180;

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EmbeddedDocumentRequest {
    pub contract_version: Option<u32>,
    pub source_id: String,
    #[serde(default = "default_source_type")]
    pub source_type: String,
    pub source_name: Option<String>,
    pub root_uri: Option<String>,
    pub uri: String,
    pub title: String,
    pub text: Option<String>,
    pub created_at: Option<String>,
    pub modified_at: Option<String>,
    pub document_type: Option<String>,
    #[serde(default)]
    pub tags: Vec<String>,
    pub index_status: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FinalizeSourceRequest {
    pub contract_version: Option<u32>,
    pub source_id: String,
    #[serde(default)]
    pub seen_uris: Vec<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EmbeddedIndexResponse {
    pub contract_version: u32,
    pub document_id: String,
    pub changed: bool,
    pub index_status: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FinalizeSourceResponse {
    pub contract_version: u32,
    pub source_id: String,
    pub deleted: usize,
}

#[derive(Debug)]
struct Chunk {
    ordinal: usize,
    text: String,
    start_offset: usize,
    end_offset: usize,
    heading_path: Option<String>,
}

fn default_source_type() -> String {
    "local".to_string()
}

fn validate_contract(version: Option<u32>) -> rusqlite::Result<()> {
    if version.unwrap_or(CONTRACT_VERSION) == CONTRACT_VERSION {
        Ok(())
    } else {
        Err(rusqlite::Error::InvalidParameterName(
            "unsupported contractVersion".into(),
        ))
    }
}

fn digest_hex(value: &str) -> String {
    hex::encode(Sha256::digest(value.as_bytes()))
}

fn stable_id(prefix: &str, value: &str) -> String {
    format!("{prefix}_{}", &digest_hex(value)[..24])
}

fn database_now(db: &Connection) -> rusqlite::Result<String> {
    db.query_row("SELECT strftime('%Y-%m-%dT%H:%M:%fZ','now')", [], |row| {
        row.get(0)
    })
}

fn heading_level(line: &str) -> Option<(usize, &str)> {
    let trimmed = line.trim_start();
    let hashes = trimmed.chars().take_while(|c| *c == '#').count();
    if !(1..=6).contains(&hashes) {
        return None;
    }
    let rest = trimmed.get(hashes..)?;
    if !rest.starts_with(char::is_whitespace) {
        return None;
    }
    Some((hashes, rest.trim()))
}

fn sections(text: &str) -> Vec<(Option<String>, String)> {
    let mut result = Vec::new();
    let mut headings: Vec<String> = Vec::new();
    let mut current_heading: Option<String> = None;
    let mut buffer: Vec<&str> = Vec::new();

    let flush = |result: &mut Vec<(Option<String>, String)>,
                 heading: &Option<String>,
                 buffer: &mut Vec<&str>| {
        let body = buffer.join("\n");
        let body = body.trim();
        if !body.is_empty() {
            result.push((heading.clone(), body.to_string()));
        }
        buffer.clear();
    };

    for line in text.lines() {
        if let Some((level, title)) = heading_level(line) {
            flush(&mut result, &current_heading, &mut buffer);
            headings.truncate(level.saturating_sub(1));
            while headings.len() < level.saturating_sub(1) {
                headings.push(String::new());
            }
            if headings.len() == level.saturating_sub(1) {
                headings.push(title.to_string());
            } else {
                headings[level - 1] = title.to_string();
            }
            current_heading = Some(
                headings
                    .iter()
                    .filter(|part| !part.is_empty())
                    .cloned()
                    .collect::<Vec<_>>()
                    .join(" > "),
            );
        } else {
            buffer.push(line);
        }
    }
    flush(&mut result, &current_heading, &mut buffer);
    if result.is_empty() && !text.trim().is_empty() {
        result.push((None, text.trim().to_string()));
    }
    result
}

fn chunks(text: &str) -> Vec<Chunk> {
    let mut result = Vec::new();
    let mut ordinal = 0usize;
    let mut source_offset = 0usize;

    for (heading_path, section) in sections(text) {
        let chars = section.chars().collect::<Vec<_>>();
        let mut start = 0usize;
        while start < chars.len() {
            let end = (start + CHUNK_MAX_CHARS).min(chars.len());
            let part = chars[start..end]
                .iter()
                .collect::<String>()
                .trim()
                .to_string();
            if !part.is_empty() {
                result.push(Chunk {
                    ordinal,
                    text: part,
                    start_offset: source_offset + start,
                    end_offset: source_offset + end,
                    heading_path: heading_path.clone(),
                });
                ordinal += 1;
            }
            if end == chars.len() {
                break;
            }
            start += CHUNK_MAX_CHARS - CHUNK_OVERLAP_CHARS;
        }
        source_offset += chars.len() + 1;
    }
    result
}

fn migrate(db: &Connection) -> rusqlite::Result<()> {
    db.execute_batch(
        r#"
CREATE TABLE IF NOT EXISTS sources(
  id TEXT PRIMARY KEY,type TEXT NOT NULL,name TEXT NOT NULL,root_uri TEXT NOT NULL,
  config_json TEXT NOT NULL DEFAULT '{}',enabled INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL,updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS documents(
  id TEXT PRIMARY KEY,source_id TEXT NOT NULL,source_type TEXT NOT NULL,
  uri TEXT NOT NULL UNIQUE,canonical_uri TEXT NOT NULL,title TEXT NOT NULL,
  mime_type TEXT,created_at TEXT,modified_at TEXT,content_hash TEXT,size INTEGER,
  language TEXT,document_type TEXT,sensitivity TEXT DEFAULT 'normal',
  tags_json TEXT DEFAULT '[]',index_status TEXT NOT NULL DEFAULT 'pending',
  last_indexed_at TEXT,deleted_at TEXT,metadata_json TEXT DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS idx_documents_source ON documents(source_id,deleted_at);
CREATE INDEX IF NOT EXISTS idx_documents_type_date ON documents(document_type,modified_at);
CREATE TABLE IF NOT EXISTS chunks(
  id TEXT PRIMARY KEY,document_id TEXT NOT NULL,ordinal INTEGER NOT NULL,
  text TEXT NOT NULL,start_offset INTEGER,end_offset INTEGER,page INTEGER,
  heading_path TEXT,embedding_json TEXT,embedding_provider TEXT,
  embedding_dim INTEGER,content_hash TEXT NOT NULL,
  FOREIGN KEY(document_id) REFERENCES documents(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_chunks_document ON chunks(document_id,ordinal);
CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
  chunk_id UNINDEXED,document_id UNINDEXED,title,text,tokenize='unicode61'
);
CREATE TABLE IF NOT EXISTS corrections(
  id TEXT PRIMARY KEY,target_id TEXT NOT NULL,field TEXT NOT NULL,
  old_value TEXT,new_value TEXT NOT NULL,reason TEXT,created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS medical_observations(
  id TEXT PRIMARY KEY,observation_type TEXT NOT NULL,value REAL NOT NULL,
  unit TEXT,observed_at TEXT,source_document_id TEXT NOT NULL,source_anchor TEXT,
  extraction_method TEXT NOT NULL,confidence REAL NOT NULL,
  verified INTEGER NOT NULL DEFAULT 0,created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS structured_records(
  id TEXT PRIMARY KEY,domain TEXT NOT NULL,record_type TEXT NOT NULL,
  entity_key TEXT NOT NULL,data_json TEXT NOT NULL,source_document_id TEXT,
  authority TEXT NOT NULL,confidence REAL NOT NULL,observed_at TEXT,
  created_at TEXT NOT NULL,updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS sync_state(
  source_id TEXT PRIMARY KEY,cursor TEXT,last_scan_at TEXT,last_error TEXT,
  stats_json TEXT DEFAULT '{}'
);
"#,
    )
}

impl PksHandle {
    pub fn open_embedded(path: impl AsRef<Path>) -> rusqlite::Result<Self> {
        if let Some(parent) = path.as_ref().parent() {
            std::fs::create_dir_all(parent)
                .map_err(|error| rusqlite::Error::ToSqlConversionFailure(Box::new(error)))?;
        }
        let db = Connection::open(path)?;
        db.busy_timeout(Duration::from_secs(5))?;
        db.execute_batch(
            "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON; PRAGMA temp_store=MEMORY;",
        )?;
        migrate(&db)?;
        Ok(Self { db })
    }

    pub fn index_embedded_document(
        &mut self,
        request: &EmbeddedDocumentRequest,
    ) -> rusqlite::Result<EmbeddedIndexResponse> {
        validate_contract(request.contract_version)?;
        let now = database_now(&self.db)?;
        let status = request.index_status.clone().unwrap_or_else(|| {
            if request.text.is_some() {
                "indexed"
            } else {
                "metadata_only"
            }
            .to_string()
        });
        if !matches!(status.as_str(), "indexed" | "metadata_only" | "deferred") {
            return Err(rusqlite::Error::InvalidParameterName(
                "unsupported indexStatus".into(),
            ));
        }

        let content_hash = request.text.as_deref().map(digest_hex);
        let document_id = stable_id("doc", &request.uri);
        let existing: Option<(Option<String>, String, String, Option<String>)> = self
            .db
            .query_row(
                "SELECT content_hash,title,index_status,deleted_at FROM documents WHERE id=?1",
                params![document_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .optional()?;
        let requires_reindex = match existing.as_ref() {
            None => true,
            Some((existing_hash, existing_title, existing_status, deleted_at)) => {
                existing_hash != &content_hash
                    || existing_title != &request.title
                    || existing_status != &status
                    || deleted_at.is_some()
            }
        };
        let changed = requires_reindex;

        let source_name = request.source_name.as_deref().unwrap_or(&request.source_id);
        let root_uri = request.root_uri.as_deref().unwrap_or(&request.uri);
        let created_at = request.created_at.as_deref().unwrap_or(&now);
        let modified_at = request.modified_at.as_deref().unwrap_or(&now);
        let document_type = request.document_type.as_deref().unwrap_or("generic");
        let tags_json = serde_json::to_string(&request.tags)
            .map_err(|error| rusqlite::Error::ToSqlConversionFailure(Box::new(error)))?;

        let prepared = if requires_reindex {
            request
                .text
                .as_deref()
                .filter(|_| status == "indexed")
                .map(chunks)
                .unwrap_or_default()
        } else {
            Vec::new()
        };

        let tx = self
            .db
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        tx.execute(
            "INSERT INTO sources(id,type,name,root_uri,enabled,created_at,updated_at)
             VALUES(?1,?2,?3,?4,1,?5,?5)
             ON CONFLICT(id) DO UPDATE SET type=excluded.type,name=excluded.name,
               root_uri=excluded.root_uri,enabled=1,updated_at=excluded.updated_at",
            params![
                request.source_id,
                request.source_type,
                source_name,
                root_uri,
                now
            ],
        )?;
        tx.execute(
            "INSERT INTO documents(
               id,source_id,source_type,uri,canonical_uri,title,mime_type,
               created_at,modified_at,content_hash,size,document_type,tags_json,
               index_status,last_indexed_at,metadata_json,deleted_at
             ) VALUES(?1,?2,?3,?4,?4,?5,'application/octet-stream',?6,?7,?8,?9,?10,?11,?12,?13,'{}',NULL)
             ON CONFLICT(id) DO UPDATE SET
               source_id=excluded.source_id,source_type=excluded.source_type,
               uri=excluded.uri,canonical_uri=excluded.canonical_uri,title=excluded.title,
               modified_at=excluded.modified_at,content_hash=excluded.content_hash,
               size=excluded.size,document_type=excluded.document_type,tags_json=excluded.tags_json,
               index_status=excluded.index_status,last_indexed_at=excluded.last_indexed_at,
               deleted_at=NULL",
            params![
                document_id,
                request.source_id,
                request.source_type,
                request.uri,
                request.title,
                created_at,
                modified_at,
                content_hash,
                request.text.as_ref().map(|text| text.len() as i64),
                document_type,
                tags_json,
                status,
                now
            ],
        )?;
        if requires_reindex {
            tx.execute(
                "DELETE FROM chunks_fts WHERE document_id=?1",
                params![document_id],
            )?;
            tx.execute(
                "DELETE FROM chunks WHERE document_id=?1",
                params![document_id],
            )?;

            for chunk in prepared {
                let chunk_hash = digest_hex(&chunk.text);
                let chunk_id = stable_id(
                    "chk",
                    &format!("{}:{}:{}", document_id, chunk.ordinal, chunk_hash),
                );
                let embedding = hash_embedding(&chunk.text, EMBEDDING_DIMENSIONS);
                let embedding_json = serde_json::to_string(&embedding)
                    .map_err(|error| rusqlite::Error::ToSqlConversionFailure(Box::new(error)))?;
                tx.execute(
                    "INSERT INTO chunks(
                       id,document_id,ordinal,text,start_offset,end_offset,page,heading_path,
                       embedding_json,embedding_provider,embedding_dim,content_hash
                     ) VALUES(?1,?2,?3,?4,?5,?6,NULL,?7,?8,?9,?10,?11)",
                    params![
                        chunk_id,
                        document_id,
                        chunk.ordinal as i64,
                        chunk.text,
                        chunk.start_offset as i64,
                        chunk.end_offset as i64,
                        chunk.heading_path,
                        embedding_json,
                        format!("hash-ngram-v1-{EMBEDDING_DIMENSIONS}"),
                        EMBEDDING_DIMENSIONS as i64,
                        chunk_hash
                    ],
                )?;
                tx.execute(
                    "INSERT INTO chunks_fts(chunk_id,document_id,title,text) VALUES(?1,?2,?3,?4)",
                    params![chunk_id, document_id, request.title, chunk.text],
                )?;
            }
        }
        tx.commit()?;

        Ok(EmbeddedIndexResponse {
            contract_version: CONTRACT_VERSION,
            document_id,
            changed,
            index_status: status,
        })
    }

    pub fn finalize_embedded_source(
        &mut self,
        request: &FinalizeSourceRequest,
    ) -> rusqlite::Result<FinalizeSourceResponse> {
        validate_contract(request.contract_version)?;
        let seen = request.seen_uris.iter().cloned().collect::<HashSet<_>>();
        let now = database_now(&self.db)?;
        let candidates = {
            let mut stmt = self.db.prepare(
                "SELECT id,uri FROM documents WHERE source_id=?1 AND deleted_at IS NULL",
            )?;
            stmt.query_map(params![request.source_id], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?
        };
        let tx = self
            .db
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let mut deleted = 0usize;
        for (id, uri) in candidates {
            if !seen.contains(&uri) {
                deleted += tx.execute(
                    "UPDATE documents SET deleted_at=?2,index_status='deleted' WHERE id=?1",
                    params![id, now],
                )?;
            }
        }
        tx.execute(
            "INSERT INTO sync_state(source_id,last_scan_at,stats_json,last_error)
             VALUES(?1,?2,?3,NULL)
             ON CONFLICT(source_id) DO UPDATE SET
               last_scan_at=excluded.last_scan_at,stats_json=excluded.stats_json,last_error=NULL",
            params![
                request.source_id,
                now,
                serde_json::json!({"seen": seen.len(), "deleted": deleted}).to_string()
            ],
        )?;
        tx.commit()?;
        Ok(FinalizeSourceResponse {
            contract_version: CONTRACT_VERSION,
            source_id: request.source_id.clone(),
            deleted,
        })
    }
}

fn json_result<T: Serialize>(value: rusqlite::Result<T>) -> *mut c_char {
    value
        .ok()
        .and_then(|result| serde_json::to_string(&result).ok())
        .and_then(|json| CString::new(json).ok())
        .map_or(ptr::null_mut(), CString::into_raw)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pks_open_embedded(path: *const c_char) -> *mut PksHandle {
    if path.is_null() {
        return ptr::null_mut();
    }
    let path = unsafe { CStr::from_ptr(path) }.to_string_lossy();
    match PksHandle::open_embedded(path.as_ref()) {
        Ok(handle) => Box::into_raw(Box::new(handle)),
        Err(_) => ptr::null_mut(),
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pks_index_document_json(
    handle: *mut PksHandle,
    request_json: *const c_char,
) -> *mut c_char {
    if handle.is_null() || request_json.is_null() {
        return ptr::null_mut();
    }
    let input = unsafe { CStr::from_ptr(request_json) }.to_string_lossy();
    let request: EmbeddedDocumentRequest = match serde_json::from_str(&input) {
        Ok(request) => request,
        Err(_) => return ptr::null_mut(),
    };
    json_result(unsafe { &mut *handle }.index_embedded_document(&request))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pks_finalize_source_json(
    handle: *mut PksHandle,
    request_json: *const c_char,
) -> *mut c_char {
    if handle.is_null() || request_json.is_null() {
        return ptr::null_mut();
    }
    let input = unsafe { CStr::from_ptr(request_json) }.to_string_lossy();
    let request: FinalizeSourceRequest = match serde_json::from_str(&input) {
        Ok(request) => request,
        Err(_) => return ptr::null_mut(),
    };
    json_result(unsafe { &mut *handle }.finalize_embedded_source(&request))
}
