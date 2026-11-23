use rusqlite::{Connection, OpenFlags, params};
use serde::{Deserialize, Serialize};
use std::{ffi::{CStr, CString, c_char}, path::Path, ptr};

pub const CONTRACT_VERSION: u32 = 1;

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchRequest {
    pub contract_version: Option<u32>,
    pub query: String,
    pub mode: Option<String>,
    pub source: Option<String>,
    pub document_type: Option<String>,
    pub date_from: Option<String>,
    pub date_to: Option<String>,
    pub limit: Option<usize>,
    pub exclude_uri: Option<String>,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SearchResult {
    pub document_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub chunk_id: Option<String>,
    pub title: String,
    pub uri: String,
    pub source_type: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub document_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub modified_at: Option<String>,
    pub snippet: String,
    pub score: f64,
    pub reasons: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub page: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub heading_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub index_status: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchResponse {
    pub contract_version: u32,
    pub results: Vec<SearchResult>,
}

pub struct PksHandle { db: Connection }

impl PksHandle {
    pub fn open(path: impl AsRef<Path>) -> rusqlite::Result<Self> {
        let db = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX)?;
        db.busy_timeout(std::time::Duration::from_secs(2))?;
        db.pragma_update(None, "query_only", "ON")?;
        Ok(Self { db })
    }

    pub fn search(&self, request: &SearchRequest) -> rusqlite::Result<SearchResponse> {
        if request.contract_version.unwrap_or(CONTRACT_VERSION) != CONTRACT_VERSION {
            return Err(rusqlite::Error::InvalidParameterName("unsupported contractVersion".into()));
        }
        let limit = request.limit.unwrap_or(12).clamp(1, 50);
        let mode = request.mode.as_deref().unwrap_or("auto");
        let mut results = match mode {
            "metadata" => self.metadata(request, limit)?,
            "fts" => self.fts(request, limit)?,
            "auto" => self.auto(request, limit)?,
            // These modes are deliberately explicit until their parity port is complete.
            "semantic" | "related" | "structured" => Vec::new(),
            _ => return Err(rusqlite::Error::InvalidParameterName("unsupported search mode".into())),
        };
        results.truncate(limit);
        Ok(SearchResponse { contract_version: CONTRACT_VERSION, results })
    }

    fn metadata(&self, req: &SearchRequest, limit: usize) -> rusqlite::Result<Vec<SearchResult>> {
        let needle = normalize(&req.query);
        if needle.is_empty() { return Ok(Vec::new()); }
        let mut stmt = self.db.prepare("SELECT id,title,uri,source_type,document_type,modified_at,index_status FROM documents WHERE deleted_at IS NULL ORDER BY title COLLATE NOCASE")?;
        let rows = stmt.query_map([], |r| Ok((
            r.get::<_,String>(0)?, r.get::<_,String>(1)?, r.get::<_,String>(2)?,
            r.get::<_,String>(3)?, r.get::<_,Option<String>>(4)?, r.get::<_,Option<String>>(5)?, r.get::<_,Option<String>>(6)?
        )))?;
        let mut out = Vec::new();
        for row in rows {
            let (id,title,uri,source_type,document_type,modified_at,index_status) = row?;
            if !matches_filters(req, &source_type, document_type.as_deref(), modified_at.as_deref()) { continue; }
            let title_key=normalize(&title); let path_key=normalize(&uri);
            let (score,reason)=if title_key==needle {(0.99,"metadata")}
                else if title_key.starts_with(&needle) {(0.975,"metadata")}
                else if title_key.contains(&needle) {(0.96,"metadata")}
                else if path_key.contains(&needle) {(0.88,"metadata")}
                else {continue};
            out.push(SearchResult { document_id:id,chunk_id:None,title,uri,source_type,document_type,modified_at,
                snippet:index_status.as_deref().unwrap_or("indexed").to_string(),score,reasons:vec![reason.into()],
                page:None,heading_path:None,index_status });
        }
        out.sort_by(|a,b| b.score.total_cmp(&a.score).then_with(||a.title.cmp(&b.title)));
        out.truncate(limit); Ok(out)
    }

    fn fts(&self, req: &SearchRequest, limit: usize) -> rusqlite::Result<Vec<SearchResult>> {
        let terms = tokens(&req.query);
        if terms.is_empty() { return Ok(Vec::new()); }
        let match_expr = terms.iter().map(|t| format!("\"{}\"", t.replace('"', ""))).collect::<Vec<_>>().join(" OR ");
        let mut stmt = self.db.prepare("SELECT d.id,c.id,d.title,d.uri,d.source_type,d.document_type,d.modified_at,c.text,c.page,c.heading_path,d.index_status,bm25(chunks_fts) AS rank FROM chunks_fts JOIN chunks c ON c.id=chunks_fts.chunk_id JOIN documents d ON d.id=c.document_id WHERE chunks_fts MATCH ?1 AND d.deleted_at IS NULL ORDER BY rank LIMIT ?2")?;
        let rows = stmt.query_map(params![match_expr, (limit*4).min(200) as i64], |r| Ok((
            r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,String>(2)?,r.get::<_,String>(3)?,r.get::<_,String>(4)?,
            r.get::<_,Option<String>>(5)?,r.get::<_,Option<String>>(6)?,r.get::<_,String>(7)?,r.get::<_,Option<i64>>(8)?,
            r.get::<_,Option<String>>(9)?,r.get::<_,Option<String>>(10)?
        )))?;
        let mut out=Vec::new();
        for row in rows {
            let (document_id,chunk_id,title,uri,source_type,document_type,modified_at,text,page,heading_path,index_status)=row?;
            if req.exclude_uri.as_deref()==Some(uri.as_str()) || !matches_filters(req,&source_type,document_type.as_deref(),modified_at.as_deref()) {continue;}
            let evidence=normalize(&text);
            let matched=terms.iter().filter(|t|evidence.contains(&normalize(t))).count();
            let minimum=if terms.len()==1 {1} else {2.max((terms.len()+1)/2)};
            if matched<minimum {continue;}
            let snippet=make_snippet(&text,&req.query);
            let score=1.0/(1.0+out.len() as f64*0.08);
            out.push(SearchResult {document_id,chunk_id:Some(chunk_id),title,uri,source_type,document_type,modified_at,
                snippet,score,reasons:vec!["full_text".into()],page,heading_path,index_status});
        }
        Ok(out)
    }

    fn auto(&self, req: &SearchRequest, limit: usize) -> rusqlite::Result<Vec<SearchResult>> {
        let metadata=self.metadata(req, (limit*2).max(20))?;
        let fts=self.fts(req, (limit*3).max(20))?;
        let mut merged:Vec<SearchResult>=fts;
        for m in metadata {
            if let Some(hit)=merged.iter_mut().find(|r|r.document_id==m.document_id) {
                hit.score=hit.score.max(m.score);
                if !hit.reasons.iter().any(|x|x=="metadata") {hit.reasons.insert(0,"metadata".into());}
            } else { merged.push(m); }
        }
        merged.sort_by(|a,b| evidence_rank(a).cmp(&evidence_rank(b)).then_with(||b.score.total_cmp(&a.score)));
        merged.truncate(limit); Ok(merged)
    }
}

fn evidence_rank(r:&SearchResult)->u8 {
    if r.reasons.iter().any(|x|x=="verified_alias" || x=="metadata" && r.score>=0.88) {0}
    else if r.reasons.iter().any(|x|x=="full_text" || x=="literal_substring") {1} else {2}
}
fn matches_filters(req:&SearchRequest, source:&str, doc_type:Option<&str>, modified:Option<&str>)->bool {
    if req.source.as_deref().is_some_and(|x|x!=source) {return false;}
    if req.document_type.as_deref().is_some_and(|x|Some(x)!=doc_type) {return false;}
    if req.date_from.as_deref().is_some_and(|x|modified.is_none_or(|m|m<x)) {return false;}
    if req.date_to.as_deref().is_some_and(|x|modified.is_none_or(|m|m>x)) {return false;}
    true
}
fn normalize(s:&str)->String { s.chars().flat_map(char::to_lowercase).filter(|c|c.is_alphanumeric()).collect() }
fn tokens(s:&str)->Vec<String> {
    let mut out=Vec::new(); let mut current=String::new();
    for c in s.chars().flat_map(char::to_lowercase) {
        if c.is_alphanumeric() {current.push(c);} else if !current.is_empty() {if !out.contains(&current){out.push(std::mem::take(&mut current));}else{current.clear();}}
    }
    if !current.is_empty()&&!out.contains(&current){out.push(current);}
    out
}
fn make_snippet(text:&str, query:&str)->String {
    let lower=text.to_lowercase(); let pos=tokens(query).iter().filter_map(|t|lower.find(t)).min().unwrap_or(0);
    let start=pos.saturating_sub(100); let end=(pos+320).min(text.len());
    let start=text.floor_char_boundary(start); let end=text.floor_char_boundary(end);
    text[start..end].split_whitespace().collect::<Vec<_>>().join(" ")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pks_open(path:*const c_char)->*mut PksHandle {
    if path.is_null(){return ptr::null_mut();}
    let path=unsafe{CStr::from_ptr(path)}.to_string_lossy();
    match PksHandle::open(path.as_ref()){Ok(h)=>Box::into_raw(Box::new(h)),Err(_)=>ptr::null_mut()}
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pks_search_json(handle:*mut PksHandle, request_json:*const c_char)->*mut c_char {
    if handle.is_null()||request_json.is_null(){return ptr::null_mut();}
    let input=unsafe{CStr::from_ptr(request_json)}.to_string_lossy();
    let response=(||{
        let request:SearchRequest=serde_json::from_str(&input).ok()?;
        let handle=unsafe{&*handle};
        let response=handle.search(&request).ok()?;
        serde_json::to_string(&response).ok()
    })();
    response.and_then(|s|CString::new(s).ok()).map_or(ptr::null_mut(),|s|s.into_raw())
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pks_string_free(value:*mut c_char) {if !value.is_null(){drop(unsafe{CString::from_raw(value)});}}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pks_close(handle:*mut PksHandle) {if !handle.is_null(){drop(unsafe{Box::from_raw(handle)});}}

#[cfg(test)]
mod tests {
    use super::*;
    fn db()->PksHandle {
        let db=Connection::open_in_memory().unwrap();
        db.execute_batch("CREATE TABLE documents(id TEXT PRIMARY KEY,title TEXT,uri TEXT,source_type TEXT,document_type TEXT,modified_at TEXT,index_status TEXT,deleted_at TEXT); CREATE TABLE chunks(id TEXT PRIMARY KEY,document_id TEXT,text TEXT,page INTEGER,heading_path TEXT); CREATE VIRTUAL TABLE chunks_fts USING fts5(chunk_id UNINDEXED,document_id UNINDEXED,title,text); INSERT INTO documents VALUES('d1','Night Piano','/docs/Night Piano.md','local','note','2026-01-01','indexed',NULL); INSERT INTO chunks VALUES('c1','d1','Night piano practice with exact content.',NULL,NULL); INSERT INTO chunks_fts VALUES('c1','d1','Night Piano','Night piano practice with exact content.'); INSERT INTO documents VALUES('d2','Practice','/docs/Practice.md','local','note','2026-01-02','indexed',NULL); INSERT INTO chunks VALUES('c2','d2','Night piano practice for another note.',NULL,NULL); INSERT INTO chunks_fts VALUES('c2','d2','Practice','Night piano practice for another note.');").unwrap();
        PksHandle{db}
    }
    #[test] fn metadata_exact_title_has_metadata_reason(){
        let r=db().search(&SearchRequest{contract_version:Some(1),query:"Night Piano".into(),mode:Some("metadata".into()),source:None,document_type:None,date_from:None,date_to:None,limit:Some(5),exclude_uri:None}).unwrap();
        assert_eq!(r.results[0].title,"Night Piano"); assert_eq!(r.results[0].reasons,vec!["metadata"]);
    }
    #[test] fn fts_returns_content_evidence_and_reason(){
        let r=db().search(&SearchRequest{contract_version:Some(1),query:"night piano practice".into(),mode:Some("fts".into()),source:None,document_type:None,date_from:None,date_to:None,limit:Some(5),exclude_uri:None}).unwrap();
        assert_eq!(r.results.len(),2); assert!(r.results.iter().all(|x|x.reasons.contains(&"full_text".into())));
    }
    #[test] fn source_filter_and_limit_are_enforced(){
        let mut r=SearchRequest{contract_version:Some(1),query:"night piano practice".into(),mode:Some("fts".into()),source:Some("managed".into()),document_type:None,date_from:None,date_to:None,limit:Some(99),exclude_uri:None};
        assert!(db().search(&r).unwrap().results.is_empty()); r.source=None;
        assert!(db().search(&r).unwrap().results.len()<=50);
    }
}
