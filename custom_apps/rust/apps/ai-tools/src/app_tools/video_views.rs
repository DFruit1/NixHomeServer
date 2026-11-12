//! Read-only downloader views. Authorization stays with the app gateway and
//! owner-scoped API; verify its owner contract before exposing any job data.
use super::{invalid, project, unavailable, valid_job_id, video_url};
use rmcp::ErrorData;
use serde::Deserialize;
use serde_json::{json, Value};

const STATUSES: &[&str] = &[
    "queued",
    "alert",
    "probing",
    "running",
    "postprocessing",
    "completed",
    "failed",
    "cancelled",
];
const MAX_BYTES: usize = 24 * 1024;
const MAX_ITEMS: usize = 10000;

/// Constructed from /api/me fetched with this operation's SSO session. Keep
/// the proof local to one call: neither tool arguments nor cached claims can
/// establish the downloader account that owns a job.
pub(super) struct Owner(String);

impl Owner {
    pub(super) fn from_session(payload: &Value, gateway_username: &str) -> Result<Self, ErrorData> {
        let username = payload["username"]
            .as_str()
            .filter(|name| {
                !name.is_empty()
                    && name.len() <= 64
                    && name
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
            })
            .ok_or_else(|| unavailable("Downloader returned an invalid current account"))?;
        // Compare using this app's existing SPN-local, case-preserved mapping;
        // the account itself must also be proven by the current app session.
        if gateway_username.split('@').next() != Some(username) {
            return Err(super::session_required());
        }
        Ok(Self(username.to_owned()))
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct JobsParams {
    url: Option<String>,
    query: Option<String>,
    status: Option<String>,
    offset: Option<usize>,
    limit: Option<usize>,
}

impl JobsParams {
    pub(super) fn validate(&self) -> Result<(), ErrorData> {
        page_args(self.offset, Some(self.limit.unwrap_or(8)), 20, 100)?;
        if self
            .query
            .as_ref()
            .is_some_and(|q| q.trim().is_empty() || q.len() > 256)
            || self
                .status
                .as_deref()
                .is_some_and(|s| !STATUSES.contains(&s))
        {
            return Err(invalid(
                "Use a nonempty query up to 256 bytes and a listed job status",
            ));
        }
        if let Some(url) = &self.url {
            video_url(url)?;
        }
        Ok(())
    }
}

pub(super) fn page_args(
    offset: Option<usize>,
    limit: Option<usize>,
    maximum: usize,
    last_offset: usize,
) -> Result<(usize, usize), ErrorData> {
    let (offset, limit) = (offset.unwrap_or(0), limit.unwrap_or(20));
    if offset > last_offset || !(1..=maximum).contains(&limit) {
        return Err(invalid(
            "Pagination is outside the tool's offset/limit bounds",
        ));
    }
    Ok((offset, limit))
}

fn clip(value: &mut Value, fields: &[&str]) {
    let mut truncated = Vec::new();
    for field in fields {
        if let Some(text) = value[*field].as_str()
            && text.len() > 1024
        {
            let mut end = 1024;
            while !text.is_char_boundary(end) {
                end -= 1;
            }
            value[*field] = json!(&text[..end]);
            truncated.push(*field);
        }
    }
    if !truncated.is_empty() {
        value["truncated_fields"] = json!(truncated);
    }
}

fn owner(job: &Value, account: &Owner) -> Result<(), ErrorData> {
    if job["createdBy"].as_str() != Some(account.0.as_str())
        || !job["id"].as_str().is_some_and(valid_job_id)
        || !job["status"]
            .as_str()
            .is_some_and(|s| STATUSES.contains(&s))
    {
        return Err(unavailable(
            "Downloader returned an unexpected owner-scoped job response",
        ));
    }
    Ok(())
}

fn summary(job: &Value) -> Value {
    let mut view = project(job, &["id", "status", "createdAt", "updatedAt", "error"]);
    if let Some(title) = job["source"]["title"].as_str() {
        view["title"] = json!(title);
    }
    clip(&mut view, &["error", "title"]);
    if let Some(url) = job["request"]["url"]
        .as_str()
        .and_then(|s| video_url(s).ok())
    {
        view["url"] = json!(url);
    }
    for (field, keys) in [
        ("progress", &["percent", "speed", "eta", "phase"][..]),
        ("alert", &["kind", "message"][..]),
    ] {
        if job[field].is_object() {
            let mut part = project(&job[field], keys);
            clip(&mut part, keys);
            view[field] = part;
        }
    }
    view["file_count"] = json!(job["files"].as_array().map_or(0, Vec::len));
    view
}

fn page(
    mut base: Value,
    items: Vec<Value>,
    key: &str,
    next: &str,
    offset: usize,
    limit: usize,
) -> Result<Value, ErrorData> {
    if offset > items.len() {
        return Err(invalid(
            "Offset exceeds the current view; restart at offset 0",
        ));
    }
    let count = items.len();
    let mut selected = Vec::new();
    for item in items.into_iter().skip(offset).take(limit) {
        selected.push(item);
        base[key] = json!(selected);
        if base.to_string().len() > MAX_BYTES - 512 {
            selected.pop();
            break;
        }
    }
    if selected.is_empty() && offset < count {
        return Err(unavailable(
            "One downloader entry exceeds the model view budget; open the app for details",
        ));
    }
    let end = offset + selected.len();
    base["offset"] = json!(offset);
    base["returned"] = json!(selected.len());
    base[next] = if end < count { json!(end) } else { Value::Null };
    base[key] = json!(selected);
    if base.to_string().len() > MAX_BYTES {
        return Err(unavailable(
            "Downloader metadata exceeds the model view budget",
        ));
    }
    Ok(base)
}

pub(super) fn jobs(
    payload: &Value,
    params: &JobsParams,
    account: &Owner,
    host: &str,
) -> Result<Value, ErrorData> {
    params.validate()?;
    let rows = payload
        .as_array()
        .ok_or_else(|| unavailable("Downloader returned an unexpected history response"))?;
    // Validate before filtering, including rows that would not match a query.
    // Never let a bad ownership contract become a partial cross-user view.
    for row in rows {
        owner(row, account)?;
    }
    let url = params.url.as_deref().map(video_url).transpose()?;
    let query = params.query.as_deref().map(|q| q.trim().to_lowercase());
    let matches: Vec<_> = rows
        .iter()
        .take(100)
        .filter(|row| {
            let row_url = row["request"]["url"]
                .as_str()
                .and_then(|s| video_url(s).ok());
            params
                .status
                .as_deref()
                .is_none_or(|s| row["status"].as_str() == Some(s))
                && url.as_ref().is_none_or(|u| row_url.as_ref() == Some(u))
                && query.as_ref().is_none_or(|q| {
                    [
                        row["source"]["title"].as_str().unwrap_or(""),
                        row_url.as_deref().unwrap_or(""),
                    ]
                    .iter()
                    .any(|s| s.to_lowercase().contains(q))
                })
        })
        .map(summary)
        .collect();
    let base = json!({"matched_recent":matches.len(),"history_scope":"newest 100 jobs for the current account, not complete history","history_limited":rows.len() >= 100,"appUrl":format!("https://{host}/"),"warning":"Read-only current snapshot; new jobs can shift offsets. No match is not proof that an uncertain submission failed. Never resubmit automatically."});
    page(
        base,
        matches,
        "jobs",
        "next_offset",
        params.offset.unwrap_or(0),
        params.limit.unwrap_or(8),
    )
}

pub(super) fn info(payload: &Value, offset: usize, limit: usize) -> Result<Value, ErrorData> {
    if payload["title"].as_str().is_none() {
        return Err(unavailable(
            "Downloader returned an unexpected video response",
        ));
    }
    let mut base = project(
        payload,
        &[
            "title",
            "id",
            "channel",
            "uploader",
            "durationSeconds",
            "uploadDate",
            "releaseDate",
            "isPlaylist",
        ],
    );
    clip(&mut base, &["title", "channel", "uploader"]);
    let chapters = payload["chapters"]
        .as_array()
        .ok_or_else(|| unavailable("Downloader returned unexpected chapter metadata"))?;
    let mut values = Vec::new();
    for chapter in chapters.iter().take(MAX_ITEMS) {
        if chapter["title"].as_str().is_none()
            || chapter["startTime"].as_f64().is_none_or(|n| n < 0.0)
        {
            return Err(unavailable(
                "Downloader returned unexpected chapter metadata",
            ));
        }
        let mut chapter = project(chapter, &["index", "title", "startTime", "endTime"]);
        clip(&mut chapter, &["title"]);
        values.push(chapter);
    }
    base["chapter_count"] = json!(chapters.len());
    base["chapters_limited"] = json!(chapters.len() > MAX_ITEMS);
    page(
        base,
        values,
        "chapters",
        "next_chapter_offset",
        offset,
        limit,
    )
}

pub(super) fn job(
    payload: &Value,
    account: &Owner,
    host: &str,
    offset: usize,
    limit: usize,
) -> Result<Value, ErrorData> {
    owner(payload, account)?;
    let mut base = summary(payload);
    if payload["source"].is_object() {
        // Leave room for complete file paths; chapter details have their own
        // paginated youtube_info tool.
        base["source"] = info(&payload["source"], 0, 5)?;
    }
    let files = payload["files"]
        .as_array()
        .ok_or_else(|| unavailable("Downloader returned unexpected file metadata"))?;
    if files.iter().any(|f| !f.is_string()) {
        return Err(unavailable("Downloader returned unexpected file metadata"));
    }
    base["files_limited"] = json!(files.len() > MAX_ITEMS);
    base["appUrl"] = json!(format!("https://{host}/"));
    page(
        base,
        files.iter().take(MAX_ITEMS).cloned().collect(),
        "files",
        "next_file_offset",
        offset,
        limit,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    // New history access must never expose another login's jobs, including
    // a mismatched owner hidden behind a title/status filter.
    #[test]
    fn history_and_details_refuse_other_owners_before_projection() {
        let params = serde_json::from_value(json!({"query":"own"})).unwrap();
        let account =
            Owner::from_session(&json!({"username":"alice"}), "alice@example.test").unwrap();
        let alice = json!({"id":"job-alice","status":"completed","createdBy":"alice","source":{"title":"own","chapters":[]},"files":[]});
        let bob = json!({"id":"job-bob","status":"completed","createdBy":"bob","source":{"title":"hidden","chapters":[]},"files":[]});
        assert!(jobs(
            &json!([alice.clone(), bob.clone()]),
            &params,
            &account,
            "example.test"
        )
        .is_err());
        assert!(job(&bob, &account, "example.test", 0, 20).is_err());
        assert!(job(&alice, &account, "example.test", 0, 20).is_ok());
        assert!(Owner::from_session(&json!({"username":"alice"}), "ALICE").is_err());
        assert!(Owner::from_session(&json!({"username":"bob"}), "alice").is_err());
        assert!(Owner::from_session(&json!({"username":"alice"}), "bob").is_err());
        assert!(Owner::from_session(&json!({"username":"alice@example.test"}), "alice").is_err());
        assert!(Owner::from_session(&json!({}), "alice").is_err());
        assert!(jobs(&json!([alice]), &params, &account, "example.test").is_ok());
        assert!(serde_json::from_value::<JobsParams>(json!({"username":"bob"})).is_err());
    }
}
