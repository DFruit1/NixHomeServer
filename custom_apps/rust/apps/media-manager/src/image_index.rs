//! Private, derived photo metadata. Stored beside provider accounts, never in
//! Immich or sidecars. A credential change starts a separate index partition.
use crate::provider_accounts::ProviderAccountStore;
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

pub(crate) const MODEL: &str = "eye@v1.0.0";
pub(crate) const PAGE_SIZE: usize = 48;

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Suggestion {
    pub tag: String,
    pub confidence: f64,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Scores {
    pub aesthetic: f64,
    pub keeper: f64,
    pub cover: f64,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Analysis {
    pub model: String,
    pub suggestions: Vec<Suggestion>,
    pub scores: Scores,
}

pub(crate) fn initialize(db: &Connection) -> rusqlite::Result<()> {
    db.execute_batch(
        "CREATE TABLE IF NOT EXISTS image_assets (
           scope TEXT NOT NULL, asset_id TEXT NOT NULL,
           filename TEXT NOT NULL, captured_at TEXT NOT NULL,
           analysis TEXT, aesthetic REAL, keeper REAL, cover REAL,
           seen INTEGER NOT NULL, retry_at INTEGER NOT NULL DEFAULT 0,
           PRIMARY KEY(scope, asset_id)
         );
         CREATE INDEX IF NOT EXISTS image_assets_date ON image_assets(scope, captured_at, asset_id);
         CREATE TABLE IF NOT EXISTS image_tags (
           scope TEXT NOT NULL, asset_id TEXT NOT NULL, tag TEXT NOT NULL,
           confidence REAL NOT NULL, PRIMARY KEY(scope, asset_id, tag),
           FOREIGN KEY(scope, asset_id) REFERENCES image_assets(scope, asset_id) ON DELETE CASCADE
         );
         CREATE INDEX IF NOT EXISTS image_tags_search ON image_tags(scope, tag, confidence, asset_id);
         CREATE TABLE IF NOT EXISTS image_scans (
           scope TEXT PRIMARY KEY, page INTEGER NOT NULL DEFAULT 1,
           generation INTEGER NOT NULL DEFAULT 1, next_scan INTEGER NOT NULL DEFAULT 0,
           error TEXT
         );",
    )
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub(crate) struct Search {
    pub page: u32,
    pub query: String,
    pub tags: String,
    pub tag_mode: String,
    pub confidence: f64,
    pub min_aesthetic: f64,
    pub min_keeper: f64,
    pub min_cover: f64,
    pub sort: String,
    pub direction: String,
    pub sort_tag: String,
    pub aesthetic_weight: f64,
    pub keeper_weight: f64,
    pub cover_weight: f64,
}
impl Default for Search {
    fn default() -> Self {
        Self {
            page: 1,
            query: String::new(),
            tags: String::new(),
            tag_mode: "all".into(),
            confidence: 0.5,
            min_aesthetic: 0.0,
            min_keeper: 0.0,
            min_cover: 0.0,
            sort: "capturedAt".into(),
            direction: "desc".into(),
            sort_tag: String::new(),
            aesthetic_weight: 1.0,
            keeper_weight: 1.0,
            cover_weight: 1.0,
        }
    }
}
pub(crate) fn valid_tag(tag: &str) -> bool {
    !tag.is_empty()
        && tag.len() <= 96
        && tag
            .bytes()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'_')
}
pub(crate) fn probability(n: f64) -> bool {
    n.is_finite() && (0.0..=1.0).contains(&n)
}
impl Search {
    pub fn tags(&self) -> Vec<&str> {
        self.tags
            .split(',')
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .collect()
    }
    pub fn valid(&self) -> bool {
        (1..=100_000).contains(&self.page)
            && self.query.len() <= 200
            && !self.query.chars().any(char::is_control)
            && self.tags.len() <= 3104
            && self.tags().len() <= 32
            && self.tags().iter().all(|t| valid_tag(t))
            && ["all", "any"].contains(&self.tag_mode.as_str())
            && [
                self.confidence,
                self.min_aesthetic,
                self.min_keeper,
                self.min_cover,
            ]
            .into_iter()
            .all(probability)
            && [
                "capturedAt",
                "aesthetic",
                "keeper",
                "cover",
                "scores",
                "tag",
            ]
            .contains(&self.sort.as_str())
            && ["asc", "desc"].contains(&self.direction.as_str())
            && (self.sort_tag.is_empty() || valid_tag(&self.sort_tag))
            && (self.sort != "tag" || valid_tag(&self.sort_tag))
            && [self.aesthetic_weight, self.keeper_weight, self.cover_weight]
                .into_iter()
                .all(|w| w.is_finite() && (0.0..=100.0).contains(&w))
            && (self.sort != "scores"
                || self.aesthetic_weight + self.keeper_weight + self.cover_weight > 0.0)
    }
}

pub(crate) struct Index<'a> {
    pub store: &'a ProviderAccountStore,
    pub scope: &'a str,
}
impl Index<'_> {
    pub fn observe(
        &self,
        id: &str,
        filename: &str,
        date: &str,
        generation: i64,
    ) -> rusqlite::Result<()> {
        self.store.index_connection()?.execute(
            "INSERT INTO image_assets(scope,asset_id,filename,captured_at,seen) VALUES (?1,?2,?3,?4,?5)
             ON CONFLICT(scope,asset_id) DO UPDATE SET filename=excluded.filename,captured_at=excluded.captured_at,seen=excluded.seen",
            params![self.scope,id,filename,date,generation])?;
        Ok(())
    }
    pub fn analysis(&self, id: &str) -> rusqlite::Result<Option<Analysis>> {
        let json: Option<String> = self
            .store
            .index_connection()?
            .query_row(
                "SELECT analysis FROM image_assets WHERE scope=?1 AND asset_id=?2",
                params![self.scope, id],
                |r| r.get(0),
            )
            .optional()?
            .flatten();
        Ok(json
            .and_then(|v| serde_json::from_str::<Analysis>(&v).ok())
            .filter(|a| a.model == MODEL))
    }
    pub fn save(&self, id: &str, analysis: &Analysis) -> rusqlite::Result<()> {
        let mut db = self.store.index_connection()?;
        let tx = db.transaction()?;
        tx.execute("UPDATE image_assets SET analysis=?3,aesthetic=?4,keeper=?5,cover=?6,retry_at=0 WHERE scope=?1 AND asset_id=?2",
            params![self.scope,id,serde_json::to_string(analysis).expect("validated analysis"),analysis.scores.aesthetic,analysis.scores.keeper,analysis.scores.cover])?;
        tx.execute(
            "DELETE FROM image_tags WHERE scope=?1 AND asset_id=?2",
            params![self.scope, id],
        )?;
        for tag in &analysis.suggestions {
            tx.execute(
                "INSERT INTO image_tags(scope,asset_id,tag,confidence) VALUES (?1,?2,?3,?4)
                ON CONFLICT(scope,asset_id,tag) DO UPDATE SET confidence=excluded.confidence",
                params![self.scope, id, tag.tag, tag.confidence],
            )?;
        }
        tx.commit()
    }
    pub fn retry_at(&self, id: &str, after: Option<i64>) -> rusqlite::Result<i64> {
        let db = self.store.index_connection()?;
        if let Some(after) = after {
            db.execute(
                "UPDATE image_assets SET retry_at=?3 WHERE scope=?1 AND asset_id=?2",
                params![self.scope, id, after],
            )?;
        }
        db.query_row(
            "SELECT retry_at FROM image_assets WHERE scope=?1 AND asset_id=?2",
            params![self.scope, id],
            |r| r.get(0),
        )
    }
    pub fn search(&self, q: &Search) -> rusqlite::Result<Vec<String>> {
        // Only fixed expressions are interpolated. Every user value is bound.
        let sort = match q.sort.as_str() {
            "aesthetic" => "a.aesthetic", "keeper" => "a.keeper", "cover" => "a.cover",
            "scores" => "(a.aesthetic*?10 + a.keeper*?11 + a.cover*?12) / (?10+?11+?12)",
            "tag" => "coalesce((SELECT confidence FROM image_tags WHERE scope=a.scope AND asset_id=a.asset_id AND tag=?9),0)",
            _ => "a.captured_at",
        };
        let direction = if q.direction == "asc" { "ASC" } else { "DESC" };
        let sql = format!("SELECT a.asset_id FROM image_assets a WHERE a.scope=?1
            AND instr(lower(a.filename),lower(?2))>0
            AND (?3='[]' OR (SELECT count(*) FROM image_tags t WHERE t.scope=a.scope AND t.asset_id=a.asset_id
              AND t.confidence>=?4 AND t.tag IN (SELECT value FROM json_each(?3))) >=
              CASE WHEN ?5='any' THEN 1 ELSE json_array_length(?3) END)
            AND (?6=0 OR a.aesthetic>=?6) AND (?7=0 OR a.keeper>=?7) AND (?8=0 OR a.cover>=?8)
            AND (?13='capturedAt' OR a.analysis IS NOT NULL)
            ORDER BY {sort} {direction}, a.asset_id ASC LIMIT ?14 OFFSET ?15");
        let db = self.store.index_connection()?;
        let mut stmt = db.prepare(&sql)?;
        let tags = q
            .tags()
            .into_iter()
            .collect::<std::collections::BTreeSet<_>>();
        stmt.query_map(
            params![
                self.scope,
                q.query.trim(),
                serde_json::to_string(&tags).expect("tags"),
                q.confidence,
                q.tag_mode,
                q.min_aesthetic,
                q.min_keeper,
                q.min_cover,
                q.sort_tag,
                q.aesthetic_weight,
                q.keeper_weight,
                q.cover_weight,
                q.sort,
                PAGE_SIZE as i64 + 1,
                (q.page as i64 - 1) * PAGE_SIZE as i64
            ],
            |r| r.get(0),
        )?
        .collect()
    }
    pub fn scan(&self) -> rusqlite::Result<(u32, i64, i64)> {
        let db = self.store.index_connection()?;
        db.execute(
            "INSERT OR IGNORE INTO image_scans(scope) VALUES (?1)",
            [self.scope],
        )?;
        db.query_row(
            "SELECT page,generation,next_scan FROM image_scans WHERE scope=?1",
            [self.scope],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
    }
    pub fn advance(
        &self,
        page: Option<u32>,
        generation: i64,
        now: i64,
        failed: bool,
    ) -> rusqlite::Result<()> {
        let mut db = self.store.index_connection()?;
        let tx = db.transaction()?;
        if page.is_none() {
            tx.execute(
                "DELETE FROM image_assets WHERE scope=?1 AND seen<>?2",
                params![self.scope, generation],
            )?;
        }
        tx.execute(
            "UPDATE image_scans SET page=?2,generation=?3,next_scan=?4,error=?5 WHERE scope=?1",
            params![
                self.scope,
                page.unwrap_or(1),
                generation + i64::from(page.is_none()),
                if page.is_none() { now + 1800 } else { 0 },
                if failed {
                    Some("Some photos could not be analyzed; they will be retried.")
                } else {
                    None
                }
            ],
        )?;
        tx.commit()
    }
    pub fn fail(&self) -> rusqlite::Result<()> {
        self.store.index_connection()?.execute("UPDATE image_scans SET error='Indexing paused; retrying automatically.',next_scan=?2 WHERE scope=?1",params![self.scope,crate::http::unix_timestamp()+60])?;
        Ok(())
    }
    pub fn status(&self) -> rusqlite::Result<serde_json::Value> {
        let db = self.store.index_connection()?;
        let (total, analyzed, failed): (i64,i64,i64) = db.query_row(
            "SELECT count(*),count(analysis),coalesce(sum(retry_at>0),0) FROM image_assets WHERE scope=?1",[self.scope],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?)))?;
        let scan: Option<(i64, Option<String>)> = db
            .query_row(
                "SELECT next_scan,error FROM image_scans WHERE scope=?1",
                [self.scope],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        Ok(
            serde_json::json!({"discovered":total,"analyzed":analyzed,"failed":failed,"scanning":scan.as_ref().is_none_or(|s| s.0<=crate::http::unix_timestamp()),"error":scan.and_then(|s|s.1)}),
        )
    }
}
