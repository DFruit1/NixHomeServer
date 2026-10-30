//! Additional provider adapters share transport bounds and reviewable candidates,
//! while each upstream's identifiers, authentication and response mapping stay local.
use super::*;
use std::{
    collections::HashMap,
    time::{Duration, Instant},
};
use tokio::sync::Mutex;

mod audnexus;
#[cfg(test)]
mod boundary_tests;
mod comic_vine;
mod discogs;
mod fanart;
mod isbndb;
mod omdb;
mod podcast_index;
pub(super) mod subdl;
mod theaudiodb;
mod tvdb;
mod wikidata;

const MAX_RESULTS: usize = 20;

#[derive(Default)]
pub(super) struct Runtime {
    requests: Mutex<HashMap<String, Instant>>,
    images: Mutex<HashMap<String, ImageReference>>,
    subtitles: Mutex<HashMap<String, subdl::DownloadReference>>,
    tokens: Mutex<HashMap<String, tvdb::Token>>,
}

struct ImageReference {
    owner: String,
    provider: String,
    url: reqwest::Url,
    expires: Instant,
}

pub(super) fn default_bases() -> BTreeMap<String, String> {
    [
        ("omdb", "https://www.omdbapi.com/"),
        ("tvdb", "https://api4.thetvdb.com/v4/"),
        ("wikidata", "https://www.wikidata.org/w/api.php"),
        ("fanart", "https://webservice.fanart.tv/v3.2/"),
        ("discogs", "https://api.discogs.com/"),
        ("theaudiodb", "https://www.theaudiodb.com/api/v1/json/"),
        ("comic-vine", "https://comicvine.gamespot.com/api/"),
        ("isbndb", "https://api2.isbndb.com/"),
        ("audnexus", "https://api.audnex.us/"),
        ("podcast-index", "https://api.podcastindex.org/api/1.0/"),
        ("subdl", "https://api.subdl.com/api/v2/"),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_string(), v.to_string()))
    .collect()
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct LookupRequest {
    #[serde(default)]
    pub query: String,
    pub id: Option<String>,
    pub media_type: Option<String>,
    pub year: Option<u16>,
    pub artist: Option<String>,
    pub season: Option<u32>,
    pub episode: Option<u32>,
    pub order: Option<String>,
    pub language: Option<String>,
    pub region: Option<String>,
    pub page: Option<u32>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Candidate {
    provider: String,
    id: String,
    title: String,
    subtitle: String,
    fields: BTreeMap<String, String>,
    provider_ids: BTreeMap<String, String>,
    evidence: BTreeMap<String, String>,
    artwork: Vec<Artwork>,
    #[serde(skip_serializing_if = "Option::is_none")]
    next: Option<LookupRequestView>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct LookupRequestView {
    id: String,
    media_type: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Artwork {
    source_url: String,
    role: String,
    language: String,
}

impl Candidate {
    fn new(provider: &str, id: impl ToString, title: impl ToString) -> Self {
        Self {
            provider: provider.to_string(),
            id: id.to_string(),
            title: title.to_string(),
            subtitle: String::new(),
            fields: BTreeMap::new(),
            provider_ids: BTreeMap::new(),
            evidence: BTreeMap::new(),
            artwork: Vec::new(),
            next: None,
        }
    }
    fn field(&mut self, key: &str, value: impl ToString) {
        let value = value.to_string();
        let value = value.trim();
        if !value.is_empty()
            && value != "N/A"
            && value.len() <= 20_000
            && !value
                .chars()
                .any(|c| c.is_control() && !matches!(c, '\n' | '\r' | '\t'))
        {
            self.fields.insert(key.to_string(), value.to_string());
        }
    }
    fn identifier(&mut self, key: &str, value: impl ToString) {
        let value = value.to_string();
        if !value.is_empty() && value.len() <= 256 && !value.chars().any(char::is_control) {
            self.provider_ids.insert(key.to_string(), value);
        }
    }
    fn drill_down(&mut self, media_type: &str) {
        self.next = Some(LookupRequestView {
            id: self.id.clone(),
            media_type: media_type.to_string(),
        });
    }
}

#[derive(Clone, Copy)]
pub(super) struct Failure {
    pub status: StatusCode,
    code: &'static str,
    message: &'static str,
}
impl Failure {
    fn invalid() -> Self {
        Self {
            status: StatusCode::UNPROCESSABLE_ENTITY,
            code: "provider_query_invalid",
            message: "Supply a valid search or provider identifier.",
        }
    }
    fn unavailable() -> Self {
        Self {
            status: StatusCode::BAD_GATEWAY,
            code: "provider_unavailable",
            message: "The provider could not complete the request. Try again later.",
        }
    }
    fn rejected() -> Self {
        Self {
            status: StatusCode::UNAUTHORIZED,
            code: "provider_credentials_rejected",
            message: "The provider rejected this account. Check its setup in Accounts.",
        }
    }
    fn limited() -> Self {
        Self {
            status: StatusCode::TOO_MANY_REQUESTS,
            code: "provider_rate_limited",
            message: "The provider quota or rate limit was reached. Try again later.",
        }
    }
    fn response(self, request_id: String) -> Response {
        ApiError::new(self.status, self.code, self.message, request_id).into_response()
    }
}
type LookupResult = Result<Vec<Candidate>, Failure>;

struct Credentials(BTreeMap<String, String>);
impl Drop for Credentials {
    fn drop(&mut self) {
        zeroize_credentials(&mut self.0);
    }
}

fn credentials(
    state: &ProviderBrokerState,
    identity: &Identity,
    provider: &str,
) -> Result<Credentials, Failure> {
    let definition = provider_definition(provider).ok_or_else(Failure::invalid)?;
    if definition.implementation_status != ImplementationStatus::Active {
        return Err(Failure::invalid());
    }
    if definition.credential_fields.is_empty() {
        return Ok(Credentials(BTreeMap::new()));
    }
    let saved = state
        .store
        .load_credentials(identity, provider)
        .map_err(|_| Failure::unavailable())?
        .ok_or(Failure {
            status: StatusCode::PRECONDITION_REQUIRED,
            code: "provider_account_required",
            message: "Configure your account for this provider under Accounts first.",
        })?;
    Ok(Credentials(saved))
}

pub(super) async fn search(
    State(state): State<ProviderBrokerState>,
    headers: HeaderMap,
    Path(provider): Path<String>,
    payload: Result<Json<LookupRequest>, JsonRejection>,
) -> Response {
    let request_id = request_id();
    let identity = match identity_from_headers(&headers, &request_id) {
        Ok(v) => v,
        Err(e) => return e.into_response(),
    };
    let mut request = match payload {
        Ok(Json(v)) => v,
        Err(_) => return invalid_json(&request_id).into_response(),
    };
    if request.id.is_none()
        && ((provider == "omdb" && request.query.starts_with("tt"))
            || (provider == "tvdb"
                && ["series:", "movie:", "episode:"]
                    .iter()
                    .any(|prefix| request.query.starts_with(prefix)))
            || (provider == "comic-vine"
                && ["volume:", "issue:"]
                    .iter()
                    .any(|prefix| request.query.starts_with(prefix))))
    {
        request.id = Some(request.query.clone());
    }
    if request.query.len() > 500
        || request.query.chars().any(char::is_control)
        || request.id.as_deref().is_some_and(|id| !valid_id(id))
        || request.query.trim().is_empty() && request.id.is_none()
        || request.page.is_some_and(|p| p > 100)
        || [
            &request.artist,
            &request.language,
            &request.region,
            &request.order,
            &request.media_type,
        ]
        .into_iter()
        .flatten()
        .any(|v| v.len() > 500 || v.chars().any(char::is_control))
    {
        return Failure::invalid().response(request_id);
    }
    let credentials = match credentials(&state, &identity, &provider) {
        Ok(v) => v,
        Err(e) => return e.response(request_id),
    };
    match lookup(&state, &identity, &provider, &credentials.0, &request).await {
        Ok(mut results) => {
            results.truncate(MAX_RESULTS);
            Json(json!({"provider":provider,"results":results,"requestId":request_id}))
                .into_response()
        }
        Err(e) => e.response(request_id),
    }
}

pub(super) async fn lookup(
    state: &ProviderBrokerState,
    identity: &Identity,
    provider: &str,
    credentials: &BTreeMap<String, String>,
    request: &LookupRequest,
) -> LookupResult {
    match provider {
        "podcast-index" => podcast_index::lookup(state, identity, credentials, request).await,
        "subdl" => subdl::lookup(state, identity, credentials, request).await,
        "omdb" => omdb::lookup(state, identity, credentials, request).await,
        "tvdb" => tvdb::lookup(state, identity, credentials, request).await,
        "wikidata" => wikidata::lookup(state, identity, request).await,
        "fanart" => fanart::lookup(state, identity, credentials, request).await,
        "discogs" => discogs::lookup(state, identity, credentials, request).await,
        "theaudiodb" => theaudiodb::lookup(state, identity, credentials, request).await,
        "comic-vine" => comic_vine::lookup(state, identity, credentials, request).await,
        "isbndb" => isbndb::lookup(state, identity, credentials, request).await,
        "audnexus" => audnexus::lookup(state, identity, request).await,
        _ => Err(Failure::invalid()),
    }
}

pub(super) async fn test(
    state: &ProviderBrokerState,
    identity: &Identity,
    provider: &str,
    credentials: &BTreeMap<String, String>,
) -> Result<(), Failure> {
    if provider == "subdl" {
        return subdl::test(state, identity, credentials).await;
    }
    if provider == "tvdb" {
        return tvdb::token(state, identity, credentials).await.map(|_| ());
    }
    let request = match provider {
        "podcast-index" => LookupRequest {
            query: "Rust".into(),
            ..Default::default()
        },
        "omdb" => LookupRequest {
            id: Some("tt0133093".into()),
            ..Default::default()
        },
        "fanart" => LookupRequest {
            id: Some("tmdb:550".into()),
            ..Default::default()
        },
        "discogs" => LookupRequest {
            id: Some("release:249504".into()),
            ..Default::default()
        },
        "theaudiodb" => LookupRequest {
            query: "Homework".into(),
            artist: Some("Daft Punk".into()),
            ..Default::default()
        },
        "comic-vine" => LookupRequest {
            query: "Batman".into(),
            ..Default::default()
        },
        "isbndb" => LookupRequest {
            id: Some("9780140328721".into()),
            ..Default::default()
        },
        _ => return Err(Failure::invalid()),
    };
    lookup(state, identity, provider, credentials, &request)
        .await
        .and_then(|records| {
            if records.is_empty() {
                Err(Failure::unavailable())
            } else {
                Ok(())
            }
        })
}

impl Runtime {
    pub(super) async fn invalidate(&self, identity: &Identity, provider: &str) {
        self.images
            .lock()
            .await
            .retain(|_, v| v.owner != identity.subject || v.provider != provider);
        if provider == "subdl" {
            self.subtitles
                .lock()
                .await
                .retain(|_, v| v.owner != identity.subject);
        }
        if provider == "tvdb" {
            self.tokens
                .lock()
                .await
                .retain(|_, v| v.owner != identity.subject);
        }
    }
}

fn valid_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 160
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b':' | b'.'))
}
fn text<'a>(value: &'a Value, key: &str) -> &'a str {
    value.get(key).and_then(Value::as_str).unwrap_or("")
}
fn number(value: &Value, key: &str) -> String {
    value
        .get(key)
        .filter(|v| v.is_number())
        .map(Value::to_string)
        .unwrap_or_default()
}
fn list(value: &Value, key: &str) -> String {
    value
        .get(key)
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .take(64)
        .filter_map(|v| v.as_str().or_else(|| v.get("name").and_then(Value::as_str)))
        .collect::<Vec<_>>()
        .join(", ")
}
fn date(candidate: &mut Candidate, value: &str) {
    if let Some(year) = value
        .get(..4)
        .and_then(|s| s.parse::<u16>().ok())
        .filter(|y| (1..=2100).contains(y))
    {
        candidate.field("year", year);
    }
    if let Some(date) = value.get(..10) {
        candidate.field("premiereDate", date);
    }
}

