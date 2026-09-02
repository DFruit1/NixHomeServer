use reqwest::{header, Client, StatusCode, Url};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeSet, HashSet},
    fmt,
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::{
    process::Command,
    sync::Mutex,
    time::{sleep, timeout},
};

pub const MUSICBRAINZ_API_BASE: &str = "https://musicbrainz.org/ws/2/";
pub const ACOUSTID_API_BASE: &str = "https://api.acoustid.org/v2/";
const MAX_CANDIDATES: usize = 6;
const FPCALC_TIMEOUT: Duration = Duration::from_secs(60);

const MAX_FP_LENGTH: usize = 4096;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LookupMode {
    Auto,
    Fingerprint,
    Search,
}

impl LookupMode {
    pub fn parse(value: Option<&str>) -> Option<Self> {
        match value.unwrap_or("auto") {
            "auto" => Some(Self::Auto),
            "fingerprint" => Some(Self::Fingerprint),
            "search" => Some(Self::Search),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AcoustidCredentials {
    pub acoustid_api_key: String,
    #[serde(default)]
    pub user_agent: Option<String>,
}

impl AcoustidCredentials {
    pub fn from_file(path: &Path) -> Result<Self, ProviderError> {
        let bytes = std::fs::read(path)
            .map_err(|error| ProviderError::new(format!("read AcoustID key: {error}")))?;
        let credentials = serde_json::from_slice::<Self>(&bytes)
            .map_err(|error| ProviderError::new(format!("parse AcoustID key JSON: {error}")))?;
        if credentials.acoustid_api_key.trim().is_empty() {
            return Err(ProviderError::new(
                "AcoustID credentials require a non-empty acoustidApiKey",
            ));
        }
        Ok(credentials)
    }
}

#[derive(Clone, Debug)]
pub struct MusicBrainzClientConfig {
    pub acoustid_api_key: Option<String>,
    pub fpcalc_path: PathBuf,
    pub musicbrainz_api_base: String,
    pub acoustid_api_base: String,
    pub request_gap: Duration,
    pub user_agent: String,
}

#[derive(Clone)]
pub struct MusicBrainzClient {
    acoustid_api_key: Option<String>,
    fpcalc_path: PathBuf,
    client: Client,
    musicbrainz_api_base: Url,
    acoustid_api_base: Url,
    request_gap: Duration,
    user_agent: String,
    last_request: Arc<Mutex<Instant>>,
}

impl MusicBrainzClient {
    pub fn new(config: MusicBrainzClientConfig) -> Result<Self, ProviderError> {
        let musicbrainz_api_base = parse_api_base(&config.musicbrainz_api_base, "MusicBrainz")?;
        let acoustid_api_base = parse_api_base(&config.acoustid_api_base, "AcoustID")?;
        let allowed_hosts = provider_hosts(&musicbrainz_api_base, &acoustid_api_base);
        let client = Client::builder()
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(30))
            .redirect(reqwest::redirect::Policy::custom(move |attempt| {
                if attempt.previous().len() >= 3 {
                    attempt.stop()
                } else if is_trusted_target(attempt.url(), &allowed_hosts) {
                    attempt.follow()
                } else {
                    attempt.stop()
                }
            }))
            .build()
            .map_err(|error| ProviderError::new(format!("build HTTPS client: {error}")))?;
        Ok(Self {
            acoustid_api_key: config
                .acoustid_api_key
                .map(|key| key.trim().to_string())
                .filter(|key| !key.is_empty()),
            fpcalc_path: config.fpcalc_path,
            client,
            musicbrainz_api_base,
            acoustid_api_base,
            request_gap: config.request_gap,
            user_agent: config.user_agent,
            last_request: Arc::new(Mutex::new(Instant::now() - config.request_gap)),
        })
    }

    pub fn has_fingerprint(&self) -> bool {
        self.acoustid_api_key.is_some()
    }

    pub async fn fingerprint_file(&self, path: &Path) -> Result<(String, u32), ProviderError> {
        self.fingerprint(path).await
    }

    pub async fn release_groups_from_ids(
        &self,
        ids: &[String],
    ) -> Result<Vec<MusicRelease>, ProviderError> {
        let mut candidates = Vec::new();
        for id in ids.iter().filter(|id| valid_mbid(id)).take(MAX_CANDIDATES) {
            match self.release_group_lookup(id).await {
                Ok(group) => candidates.push(normalize_release_group(group, "fingerprint")),
                Err(_) => continue,
            }
        }
        Ok(candidates)
    }

    pub async fn lookup_music(
        &self,
        path: &Path,
        artist: Option<&str>,
        title: Option<&str>,
        mode: LookupMode,
    ) -> Result<Vec<MusicRelease>, ProviderError> {
        match mode {
            LookupMode::Fingerprint => self.identify_by_fingerprint(path).await,
            LookupMode::Search => self.search_release_groups(artist, title).await,
            LookupMode::Auto => {
                if self.acoustid_api_key.is_some() {
                    match self.identify_by_fingerprint(path).await {
                        Ok(found) if !found.is_empty() => return Ok(found),
                        Ok(_) => {}
                        Err(_) => {}
                    }
                }
                self.search_release_groups(artist, title).await
            }
        }
    }

    async fn identify_by_fingerprint(
        &self,
        path: &Path,
    ) -> Result<Vec<MusicRelease>, ProviderError> {
        let (fingerprint, duration) = self.fingerprint(path).await?;
        let release_group_ids = self.acoustid_lookup(&fingerprint, duration).await?;
        let mut candidates = Vec::new();
        for id in release_group_ids.into_iter().take(MAX_CANDIDATES) {
            match self.release_group_lookup(&id).await {
                Ok(group) => candidates.push(normalize_release_group(group, "fingerprint")),
                Err(_) => continue,
            }
        }
        Ok(candidates)
    }

    async fn search_release_groups(
        &self,
        artist: Option<&str>,
        title: Option<&str>,
    ) -> Result<Vec<MusicRelease>, ProviderError> {
        let query = build_release_group_query(artist, title)?;
        self.throttle().await;
        let url = self
            .musicbrainz_api_base
            .join("release-group/")
            .map_err(|error| ProviderError::new(format!("build search URL: {error}")))?;
        let response = self
            .provider_request(self.client.get(url))
            .query(&[
                ("query", query.as_str()),
                ("limit", &MAX_CANDIDATES.to_string()),
                ("fmt", "json"),
            ])
            .send()
            .await
            .map_err(|error| ProviderError::new(format!("search request failed: {error}")))?;
        let response = require_success(response, "MusicBrainz search").await?;
        let payload = response
            .json::<SearchResponse>()
            .await
            .map_err(|error| ProviderError::new(format!("decode search response: {error}")))?;
        let mut candidates = Vec::new();
        for entry in payload.release_groups.into_iter().take(MAX_CANDIDATES) {
            if !valid_mbid(&entry.id) {
                continue;
            }
            match self.release_group_lookup(&entry.id).await {
                Ok(group) => candidates.push(normalize_release_group(group, "search")),
                Err(_) => continue,
            }
        }
        Ok(candidates)
    }

    async fn release_group_lookup(&self, id: &str) -> Result<ReleaseGroup, ProviderError> {
        self.throttle().await;
        let url = self
            .musicbrainz_api_base
            .join(&format!("release-group/{id}"))
            .map_err(|error| ProviderError::new(format!("build release URL: {error}")))?;
        let response = self
            .provider_request(self.client.get(url))
            .query(&[("inc", "artist-credits+genres+releases"), ("fmt", "json")])
            .send()
            .await
            .map_err(|error| ProviderError::new(format!("release request failed: {error}")))?;
        let response = require_success(response, "MusicBrainz release lookup").await?;
        response
            .json::<ReleaseGroup>()
            .await
            .map_err(|error| ProviderError::new(format!("decode release response: {error}")))
    }

    async fn acoustid_lookup(
        &self,
        fingerprint: &str,
        duration: u32,
    ) -> Result<Vec<String>, ProviderError> {
        let key = self
            .acoustid_api_key
            .as_deref()
            .ok_or_else(|| ProviderError::new("AcoustID API key is not configured"))?;
        self.throttle().await;
        let url = self
            .acoustid_api_base
            .join("lookup")
            .map_err(|error| ProviderError::new(format!("build lookup URL: {error}")))?;
        let response = self
            .provider_request(self.client.get(url))
            .query(&[
                ("client", key),
                ("fingerprint", fingerprint),
                ("duration", &duration.to_string()),
                ("meta", "recordings+releasegroups"),
            ])
            .send()
            .await
            .map_err(|error| ProviderError::new(format!("lookup request failed: {error}")))?;
        let response = require_success(response, "AcoustID lookup").await?;
        let payload = response
            .json::<AcoustidLookupResponse>()
            .await
            .map_err(|error| ProviderError::new(format!("decode lookup response: {error}")))?;
        if payload.status != "ok" {
            return Err(ProviderError::new("AcoustID rejected the lookup request"));
        }
        let mut seen = HashSet::new();
        let mut ids = Vec::new();
        for result in payload.results {
            for recording in result.recordings {
                for group in recording.releasegroups {
                    if valid_mbid(&group.id) && seen.insert(group.id.clone()) {
                        ids.push(group.id);
                    }
                }
            }
        }
        Ok(ids)
    }

    async fn fingerprint(&self, path: &Path) -> Result<(String, u32), ProviderError> {
        let child = Command::new(&self.fpcalc_path)
            .arg(path)
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .map_err(|error| {
                ProviderError::new(format!(
                    "start fingerprint calculator {}: {error}",
                    self.fpcalc_path.display()
                ))
            })?;
        let output = timeout(FPCALC_TIMEOUT, child.wait_with_output())
            .await
            .map_err(|_| ProviderError::new("fingerprint calculation timed out"))?
            .map_err(|error| ProviderError::new(format!("read fingerprint output: {error}")))?;
        if !output.status.success() && output.stdout.is_empty() {
            return Err(ProviderError::new("fingerprint calculator failed"));
        }
        parse_fingerprint_output(&output.stdout)
            .ok_or_else(|| ProviderError::new("fingerprint calculator produced no usable output"))
    }

    async fn throttle(&self) {
        let gap = self.request_gap;
        if gap.is_zero() {
            return;
        }
        let mut last = self.last_request.lock().await;
        let elapsed = last.elapsed();
        if elapsed < gap {
            sleep(gap - elapsed).await;
        }
        *last = Instant::now();
    }

    fn provider_request(&self, request: reqwest::RequestBuilder) -> reqwest::RequestBuilder {
        request.header(header::USER_AGENT, &self.user_agent)
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MusicRelease {
    pub release_group_id: String,
    pub artist: String,
    pub title: String,
    pub release_type: Option<String>,
    pub year: Option<u16>,
    pub genres: Vec<String>,
    pub label: Option<String>,
    pub track_count: Option<u32>,
    pub match_method: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "kebab-case")]
struct SearchResponse {
    #[serde(rename = "release-groups")]
    release_groups: Vec<SearchReleaseGroup>,
}

#[derive(Debug, Deserialize)]
struct SearchReleaseGroup {
    id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "kebab-case")]
struct ReleaseGroup {
    id: String,
    title: String,
    #[serde(rename = "primary-type")]
    primary_type: Option<String>,
    #[serde(rename = "first-release-date")]
    first_release_date: Option<String>,
    #[serde(rename = "artist-credit")]
    artist_credit: Vec<ArtistCredit>,
    #[serde(default)]
    genres: Vec<NamedEntity>,
    #[serde(default)]
    releases: Vec<ReleaseRef>,
}

#[derive(Debug, Deserialize)]
struct ArtistCredit {
    name: String,
    #[serde(default)]
    joinphrase: String,
}

#[derive(Debug, Deserialize)]
struct NamedEntity {
    name: String,
}

#[derive(Debug, Deserialize)]
struct ReleaseRef {
    #[serde(default, rename = "label-info")]
    label_info: Vec<LabelInfo>,
    #[serde(default)]
    media: Vec<Media>,
}

#[derive(Debug, Deserialize)]
struct LabelInfo {
    label: Option<Label>,
}

#[derive(Debug, Deserialize)]
struct Label {
    name: String,
}

#[derive(Debug, Deserialize)]
struct Media {
    #[serde(default, rename = "track-count")]
    track_count: Option<u32>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "lowercase")]
struct AcoustidLookupResponse {
    status: String,
    #[serde(default)]
    results: Vec<AcoustidResult>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "lowercase")]
