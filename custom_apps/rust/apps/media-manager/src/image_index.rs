//! Private, derived photo metadata. Stored beside provider accounts, never in
//! Immich or sidecars. A credential change starts a separate index partition.
use crate::{image_search, provider_accounts::ProviderAccountStore};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

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
           tagged INTEGER NOT NULL DEFAULT 0,
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
    )?;
    let has_tagged = db
        .prepare("PRAGMA table_info(image_assets)")?
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<rusqlite::Result<Vec<_>>>()?
        .iter()
        .any(|name| name == "tagged");
    if !has_tagged {
        let tx = db.unchecked_transaction()?;
        tx.execute_batch(
            "ALTER TABLE image_assets ADD COLUMN tagged INTEGER NOT NULL DEFAULT 0;
            UPDATE image_assets SET tagged=1 WHERE analysis IS NOT NULL;",
        )?;
        tx.commit()?;
    }
    Ok(())
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub(crate) struct Search {
    pub page: u32,
    pub query: String,
    pub tags: String,
    pub tag_mode: String,
    pub related: bool,
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
            related: true,
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
    /// Typed words as normalised EYE-style identifiers, in input order.
    pub fn terms(&self) -> Vec<String> {
        let mut seen = BTreeSet::new();
        self.tags
            .split(',')
            .map(str::trim)
            .filter(|term| !term.is_empty())
            .map(image_search::normalize)
            .filter(|term| !term.is_empty() && seen.insert(term.clone()))
            .collect()
    }
    pub fn valid(&self) -> bool {
        let terms = self.terms();
        (1..=100_000).contains(&self.page)
            && self.query.len() <= 200
            && !self.query.chars().any(char::is_control)
            && self.tags.len() <= 3104
            && terms.len() <= image_search::MAX_TERMS
            && terms.iter().all(|term| valid_tag(term))
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
            && self.sort_tag.len() <= 96
            && (self.sort != "tag" || valid_tag(&image_search::normalize(&self.sort_tag)))
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
        tx.execute("UPDATE image_assets SET analysis=?3,aesthetic=?4,keeper=?5,cover=?6,retry_at=0,tagged=1 WHERE scope=?1 AND asset_id=?2",
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
    pub fn tagged(&self, id: &str) -> rusqlite::Result<bool> {
        Ok(self
            .store
            .index_connection()?
            .query_row(
                "SELECT tagged FROM image_assets WHERE scope=?1 AND asset_id=?2",
                params![self.scope, id],
                |row| row.get(0),
            )
            .optional()?
            .unwrap_or(false))
    }
    /// Retain useful previous analysis until a replacement has been saved.
    pub fn mark_for_retagging(&self, id: &str) -> rusqlite::Result<()> {
        self.store.index_connection()?.execute(
            "UPDATE image_assets SET tagged=0,retry_at=0 WHERE scope=?1 AND asset_id=?2",
            params![self.scope, id],
        )?;
        Ok(())
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
    /// Matching asset ids plus the widened tags that actually occur in this
    /// account's index, for the browser to explain them.
    pub fn search(
        &self,
        q: &Search,
    ) -> rusqlite::Result<(Vec<String>, Vec<image_search::TagMatch>)> {
        // Only fixed expressions are interpolated. Every user value is bound.
        let sort = match q.sort.as_str() {
            "aesthetic" => "a.aesthetic", "keeper" => "a.keeper", "cover" => "a.cover",
            "scores" => "(a.aesthetic*?10 + a.keeper*?11 + a.cover*?12) / (?10+?11+?12)",
            "tag" => "coalesce((SELECT max(confidence) FROM image_tags WHERE scope=a.scope AND asset_id=a.asset_id AND tag IN (SELECT value FROM json_each(?9))),0)",
            _ => "a.captured_at",
        };
        let direction = if q.direction == "asc" { "ASC" } else { "DESC" };
        // The tag filter is resolved once for the whole scope instead of inside a
        // per-asset correlated subquery: a correlated "tag IN list" made SQLite
        // drive each asset from the tag index, scanning every row sharing the tag
        // for every candidate photo (tens of seconds on a real library).
        //
        // Each typed word keeps its own candidate group, so a widened word still
        // counts once toward "all tags". Decision tags are compared with their
        // saved spelling; the caller adds the raw values to the same group.
        let sql = format!(
            "SELECT a.asset_id FROM image_assets a WHERE a.scope=?1
            AND instr(lower(a.filename),lower(?2))>0
            AND (?3='[]' OR a.asset_id IN (
                SELECT matched.asset_id FROM (
                  SELECT t.asset_id AS asset_id, qt.key AS term FROM image_tags t, json_each(?3) qt
                    WHERE t.scope=?1 AND t.confidence>=?4
                      AND t.tag IN (SELECT value FROM json_each(qt.value))
                  UNION
                  SELECT d.asset_id, qt.key FROM decision_tags d, json_each(?3) qt
                    WHERE d.scope=?1
                      AND d.tag IN (SELECT value FROM json_each(qt.value))
                ) matched
                GROUP BY matched.asset_id
                HAVING count(DISTINCT matched.term) >=
                  CASE WHEN ?5='any' THEN 1 ELSE (SELECT count(*) FROM json_each(?3)) END
              ))
            AND (?6=0 OR a.aesthetic>=?6) AND (?7=0 OR a.keeper>=?7) AND (?8=0 OR a.cover>=?8)
            AND (?13='capturedAt' OR a.analysis IS NOT NULL)
            ORDER BY {sort} {direction}, a.asset_id ASC LIMIT ?14 OFFSET ?15"
        );
        let db = self.store.index_connection()?;
        let mut plan = image_search::plan(&q.terms(), q.related);
        let decision_tags = distinct_decision_tags(&db, self.scope)?;
        plan.attach_decision_tags(&decision_tags);
        let sort_plan = if q.sort == "tag" {
            image_search::plan(&[image_search::normalize(&q.sort_tag)], q.related)
        } else {
            image_search::plan(&[], false)
        };
        let present = present_tags(&db, self.scope, q.confidence, &plan, &decision_tags)?;
        let mut stmt = db.prepare(&sql)?;
        let ids = stmt
            .query_map(
                params![
                    self.scope,
                    q.query.trim(),
                    plan.groups(),
                    q.confidence,
                    q.tag_mode,
                    q.min_aesthetic,
                    q.min_keeper,
                    q.min_cover,
                    sort_plan.flat(),
                    q.aesthetic_weight,
                    q.keeper_weight,
                    q.cover_weight,
                    q.sort,
                    PAGE_SIZE as i64 + 1,
                    (q.page as i64 - 1) * PAGE_SIZE as i64
                ],
                |r| r.get(0),
            )?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok((ids, plan.report(&present)))
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

/// Decision tags are stored exactly as their owner wrote them. A search reads
/// the scope's distinct values once so `image_search` can attach the matching
/// raw spelling to each typed word.
fn distinct_decision_tags(db: &Connection, scope: &str) -> rusqlite::Result<Vec<String>> {
    let mut stmt = db.prepare("SELECT DISTINCT tag FROM decision_tags WHERE scope=?1")?;
    stmt.query_map([scope], |row| row.get(0))?.collect()
}

/// Tags from this account's index that would count for the current search, so
/// the response can name the widening that actually applies to these photos.
fn present_tags(
    db: &Connection,
    scope: &str,
    confidence: f64,
    plan: &image_search::Plan,
    decision_tags: &[String],
) -> rusqlite::Result<BTreeSet<String>> {
    let mut present: BTreeSet<String> = decision_tags.iter().cloned().collect();
    if plan.terms.is_empty() {
        return Ok(present);
    }
    let mut stmt = db.prepare(
        "SELECT DISTINCT tag FROM image_tags
         WHERE scope=?1 AND confidence>=?2
           AND tag IN (SELECT value FROM json_each(?3))",
    )?;
    let matched = stmt.query_map(params![scope, confidence, plan.flat()], |row| {
        row.get::<_, String>(0)
    })?;
    for tag in matched {
        present.insert(tag?);
    }
    Ok(present)
}
