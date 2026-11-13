//! Additive, subject/credential-scoped decisions. Never mutate originals.
use crate::image_index::{probability, Index, Scores};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

#[derive(Clone, Copy, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) enum RuleKind {
    /// One d1 proposition with optional Yes/No tag or archive actions.
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
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub yes_archive: bool,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub no_archive: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bounds: Option<ScoreBounds>,
    pub automatic: bool,
}
impl Rule {
    pub fn signature(&self) -> String {
        let original = format!(
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
        );
        // Keep existing assessments valid when neither new action is enabled.
        if self.yes_archive || self.no_archive {
            format!(
                "{:x}",
                Sha256::digest(format!(
                    "{original}:{}:{}",
                    self.yes_archive, self.no_archive
                ))
            )
        } else {
            original
        }
    }
    pub fn archives(&self, probability: f64) -> bool {
        self.kind == RuleKind::YesNo
            && if probability >= 0.5 {
                self.yes_archive
            } else {
                self.no_archive
            }
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
                        && (!self.yes_archive || self.yes_tag.is_empty())
                        && (!self.no_archive || self.no_tag.is_empty())
                        && [&self.yes_tag, &self.no_tag]
                            .into_iter()
                            .all(|s| s.is_empty() || valid_tag(s))
                }
                RuleKind::Category => {
                    self.yes_tag.is_empty()
                        && self.no_tag.is_empty()
                        && !self.yes_archive
                        && !self.no_archive
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
// The rollback closure reads only the five-field document in decision_rules.
// Use the richer document only while its legacy projection remains unchanged;
// edits made by an older binary must win over stale newer configuration.
const RULES_QUERY: &str = "SELECT COALESCE(d.rules,b.rules) FROM decision_rules b
    LEFT JOIN decision_rule_documents d ON d.scope=b.scope AND d.legacy_rules=b.rules
    WHERE b.scope=?1";

pub(crate) fn initialize(db: &Connection) -> rusqlite::Result<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS decision_rules(scope TEXT PRIMARY KEY, rules TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS decision_rule_documents(scope TEXT PRIMARY KEY, legacy_rules TEXT NOT NULL,
            rules TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS decision_tags(scope TEXT NOT NULL, asset_id TEXT NOT NULL, tag TEXT NOT NULL,
            PRIMARY KEY(scope,asset_id,tag));
        CREATE INDEX IF NOT EXISTS decision_tags_search ON decision_tags(scope,tag,asset_id);
        CREATE TABLE IF NOT EXISTS decision_retries(scope TEXT NOT NULL, asset_id TEXT NOT NULL, retry_at INTEGER NOT NULL,
            PRIMARY KEY(scope,asset_id));
        CREATE TABLE IF NOT EXISTS decision_results(scope TEXT NOT NULL, asset_id TEXT NOT NULL,
            rule_id TEXT NOT NULL, signature TEXT NOT NULL, probability REAL NOT NULL, assessed_at TEXT NOT NULL,
            PRIMARY KEY(scope,asset_id,rule_id));
        CREATE TABLE IF NOT EXISTS decision_album_assignments(scope TEXT NOT NULL, asset_id TEXT NOT NULL,
            rule_id TEXT NOT NULL, signature TEXT NOT NULL, name TEXT NOT NULL,
            PRIMARY KEY(scope,asset_id,rule_id));
        CREATE TABLE IF NOT EXISTS decision_archive_assignments(scope TEXT NOT NULL, asset_id TEXT NOT NULL,
            rule_id TEXT NOT NULL, signature TEXT NOT NULL,
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
            .query_row(RULES_QUERY, [self.scope], |r| r.get(0))
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
        let mut db = self.store.index_connection()?;
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        // Unsupported category/bounded questions remain retained in the new
        // document, but cannot run with different semantics on an old closure.
        let legacy: Vec<_> = rules
            .iter()
            .filter(|r| {
                r.kind == RuleKind::YesNo
                    && !r.yes_archive
                    && !r.no_archive
                    && !r.bounds.as_ref().is_some_and(ScoreBounds::any)
            })
            .map(|r| {
                serde_json::json!({
                    "id": r.id, "question": r.question, "yesTag": r.yes_tag,
                    "noTag": r.no_tag, "automatic": r.automatic,
                })
            })
            .collect();
        let legacy = serde_json::to_string(&legacy).unwrap();
        tx.execute(
            "INSERT INTO decision_rule_documents(scope,legacy_rules,rules) VALUES(?1,?2,?3)
             ON CONFLICT(scope) DO UPDATE SET legacy_rules=excluded.legacy_rules,rules=excluded.rules",
            params![self.scope, legacy, serde_json::to_string(rules).unwrap()],
        )?;
        tx.execute(
            "INSERT INTO decision_rules(scope,rules) VALUES(?1,?2)
            ON CONFLICT(scope) DO UPDATE SET rules=excluded.rules",
            params![self.scope, legacy],
        )?;
        // Rule edits cancel only pending remote actions; applied actions remain.
        for table in ["decision_album_assignments", "decision_archive_assignments"] {
            let obsolete = {
                let mut stmt = tx.prepare(&format!(
                    "SELECT DISTINCT rule_id,signature FROM {table} WHERE scope=?1"
                ))?;
                let rows = stmt.query_map([self.scope], |r| {
                    Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
                })?;
                rows.collect::<rusqlite::Result<Vec<_>>>()?
            };
            for (rule_id, signature) in obsolete {
                if !rules
                    .iter()
                    .any(|r| r.id == rule_id && r.signature() == signature)
                {
                    tx.execute(
                        &format!(
                            "DELETE FROM {table} WHERE scope=?1 AND rule_id=?2 AND signature=?3"
                        ),
                        params![self.scope, rule_id, signature],
                    )?;
                }
            }
        }
        tx.commit()
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
    pub fn pending_album(&self, asset: &str, rule: &Rule) -> rusqlite::Result<Option<String>> {
        self.store
            .index_connection()?
            .query_row(
                "SELECT name FROM decision_album_assignments
             WHERE scope=?1 AND asset_id=?2 AND rule_id=?3 AND signature=?4",
                params![self.scope, asset, rule.id, rule.signature()],
                |r| r.get(0),
            )
            .optional()
    }
    pub fn complete_album(&self, asset: &str, rule: &Rule, name: &str) -> rusqlite::Result<()> {
        self.store.index_connection()?.execute(
            "DELETE FROM decision_album_assignments
             WHERE scope=?1 AND asset_id=?2 AND rule_id=?3 AND signature=?4 AND name=?5",
            params![self.scope, asset, rule.id, rule.signature(), name],
        )?;
        Ok(())
    }
    pub fn pending_archive(&self, asset: &str, rule: &Rule) -> rusqlite::Result<bool> {
        self.store.index_connection()?.query_row(
            "SELECT EXISTS(SELECT 1 FROM decision_archive_assignments WHERE scope=?1 AND asset_id=?2 AND rule_id=?3 AND signature=?4)",
            params![self.scope, asset, rule.id, rule.signature()], |r| r.get(0))
    }
    pub fn complete_archive(&self, asset: &str, rule: &Rule) -> rusqlite::Result<()> {
        self.store.index_connection()?.execute(
            "DELETE FROM decision_archive_assignments WHERE scope=?1 AND asset_id=?2 AND rule_id=?3 AND signature=?4",
            params![self.scope, asset, rule.id, rule.signature()])?;
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
        albums: &[Option<&str>],
    ) -> rusqlite::Result<bool> {
        let mut db = self.store.index_connection()?;
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        // A saved edit/removal during inference must not apply obsolete actions.
        let raw: String = tx.query_row(RULES_QUERY, [self.scope], |r| r.get(0))?;
        let current: Vec<Rule> = serde_json::from_str(&raw).unwrap_or_default();
        if rules.len() != probabilities.len()
            || rules.len() != albums.len()
            || probabilities.iter().any(|p| !probability(*p))
            || rules.iter().any(|r| {
                !current.iter().any(|c| {
                    c.id == r.id && c.signature() == r.signature() && c.automatic == r.automatic
                })
            })
        {
            return Ok(false);
        }
        for ((rule, p), album) in rules.iter().zip(probabilities).zip(albums) {
            tx.execute(
                "DELETE FROM decision_album_assignments WHERE scope=?1 AND asset_id=?2 AND rule_id=?3",
                params![self.scope, asset, rule.id],
            )?;
            if let Some(name) = album {
                // Persist the selected category atomically with inference/tags.
                // Network errors must not make a completed assessment lose its work.
                tx.execute(
                    "INSERT INTO decision_album_assignments VALUES(?1,?2,?3,?4,?5)",
                    params![self.scope, asset, rule.id, rule.signature(), name],
                )?;
            }
            tx.execute("DELETE FROM decision_archive_assignments WHERE scope=?1 AND asset_id=?2 AND rule_id=?3", params![self.scope, asset, rule.id])?;
            if !asset.starts_with("file:") && rule.archives(*p) {
                tx.execute(
                    "INSERT INTO decision_archive_assignments VALUES(?1,?2,?3,?4)",
                    params![self.scope, asset, rule.id, rule.signature()],
                )?;
            }
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