struct AcoustidResult {
    #[serde(default)]
    recordings: Vec<AcoustidRecording>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "lowercase")]
struct AcoustidRecording {
    #[serde(default)]
    releasegroups: Vec<AcoustidReleaseGroup>,
}

#[derive(Debug, Deserialize)]
struct AcoustidReleaseGroup {
    id: String,
}

fn normalize_release_group(group: ReleaseGroup, method: &str) -> MusicRelease {
    let artist = join_artist_credit(&group.artist_credit);
    let year = group
        .first_release_date
        .as_deref()
        .and_then(|date| date.split('-').next())
        .and_then(|value| value.parse::<u16>().ok())
        .filter(|year| (1..=2100).contains(year));
    let genres = group
        .genres
        .into_iter()
        .map(|genre| genre.name.trim().to_string())
        .filter(|genre| !genre.is_empty() && genre.len() <= 500)
        .collect::<BTreeSet<_>>()
        .into_iter()
        .take(12)
        .collect::<Vec<_>>();
    let (label, track_count) = release_label_and_tracks(&group.releases);
    MusicRelease {
        release_group_id: group.id,
        artist,
        title: group.title,
        release_type: group.primary_type,
        year,
        genres,
        label,
        track_count,
        match_method: method.to_string(),
    }
}

