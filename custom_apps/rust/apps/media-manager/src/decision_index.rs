//! Additive, subject/credential-scoped decisions. Never mutate originals or Immich.
use crate::image_index::{probability, Index};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Rule {
    pub id: String,
    pub question: String,
    pub yes_tag: String,
    pub no_tag: String,
    pub automatic: bool,
}
impl Rule {
    pub fn signature(&self) -> String {
        format!(
            "{:x}",
            Sha256::digest(
                serde_json::to_vec(&(&self.question, &self.yes_tag, &self.no_tag)).unwrap()
            )
        )
    }
    pub fn valid(&self) -> bool {
        !self.id.is_empty()
            && self.id.len() <= 64
            && self
                .id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-')
            && !self.question.trim().is_empty()
            && self.question.len() <= 1000
            && !self.question.chars().any(char::is_control)
            && [&self.yes_tag, &self.no_tag]
                .into_iter()
                .all(|s| s.is_empty() || valid_tag(s))
    }
}
pub(crate) fn valid_tag(s: &str) -> bool {
    !s.trim().is_empty()
        && s == s.trim()
        && s.len() <= 96
        && !s.chars().any(|c| c.is_control() || c == ',')
}
pub(crate) fn initialize(db: &Connection) -> rusqlite::Result<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS decision_rules(scope TEXT PRIMARY KEY, rules TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS decision_tags(scope TEXT NOT NULL, asset_id TEXT NOT NULL, tag TEXT NOT NULL,
            PRIMARY KEY(scope,asset_id,tag));
        CREATE INDEX IF NOT EXISTS decision_tags_search ON decision_tags(scope,tag,asset_id);
        CREATE TABLE IF NOT EXISTS decision_retries(scope TEXT NOT NULL, asset_id TEXT NOT NULL, retry_at INTEGER NOT NULL,
            PRIMARY KEY(scope,asset_id));
        CREATE TABLE IF NOT EXISTS decision_results(scope TEXT NOT NULL, asset_id TEXT NOT NULL,
            rule_id TEXT NOT NULL, signature TEXT NOT NULL, probability REAL NOT NULL, assessed_at TEXT NOT NULL,
            PRIMARY KEY(scope,asset_id,rule_id));")
}
impl Index<'_> {
    pub fn decision_retry(&self, asset: &str, after: Option<i64>) -> rusqlite::Result<i64> {
        let db = self.store.index_connection()?;
        if let Some(after) = after {
            db.execute("INSERT INTO decision_retries VALUES(?1,?2,?3) ON CONFLICT(scope,asset_id) DO UPDATE SET retry_at=excluded.retry_at",params![self.scope,asset,after])?;
        }
        Ok(db
            .query_row(
                "SELECT retry_at FROM decision_retries WHERE scope=?1 AND asset_id=?2",
                params![self.scope, asset],
                |r| r.get(0),
            )
            .optional()?
            .unwrap_or(0))
    }
    pub fn rules(&self) -> rusqlite::Result<Vec<Rule>> {
        let raw: Option<String> = self
            .store
            .index_connection()?
            .query_row(
                "SELECT rules FROM decision_rules WHERE scope=?1",
                [self.scope],
                |r| r.get(0),
            )
            .optional()?;
        raw.map(|s| {
            serde_json::from_str(&s).map_err(|e| {
                rusqlite::Error::FromSqlConversionFailure(
                    0,
                    rusqlite::types::Type::Text,
                    Box::new(e),
                )
            })
        })
        .transpose()
        .map(Option::unwrap_or_default)
    }
    pub fn save_rules(&self, rules: &[Rule]) -> rusqlite::Result<()> {
        self.store.index_connection()?.execute(
            "INSERT INTO decision_rules(scope,rules) VALUES(?1,?2)
            ON CONFLICT(scope) DO UPDATE SET rules=excluded.rules",
            params![self.scope, serde_json::to_string(rules).unwrap()],
        )?;
        Ok(())
    }
    pub fn decision_tags(&self, asset: &str) -> rusqlite::Result<Vec<String>> {
        let db = self.store.index_connection()?;
        let mut stmt = db
            .prepare("SELECT tag FROM decision_tags WHERE scope=?1 AND asset_id=?2 ORDER BY tag")?;
        stmt.query_map(params![self.scope, asset], |r| r.get(0))?
            .collect()
    }
    pub fn needs_decision(&self, asset: &str, rule: &Rule) -> rusqlite::Result<bool> {
        let done: bool = self.store.index_connection()?.query_row(
            "SELECT EXISTS(SELECT 1 FROM decision_results
            WHERE scope=?1 AND asset_id=?2 AND rule_id=?3 AND signature=?4)",
            params![self.scope, asset, rule.id, rule.signature()],
            |r| r.get(0),
        )?;
        Ok(!done)
    }
    pub fn save_decisions(
        &self,
        asset: &str,
        rules: &[Rule],
        probabilities: &[f64],
        timestamp: &str,
    ) -> rusqlite::Result<bool> {
        let mut db = self.store.index_connection()?;
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        // A saved edit/removal during inference must not apply obsolete actions.
        let raw: String = tx.query_row(
            "SELECT rules FROM decision_rules WHERE scope=?1",
            [self.scope],
            |r| r.get(0),
        )?;
        let current: Vec<Rule> = serde_json::from_str(&raw).unwrap_or_default();
        if rules.len() != probabilities.len()
            || probabilities.iter().any(|p| !probability(*p))
            || rules.iter().any(|r| {
                !current.iter().any(|c| {
                    c.id == r.id && c.signature() == r.signature() && c.automatic == r.automatic
                })
            })
        {
            return Ok(false);
        }
        for (rule, p) in rules.iter().zip(probabilities) {
            let tag = if *p >= 0.5 {
                &rule.yes_tag
            } else {
                &rule.no_tag
            };
            if !tag.is_empty() {
                tx.execute(
                    "INSERT OR IGNORE INTO decision_tags VALUES(?1,?2,?3)",
                    params![self.scope, asset, tag],
                )?;
            }
            tx.execute("INSERT INTO decision_results VALUES(?1,?2,?3,?4,?5,?6)
                ON CONFLICT(scope,asset_id,rule_id) DO UPDATE SET signature=excluded.signature,probability=excluded.probability,assessed_at=excluded.assessed_at",
                params![self.scope,asset,rule.id,rule.signature(),p,timestamp])?;
        }
        tx.execute(
            "INSERT OR IGNORE INTO decision_tags VALUES(?1,?2,?3)",
            params![self.scope, asset, format!("auto-tagged {timestamp}")],
        )?;
        tx.execute(
            "DELETE FROM decision_retries WHERE scope=?1 AND asset_id=?2",
            params![self.scope, asset],
        )?;
        tx.commit()?;
        Ok(true)
    }
}