fn url(state: &ProviderBrokerState, provider: &str, path: &str) -> Result<reqwest::Url, Failure> {
    let base = state
        .endpoints
        .additional_api_bases
        .get(provider)
        .ok_or_else(Failure::unavailable)?;
    provider_test_url(base, path).map_err(|_| Failure::invalid())
}
async fn json_request(
    state: &ProviderBrokerState,
    identity: &Identity,
    provider: &str,
    request: reqwest::RequestBuilder,
) -> Result<Value, Failure> {
    // Reserve request times, then release the lock before waiting or doing IO.
    let gap = match provider {
        "comic-vine" => 1000,
        "wikidata" | "audnexus" => 1000,
        "theaudiodb" => 2100,
        _ => 300,
    };
    let now = Instant::now();
    let key = format!("{}:{provider}", identity.subject);
    let wait = {
        let mut gates = state.additional.requests.lock().await;
        gates.retain(|_, v| now.saturating_duration_since(*v) < Duration::from_secs(3600));
        if gates.len() >= 4096 && !gates.contains_key(&key) {
            return Err(Failure::limited());
        }
        let global = format!("public:{provider}");
        let global_limit = matches!(provider, "wikidata" | "audnexus" | "theaudiodb");
        let scheduled = gates
            .get(&key)
            .copied()
            .unwrap_or(now)
            .max(now)
            .max(if global_limit {
                gates.get(&global).copied().unwrap_or(now)
            } else {
                now
            });
        if global_limit {
            gates.insert(global, scheduled + Duration::from_millis(gap));
        }
        if scheduled.duration_since(now) > Duration::from_secs(10) {
            return Err(Failure::limited());
        }
        gates.insert(key.clone(), scheduled + Duration::from_millis(gap));
        scheduled.saturating_duration_since(now)
    };
    tokio::time::sleep(wait).await;
    let response = request.send().await.map_err(|_| Failure::unavailable())?;
    if response.status() == StatusCode::TOO_MANY_REQUESTS {
        let seconds = response
            .headers()
            .get("retry-after")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.parse::<u64>().ok())
            .unwrap_or(60)
            .clamp(1, 3600);
        state
            .additional
            .requests
            .lock()
            .await
            .insert(key, Instant::now() + Duration::from_secs(seconds));
        return Err(Failure::limited());
    }
    if matches!(
        response.status(),
        StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN
    ) {
        return Err(Failure::rejected());
    }
    if response.status() == StatusCode::NOT_FOUND {
        return Ok(Value::Null);
    }
    if !response.status().is_success() {
        return Err(Failure::unavailable());
    }
    bounded_provider_json(response)
        .await
        .map_err(|_| Failure::unavailable())
}

