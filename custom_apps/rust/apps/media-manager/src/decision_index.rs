//! Additive, subject/credential-scoped decisions. Never mutate originals.
use crate::image_index::{probability, Index, Scores};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

#[derive(Clone, Copy, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) enum RuleKind {
    /// One d1 proposition with optional Yes/No tags.
    #[default]
    YesNo,
    /// One d1 proposition per category; the most probable category names an
    /// Immich album for the assessed photo.
    Category,
}

#[derive(Clone, Default, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ScoreBounds {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub aesthetic_min: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub aesthetic_max: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub keeper_min: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub keeper_max: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover_min: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover_max: Option<f64>,
}

impl ScoreBounds {
    pub fn any(&self) -> bool {
        [
            self.aesthetic_min,
            self.aesthetic_max,
            self.keeper_min,
            self.keeper_max,
            self.cover_min,
            self.cover_max,
        ]
        .into_iter()
        .any(|bound| bound.is_some())
    }

    fn valid(&self) -> bool {
        [
            (self.aesthetic_min, self.aesthetic_max),
            (self.keeper_min, self.keeper_max),
            (self.cover_min, self.cover_max),
        ]
        .into_iter()
        .all(|(min, max)| {
            [min, max].into_iter().flatten().all(probability)
                && match (min, max) {
                    (Some(min), Some(max)) => min <= max,
                    _ => true,
                }
        })
    }

    /// EYE scores are relative model judgments; a bound only gates whether the
    /// rule runs. Scores are never used as question answers.
    pub fn allows(&self, scores: &Scores) -> bool {
        self.aesthetic_min.is_none_or(|min| scores.aesthetic >= min)
            && self.aesthetic_max.is_none_or(|max| scores.aesthetic <= max)
            && self.keeper_min.is_none_or(|min| scores.keeper >= min)
            && self.keeper_max.is_none_or(|max| scores.keeper <= max)
            && self.cover_min.is_none_or(|min| scores.cover >= min)
            && self.cover_max.is_none_or(|max| scores.cover <= max)
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Rule {
    pub id: String,
    #[serde(default)]
    pub kind: RuleKind,
    pub question: String,
    #[serde(default)]
    pub yes_tag: String,
    #[serde(default)]
    pub no_tag: String,
    #[serde(default)]
    pub categories: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bounds: Option<ScoreBounds>,
    pub automatic: bool,
}
impl Rule {
    pub fn signature(&self) -> String {
        format!(
            "{:x}",
            Sha256::digest(
                serde_json::to_vec(&(
                    self.kind,
                    &self.question,
                    &self.yes_tag,
                    &self.no_tag,
                    &self.categories,
                    &self.bounds,
                ))
                .unwrap()
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
            && match self.kind {
                RuleKind::YesNo => {
                    self.categories.is_empty()
                        && [&self.yes_tag, &self.no_tag]
                            .into_iter()
                            .all(|s| s.is_empty() || valid_tag(s))
                }
                RuleKind::Category => {
                    self.yes_tag.is_empty()
                        && self.no_tag.is_empty()
                        && (2..=12).contains(&self.categories.len())
                        && self.categories.iter().all(|name| valid_category(name))
                        && {
                            let unique: std::collections::BTreeSet<String> = self
                                .categories
                                .iter()
                                .map(|name| name.to_lowercase())
                                .collect();
                            unique.len() == self.categories.len()
                        }
                }
            }
            && self.bounds.as_ref().is_none_or(ScoreBounds::valid)
    }
}
pub(crate) fn valid_tag(s: &str) -> bool {
    !s.trim().is_empty()
        && s == s.trim()
        && s.len() <= 96
        && !s.chars().any(|c| c.is_control() || c == ',')
}
pub(crate) fn valid_category(name: &str) -> bool {
    !name.trim().is_empty()
        && name == name.trim()
        && name.len() <= 96
        && !name.chars().any(char::is_control)
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
            PRIMARY KEY(scope,asset_id,rule_id));
        CREATE TABLE IF NOT EXISTS decision_albums(scope TEXT NOT NULL, name TEXT NOT NULL, album_id TEXT NOT NULL,
            PRIMARY KEY(scope,name));")
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
    pub fn album_id(&self, name: &str) -> rusqlite::Result<Option<String>> {
        self.store
            .index_connection()?
            .query_row(
                "SELECT album_id FROM decision_albums WHERE scope=?1 AND name=?2",
                params![self.scope, name],
                |r| r.get(0),
            )
            .optional()
    }
    pub fn save_album(&self, name: &str, album_id: &str) -> rusqlite::Result<()> {
        self.store.index_connection()?.execute(
            "INSERT INTO decision_albums(scope,name,album_id) VALUES(?1,?2,?3)
            ON CONFLICT(scope,name) DO UPDATE SET album_id=excluded.album_id",
            params![self.scope, name, album_id],
        )?;
        Ok(())
    }
    pub fn forget_album(&self, name: &str) -> rusqlite::Result<()> {
        self.store.index_connection()?.execute(
            "DELETE FROM decision_albums WHERE scope=?1 AND name=?2",
            params![self.scope, name],
        )?;
        Ok(())
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
            let tag = if rule.kind == RuleKind::YesNo && *p >= 0.5 {
                &rule.yes_tag
            } else if rule.kind == RuleKind::YesNo {
                &rule.no_tag
            } else {
                ""
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
