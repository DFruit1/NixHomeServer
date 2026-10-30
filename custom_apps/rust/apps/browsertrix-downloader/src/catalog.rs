//! Durable ownership and inventories are independent of disposable job history.
use crate::{
    archive_engine::{ArchiveReport, PageRecord, ResourceRecord, Verification},
    database::Database,
    model::{CreateJobRequest, JobRuntime, Operation, ResumeOptions},
};
use rusqlite::{params, OptionalExtension, TransactionBehavior};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use serde_json::{json, Value};

pub fn now() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}
pub fn sql_json<T: Serialize>(value: &T) -> rusqlite::Result<String> {
    serde_json::to_string(value).map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))
}
pub fn from_json<T: DeserializeOwned>(value: &str) -> rusqlite::Result<T> {
    serde_json::from_str(value).map_err(|e| {
        rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(e))
    })
}
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct ArchiveSummary {
    pub unique_payload_bytes: u64,
    pub duplicate_payload_bytes: u64,
    pub metadata_bytes: u64,
    pub warnings: Vec<String>,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Archive {
    pub id: String,
    pub created_at: String,
    pub updated_at: String,
    pub created_by: String,
    pub url: String,
    pub title: String,
    pub archive_file: String,
    pub archive_bytes: u64,
    pub sha256: String,
    pub tags: Vec<String>,
    pub collection: String,
    pub favorite: bool,
    pub notes: String,
    pub trashed: bool,
    pub parent_id: Option<String>,
    pub parent_sha256: Option<String>,
    pub capture_status: String,
    pub stop_reason: Option<String>,
    pub request: Option<CreateJobRequest>,
    pub report: ArchiveSummary,
    pub verification: Option<Verification>,
    pub clean_rules: Vec<crate::model::SelectorRule>,
    pub dependencies: Vec<String>,
    pub dependency_hashes: std::collections::BTreeMap<String, String>,
    pub visibility: String,
    pub page_count: u64,
    pub resource_count: u64,
}
impl Archive {
    pub fn new(
        id: String,
        owner: String,
        request: Option<CreateJobRequest>,
        report: &ArchiveReport,
    ) -> Self {
        let stamp = now();
        let private = request
            .as_ref()
            .is_some_and(|r| r.options.profile_id.is_some());
        Self {
            id,
            created_at: stamp.clone(),
            updated_at: stamp,
            created_by: owner,
            url: request.as_ref().map(|r| r.url.clone()).unwrap_or_else(|| {
                report
                    .pages
                    .first()
                    .map(|p| p.url.clone())
                    .unwrap_or_default()
            }),
            title: report.title.clone(),
            archive_file: String::new(),
            archive_bytes: report.archive_bytes,
            sha256: report.sha256.clone(),
            tags: vec![],
            collection: request
                .as_ref()
                .and_then(|r| r.collection.clone())
                .unwrap_or_default(),
            favorite: false,
            notes: String::new(),
            trashed: false,
            parent_id: None,
            parent_sha256: None,
            capture_status: "complete".into(),
            stop_reason: None,
            request,
            report: ArchiveSummary {
                unique_payload_bytes: report.unique_payload_bytes,
                duplicate_payload_bytes: report.duplicate_payload_bytes,
                metadata_bytes: report.metadata_bytes,
                warnings: report.warnings.iter().take(100).cloned().collect(),
            },
            verification: None,
            clean_rules: vec![],
            dependencies: vec![],
            dependency_hashes: Default::default(),
            visibility: if private { "private" } else { "shared" }.into(),
            page_count: report.pages.len() as u64,
            resource_count: report.resources.len() as u64,
        }
    }
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PublicationIntent {
    pub archive: Archive,
    pub report: ArchiveReport,
    pub source: String,
    pub job_id: Option<String>,
    pub final_status: String,
    #[serde(default)]
    pub coverage: Vec<crate::coverage::CoverageRecord>,
}
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct ListQuery {
    pub q: String,
    pub offset: u64,
    pub limit: Option<u32>,
    pub sort: String,
    pub favorite: Option<bool>,
    pub collection: Option<String>,
    pub tag: Option<String>,
    pub trashed: Option<bool>,
    pub mime: Option<String>,
    pub domain: Option<String>,
}
impl ListQuery {
    pub fn limit(&self) -> u32 {
        self.limit.unwrap_or(50).clamp(1, 100)
    }
    pub fn offset(&self) -> i64 {
        self.offset.min(i64::MAX as u64) as i64
    }
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Page<T: Serialize> {
    pub items: Vec<T>,
    pub total: u64,
    pub offset: u64,
    pub limit: u32,
}
impl Database {
    pub(crate) fn migrate_catalog(&self) -> rusqlite::Result<()> {
        self.connect()?.execute_batch("CREATE TABLE IF NOT EXISTS archive_coverage(archive_id TEXT NOT NULL,ordinal INTEGER NOT NULL,url TEXT NOT NULL,kind TEXT NOT NULL,reason TEXT NOT NULL,document TEXT NOT NULL,PRIMARY KEY(archive_id,ordinal));")?;
        self.connect()?.execute_batch("CREATE TABLE IF NOT EXISTS archives(id TEXT PRIMARY KEY,owner TEXT NOT NULL,sha256 TEXT NOT NULL,document TEXT NOT NULL); CREATE INDEX IF NOT EXISTS archives_owner ON archives(owner); CREATE INDEX IF NOT EXISTS archives_hash ON archives(owner,sha256); CREATE TABLE IF NOT EXISTS archive_pages(archive_id TEXT NOT NULL REFERENCES archives(id),ordinal INTEGER NOT NULL,url TEXT NOT NULL,title TEXT NOT NULL,text TEXT NOT NULL,document TEXT NOT NULL,PRIMARY KEY(archive_id,ordinal)); CREATE INDEX IF NOT EXISTS archive_pages_url ON archive_pages(archive_id,url); CREATE TABLE IF NOT EXISTS archive_resources(archive_id TEXT NOT NULL REFERENCES archives(id),ordinal INTEGER NOT NULL,url TEXT NOT NULL,mime TEXT NOT NULL,domain TEXT NOT NULL,document TEXT NOT NULL,PRIMARY KEY(archive_id,ordinal)); CREATE TABLE IF NOT EXISTS publication_intents(id TEXT PRIMARY KEY,document TEXT NOT NULL,completed INTEGER NOT NULL DEFAULT 0); CREATE TABLE IF NOT EXISTS owned_records(id TEXT NOT NULL,owner TEXT NOT NULL,kind TEXT NOT NULL,document TEXT NOT NULL,PRIMARY KEY(id,kind)); CREATE INDEX IF NOT EXISTS owned_records_owner ON owned_records(owner,kind);")?;
        // Legacy jobs provide authoritative ownership evidence; bare files never do.
        let c = self.connect()?;
        let mut stmt=c.prepare("SELECT id,created_at,updated_at,created_by,request_json,archive_file,archive_bytes FROM jobs WHERE archive_file IS NOT NULL AND status='completed' AND json_extract(runtime_json,'$.archiveId') IS NULL AND coalesce(json_extract(runtime_json,'$.operation.kind'),'capture')='capture' AND id NOT IN (SELECT id FROM archives)")?;
        let legacy = stmt
            .query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, String>(3)?,
                    r.get::<_, String>(4)?,
                    r.get::<_, String>(5)?,
                    r.get::<_, i64>(6)? as u64,
                ))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        for (id, created, updated, owner, req, file, bytes) in legacy {
            let request: CreateJobRequest = from_json(&req)?;
            let mut archive = Archive::new(id, owner, Some(request), &ArchiveReport::default());
            archive.created_at = created;
            archive.updated_at = updated;
            archive.archive_file = file;
            archive.archive_bytes = bytes;
            archive
                .report
                .warnings
                .push("Legacy ownership migrated; fixity has not run".into());
            self.save_archive_metadata(&archive)?;
        }
        Ok(())
    }
    pub fn save_archive_metadata(&self, a: &Archive) -> rusqlite::Result<()> {
        self.connect()?.execute("INSERT INTO archives(id,owner,sha256,document) VALUES(?1,?2,?3,?4) ON CONFLICT(id) DO UPDATE SET document=excluded.document,sha256=excluded.sha256 WHERE archives.owner=excluded.owner",params![a.id,a.created_by,a.sha256,sql_json(a)?])?;
        Ok(())
    }
    pub fn archive_for_user(&self, id: &str, owner: &str) -> rusqlite::Result<Option<Archive>> {
        self.connect()?
            .query_row(
                "SELECT document FROM archives WHERE id=?1 AND owner=?2",
                params![id, owner],
                |r| from_json(&r.get::<_, String>(0)?),
            )
            .optional()
    }
    pub fn archive_by_hash(&self, owner: &str, hash: &str) -> rusqlite::Result<Option<Archive>> {
        self.connect()?
            .query_row(
                "SELECT document FROM archives WHERE owner=?1 AND sha256=?2 LIMIT 1",
                params![owner, hash],
                |r| from_json(&r.get::<_, String>(0)?),
            )
            .optional()
    }
    pub fn archives(&self, owner: &str, q: &ListQuery) -> rusqlite::Result<Page<Archive>> {
        let c = self.connect()?;
        let filters="owner=?1 AND (?2='' OR instr(lower(json_extract(document,'$.title')||' '||json_extract(document,'$.url')||' '||json_extract(document,'$.notes')),lower(?2))>0) AND (?3 IS NULL OR json_extract(document,'$.favorite')=?3) AND (?4 IS NULL OR json_extract(document,'$.collection')=?4) AND json_extract(document,'$.trashed')=?5 AND (?6 IS NULL OR EXISTS(SELECT 1 FROM json_each(json_extract(document,'$.tags')) WHERE value=?6))";
        let order = match q.sort.as_str() {
            "oldest" => "json_extract(document,'$.createdAt') ASC",
            "title" => "json_extract(document,'$.title') COLLATE NOCASE ASC",
            "size" => "json_extract(document,'$.archiveBytes') DESC",
            _ => "json_extract(document,'$.createdAt') DESC",
        };
        let values = params![
            owner,
            q.q,
            q.favorite,
            q.collection,
            q.trashed.unwrap_or(false),
            q.tag
        ];
        let total = c.query_row(
            &format!("SELECT count(*) FROM archives WHERE {filters}"),
            values,
            |r| r.get::<_, i64>(0).map(|v| v as u64),
        )?;
        let mut st = c.prepare(&format!(
            "SELECT document FROM archives WHERE {filters} ORDER BY {order},id LIMIT ?7 OFFSET ?8"
        ))?;
        let items = st
            .query_map(
                params![
                    owner,
                    q.q,
                    q.favorite,
                    q.collection,
                    q.trashed.unwrap_or(false),
                    q.tag,
                    q.limit(),
                    q.offset()
                ],
                |r| from_json(&r.get::<_, String>(0)?),
            )?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(Page {
            items,
            total,
            offset: q.offset,
            limit: q.limit(),
        })
    }
    pub fn put_intent(&self, intent: &PublicationIntent) -> rusqlite::Result<()> {
        self.connect()?.execute(
            "INSERT INTO publication_intents(id,document) VALUES(?1,?2)",
            params![intent.archive.id, sql_json(intent)?],
        )?;
        Ok(())
    }
    pub fn pending_intent_ids(&self) -> rusqlite::Result<Vec<String>> {
        self.connect()?
            .prepare("SELECT id FROM publication_intents WHERE completed=0 LIMIT 1000")?
            .query_map([], |r| r.get(0))?
            .collect()
    }
    pub fn pending_intent(&self, id: &str) -> rusqlite::Result<Option<PublicationIntent>> {
        self.connect()?
            .query_row(
                "SELECT document FROM publication_intents WHERE id=?1 AND completed=0",
                [id],
                |r| from_json(&r.get::<_, String>(0)?),
            )
            .optional()
    }
    pub fn finalize_intent(&self, intent: &PublicationIntent) -> rusqlite::Result<()> {
        let mut c = self.connect()?;
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let a = &intent.archive;
        tx.execute("DELETE FROM archive_coverage WHERE archive_id=?1", [&a.id])?;
        for (ordinal, row) in intent.coverage.iter().enumerate() {
            tx.execute(
                "INSERT INTO archive_coverage VALUES(?1,?2,?3,?4,?5,?6)",
                params![
                    a.id,
                    ordinal as i64,
                    row.url,
                    row.kind,
                    row.reason,
                    sql_json(row)?
                ],
            )?;
        }
        tx.execute("INSERT INTO archives(id,owner,sha256,document) VALUES(?1,?2,?3,?4) ON CONFLICT(id) DO NOTHING",params![a.id,a.created_by,a.sha256,sql_json(a)?])?;
        let identity: (String, String) = tx.query_row(
            "SELECT owner,sha256 FROM archives WHERE id=?1",
            [&a.id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;
        if identity != (a.created_by.clone(), a.sha256.clone()) {
            return Err(rusqlite::Error::InvalidQuery);
        }
        tx.execute("DELETE FROM archive_pages WHERE archive_id=?1", [&a.id])?;
        tx.execute("DELETE FROM archive_resources WHERE archive_id=?1", [&a.id])?;
        {
            let mut st = tx.prepare("INSERT INTO archive_pages VALUES(?1,?2,?3,?4,?5,?6)")?;
            for (i, p) in intent.report.pages.iter().enumerate() {
                st.execute(params![
                    a.id,
                    i as i64,
                    p.url,
                    p.title,
                    p.text,
                    sql_json(p)?
                ])?;
            }
        }
        {
            let mut st = tx.prepare("INSERT INTO archive_resources VALUES(?1,?2,?3,?4,?5,?6)")?;
            for (i, r) in intent.report.resources.iter().enumerate() {
                st.execute(params![
                    a.id,
                    i as i64,
                    r.url,
                    r.mime,
                    r.domain,
                    sql_json(r)?
                ])?;
            }
        }
        if let Some(id) = &intent.job_id {
            let data: Option<String> = tx
                .query_row(
                    "SELECT runtime_json FROM jobs WHERE id=?1 AND created_by=?2",
                    params![id, a.created_by],
                    |r| r.get(0),
                )
                .optional()?;
            if let Some(data) = data {
                let mut rt: JobRuntime = from_json(&data)?;
                rt.archive_id = Some(a.id.clone());
                rt.bytes_stored = a.archive_bytes;
                tx.execute("UPDATE jobs SET archive_file=?2,archive_bytes=?3,status=?4,runtime_json=?5,updated_at=?6 WHERE id=?1",params![id,a.archive_file,a.archive_bytes as i64,intent.final_status,rt.storage_json().map_err(|e|rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?,now()])?;
            }
        }
        tx.execute(
            "UPDATE publication_intents SET completed=1 WHERE id=?1",
            [&a.id],
        )?;
        tx.commit()
    }
    pub fn pages(&self, id: &str, q: &ListQuery) -> rusqlite::Result<Page<PageRecord>> {
        let c = self.connect()?;
        let filter =
            "archive_id=?1 AND (?2='' OR instr(lower(url||' '||title||' '||text),lower(?2))>0)";
        let total = c.query_row(
            &format!("SELECT count(*) FROM archive_pages WHERE {filter}"),
            params![id, q.q],
            |r| r.get::<_, i64>(0).map(|v| v as u64),
        )?;
        let items=c.prepare(&format!("SELECT document FROM archive_pages WHERE {filter} ORDER BY ordinal LIMIT ?3 OFFSET ?4"))?.query_map(params![id,q.q,q.limit(),q.offset()],|r|{let mut p:PageRecord=from_json(&r.get::<_,String>(0)?)?;p.text=p.text.chars().take(1000).collect();p.resource_urls.truncate(100);Ok(p)})?.collect::<rusqlite::Result<_>>()?;
        Ok(Page {
            items,
            total,
            offset: q.offset,
            limit: q.limit(),
        })
    }
    pub fn coverage(
        &self,
        id: &str,
        q: &ListQuery,
    ) -> rusqlite::Result<Page<crate::coverage::CoverageRecord>> {
        let c = self.connect()?;
        let filter =
            "archive_id=?1 AND (?2='' OR instr(lower(url||' '||kind||' '||reason),lower(?2))>0)";
        let total = c.query_row(
            &format!("SELECT count(*) FROM archive_coverage WHERE {filter}"),
            params![id, q.q],
            |r| r.get::<_, i64>(0).map(|n| n as u64),
        )?;
        let items=c.prepare(&format!("SELECT document FROM archive_coverage WHERE {filter} ORDER BY ordinal LIMIT ?3 OFFSET ?4"))?.query_map(params![id,q.q,q.limit(),q.offset()],|r|from_json(&r.get::<_,String>(0)?))?.collect::<rusqlite::Result<_>>()?;
        Ok(Page {
            items,
            total,
            offset: q.offset,
            limit: q.limit(),
        })
    }
    pub fn resources(&self, id: &str, q: &ListQuery) -> rusqlite::Result<Page<ResourceRecord>> {
        let c = self.connect()?;
        let filter="archive_id=?1 AND (?2='' OR instr(lower(url),lower(?2))>0) AND (?3 IS NULL OR mime LIKE ?3||'%') AND (?4 IS NULL OR domain=?4)";
        let total = c.query_row(
            &format!("SELECT count(*) FROM archive_resources WHERE {filter}"),
            params![id, q.q, q.mime, q.domain],
            |r| r.get::<_, i64>(0).map(|v| v as u64),
        )?;
        let items=c.prepare(&format!("SELECT document FROM archive_resources WHERE {filter} ORDER BY ordinal LIMIT ?5 OFFSET ?6"))?.query_map(params![id,q.q,q.mime,q.domain,q.limit(),q.offset()],|r|{let mut p:ResourceRecord=from_json(&r.get::<_,String>(0)?)?;p.pages.truncate(100);Ok(p)})?.collect::<rusqlite::Result<_>>()?;
        Ok(Page {
            items,
            total,
            offset: q.offset,
            limit: q.limit(),
        })
    }
    pub fn search_pages(&self, owner: &str, q: &ListQuery) -> rusqlite::Result<Page<Value>> {
        let c = self.connect()?;
        let filter="a.owner=?1 AND json_extract(a.document,'$.trashed')=0 AND instr(lower(p.url||' '||p.title||' '||p.text),lower(?2))>0";
        let total=c.query_row(&format!("SELECT count(*) FROM archive_pages p JOIN archives a ON a.id=p.archive_id WHERE {filter}"),params![owner,q.q],|r|r.get::<_,i64>(0).map(|v|v as u64))?;
        let items=c.prepare(&format!("SELECT p.archive_id,p.url,p.title,substr(p.text,1,300),json_extract(p.document,'$.ts') FROM archive_pages p JOIN archives a ON a.id=p.archive_id WHERE {filter} ORDER BY json_extract(a.document,'$.createdAt') DESC,p.ordinal LIMIT ?3 OFFSET ?4"))?.query_map(params![owner,q.q,q.limit(),q.offset()],|r|{let id:String=r.get(0)?;let url:String=r.get(1)?;let ts:String=r.get(4)?;let mut replay=url::form_urlencoded::Serializer::new(String::new());replay.append_pair("source",&format!("/api/archives/{id}/replay.json")).append_pair("url",&url).append_pair("ts",&ts);Ok(json!({"archiveId":id,"url":url,"title":r.get::<_,String>(2)?,"snippet":r.get::<_,String>(3)?,"ts":ts,"replayUrl":format!("/replay/?{}",replay.finish())}))})?.collect::<rusqlite::Result<_>>()?;
        Ok(Page {
            items,
            total,
            offset: q.offset,
            limit: q.limit(),
        })
    }
    pub fn record(&self, kind: &str, id: &str, owner: &str) -> rusqlite::Result<Option<Value>> {
        self.connect()?
            .query_row(
                "SELECT document FROM owned_records WHERE kind=?1 AND id=?2 AND owner=?3",
                params![kind, id, owner],
                |r| from_json(&r.get::<_, String>(0)?),
            )
            .optional()
    }
    pub fn records(&self, kind: &str, owner: &str) -> rusqlite::Result<Vec<Value>> {
        self.connect()?.prepare("SELECT document FROM owned_records WHERE kind=?1 AND owner=?2 ORDER BY id LIMIT 500")?.query_map(params![kind,owner],|r|from_json(&r.get::<_,String>(0)?))?.collect()
    }
    pub fn put_record(
        &self,
        kind: &str,
        id: &str,
        owner: &str,
        value: &Value,
    ) -> rusqlite::Result<()> {
        self.connect()?.execute("INSERT INTO owned_records(id,owner,kind,document) VALUES(?1,?2,?3,?4) ON CONFLICT(id,kind) DO UPDATE SET document=excluded.document WHERE owned_records.owner=excluded.owner",params![id,owner,kind,sql_json(value)?])?;
        Ok(())
    }
    pub fn delete_record(&self, kind: &str, id: &str, owner: &str) -> rusqlite::Result<usize> {
        self.connect()?.execute(
            "DELETE FROM owned_records WHERE kind=?1 AND id=?2 AND owner=?3",
            params![kind, id, owner],
        )
    }
    pub fn set_runtime(&self, id: &str, rt: &JobRuntime) -> rusqlite::Result<()> {
        self.connect()?.execute(
            "UPDATE jobs SET runtime_json=?2,updated_at=?3 WHERE id=?1",
            params![
                id,
                rt.storage_json()
                    .map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?,
                now()
            ],
        )?;
        Ok(())
    }
    pub fn queue_operation(
        &self,
        id: &str,
        owner: &str,
        request: &CreateJobRequest,
        operation: Operation,
    ) -> rusqlite::Result<()> {
        let mut c = self.connect()?;
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let rt = JobRuntime {
            operation,
            ..Default::default()
        };
        tx.execute("INSERT INTO jobs(id,created_at,updated_at,created_by,status,request_json,runtime_json) VALUES(?1,?2,?2,?3,'queued',?4,?5)",params![id,now(),owner,sql_json(request)?,rt.storage_json().map_err(|e|rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?])?;
        tx.commit()
    }
    pub fn request_control(&self, id: &str, owner: &str, control: &str) -> Result<(), String> {
        let mut c = self.connect().map_err(|e| e.to_string())?;
        let tx = c
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|e| e.to_string())?;
        let (data, status): (String, String) = tx
            .query_row(
                "SELECT runtime_json,status FROM jobs WHERE id=?1 AND created_by=?2",
                params![id, owner],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .map_err(|_| "job not found".to_owned())?;
        if !matches!(status.as_str(), "queued" | "starting" | "running") {
            return Err("job cannot be paused or stopped in its current state".into());
        }
        let mut rt: JobRuntime = serde_json::from_str(&data).map_err(|e| e.to_string())?;
        rt.control = Some(control.into());
        let next = if status == "queued" {
            "paused"
        } else {
            status.as_str()
        };
        tx.execute(
            "UPDATE jobs SET runtime_json=?2,status=?3,updated_at=?4 WHERE id=?1",
            params![
                id,
                rt.storage_json().map_err(|e| e.to_string())?,
                next,
                now()
            ],
        )
        .map_err(|e| e.to_string())?;
        tx.commit().map_err(|e| e.to_string())
    }
    pub fn resume(&self, id: &str, owner: &str, ext: &ResumeOptions) -> Result<(), String> {
        let mut c = self.connect().map_err(|e| e.to_string())?;
        let tx = c
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|e| e.to_string())?;
        let (data, status, request): (String, String, String) = tx
            .query_row(
                "SELECT runtime_json,status,request_json FROM jobs WHERE id=?1 AND created_by=?2",
                params![id, owner],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .map_err(|_| "job not found".to_owned())?;
        let mut rt: JobRuntime = serde_json::from_str(&data).map_err(|e| e.to_string())?;
        let mut request: CreateJobRequest =
            serde_json::from_str(&request).map_err(|e| e.to_string())?;
        if rt.control.as_deref() == Some("discard")
            || !matches!(status.as_str(), "partial" | "paused")
            || (rt.attempt > 0 && !rt.can_resume)
        {
            return Err("no durable checkpoint is available for resume".into());
        }
        if ext.additional_pages > 500
            || ext.additional_minutes > 120
            || ext.additional_bytes > 16 * 1024 * 1024 * 1024
        {
            return Err("resume extension exceeds bounded maximum".into());
        }
        let done = rt.coverage.as_ref().map(|p| p.pages_done).unwrap_or(0);
        let pages = request
            .page_limit
            .checked_add(ext.additional_pages)
            .filter(|n| *n <= 5000)
            .ok_or("cumulative page limit exceeds 5000")?;
        let bytes = request
            .options
            .size_limit_bytes
            .unwrap_or(2 * 1024 * 1024 * 1024)
            .checked_add(ext.additional_bytes)
            .filter(|n| *n <= 16 * 1024 * 1024 * 1024)
            .ok_or("cumulative WARC byte limit exceeds 16GiB")?;
        let minutes = request
            .time_limit_minutes
            .checked_add(ext.additional_minutes)
            .filter(|n| *n <= 1440)
            .ok_or("cumulative time limit exceeds 24 hours")?;
        if done >= u64::from(pages)
            || rt.warc_bytes >= bytes
            || rt.runtime_seconds >= u64::from(minutes) * 60
            || (rt.stop_reason.as_deref() == Some("time-limit") && ext.additional_minutes == 0)
        {
            return Err("capture budget exhausted; supply an explicit bounded additionalPages, additionalMinutes or additionalBytes extension".into());
        }
        request.page_limit = pages;
        request.options.size_limit_bytes = Some(bytes);
        request.time_limit_minutes = minutes;
        rt.control = None;
        rt.stop_reason = None;
        rt.can_resume = false;
        rt.attempt_deadline = None;
        tx.execute("UPDATE jobs SET status='queued',request_json=?2,runtime_json=?3,updated_at=?4 WHERE id=?1",params![id,sql_json(&request).map_err(|e|e.to_string())?,rt.storage_json().map_err(|e|e.to_string())?,now()]).map_err(|e|e.to_string())?;
        tx.commit().map_err(|e| e.to_string())
    }
    pub fn set_runtime_preserving_control(
        &self,
        id: &str,
        rt: &JobRuntime,
    ) -> rusqlite::Result<()> {
        self.connect()?.execute("UPDATE jobs SET runtime_json=json_set(json(?2),'$.control',json_extract(runtime_json,'$.control'),'$.canResume',json(CASE WHEN json_extract(runtime_json,'$.control')='discard' THEN 'false' WHEN json_extract(json(?2),'$.canResume')=1 THEN 'true' ELSE 'false' END),'$.resumeConfig',CASE WHEN json_extract(runtime_json,'$.control')='discard' THEN json_extract(runtime_json,'$.resumeConfig') ELSE json_extract(json(?2),'$.resumeConfig') END,'$.stopReason',CASE WHEN json_extract(runtime_json,'$.control')='discard' THEN 'discard' ELSE json_extract(json(?2),'$.stopReason') END,'$.discardCleanupPending',json_extract(runtime_json,'$.discardCleanupPending')),updated_at=?3 WHERE id=?1",params![id,rt.storage_json().map_err(|e|rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?,now()])?;
        Ok(())
    }
    pub fn begin_capture(&self, id: &str, rt: &JobRuntime) -> rusqlite::Result<bool> {
        Ok(self.connect()?.execute("UPDATE jobs SET status='running',runtime_json=?2,updated_at=?3 WHERE id=?1 AND status='starting' AND json_extract(runtime_json,'$.control') IS NULL",params![id,rt.storage_json().map_err(|e|rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?,now()])?==1)
    }
    /// Freeze stop/discard controls atomically with the packaging transition.
    /// Once this commits, new controls are rejected by the existing state gate.
    pub fn prepare_publication(
        &self,
        id: &str,
        rt: &JobRuntime,
    ) -> rusqlite::Result<Option<JobRuntime>> {
        let mut c = self.connect()?;
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let (status, stored): (String, String) = tx.query_row(
            "SELECT status,runtime_json FROM jobs WHERE id=?1",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;
        if status == "cancelling" {
            return Ok(None);
        }
        if status != "running" {
            return Err(rusqlite::Error::InvalidQuery);
        }
        let current: JobRuntime = from_json(&stored)?;
        let mut frozen = rt.clone();
        frozen.control = current.control;
        if let Some(control) = frozen.control.as_deref() {
            frozen.stop_reason = match control {
                "pause" => Some("pause".into()),
                "stop" => Some("stop-and-save".into()),
                _ => frozen.stop_reason,
            };
        }
        tx.execute(
            "UPDATE jobs SET status='packaging',runtime_json=?2,updated_at=?3 WHERE id=?1",
            params![
                id,
                frozen
                    .storage_json()
                    .map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?,
                now()
            ],
        )?;
        tx.commit()?;
        Ok(Some(frozen))
    }
    pub fn list_jobs_for_recovery(&self) -> rusqlite::Result<Vec<crate::model::Job>> {
        let c = self.connect()?;
        let ids = c
            .prepare("SELECT id FROM jobs WHERE status='paused' OR (status='cancelled' AND json_extract(runtime_json,'$.discardCleanupPending')=1) LIMIT 1000")?
            .query_map([], |r| r.get::<_, String>(0))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        ids.iter()
            .filter_map(|id| self.job(id).transpose())
            .collect()
    }
    pub fn discarded_jobs(&self) -> rusqlite::Result<Vec<crate::model::Job>> {
        let c = self.connect()?;
        let ids = c.prepare("SELECT id FROM jobs WHERE status='cancelled' AND json_extract(runtime_json,'$.discardCleanupPending')=1 LIMIT 1000")?
            .query_map([], |r| r.get::<_, String>(0))?.collect::<rusqlite::Result<Vec<_>>>()?;
        ids.iter()
            .filter_map(|id| self.job(id).transpose())
            .collect()
    }
    pub fn finish_discard_cleanup(&self, id: &str) -> rusqlite::Result<()> {
        self.connect()?.execute("UPDATE jobs SET runtime_json=json_remove(json_set(runtime_json,'$.canResume',json('false'),'$.resumeConfig',NULL,'$.attemptDeadline',NULL,'$.stopReason','discard'),'$.discardCleanupPending'),updated_at=?2 WHERE id=?1 AND status='cancelled' AND json_extract(runtime_json,'$.control')='discard'", params![id, now()])?;
        Ok(())
    }
    pub fn restore_checkpoint(&self, id: &str, saved: &str) -> rusqlite::Result<()> {
        self.connect()?.execute("UPDATE jobs SET runtime_json=json_set(runtime_json,'$.canResume',json('true'),'$.resumeConfig',?2,'$.stopReason','worker-restart'),updated_at=?3 WHERE id=?1 AND status='paused' AND coalesce(json_extract(runtime_json,'$.control'),'')!='discard'", params![id, saved, now()])?;
        Ok(())
    }
    pub fn replace_legacy_inventory(&self, intent: &PublicationIntent) -> rusqlite::Result<()> {
        self.save_archive_metadata(&intent.archive)?;
        self.finalize_intent(intent)
    }
    pub fn dispatch_due_schedules(&self) -> rusqlite::Result<usize> {
        let mut c = self.connect()?;
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let stamp = now();
        let due=tx.prepare("SELECT id,owner,document FROM owned_records WHERE kind='schedule' AND json_extract(document,'$.enabled')=1 AND json_extract(document,'$.nextRunAt')<=?1 ORDER BY id LIMIT 10")?.query_map([&stamp],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,from_json::<Value>(&r.get::<_,String>(2)?)?)))?.collect::<rusqlite::Result<Vec<_>>>()?;
        let mut count = 0;
        for (id, owner, mut value) in due {
            let active = if let Some(last) = value["lastJobId"].as_str() {
                tx.query_row("SELECT EXISTS(SELECT 1 FROM jobs WHERE id=?1 AND status IN ('queued','starting','running','packaging'))",[last],|r|r.get::<_,bool>(0))?
            } else {
                false
            };
            if active {
                continue;
            }
            let recipe: Option<String> = tx
                .query_row(
                    "SELECT document FROM owned_records WHERE kind='recipe' AND id=?1 AND owner=?2",
                    params![value["recipeId"].as_str().unwrap_or(""), owner],
                    |r| r.get(0),
                )
                .optional()?;
            value["lastRunAt"] = json!(stamp);
            value["nextRunAt"] = json!((chrono::Utc::now()
                + chrono::Duration::minutes(
                    value["intervalMinutes"]
                        .as_i64()
                        .unwrap_or(60)
                        .clamp(60, 525600)
                ))
            .to_rfc3339_opts(chrono::SecondsFormat::Millis, true));
            if let Some(recipe) = recipe {
                let recipe: Value = from_json(&recipe)?;
                let duplicate:Option<String>=tx.query_row("SELECT id FROM jobs WHERE created_by=?1 AND status IN ('queued','starting','running','packaging') AND json_extract(request_json,'$.url')=?2 AND coalesce(json_extract(runtime_json,'$.operation.kind'),'capture') IN ('capture','sample','repair') LIMIT 1",params![owner,recipe["request"]["url"].as_str().unwrap_or("")],|r|r.get(0)).optional()?;
                if let Some(existing) = duplicate {
                    value["lastJobId"] = json!(existing);
                    value["lastError"] =
                        json!("Existing active capture retained; duplicate dispatch skipped");
                    tx.execute(
                        "UPDATE owned_records SET document=?2 WHERE id=?1 AND kind='schedule'",
                        params![id, sql_json(&value)?],
                    )?;
                    continue;
                }
                let job_id = crate::queue::random_job_id();
                tx.execute("INSERT INTO jobs(id,created_at,updated_at,created_by,status,request_json) VALUES(?1,?2,?2,?3,'queued',?4)",params![job_id,stamp,owner,sql_json(&recipe["request"])?])?;
                value["lastJobId"] = json!(job_id);
                value["lastError"] = Value::Null;
                count += 1;
            } else {
                value["lastError"] = json!("recipe no longer available");
                value["enabled"] = json!(false);
            }
            tx.execute(
                "UPDATE owned_records SET document=?2 WHERE id=?1 AND kind='schedule'",
                params![id, sql_json(&value)?],
            )?;
        }
        tx.commit()?;
        Ok(count)
    }
}

impl Database {
    pub fn patch_record(
        &self,
        kind: &str,
        id: &str,
        owner: &str,
        patch: &Value,
    ) -> rusqlite::Result<usize> {
        self.connect()?.execute("UPDATE owned_records SET document=json_patch(document,?4) WHERE kind=?1 AND id=?2 AND owner=?3",params![kind,id,owner,sql_json(patch)?])
    }
    pub fn finish_schedules(&self, job: &crate::model::Job) -> rusqlite::Result<()> {
        self.connect()?.execute("UPDATE owned_records SET document=json_set(document,'$.lastError',?2,'$.lastResult',json(?3)) WHERE kind='schedule' AND owner=?4 AND json_extract(document,'$.lastJobId')=?1",params![job.id,job.error,sql_json(&json!({"status":job.status,"archiveId":job.runtime.archive_id,"finishedAt":now()}))?,job.created_by])?;
        Ok(())
    }
    pub fn queue_batch(
        &self,
        owner: &str,
        requests: &[CreateJobRequest],
    ) -> rusqlite::Result<Vec<String>> {
        let mut c = self.connect()?;
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let stamp = now();
        let mut ids = vec![];
        for r in requests {
            let id = crate::queue::random_job_id();
            tx.execute("INSERT INTO jobs(id,created_at,updated_at,created_by,status,request_json) VALUES(?1,?2,?2,?3,'queued',?4)",params![id,stamp,owner,sql_json(r)?])?;
            ids.push(id);
        }
        tx.commit()?;
        Ok(ids)
    }
    pub fn create_unique_capture(
        &self,
        id: &str,
        owner: &str,
        request: &CreateJobRequest,
    ) -> rusqlite::Result<bool> {
        let mut c = self.connect()?;
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let active=tx.query_row("SELECT EXISTS(SELECT 1 FROM jobs WHERE created_by=?1 AND status IN('queued','starting','running','packaging') AND json_extract(request_json,'$.url')=?2 AND coalesce(json_extract(runtime_json,'$.operation.kind'),'capture') IN('capture','sample','repair'))",params![owner,request.url],|r|r.get::<_,bool>(0))?;
        if active {
            return Ok(false);
        }
        tx.execute("INSERT INTO jobs(id,created_at,updated_at,created_by,status,request_json) VALUES(?1,?2,?2,?3,'queued',?4)",params![id,now(),owner,sql_json(request)?])?;
        tx.commit()?;
        Ok(true)
    }
    pub fn dependents(&self, id: &str, owner: &str) -> rusqlite::Result<Vec<String>> {
        self.connect()?.prepare("SELECT a.id FROM archives a JOIN json_each(json_extract(a.document,'$.dependencies')) dep ON dep.value=?1 WHERE a.owner=?2 LIMIT 1000")?.query_map(params![id,owner],|r|r.get(0))?.collect()
    }
}