async fn artwork(
    state: &ProviderBrokerState,
    identity: &Identity,
    candidate: &mut Candidate,
    source: &str,
    role: &str,
    language: &str,
) {
    let Ok(url) = reqwest::Url::parse(source) else {
        return;
    };
    if !trusted_image(&candidate.provider, &url) {
        return;
    }
    let handle = rand::random::<[u8; 16]>()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<String>();
    let mut images = state.additional.images.lock().await;
    images.retain(|_, v| v.expires > Instant::now());
    if images.len() >= 1024 {
        return;
    }
    images.insert(
        handle.clone(),
        ImageReference {
            owner: identity.subject.clone(),
            provider: candidate.provider.clone(),
            url,
            expires: Instant::now() + Duration::from_secs(900),
        },
    );
    candidate.artwork.push(Artwork {
        source_url: format!("/provider-lookups/{}/artwork/{handle}", candidate.provider),
        role: role.to_string(),
        language: language.to_string(),
    });
}

fn trusted_image(provider: &str, url: &reqwest::Url) -> bool {
    if url.scheme() != "https"
        || !url.username().is_empty()
        || url.password().is_some()
        || url.port().is_some_and(|v| v != 443)
    {
        return false;
    }
    let host = url.host_str().unwrap_or("");
    let hosts: &[&str] = match provider {
        "omdb" => &["m.media-amazon.com", "ia.media-imdb.com"],
        "tvdb" => &["artworks.thetvdb.com"],
        "fanart" => &["assets.fanart.tv"],
        "discogs" => &["i.discogs.com"],
        "theaudiodb" => &["www.theaudiodb.com", "r2.theaudiodb.com"],
        "comic-vine" => &[
            "comicvine.gamespot.com",
            "www.comicvine.com",
            "comicvine1.cbsistatic.com",
        ],
        "audnexus" => &[
            "m.media-amazon.com",
            "images-na.ssl-images-amazon.com",
            "images-eu.ssl-images-amazon.com",
        ],
        _ => &[],
    };
    hosts.contains(&host)
}

