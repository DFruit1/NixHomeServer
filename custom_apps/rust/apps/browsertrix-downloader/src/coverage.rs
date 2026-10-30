//! Bounded durable coverage receipts; large inventories never enter polling.
use crate::{archive_engine::ArchiveReport, model::Job};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    io::{BufRead, BufReader, Read},
    path::Path,
};
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CoverageRecord {
    pub url: String,
    pub kind: String,
    pub reason: String,
    pub status: Option<u16>,
}
pub fn collect(
    root: &Path,
    job: &Job,
    report: &ArchiveReport,
) -> Result<Vec<CoverageRecord>, String> {
    let mut rows = Vec::new();
    for r in &report.resources {
        if r.status >= 400 {
            rows.push(CoverageRecord {
                url: r.url.chars().take(4096).collect(),
                kind: "captured-http-error".into(),
                reason: format!(
                    "Captured HTTP {} response; this is distinct from a missing replay resource",
                    r.status
                ),
                status: Some(r.status),
            });
        }
        if rows.len() >= 20000 {
            break;
        }
    }
    let collection = job.request.collection.as_deref().unwrap_or(&job.id);
    for (path, kind) in [
        (
            root.join("coverage.jsonl"),
            "intentionally-omitted-resource",
        ),
        (
            root.join("collections")
                .join(collection)
                .join("reports/skippedPages.jsonl"),
            "skipped-page",
        ),
    ] {
        if !path.exists() {
            continue;
        }
        let file = crate::custody::open_nofollow(&path)?;
        let truncated = file.metadata().map_err(|e| e.to_string())?.len() > 32 * 1024 * 1024;
        let mut reader = BufReader::new(file.take(32 * 1024 * 1024));
        let mut line = Vec::new();
        while rows.len() < 20000 {
            line.clear();
            let n = reader
                .by_ref()
                .take(16385)
                .read_until(b'\n', &mut line)
                .map_err(|e| e.to_string())?;
            if n == 0 {
                break;
            }
            if n > 16384 {
                rows.push(limit_record());
                break;
            }
            if let Ok(v) = serde_json::from_slice::<Value>(&line) {
                let url = v["url"].as_str().or_else(|| v["details"].as_str());
                let Some(url) = url else {
                    continue;
                };
                let reason = v["reason"]
                    .as_str()
                    .map(str::to_owned)
                    .unwrap_or_else(|| v["reason"].to_string());
                let recovered = kind == "skipped-page"
                    && reason == "pageLimit"
                    && report.pages.iter().any(|p| p.url == url);
                rows.push(CoverageRecord {
                    url: url.chars().take(4096).collect(),
                    kind: if recovered { "recovered-page" } else { kind }.into(),
                    reason: if recovered {
                        "Previously page-limited; captured in this version".into()
                    } else {
                        reason.chars().take(1000).collect()
                    },
                    status: None,
                });
            }
        }
        if truncated {
            rows.push(limit_record());
        }
    }
    if rows.len() >= 20000 {
        rows.truncate(20000);
        rows.push(limit_record());
    }
    Ok(rows)
}

/// Native queue limits can report even duplicate URLs as overflow. Treat an
/// exhausted budget as complete only when the entire bounded deferred list is
/// represented in the native captured-page inventory; unknown/truncated stays
/// partial. This never parses archive payloads in job polling.
pub fn unfinished_page_limit(root: &Path, collection: &str) -> Result<bool, String> {
    let base = root.join("collections").join(collection);
    let mut captured = std::collections::BTreeSet::new();
    for name in ["pages/pages.jsonl", "pages/extraPages.jsonl"] {
        let path = base.join(name);
        if !path.exists() {
            continue;
        }
        let Some(rows) = native_rows(&path)? else {
            return Ok(true);
        };
        for value in rows {
            if let Some(url) = value["url"].as_str() {
                captured.insert(url.to_owned());
            }
        }
    }
    if captured.is_empty() {
        return Ok(true);
    }
    let path = base.join("reports/skippedPages.jsonl");
    if !path.exists() {
        return Ok(true);
    }
    let Some(rows) = native_rows(&path)? else {
        return Ok(true);
    };
    Ok(rows.iter().any(|row| {
        row["reason"] == "pageLimit"
            && row["url"]
                .as_str()
                .is_none_or(|url| !captured.contains(url))
    }))
}
fn native_rows(path: &Path) -> Result<Option<Vec<Value>>, String> {
    let file = crate::custody::open_nofollow(path)?;
    if file.metadata().map_err(|e| e.to_string())?.len() > 32 * 1024 * 1024 {
        return Ok(None);
    }
    let mut input = BufReader::new(file);
    let mut rows = Vec::new();
    let mut line = Vec::new();
    loop {
        line.clear();
        let n = input
            .by_ref()
            .take(2 * 1024 * 1024 + 1)
            .read_until(b'\n', &mut line)
            .map_err(|e| e.to_string())?;
        if n == 0 {
            return Ok(Some(rows));
        }
        if n > 2 * 1024 * 1024 || rows.len() >= 20000 {
            return Ok(None);
        }
        let Ok(mut value) = serde_json::from_slice::<Value>(&line) else {
            return Ok(None);
        };
        // Drop native rendered text and unrelated fields immediately.
        if let Some(object) = value.as_object_mut() {
            object.retain(|key, _| matches!(key.as_str(), "url" | "reason"));
        }
        rows.push(value);
    }
}
fn limit_record() -> CoverageRecord {
    CoverageRecord{url:String::new(),kind:"coverage-limit".into(),reason:"Coverage receipt capped at 20,000 rows / 32MiB per native report; remaining native details were not catalogued, so this receipt is incomplete".into(),status:None}
}