fn join_artist_credit(credit: &[ArtistCredit]) -> String {
    let mut rendered = String::new();
    for part in credit {
        rendered.push_str(&part.name);
        if !part.joinphrase.is_empty() {
            rendered.push_str(&part.joinphrase);
        }
    }
    let rendered = rendered.split_whitespace().collect::<Vec<_>>().join(" ");
    if rendered.len() > 500 {
        rendered.chars().take(500).collect()
    } else {
        rendered
    }
}

fn release_label_and_tracks(releases: &[ReleaseRef]) -> (Option<String>, Option<u32>) {
    let mut label = None;
    let mut track_count = None;
    for release in releases {
        if label.is_none() {
            label = release
                .label_info
                .iter()
                .filter_map(|info| info.label.as_ref())
                .map(|entry| entry.name.trim().to_string())
                .find(|name| !name.is_empty() && name.len() <= 500);
        }
        if track_count.is_none() {
            let total = release
                .media
                .iter()
                .filter_map(|media| media.track_count)
                .sum::<u32>();
            if total > 0 {
                track_count = Some(total);
            }
        }
        if label.is_some() && track_count.is_some() {
            break;
        }
    }
    (label, track_count)
}

fn build_release_group_query(
    artist: Option<&str>,
    title: Option<&str>,
) -> Result<String, ProviderError> {
    let escape = |value: &str| value.replace('\\', "\\\\").replace('"', "\\\"");
    let mut terms = Vec::new();
    if let Some(title) = title.map(str::trim).filter(|value| !value.is_empty()) {
        terms.push(format!("releasegroup:\"{}\"", escape(title)));
    }
    if let Some(artist) = artist.map(str::trim).filter(|value| !value.is_empty()) {
        terms.push(format!("artist:\"{}\"", escape(artist)));
    }
    if terms.is_empty() {
        return Err(ProviderError::new(
            "MusicBrainz search requires an artist, a title, or both",
        ));
    }
    Ok(terms.join(" AND "))
}

