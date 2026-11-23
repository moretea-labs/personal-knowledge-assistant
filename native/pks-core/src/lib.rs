use rusqlite::{Connection, OpenFlags, OptionalExtension, params};
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
        if mode == "auto" && looks_structured(&request.query) { return Ok(SearchResponse { contract_version: CONTRACT_VERSION, results: self.structured(request, limit)? }); }
        let mut results = match mode {
            "metadata" => self.metadata(request, limit)?,
            "fts" => self.fts(request, limit)?,
            "auto" => self.auto(request, limit)?,
            "semantic" => self.semantic(request, limit)?,
            "related" => self.related(request, limit)?,
            "structured" => self.structured(request, limit)?,
            // Unknown modes are rejected rather than silently changing retrieval semantics.
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

    fn structured(&self, req: &SearchRequest, limit: usize) -> rusqlite::Result<Vec<SearchResult>> {
        let query=req.query.to_lowercase();
        let observation_type=if query.contains("胱抑素")||query.contains("cystatin") {"cystatin_c"}
            else if query.contains("肌酐")||query.contains("creatinine") {"creatinine"}
            else if query.contains("他克莫司")||query.contains("tacrolimus") {"tacrolimus_trough"}
            else {return Ok(Vec::new());};
        let mut stmt=self.db.prepare("SELECT m.source_document_id,d.title,d.uri,d.source_type,m.observation_type,m.value,m.unit,m.observed_at FROM medical_observations m JOIN documents d ON d.id=m.source_document_id WHERE m.observation_type=?1 AND d.deleted_at IS NULL ORDER BY m.observed_at DESC LIMIT ?2")?;
        let rows=stmt.query_map(params![observation_type,limit as i64],|r|Ok((
            r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,String>(2)?,r.get::<_,String>(3)?,
            r.get::<_,String>(4)?,r.get::<_,String>(5)?,r.get::<_,Option<String>>(6)?,r.get::<_,Option<String>>(7)?
        )))?;
        let mut results=Vec::new();
        for (index,row) in rows.enumerate() {
            let (document_id,title,uri,source_type,kind,value,unit,observed_at)=row?;
            let snippet=format!("{}: {}{} ({})",kind,value,unit.as_deref().map(|u|format!(" {u}")).unwrap_or_default(),observed_at.as_deref().unwrap_or("date unknown"));
            results.push(SearchResult{document_id,chunk_id:None,title,uri,source_type,document_type:Some("health_report".into()),
                modified_at:observed_at,snippet,score:1.0-index as f64*0.02,reasons:vec!["structured_health".into()],
                page:None,heading_path:None,index_status:None});
        }
        Ok(results)
    }

    fn semantic(&self, req: &SearchRequest, limit: usize) -> rusqlite::Result<Vec<SearchResult>> {
        let dimensions: Option<i64> = self.db.query_row(
            "SELECT embedding_dim FROM chunks WHERE embedding_json IS NOT NULL AND embedding_provider LIKE 'hash-ngram-v1-%' AND embedding_dim IS NOT NULL LIMIT 1",
            [], |row| row.get(0)
        ).optional()?;
        let Some(dimensions) = dimensions.filter(|d| *d > 0 && *d <= 4096) else { return Ok(Vec::new()); };
        let query_vector = hash_embedding(&req.query, dimensions as usize);
        let mut stmt = self.db.prepare("SELECT d.id,c.id,d.title,d.uri,d.source_type,d.document_type,d.modified_at,c.text,c.page,c.heading_path,d.index_status,c.embedding_json,c.embedding_provider,c.embedding_dim FROM chunks c JOIN documents d ON d.id=c.document_id WHERE c.embedding_json IS NOT NULL AND c.embedding_provider=?1 AND c.embedding_dim=?2 AND d.deleted_at IS NULL ORDER BY d.modified_at DESC LIMIT 5000")?;
        let provider = format!("hash-ngram-v1-{dimensions}");
        let rows = stmt.query_map(params![provider, dimensions], |r| Ok((
            r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,String>(2)?,r.get::<_,String>(3)?,r.get::<_,String>(4)?,
            r.get::<_,Option<String>>(5)?,r.get::<_,Option<String>>(6)?,r.get::<_,String>(7)?,r.get::<_,Option<i64>>(8)?,
            r.get::<_,Option<String>>(9)?,r.get::<_,Option<String>>(10)?,r.get::<_,String>(11)?
        )))?;
        let mut ranked = Vec::new();
        for row in rows {
            let (document_id,chunk_id,title,uri,source_type,document_type,modified_at,text,page,heading_path,index_status,encoded) = row?;
            if req.exclude_uri.as_deref()==Some(uri.as_str()) || !matches_filters(req,&source_type,document_type.as_deref(),modified_at.as_deref()) {continue;}
            let vector:Vec<f32> = match serde_json::from_str(&encoded) {Ok(v)=>v,Err(_)=>continue};
            let score=cosine(&query_vector,&vector);
            if score<=0.12 {continue;}
            ranked.push(SearchResult {document_id,chunk_id:Some(chunk_id),title,uri,source_type,document_type,modified_at,
                snippet:make_snippet(&text,&req.query),score:score*0.82,reasons:vec!["semantic_hash".into()],page,heading_path,index_status});
        }
        ranked.sort_by(|a,b|b.score.total_cmp(&a.score));
        ranked.truncate(limit); Ok(ranked)
    }

    fn related(&self, req: &SearchRequest, limit: usize) -> rusqlite::Result<Vec<SearchResult>> {
        let evidence_terms=related_evidence_terms(&req.query);
        if evidence_terms.len()<2 {return Ok(Vec::new());}
        let keywords=related_keywords(&req.query);
        if keywords.len()<2 {return Ok(Vec::new());}
        let mut fts_request=req.clone();
        fts_request.query=keywords.iter().take(12).cloned().collect::<Vec<_>>().join(" ");
        let mut candidates=self.fts(&fts_request,(limit*6).max(40))?;
        candidates.extend(self.semantic(req,(limit*6).max(40))?);
        let mut ranked:Vec<SearchResult>=Vec::new();
        for mut hit in candidates {
            if req.exclude_uri.as_deref()==Some(hit.uri.as_str()) {continue;}
            let evidence=normalize(&hit.snippet);
            let matches=evidence_terms.iter().filter(|term|evidence.contains(&normalize(term))).count();
            let coverage=matches as f64/evidence_terms.len() as f64;
            if matches<2 || coverage<0.24 {continue;}
            let similarity=if hit.reasons.iter().any(|r|r=="semantic_hash"){hit.score/0.82}else{0.0};
            hit.score=coverage*0.8+similarity*0.2;
            hit.reasons.insert(0,"related_content".into());
            if let Some(existing)=ranked.iter_mut().find(|r|r.document_id==hit.document_id) {
                if hit.score>existing.score {*existing=hit;}
            } else {ranked.push(hit);}
        }
        ranked.sort_by(|a,b|b.score.total_cmp(&a.score).then_with(||a.title.cmp(&b.title)));
        ranked.truncate(limit); Ok(ranked)
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

fn looks_structured(query:&str)->bool { let q=query.to_lowercase(); q.contains("肌酐")||q.contains("胱抑素")||q.contains("cystatin")||q.contains("creatinine")||q.contains("他克莫司")||q.contains("tacrolimus") }
fn related_keywords(query:&str)->Vec<String> {
    const IGNORE:&[&str]=&["my","the","and","about","with","from","this","that","your","for","are","was","were","into","page","notes","note","markdown","file","files","folder","folders","document","documents","search","content","pdf","path","paths","location","where","find","locate","please","help","all","every","is","a","an","to","of","in","on","at","by","as","or","but","how","what","when","which","who","why","can","could","should","would","it","you","we","our","i","me","app","apps","ui","ux"];
    tokens(query).into_iter().filter(|t|t.chars().count()>=2&&!IGNORE.contains(&t.as_str())).take(24).collect()
}
fn related_evidence_terms(query:&str)->Vec<String> {
    related_keywords(query).into_iter().filter(|t|t.chars().count()>=2).collect()
}
pub fn embedding_words(text:&str)->Vec<String> {
    let mut words=Vec::new();
    let mut current=String::new();
    for c in text.chars().flat_map(char::to_lowercase) {
        if c.is_alphanumeric() {current.push(c);}
        else if !current.is_empty() {words.push(std::mem::take(&mut current));}
    }
    if !current.is_empty(){words.push(current);}
    words
}
pub fn hash_embedding(text:&str, dimensions:usize)->Vec<f64> {
    let mut vector=vec![0.0f64;dimensions];
    let lower=text.to_lowercase();
    let mut features=embedding_words(&lower).into_iter().take(800).collect::<Vec<_>>();
    let chars=lower.chars().filter(|c|!c.is_whitespace()).collect::<Vec<_>>();
    for pair in chars.windows(2).take(1200) {features.push(pair.iter().collect());}
    for feature in features {
        let mut hash=2166136261u32;
        for unit in feature.encode_utf16() {hash^=unit as u32;hash=hash.wrapping_mul(16777619);}
        let index=(hash as usize)%dimensions;
        vector[index]+=if ((hash>>8)&1)==1 {1.0f64} else {-1.0f64};
    }
    let norm=vector.iter().map(|v|v*v).sum::<f64>().sqrt().max(1.0);
    vector.iter_mut().for_each(|v|*v/=norm);
    vector
}
fn cosine(a:&[f64],b:&[f32])->f64 {
    let n=a.len().min(b.len());
    let mut dot=0.0f64;let mut aa=0.0f64;let mut bb=0.0f64;
    for i in 0..n {dot+=a[i]*(b[i] as f64);aa+=a[i].powi(2);bb+=(b[i] as f64).powi(2);}
    dot/((aa.sqrt()*bb.sqrt()).max(1.0))
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
        db.execute_batch("CREATE TABLE documents(id TEXT PRIMARY KEY,title TEXT,uri TEXT,source_type TEXT,document_type TEXT,modified_at TEXT,index_status TEXT,deleted_at TEXT); CREATE TABLE chunks(id TEXT PRIMARY KEY,document_id TEXT,text TEXT,page INTEGER,heading_path TEXT,embedding_json TEXT,embedding_provider TEXT,embedding_dim INTEGER); CREATE VIRTUAL TABLE chunks_fts USING fts5(chunk_id UNINDEXED,document_id UNINDEXED,title,text); INSERT INTO documents VALUES('d1','Night Piano','/docs/Night Piano.md','local','note','2026-01-01','indexed',NULL); INSERT INTO chunks(id,document_id,text) VALUES('c1','d1','Night piano practice with exact content.'); INSERT INTO chunks_fts VALUES('c1','d1','Night Piano','Night piano practice with exact content.'); INSERT INTO documents VALUES('d2','Practice','/docs/Practice.md','local','note','2026-01-02','indexed',NULL); INSERT INTO chunks(id,document_id,text) VALUES('c2','d2','Night piano practice for another note.'); INSERT INTO chunks_fts VALUES('c2','d2','Practice','Night piano practice for another note.'); INSERT INTO documents VALUES('d3','Chord Finger Exercises','/docs/Chord Finger Exercises.md','local','note','2026-01-03','indexed',NULL); INSERT INTO chunks(id,document_id,text) VALUES('c3','d3','Guitar chord switching and finger positioning exercises improve transitions.'); INSERT INTO chunks_fts VALUES('c3','d3','Chord Finger Exercises','Guitar chord switching and finger positioning exercises improve transitions.');").unwrap();
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
    #[test] fn semantic_hash_retrieval_matches_stored_hash_vectors(){
         let handle=db();
         let vector=hash_embedding("Night piano practice",128);
         handle.db.execute("UPDATE chunks SET embedding_json=?1,embedding_provider=?2,embedding_dim=?3 WHERE id='c1'",
             params![serde_json::to_string(&vector).unwrap(),"hash-ngram-v1-128",128]).unwrap();
         let r=handle.search(&SearchRequest{contract_version:Some(1),query:"Night piano practice".into(),mode:Some("semantic".into()),source:None,document_type:None,date_from:None,date_to:None,limit:Some(5),exclude_uri:None}).unwrap();
         assert_eq!(r.results[0].document_id,"d1");
         assert!(r.results[0].reasons.contains(&"semantic_hash".into()));
     }
     #[test] fn related_requires_multiple_content_terms_and_excludes_self(){
         let r=db().search(&SearchRequest{contract_version:Some(1),query:"Guitar chord switching finger positioning exercises".into(),mode:Some("related".into()),source:None,document_type:None,date_from:None,date_to:None,limit:Some(5),exclude_uri:Some("/docs/Guitar Practice.md".into())}).unwrap();
         assert_eq!(r.results[0].title,"Chord Finger Exercises");
         assert!(r.results[0].reasons.contains(&"related_content".into()));
         let weak=db().search(&SearchRequest{contract_version:Some(1),query:"Guitar".into(),mode:Some("related".into()),source:None,document_type:None,date_from:None,date_to:None,limit:Some(5),exclude_uri:None}).unwrap();
         assert!(weak.results.is_empty());
     }
     #[test] fn source_filter_and_limit_are_enforced(){
        let mut r=SearchRequest{contract_version:Some(1),query:"night piano practice".into(),mode:Some("fts".into()),source:Some("managed".into()),document_type:None,date_from:None,date_to:None,limit:Some(99),exclude_uri:None};
        assert!(db().search(&r).unwrap().results.is_empty()); r.source=None;
        assert!(db().search(&r).unwrap().results.len()<=50);
    }
}
