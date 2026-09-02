use reqwest::{header, Client, StatusCode, Url};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use std::{
    fmt,
    path::Path,
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::{sync::Mutex, time::sleep};
use zeroize::Zeroize;

pub const TMDB_API_BASE: &str = "https://api.themoviedb.org/3/";
const MAX_CANDIDATES: usize = 10;
const MAX_PROVIDER_JSON_BYTES: usize = 4 * 1024 * 1024;

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TmdbCredentials {
    pub api_key: String,
    #[serde(default)]
    pub user_agent: Option<String>,
}

impl TmdbCredentials {
    pub fn from_file(path: &Path) -> Result<Self, ProviderError> {
        let bytes = std::fs::read(path)
            .map_err(|error| ProviderError::new(format!("read TMDB key: {error}")))?;
        let credentials = serde_json::from_slice::<Self>(&bytes)
            .map_err(|error| ProviderError::new(format!("parse TMDB key JSON: {error}")))?;
        if credentials.api_key.trim().is_empty() {
            return Err(ProviderError::new(
                "TMDB credentials require a non-empty apiKey",
            ));
        }
        Ok(credentials)
    }
}

#[derive(Clone, Debug)]
pub struct TmdbClientConfig {
    pub api_key: Option<String>,
    pub tmdb_api_base: String,
    pub request_gap: Duration,
    pub user_agent: String,
}

#[derive(Clone)]
pub struct TmdbClient {
    api_key: Option<String>,
    client: Client,
    tmdb_api_base: Url,
    request_gap: Duration,
    user_agent: String,
    last_request: Arc<Mutex<Instant>>,
}

impl TmdbClient {
    pub fn new(config: TmdbClientConfig) -> Result<Self, ProviderError> {
        let tmdb_api_base = parse_api_base(&config.tmdb_api_base, "TMDB")?;
        let allowed_hosts = provider_hosts(&tmdb_api_base);
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
            api_key: config
                .api_key
                .map(|key| key.trim().to_string())
                .filter(|key| !key.is_empty()),
            client,
            tmdb_api_base,
            request_gap: config.request_gap,
            user_agent: config.user_agent,
            last_request: Arc::new(Mutex::new(Instant::now() - config.request_gap)),
        })
    }

    pub fn has_api_key(&self) -> bool {
        self.api_key.is_some()
    }

    pub async fn search_movies(
        &self,
        query: &str,
        year: Option<u16>,
    ) -> Result<Vec<TmdbMovie>, ProviderError> {
        if query.trim().is_empty() {
            return Err(ProviderError::new("TMDB search requires a non-empty query"));
        }
        self.throttle().await;
        let url = self
            .tmdb_api_base
            .join("search/movie")
            .map_err(|error| ProviderError::new(format!("build search URL: {error}")))?;
        let mut query_params = vec![("query", query.to_string())];
        if let Some(year) = year {
            query_params.push(("year", year.to_string()));
        }
        query_params.push(("include_adult", "false".to_string()));
        query_params.push(("language", "en-US".to_string()));
        query_params.push(("page", "1".to_string()));
        let response = self
            .provider_request(self.client.get(url))
            .query(&query_params)
            .send()
            .await
            .map_err(|error| ProviderError::new(format!("search request failed: {error}")))?;
        let response = require_success(response, "TMDB movie search").await?;
        let payload =
            decode_json::<TmdbSearchResponse<TmdbMovie>>(response, "search response").await?;
        let mut candidates = Vec::new();
        for movie in payload.results.into_iter().take(MAX_CANDIDATES) {
            if movie.id == 0 {
                continue;
            }
            candidates.push(movie);
        }
        Ok(candidates)
    }

    pub async fn search_tv_shows(
        &self,
        query: &str,
        year: Option<u16>,
    ) -> Result<Vec<TmdbTvShow>, ProviderError> {
        if query.trim().is_empty() {
            return Err(ProviderError::new("TMDB search requires a non-empty query"));
        }
        self.throttle().await;
        let url = self
            .tmdb_api_base
            .join("search/tv")
            .map_err(|error| ProviderError::new(format!("build search URL: {error}")))?;
        let mut query_params = vec![("query", query.to_string())];
        if let Some(year) = year {
            query_params.push(("first_air_date_year", year.to_string()));
        }
        query_params.push(("include_adult", "false".to_string()));
        query_params.push(("language", "en-US".to_string()));
        query_params.push(("page", "1".to_string()));
        let response = self
            .provider_request(self.client.get(url))
            .query(&query_params)
            .send()
            .await
            .map_err(|error| ProviderError::new(format!("search request failed: {error}")))?;
        let response = require_success(response, "TMDB TV search").await?;
        let payload =
            decode_json::<TmdbSearchResponse<TmdbTvShow>>(response, "search response").await?;
        let mut candidates = Vec::new();
        for show in payload.results.into_iter().take(MAX_CANDIDATES) {
            if show.id == 0 {
                continue;
            }
            candidates.push(show);
        }
        Ok(candidates)
    }

    pub async fn get_movie_details(
        &self,
        movie_id: u32,
    ) -> Result<TmdbMovieDetails, ProviderError> {
        self.throttle().await;
        let url = self
            .tmdb_api_base
            .join(&format!("movie/{movie_id}"))
            .map_err(|error| ProviderError::new(format!("build movie URL: {error}")))?;
        let response = self
            .provider_request(self.client.get(url))
            .query(&[
                ("append_to_response", "credits,keywords,external_ids"),
                ("language", "en-US"),
            ])
            .send()
            .await
            .map_err(|error| {
                ProviderError::new(format!("movie details request failed: {error}"))
            })?;
        let response = require_success(response, "TMDB movie details").await?;
        decode_json::<TmdbMovieDetails>(response, "movie details").await
    }

    pub async fn get_tv_show_details(
        &self,
        tv_id: u32,
    ) -> Result<TmdbTvShowDetails, ProviderError> {
        self.throttle().await;
        let url = self
            .tmdb_api_base
            .join(&format!("tv/{tv_id}"))
            .map_err(|error| ProviderError::new(format!("build TV show URL: {error}")))?;
        let response = self
            .provider_request(self.client.get(url))
            .query(&[
                ("append_to_response", "credits,keywords,external_ids"),
                ("language", "en-US"),
            ])
            .send()
            .await
            .map_err(|error| {
                ProviderError::new(format!("TV show details request failed: {error}"))
            })?;
        let response = require_success(response, "TMDB TV show details").await?;
        decode_json::<TmdbTvShowDetails>(response, "TV show details").await
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
        let mut request = request.header(header::USER_AGENT, &self.user_agent);
        if let Some(key) = &self.api_key {
            request = request.bearer_auth(key);
        }
        request
    }
}