pub(super) async fn image(
    State(state): State<ProviderBrokerState>,
    headers: HeaderMap,
    Path((provider, handle)): Path<(String, String)>,
) -> Response {
    let request_id = request_id();
    let identity = match identity_from_headers(&headers, &request_id) {
        Ok(v) => v,
        Err(e) => return e.into_response(),
    };
    if let Err(e) = credentials(&state, &identity, &provider) {
        return e.response(request_id);
    }
    let target = state
        .additional
        .images
        .lock()
        .await
        .get(&handle)
        .filter(|v| {
            v.owner == identity.subject && v.provider == provider && v.expires > Instant::now()
        })
        .map(|v| v.url.clone());
    let Some(target) = target.filter(|v| trusted_image(&provider, v)) else {
        return ApiError::new(
            StatusCode::NOT_FOUND,
            "provider_artwork_not_found",
            "Search again to refresh this artwork reference.",
            request_id,
        )
        .into_response();
    };
    artwork_lookups::proxy_image_response(
        &state.client,
        target,
        "Provider artwork",
        request_id,
        false,
    )
    .await
}

#[cfg(test)]
mod safety_tests {
    use super::*;
    use axum::{
        body::{to_bytes, Body},
        http::Request,
    };
    use tower::ServiceExt;

    // New coverage is warranted by the concrete credential-exfiltration and
    // cross-user disclosure risks at this network-capable boundary (AGENTS.md).
    #[test]
    fn artwork_origins_cannot_exfiltrate_credentials_or_reach_private_services() {
        for source in [
            "http://assets.fanart.tv/x.png",
            "https://assets.fanart.tv.evil.example/x.png",
            "https://localhost/x.png",
            "https://assets.fanart.tv:8443/x.png",
            "https://key@assets.fanart.tv/x.png",
        ] {
            assert!(
                !trusted_image("fanart", &reqwest::Url::parse(source).unwrap()),
                "{source}"
            );
        }
        assert!(trusted_image(
            "fanart",
            &reqwest::Url::parse("https://assets.fanart.tv/fanart/movie.png").unwrap()
        ));
        assert!(!trusted_image(
            "omdb",
            &reqwest::Url::parse("https://assets.fanart.tv/fanart/movie.png").unwrap()
        ));
    }