fn parse_fingerprint_output(stdout: &[u8]) -> Option<(String, u32)> {
    let text = std::str::from_utf8(stdout).ok()?;
    let mut duration = None;
    let mut fingerprint = None;
    for line in text.lines() {
        if let Some(value) = line.strip_prefix("DURATION=") {
            duration = value.trim().parse::<u32>().ok();
        } else if let Some(value) = line.strip_prefix("FINGERPRINT=") {
            let value = value.trim();
            if !value.is_empty() && value.len() <= MAX_FP_LENGTH {
                fingerprint = Some(value.to_string());
            }
        }
    }
    Some((
        fingerprint.filter(|value| is_plausible_fingerprint(value))?,
        duration.filter(|duration| *duration > 0)?,
    ))
}

fn is_plausible_fingerprint(value: &str) -> bool {
    let bytes = value.as_bytes();
    if bytes.len() < 100 {
        return false;
    }
    let sample = &bytes[..100];
    let mut seen = [false; 256];
    let mut distinct = 0;
    for byte in sample {
        if !seen[*byte as usize] {
            seen[*byte as usize] = true;
            distinct += 1;
        }
    }
    distinct >= 3
}

fn valid_mbid(value: &str) -> bool {
    value.len() == 36
        && value
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() || byte == b'-')
        && value.matches('-').count() == 4
}