async fn decode_json<T: DeserializeOwned>(
    mut response: reqwest::Response,
    operation: &str,
) -> Result<T, ProviderError> {
    if response
        .content_length()
        .is_some_and(|length| length > MAX_PROVIDER_JSON_BYTES as u64)
    {
        return Err(ProviderError::new(format!(
            "{operation} exceeded the provider response limit"
        )));
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|error| ProviderError::new(format!("read {operation}: {error}")))?
    {
        if bytes.len().saturating_add(chunk.len()) > MAX_PROVIDER_JSON_BYTES {
            return Err(ProviderError::new(format!(
                "{operation} exceeded the provider response limit"
            )));
        }
        bytes.extend_from_slice(&chunk);
    }
    serde_json::from_slice(&bytes)
        .map_err(|error| ProviderError::new(format!("decode {operation}: {error}")))
}

impl Drop for TmdbClient {
    fn drop(&mut self) {
        self.api_key.zeroize();
    }
}

impl Drop for TmdbCredentials {
    fn drop(&mut self) {
        self.api_key.zeroize();
        if let Some(user_agent) = &mut self.user_agent {
            user_agent.zeroize();
        }
    }
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TmdbMovie {
    pub id: u32,
    pub title: String,
    pub original_title: String,
    pub overview: String,
    #[serde(rename = "release_date")]
    pub release_date: Option<String>,
    #[serde(rename = "vote_average")]
    pub vote_average: f32,
    #[serde(rename = "vote_count")]
    pub vote_count: u32,
    #[serde(rename = "poster_path")]
    pub poster_path: Option<String>,
    #[serde(rename = "backdrop_path")]
    pub backdrop_path: Option<String>,
    #[serde(rename = "genre_ids")]
    pub genre_ids: Vec<u32>,
    pub adult: bool,
    pub popularity: f32,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TmdbTvShow {
    pub id: u32,
    pub name: String,
    pub original_name: String,
    pub overview: String,
    #[serde(rename = "first_air_date")]
    pub first_air_date: Option<String>,
    #[serde(rename = "vote_average")]
    pub vote_average: f32,
    #[serde(rename = "vote_count")]
    pub vote_count: u32,
    #[serde(rename = "poster_path")]
    pub poster_path: Option<String>,
    #[serde(rename = "backdrop_path")]
    pub backdrop_path: Option<String>,
    #[serde(rename = "genre_ids")]
    pub genre_ids: Vec<u32>,
    pub origin_country: Vec<String>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TmdbMovieDetails {
    pub id: u32,
    pub title: String,
    pub original_title: String,
    pub overview: String,
    #[serde(rename = "release_date")]
    pub release_date: Option<String>,
    #[serde(rename = "runtime")]
    pub runtime: Option<u32>,
    #[serde(rename = "vote_average")]
    pub vote_average: f32,
    #[serde(rename = "vote_count")]
    pub vote_count: u32,
    #[serde(rename = "poster_path")]
    pub poster_path: Option<String>,
    #[serde(rename = "backdrop_path")]
    pub backdrop_path: Option<String>,
    pub genres: Vec<TmdbGenre>,
    #[serde(rename = "production_companies")]
    pub production_companies: Vec<TmdbProductionCompany>,
    #[serde(rename = "production_countries")]
    pub production_countries: Vec<TmdbProductionCountry>,
    #[serde(rename = "spoken_languages")]
    pub spoken_languages: Vec<TmdbSpokenLanguage>,
    pub status: String,
    #[serde(rename = "tagline")]
    pub tagline: Option<String>,
    pub credits: Option<TmdbCredits>,
    pub keywords: Option<TmdbKeywords>,
    #[serde(rename = "external_ids")]
    pub external_ids: Option<TmdbExternalIds>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TmdbTvShowDetails {
    pub id: u32,
    pub name: String,
    pub original_name: String,
    pub overview: String,
    #[serde(rename = "first_air_date")]
    pub first_air_date: Option<String>,
    #[serde(rename = "last_air_date")]
    pub last_air_date: Option<String>,
    #[serde(rename = "number_of_seasons")]
    pub number_of_seasons: u32,
    #[serde(rename = "number_of_episodes")]
    pub number_of_episodes: u32,
    #[serde(rename = "vote_average")]
    pub vote_average: f32,
    #[serde(rename = "vote_count")]
    pub vote_count: u32,
    #[serde(rename = "poster_path")]
    pub poster_path: Option<String>,
    #[serde(rename = "backdrop_path")]
    pub backdrop_path: Option<String>,
    pub genres: Vec<TmdbGenre>,
    #[serde(rename = "production_companies")]
    pub production_companies: Vec<TmdbProductionCompany>,
    #[serde(rename = "production_countries")]
    pub production_countries: Vec<TmdbProductionCountry>,
    #[serde(rename = "spoken_languages")]
    pub spoken_languages: Vec<TmdbSpokenLanguage>,
    pub status: String,
    pub credits: Option<TmdbCredits>,
    pub keywords: Option<TmdbKeywords>,
    #[serde(rename = "external_ids")]
    pub external_ids: Option<TmdbExternalIds>,
    #[serde(rename = "episode_run_time")]
    pub episode_run_time: Vec<u32>,
    #[serde(rename = "type")]
    pub show_type: Option<String>,
    #[serde(rename = "in_production")]
    pub in_production: bool,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TmdbGenre {
    pub id: u32,
    pub name: String,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TmdbProductionCompany {
    pub id: u32,
    pub name: String,
    #[serde(rename = "logo_path")]
    pub logo_path: Option<String>,
    #[serde(rename = "origin_country")]
    pub origin_country: String,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TmdbProductionCountry {
    #[serde(rename = "iso_3166_1")]
    pub iso_3166_1: String,
    pub name: String,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TmdbSpokenLanguage {
    #[serde(rename = "english_name")]
    pub english_name: String,
    #[serde(rename = "iso_639_1")]
    pub iso_639_1: String,
    pub name: String,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TmdbCredits {
    pub cast: Vec<TmdbCastMember>,
    pub crew: Vec<TmdbCrewMember>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TmdbCastMember {
    pub id: u32,
    pub name: String,
    pub character: String,
    pub order: u32,
    #[serde(rename = "profile_path")]
    pub profile_path: Option<String>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TmdbCrewMember {
    pub id: u32,
    pub name: String,
    pub job: String,
    pub department: String,
    #[serde(rename = "profile_path")]
    pub profile_path: Option<String>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TmdbKeywords {
    pub keywords: Vec<TmdbKeyword>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TmdbKeyword {
    pub id: u32,
    pub name: String,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TmdbExternalIds {
    #[serde(rename = "imdb_id")]
    pub imdb_id: Option<String>,
    #[serde(rename = "wikidata_id")]
    pub wikidata_id: Option<String>,
    #[serde(rename = "facebook_id")]
    pub facebook_id: Option<String>,
    #[serde(rename = "instagram_id")]
    pub instagram_id: Option<String>,
    #[serde(rename = "twitter_id")]
    pub twitter_id: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct TmdbSearchResponse<T> {
    #[serde(default)]
    results: Vec<T>,
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

fn provider_hosts(tmdb: &Url) -> Vec<String> {
    tmdb.host_str().map(str::to_string).into_iter().collect()
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
    use super::{is_trusted_origin, TmdbCredentials};

    #[test]
    fn tmdb_credentials_reject_an_empty_key() {
        let temp = tempfile::tempdir().expect("temporary directory");
        let file = temp.path().join("key.json");
        std::fs::write(&file, r#"{"apiKey":"  "}"#).expect("write key");
        assert!(TmdbCredentials::from_file(&file).is_err());
    }

    #[test]
    fn trusted_origins_allow_https_and_loopback_http_only() {
        assert!(is_trusted_origin(
            &reqwest::Url::parse("https://api.themoviedb.org/3/").unwrap()
        ));
        assert!(is_trusted_origin(
            &reqwest::Url::parse("http://127.0.0.1:8087/").unwrap()
        ));
        assert!(!is_trusted_origin(
            &reqwest::Url::parse("http://api.themoviedb.org/3/").unwrap()
        ));
    }
}