    #[tokio::test]
    async fn provider_errors_redact_credentials_and_require_the_callers_account() {
        let upstream = Router::new().route(
            "/",
            get(|| async {
                Json(json!({"Response":"False","Error":"Invalid API key fixture-only-secret"}))
            }),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            axum::serve(listener, upstream).await.unwrap();
        });
        let temp = tempfile::tempdir().unwrap();
        let store = Arc::new(
            ProviderAccountStore::open(
                &temp.path().join("accounts.sqlite3"),
                &temp.path().join("master.key"),
            )
            .unwrap(),
        );
        let identity = Identity {
            subject: "owner".into(),
            username: "owner".into(),
            groups: vec!["users".into()],
        };
        store
            .save(
                &identity,
                "omdb",
                &BTreeMap::from([("apiKey".into(), "fixture-only-secret".into())]),
                1,
            )
            .unwrap();
        let mut endpoints = ProviderTestEndpoints::default();
        endpoints
            .additional_api_bases
            .insert("omdb".into(), format!("http://{address}/"));
        let state = ProviderBrokerState::with_test_endpoints(store, endpoints).unwrap();
        let app = provider_account_router(state);
        for (subject, expected) in [
            ("owner", StatusCode::UNAUTHORIZED),
            ("other-user", StatusCode::PRECONDITION_REQUIRED),
        ] {
            let request = Request::builder()
                .method("POST")
                .uri("/api/v1/provider-lookups/omdb/search")
                .header("content-type", "application/json")
                .header("x-forwarded-user", subject)
                .header("x-forwarded-groups", "users")
                .body(Body::from(r#"{"query":"Example"}"#))
                .unwrap();
            let response = app.clone().oneshot(request).await.unwrap();
            assert_eq!(response.status(), expected);
            let bytes = to_bytes(response.into_body(), 4096).await.unwrap();
            assert!(!String::from_utf8_lossy(&bytes).contains("fixture-only-secret"));
        }
        server.abort();
    }

    #[tokio::test]
    async fn artwork_references_are_owner_bound_and_invalidated_on_account_change() {
        let temp = tempfile::tempdir().unwrap();
        let state = ProviderBrokerState::new(Arc::new(
            ProviderAccountStore::open(
                &temp.path().join("accounts.sqlite3"),
                &temp.path().join("master.key"),
            )
            .unwrap(),
        ))
        .unwrap();
        let identity = Identity {
            subject: "owner".into(),
            username: "display".into(),
            groups: vec!["users".into()],
        };
        let mut candidate = Candidate::new("fanart", "tmdb:550", "Example");
        artwork(
            &state,
            &identity,
            &mut candidate,
            "https://assets.fanart.tv/example.jpg",
            "cover",
            "",
        )
        .await;
        assert_eq!(candidate.artwork.len(), 1);
        let images = state.additional.images.lock().await;
        let reference = images.values().next().unwrap();
        assert_eq!(reference.owner, "owner");
        assert_eq!(reference.provider, "fanart");
        drop(images);
        state.additional.invalidate(&identity, "fanart").await;
        assert!(state.additional.images.lock().await.is_empty());
    }
}