fn parse_api_base(value: &str, label: &str) -> Result<Url, ProviderError> {
    let url = Url::parse(value)
        .map_err(|error| ProviderError::new(format!("{label} API URL is invalid: {error}")))?;
    if !is_trusted_origin(&url) {
        return Err(ProviderError::new(format!(
            "{label} API URL must use HTTPS (or a loopback HTTP mirror): {value}"
        )));
    }
    Ok(url)
}

fn provider_hosts(musicbrainz: &Url, acoustid: &Url) -> Vec<String> {
    [musicbrainz, acoustid]
        .into_iter()
        .filter_map(Url::host_str)
        .map(str::to_string)
        .collect()
}

fn is_trusted_origin(url: &Url) -> bool {
    if url.scheme() == "https" {
        return true;
    }
    url.scheme() == "http"
        && url
            .host_str()
            .is_some_and(|host| matches!(host, "localhost" | "127.0.0.1" | "::1"))
}

fn is_trusted_target(url: &Url, allowed_hosts: &[String]) -> bool {
    is_trusted_origin(url)
        && url
            .host_str()
            .is_some_and(|host| allowed_hosts.iter().any(|allowed| allowed == host))
}

async fn require_success(
    response: reqwest::Response,
    operation: &str,
) -> Result<reqwest::Response, ProviderError> {
    if response.status().is_success() {
        return Ok(response);
    }
    let status = response.status();
    let category = match status {
        StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => "provider credentials were rejected",
        StatusCode::TOO_MANY_REQUESTS => "provider quota or rate limit was reached",
        _ if status.is_server_error() => "provider service is unavailable",
        _ => "provider rejected the request",
    };
    Err(ProviderError::new(format!(
        "{operation}: {category} (HTTP {})",
        status.as_u16()
    )))
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProviderError(String);

impl ProviderError {
    fn new(message: impl Into<String>) -> Self {
        Self(message.into())
    }
}

impl fmt::Display for ProviderError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for ProviderError {}

#[cfg(test)]
mod tests {
    use super::{
        build_release_group_query, is_trusted_origin, join_artist_credit, normalize_release_group,
        parse_fingerprint_output, valid_mbid, AcoustidCredentials, ArtistCredit, ReleaseGroup,
        ReleaseRef,
    };

    #[test]
    fn acoustid_credentials_reject_an_empty_key() {
        let temp = tempfile::tempdir().expect("temporary directory");
        let file = temp.path().join("key.json");
        std::fs::write(&file, r#"{"acoustidApiKey":"  "}"#).expect("write key");
        assert!(AcoustidCredentials::from_file(&file).is_err());
    }

    #[test]
    fn fpcalc_key_value_output_is_parsed() {
        let output = format!("DURATION=271\nFINGERPRINT=AQ{}\n", "ABC".repeat(50));
        let (fingerprint, duration) = parse_fingerprint_output(output.as_bytes()).expect("parsed");
        assert_eq!(duration, 271);
        assert_eq!(fingerprint, format!("AQ{}", "ABC".repeat(50)));
    }

    #[test]
    fn fpcalc_output_without_a_fingerprint_is_rejected() {
        let output = b"ERROR: something\nDURATION=271\n";
        assert!(parse_fingerprint_output(output).is_none());
    }

    #[test]
    fn degenerate_all_identical_fingerprints_are_rejected() {
        let degenerate = format!("AQ{}", "A".repeat(200));
        assert!(!super::is_plausible_fingerprint(&degenerate));
        let varied = format!("AQ{}", "ABC".repeat(100));
        assert!(super::is_plausible_fingerprint(&varied));
    }

    #[test]
    fn musicbrainz_ids_must_be_uuid_shaped() {
        assert!(valid_mbid("1b022e01-4da6-387b-8658-8678046e4cef"));
        assert!(!valid_mbid("../release-group/../"));
        assert!(!valid_mbid("not-a-mbid"));
    }

    #[test]
    fn artist_credit_joinphrases_are_preserved() {
        let credit = vec![
            ArtistCredit {
                name: "Tom Waits".to_string(),
                joinphrase: " / ".to_string(),
            },
            ArtistCredit {
                name: "Kathleen Brennan".to_string(),
                joinphrase: String::new(),
            },
        ];
        assert_eq!(join_artist_credit(&credit), "Tom Waits / Kathleen Brennan");
    }

    #[test]
    fn release_group_normalization_maps_core_fields() {
        let group = ReleaseGroup {
            id: "1b022e01-4da6-387b-8658-8678046e4cef".to_string(),
            title: "Nevermind".to_string(),
            primary_type: Some("Album".to_string()),
            first_release_date: Some("1991-09-24".to_string()),
            artist_credit: vec![ArtistCredit {
                name: "Nirvana".to_string(),
                joinphrase: String::new(),
            }],
            genres: vec![
                super::NamedEntity {
                    name: "grunge".to_string(),
                },
                super::NamedEntity {
                    name: "alternative rock".to_string(),
                },
            ],
            releases: vec![ReleaseRef {
                label_info: vec![super::LabelInfo {
                    label: Some(super::Label {
                        name: "DGC".to_string(),
                    }),
                }],
                media: vec![super::Media {
                    track_count: Some(12),
                }],
            }],
        };
        let release = normalize_release_group(group, "search");
        assert_eq!(release.artist, "Nirvana");
        assert_eq!(release.title, "Nevermind");
        assert_eq!(release.year, Some(1991));
        assert_eq!(release.genres, vec!["alternative rock", "grunge"]);
        assert_eq!(release.label.as_deref(), Some("DGC"));
        assert_eq!(release.track_count, Some(12));
        assert_eq!(release.match_method, "search");
    }

    #[test]
    fn search_query_escapes_lucene_quotes() {
        let query =
            build_release_group_query(Some(r#"The "Band""#), Some("In Utero")).expect("query");
        assert_eq!(
            query,
            "releasegroup:\"In Utero\" AND artist:\"The \\\"Band\\\"\""
        );
    }

    #[test]
    fn trusted_origins_allow_https_and_loopback_http_only() {
        assert!(is_trusted_origin(
            &reqwest::Url::parse("https://musicbrainz.org/ws/2/").unwrap()
        ));
        assert!(is_trusted_origin(
            &reqwest::Url::parse("http://127.0.0.1:8087/").unwrap()
        ));
        assert!(!is_trusted_origin(
            &reqwest::Url::parse("http://musicbrainz.org/ws/2/").unwrap()
        ));
    }
}
