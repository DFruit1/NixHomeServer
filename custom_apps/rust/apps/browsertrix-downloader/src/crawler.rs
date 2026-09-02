use crate::model::{CrawlScope, CreateJobRequest, JobProgress};
use serde_json::Value;
use std::{ffi::OsString, path::Path};

pub fn build_crawl_args(
    request: &CreateJobRequest,
    collection: &str,
    crawl_dir: &Path,
    image: &str,
) -> Vec<OsString> {
    // Use custom collection name if provided, otherwise fall back to the provided collection (job ID)
    let collection_name = request.collection.as_deref().unwrap_or(collection);
    [
        "run".into(),
        "--rm".into(),
        "--shm-size=1g".into(),
        "--cap-add=SYS_ADMIN".into(),
        "--security-opt=seccomp=unconfined".into(),
        // The host kernel rejects procfs mounts from this rootless user
        // namespace. Keep the container's network and filesystem isolation,
        // but reuse the host PID namespace so crun does not need that mount.
        "--pid=host".into(),
        // The service sandbox prevents changing the hostname when the UTS
        // namespace is private, so share it with the host as well.
        "--uts=host".into(),
        "-v".into(),
        format!("{}:/crawls", crawl_dir.display()).into(),
        "--network=slirp4netns:allow_host_loopback=false".into(),
        image.into(),
        "crawl".into(),
        "--url".into(),
        request.url.clone().into(),
        "--collection".into(),
        collection_name.into(),
        "--cwd".into(),
        "/crawls".into(),
        "--scopeType".into(),
        request.scope.as_str().into(),
        "--depth".into(),
        if request.scope == CrawlScope::Page {
            "0"
        } else {
            "1"
        }
        .into(),
        "--limit".into(),
        request.page_limit.to_string().into(),
        "--timeLimit".into(),
        (request.time_limit_minutes * 60).to_string().into(),
        "--workers".into(),
        "1".into(),
        "--generateWACZ".into(),
        "--text".into(),
        "--overwrite".into(),
    ]
    .into_iter()
    .collect()
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct CrawlLogProgress {
    pub pages_done: Option<u64>,
    pub pages_queued: Option<u64>,
    pub pages_failed: Option<u64>,
}

pub fn parse_crawl_log_line(line: &str) -> Option<CrawlLogProgress> {
    let trimmed = line.trim();
    if !trimmed.starts_with('{') {
        return None;
    }
    let value = serde_json::from_str::<Value>(trimmed).ok()?;
    let mut progress = CrawlLogProgress::default();
    if let Some(stats) = value.get("stats").and_then(Value::as_object) {
        progress.pages_done = stats.get("done").and_then(json_u64);
        progress.pages_queued = stats.get("queued").and_then(json_u64);
        progress.pages_failed = stats.get("failed").and_then(json_u64);
    }
    if value.get("message").and_then(Value::as_str) == Some("pageCrawled")
        && progress.pages_done.is_none()
    {
        progress.pages_done = Some(1);
    }
    (progress != CrawlLogProgress::default()).then_some(progress)
}

pub fn merge_progress(current: &JobProgress, update: &CrawlLogProgress) -> JobProgress {
    JobProgress {
        pages_done: update
            .pages_done
            .unwrap_or(current.pages_done)
            .max(current.pages_done),
        pages_queued: update.pages_queued.unwrap_or(current.pages_queued),
        pages_failed: update.pages_failed.unwrap_or(current.pages_failed),
    }
}

pub fn log_line_text(line: &str) -> Option<String> {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return None;
    }
    if trimmed.starts_with('{') {
        let value = match serde_json::from_str::<Value>(trimmed) {
            Ok(value) => value,
            Err(_) => return Some(shorten(trimmed)),
        };
        let text = ["message", "details", "page"]
            .into_iter()
            .filter_map(|key| value.get(key).and_then(Value::as_str))
            .collect::<Vec<_>>()
            .join(" ");
        return (!text.is_empty()).then(|| shorten(&text));
    }
    Some(shorten(trimmed))
}

fn json_u64(value: &Value) -> Option<u64> {
    value
        .as_u64()
        .or_else(|| value.as_str().and_then(|text| text.parse().ok()))
        .or_else(|| {
            value
                .as_f64()
                .filter(|number| number.is_finite() && *number >= 0.0)
                .map(|number| number as u64)
        })
}

fn shorten(value: &str) -> String {
    value.chars().take(240).collect()
}
