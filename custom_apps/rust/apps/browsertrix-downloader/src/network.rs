//! Public-only discovery: no proxy, no implicit redirects, DNS pinned to the
//! checked addresses for each individual connection (including every redirect).
use crate::{
    archive_engine::{self, Estimate, PageSample},
    catalog::ListQuery,
    database::Database,
    model::{CrawlScope, CreateJobRequest},
    queue::JobQueue,
    validation::{parse_create_job, CreateJobInput},
};
use serde::Serialize;
use std::{
    collections::{BTreeMap, BTreeSet, VecDeque},
    io::Read,
    net::SocketAddr,
    time::Duration,
};
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Preflight {
    pub urls: Vec<String>,
    pub groups: Vec<Group>,
    pub estimate: Estimate,
    pub warnings: Vec<String>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Group {
    pub prefix: String,
    pub pages: u64,
}
const RESPONSE_LIMIT: usize = 512 * 1024;
pub async fn fetch_public(queue: &JobQueue, input: &str) -> Result<(String, String), String> {
    let mut target = input.to_owned();
    for _ in 0..5 {
        let parsed = parse_create_job(CreateJobInput {
            url: target,
            scope: None,
            page_limit: None,
            time_limit_minutes: None,
            collection: None,
            options: None,
        })
        .map_err(|e| e.to_string())?;
        let url = url::Url::parse(&parsed.request.url).map_err(|e| e.to_string())?;
        let host = url.host_str().ok_or("hostname missing")?;
        let ips = tokio::time::timeout(Duration::from_secs(2), queue.resolve_public(host))
            .await
            .map_err(|_| "DNS lookup deadline exceeded")?
            .map_err(|e| e.to_string())?;
        let addresses = ips
            .iter()
            .map(|ip| SocketAddr::new(*ip, url.port_or_known_default().unwrap_or(443)))
            .collect::<Vec<_>>();
        let client = reqwest::Client::builder()
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .resolve_to_addrs(host, &addresses)
            .connect_timeout(Duration::from_secs(3))
            .timeout(Duration::from_secs(5))
            .build()
            .map_err(|e| e.to_string())?;
        let mut response = client
            .get(url.clone())
            .header("Accept-Encoding", "identity")
            .header("User-Agent", "NixHomeServer-WebArchives-Preflight/1")
            .send()
            .await
            .map_err(|_| "public discovery request failed")?;
        if response.status().is_redirection() {
            let location = response
                .headers()
                .get(reqwest::header::LOCATION)
                .and_then(|v| v.to_str().ok())
                .ok_or("redirect has no valid Location")?;
            target = url
                .join(location)
                .map_err(|_| "invalid redirect URL")?
                .to_string();
            continue;
        }
        if !response.status().is_success() {
            return Err(format!("discovery HTTP status {}", response.status()));
        }
        let mime = response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("");
        if !mime.contains("html") && !mime.contains("xml") && !mime.starts_with("text/plain") {
            return Err("discovery skipped a non-document response".into());
        }
        if response
            .content_length()
            .is_some_and(|n| n > RESPONSE_LIMIT as u64)
        {
            return Err("discovery response exceeds byte cap".into());
        }
        let encoding = response
            .headers()
            .get(reqwest::header::CONTENT_ENCODING)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("identity")
            .to_owned();
        let mut bytes = vec![];
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|_| "discovery response read failed")?
        {
            if bytes.len().saturating_add(chunk.len()) > RESPONSE_LIMIT {
                return Err("discovery response exceeds byte cap".into());
            }
            bytes.extend_from_slice(&chunk);
        }
        if encoding == "gzip" {
            bytes = tokio::task::spawn_blocking(move || {
                let mut out = vec![];
                flate2::read::GzDecoder::new(&bytes[..])
                    .take(RESPONSE_LIMIT as u64 + 1)
                    .read_to_end(&mut out)
                    .map_err(|_| "invalid gzip response")?;
                if out.len() > RESPONSE_LIMIT {
                    return Err("inflated discovery response exceeds byte cap");
                }
                Ok(out)
            })
            .await
            .map_err(|_| "discovery decompression failed")??;
        } else if !matches!(encoding.as_str(), "identity" | "") {
            return Err("unsupported discovery encoding".into());
        }
        return Ok((
            url.to_string(),
            String::from_utf8_lossy(&bytes).into_owned(),
        ));
    }
    Err("discovery redirect limit exceeded".into())
}
pub fn in_scope(request: &CreateJobRequest, candidate: &str) -> bool {
    let Ok(target) = url::Url::parse(candidate) else {
        return false;
    };
    let base_scope = std::iter::once(&request.url)
        .chain(request.options.seeds.iter())
        .any(|seed| {
            let Ok(base) = url::Url::parse(seed) else {
                return false;
            };
            match request.scope {
                CrawlScope::Page => {
                    let mut a = base;
                    let mut b = target.clone();
                    a.set_fragment(None);
                    b.set_fragment(None);
                    a == b
                }
                CrawlScope::PageSpa => {
                    let mut a = base;
                    let mut b = target.clone();
                    a.set_fragment(None);
                    b.set_fragment(None);
                    a == b
                }
                CrawlScope::Prefix => {
                    let prefix = base
                        .path()
                        .rsplit_once('/')
                        .map(|(v, _)| format!("{v}/"))
                        .unwrap_or_else(|| "/".into());
                    base.origin() == target.origin() && target.path().starts_with(&prefix)
                }
                CrawlScope::Host => base.origin() == target.origin(),
                CrawlScope::Domain => {
                    let base_host = base.host_str().unwrap_or("");
                    let first = base_host.split('.').next().unwrap_or("");
                    let domain = if first.starts_with("www")
                        && first[3..].bytes().all(|v| v.is_ascii_digit())
                    {
                        base_host
                            .split_once('.')
                            .map(|(_, v)| v)
                            .unwrap_or(base_host)
                    } else {
                        base_host
                    };
                    let host = target.host_str().unwrap_or("");
                    base.scheme() == target.scheme()
                        && base.port_or_known_default() == target.port_or_known_default()
                        && (host == domain || host.ends_with(&format!(".{domain}")))
                }
            }
        });
    base_scope
        && (request.options.include.is_empty()
            || request
                .options
                .include
                .iter()
                .any(|p| regex::Regex::new(p).is_ok_and(|rx| rx.is_match(candidate))))
        && !request
            .options
            .exclude
            .iter()
            .any(|p| regex::Regex::new(p).is_ok_and(|rx| rx.is_match(candidate)))
}
pub async fn preflight(
    db: &Database,
    queue: &JobQueue,
    owner: &str,
    request: &CreateJobRequest,
) -> Result<Preflight, String> {
    tokio::time::timeout(Duration::from_secs(15), discover(db, queue, owner, request))
        .await
        .map_err(|_| "preflight total 15-second deadline exceeded".to_owned())?
}
async fn discover(
    db: &Database,
    queue: &JobQueue,
    owner: &str,
    request: &CreateJobRequest,
) -> Result<Preflight, String> {
    queue
        .validate_request(request)
        .await
        .map_err(|e| e.to_string())?;
    let mut pending = VecDeque::new();
    pending.push_back((request.url.clone(), 0u8));
    for seed in &request.options.seeds {
        pending.push_back((seed.clone(), 0));
    }
    let mut urls = BTreeSet::new();
    let mut fetched = BTreeSet::new();
    let mut warnings=vec!["Discovery is bounded to 8 documents, 1000 URLs, 4MiB inflated data and 15 seconds; dynamic routes may remain unknown.".into()];
    let mut total = 0;
    let link = regex::Regex::new(r#"(?is)<a\b[^>]*\bhref\s*=\s*["']([^"']{1,2048})["']"#)
        .map_err(|e| e.to_string())?;
    while let Some((url, depth)) = pending.pop_front() {
        if fetched.len() >= 8 || urls.len() >= 1000 || total >= 4 * 1024 * 1024 {
            break;
        }
        if !fetched.insert(url.clone()) {
            continue;
        }
        let (final_url, body) = match fetch_public(queue, &url).await {
            Ok(value) => value,
            Err(error) => {
                warnings.push(format!("Skipped bounded discovery document: {error}"));
                continue;
            }
        };
        total += body.len();
        if in_scope(request, &final_url) {
            urls.insert(final_url.clone());
        }
        let base = url::Url::parse(&final_url).map_err(|e| e.to_string())?;
        let mut discovered = vec![];
        if let Ok(xml) = roxmltree::Document::parse(&body) {
            for location in xml
                .descendants()
                .filter(|n| n.is_element() && n.tag_name().name() == "loc")
                .take(1000)
            {
                if let Some(text) = location.text() {
                    if text.len() > 2048 {
                        continue;
                    }
                    if let Ok(url) = base.join(text.trim()) {
                        let sitemap =
                            url.path().ends_with(".xml") || url.path().ends_with(".xml.gz");
                        discovered.push((url.to_string(), sitemap));
                    }
                }
            }
        } else {
            for capture in link.captures_iter(&body).take(1000) {
                if let Ok(url) = base.join(&capture[1]) {
                    discovered.push((url.to_string(), false));
                }
            }
            if depth == 0 && request.scope != CrawlScope::Page {
                if let Ok(url) = base.join("/sitemap.xml") {
                    pending.push_back((url.to_string(), 1));
                }
            }
        }
        for (url, sitemap) in discovered {
            let normalized = match parse_create_job(CreateJobInput {
                url,
                scope: Some(request.scope),
                page_limit: None,
                time_limit_minutes: None,
                collection: None,
                options: None,
            }) {
                Ok(p) => p.request.url,
                Err(_) => continue,
            };
            if sitemap && depth < 2 {
                pending.push_back((normalized, depth + 1));
                continue;
            }
            if !in_scope(request, &normalized) {
                continue;
            }
            urls.insert(normalized.clone());
            if depth < 1 && urls.len() < 1000 {
                pending.push_back((normalized, depth + 1));
            }
        }
    }
    if urls.is_empty() {
        urls.insert(request.url.clone());
        warnings.push(
            "No discovery response succeeded; only explicitly selected seeds are known.".into(),
        );
    }
    if urls
        .iter()
        .any(|u| u.contains("calendar") || u.matches('=').count() > 4)
    {
        warnings.push(
            "Possible calendar or query-parameter crawl trap; review includes/excludes and limits."
                .into(),
        );
    }
    let mut groups = BTreeMap::<String, u64>::new();
    for url in &urls {
        if let Ok(url) = url::Url::parse(url) {
            let prefix = format!(
                "{}{}",
                url.origin().ascii_serialization(),
                url.path().split('/').take(3).collect::<Vec<_>>().join("/")
            );
            *groups.entry(prefix).or_default() += 1;
        }
    }
    let host = url::Url::parse(&request.url)
        .map_err(|e| e.to_string())?
        .host_str()
        .unwrap_or("")
        .to_owned();
    let history = db
        .archives(
            owner,
            &ListQuery {
                q: host.clone(),
                limit: Some(10),
                ..Default::default()
            },
        )
        .map_err(|e| e.to_string())?;
    let samples = history
        .items
        .iter()
        .filter(|a| {
            matches!(a.capture_status.as_str(), "complete" | "partial")
                && a.page_count > 0
                && a.request.as_ref().is_some_and(|r| {
                    r.options.profile_id.is_none()
                        && r.options.media == request.options.media
                        && r.options.preset == request.options.preset
                        && url::Url::parse(&r.url)
                            .is_ok_and(|u| u.host_str() == Some(host.as_str()))
                })
        })
        .take(10)
        .map(|a| PageSample {
            url: a.url.clone(),
            bytes: a.archive_bytes / a.page_count.max(1),
            shared_bytes: 0,
            resource_digests: Default::default(),
            measured: true,
        })
        .collect::<Vec<_>>();
    let mut estimate =
        archive_engine::estimate_size(&samples, urls.len() as u64, request.page_limit, true);
    estimate.assumptions.push(if samples.is_empty(){"Discovery estimate only; no static HTML response is labelled browser-captured. Queue /api/samples for actual representative browser measurements.".into()}else{"Measured history from same-owner Browsertrix captures with matching host, preset and media. Per-page marginal size is inferred from measured package size; shared payload attribution remains unknown.".into()});
    let mut urls = urls.into_iter().collect::<Vec<_>>();
    urls.truncate(1000);
    Ok(Preflight {
        urls,
        groups: groups
            .into_iter()
            .map(|(prefix, pages)| Group { prefix, pages })
            .collect(),
        estimate,
        warnings,
    })
}
