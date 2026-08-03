use reqwest::{header, Client, StatusCode, Url};
use serde::{Deserialize, Serialize};
use std::{
    fmt,
    io::{self, Read, Seek, SeekFrom},
    path::Path,
    time::Duration,
};

const API_BASE_URL: &str = "https://api.opensubtitles.com/api/v1/";
const MAX_DOWNLOAD_BYTES: usize = 10 * 1024 * 1024;
const MOVIE_HASH_CHUNK_BYTES: usize = 64 * 1024;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MovieHash {
    pub value: String,
    pub byte_size: u64,
}

pub fn opensubtitles_movie_hash(reader: &mut (impl Read + Seek)) -> io::Result<MovieHash> {
    let byte_size = reader.seek(SeekFrom::End(0))?;
    if byte_size < (MOVIE_HASH_CHUNK_BYTES * 2) as u64 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "video is too small for distinct OpenSubtitles hash chunks",
        ));
    }

    let mut checksum = byte_size;
    let mut chunk = [0_u8; MOVIE_HASH_CHUNK_BYTES];
    reader.seek(SeekFrom::Start(0))?;
    reader.read_exact(&mut chunk)?;
    checksum = add_movie_hash_chunk(checksum, &chunk);
    reader.seek(SeekFrom::End(-(MOVIE_HASH_CHUNK_BYTES as i64)))?;
    reader.read_exact(&mut chunk)?;
    checksum = add_movie_hash_chunk(checksum, &chunk);

    Ok(MovieHash {
        value: format!("{checksum:016x}"),
        byte_size,
    })
}

fn add_movie_hash_chunk(mut checksum: u64, chunk: &[u8; MOVIE_HASH_CHUNK_BYTES]) -> u64 {
    for bytes in chunk.chunks_exact(8) {
        checksum = checksum.wrapping_add(u64::from_le_bytes(
            bytes.try_into().expect("eight-byte hash word"),
        ));
    }
    checksum
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct OpenSubtitlesCredentials {
    pub api_key: String,
    pub username: String,
    pub password: String,
    #[serde(default = "default_user_agent")]
    pub user_agent: String,
}

impl OpenSubtitlesCredentials {
    pub fn from_file(path: &Path) -> Result<Self, ProviderError> {
        let bytes = std::fs::read(path)
            .map_err(|error| ProviderError::new(format!("read credentials: {error}")))?;
        let credentials = serde_json::from_slice::<Self>(&bytes)
            .map_err(|error| ProviderError::new(format!("parse credentials JSON: {error}")))?;
        if credentials.api_key.trim().is_empty()
            || credentials.username.trim().is_empty()
            || credentials.password.is_empty()
            || credentials.user_agent.trim().is_empty()
        {
            return Err(ProviderError::new(
                "credentials require apiKey, username, password, and userAgent",
            ));
        }
        Ok(credentials)
    }
}

fn default_user_agent() -> String {
    "NixHomeServer Media Manager v0.1".to_string()
}

#[derive(Clone)]
pub struct OpenSubtitlesClient {
    credentials: OpenSubtitlesCredentials,
    client: Client,
    api_base: Url,
}

impl OpenSubtitlesClient {
    pub fn new(credentials: OpenSubtitlesCredentials) -> Result<Self, ProviderError> {
        let client = Client::builder()
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(30))
            .redirect(reqwest::redirect::Policy::custom(|attempt| {
                if attempt.previous().len() >= 3 {
                    attempt.stop()
                } else if is_opensubtitles_host(attempt.url().host_str())
                    && attempt.url().scheme() == "https"
                {
                    attempt.follow()
                } else {
                    attempt.stop()
                }
            }))
            .build()
            .map_err(|error| ProviderError::new(format!("build HTTPS client: {error}")))?;
        Ok(Self {
            credentials,
            client,
            api_base: Url::parse(API_BASE_URL)
                .map_err(|error| ProviderError::new(format!("parse API URL: {error}")))?,
        })
    }

    pub async fn search_by_query(
        &self,
        query: &str,
        languages: &str,
    ) -> Result<Vec<SubtitleMatch>, ProviderError> {
        self.search(&[("query", query), ("languages", languages)])
            .await
    }

    pub async fn search_by_hash(
        &self,
        movie_hash: &MovieHash,
        languages: &str,
    ) -> Result<Vec<SubtitleMatch>, ProviderError> {
        let byte_size = movie_hash.byte_size.to_string();
        self.search(&[
            ("moviehash", movie_hash.value.as_str()),
            ("moviebytesize", byte_size.as_str()),
            ("languages", languages),
        ])
        .await
    }

    async fn search(
        &self,
        parameters: &[(&str, &str)],
    ) -> Result<Vec<SubtitleMatch>, ProviderError> {
        let url = self
            .api_base
            .join("subtitles")
            .map_err(|error| ProviderError::new(format!("build search URL: {error}")))?;
        let response = self
            .provider_headers(self.client.get(url))
            .query(parameters)
            .send()
            .await
            .map_err(|error| ProviderError::new(format!("search request failed: {error}")))?;
        let response = require_success(response, "subtitle search").await?;
        let payload = response
            .json::<SearchResponse>()
            .await
            .map_err(|error| ProviderError::new(format!("decode search response: {error}")))?;
        Ok(flatten_search_response(payload))
    }

    pub async fn download(&self, file_id: i64) -> Result<Vec<u8>, ProviderError> {
        if file_id <= 0 {
            return Err(ProviderError::new("subtitle file ID must be positive"));
        }
        let login_url = self
            .api_base
            .join("login")
            .map_err(|error| ProviderError::new(format!("build login URL: {error}")))?;
        let response = self
            .provider_headers(self.client.post(login_url))
            .json(&serde_json::json!({
                "username": self.credentials.username,
                "password": self.credentials.password,
            }))
            .send()
            .await
            .map_err(|error| ProviderError::new(format!("login request failed: {error}")))?;
        let response = require_success(response, "provider login").await?;
        let login = response
            .json::<LoginResponse>()
            .await
            .map_err(|error| ProviderError::new(format!("decode login response: {error}")))?;
        if login.token.trim().is_empty() {
            return Err(ProviderError::new("provider login returned no token"));
        }
        let api_base = match login.base_url.as_deref() {
            Some(base_url) if !base_url.trim().is_empty() => provider_base_url(base_url)?,
            _ => self.api_base.clone(),
        };
        let download_url = api_base
            .join("download")
            .map_err(|error| ProviderError::new(format!("build download URL: {error}")))?;
        let response = self
            .provider_headers(self.client.post(download_url))
            .bearer_auth(&login.token)
            .json(&serde_json::json!({ "file_id": file_id, "sub_format": "srt" }))
            .send()
            .await
            .map_err(|error| ProviderError::new(format!("download request failed: {error}")))?;
        let response = require_success(response, "subtitle download allocation").await?;
        let allocation = response
            .json::<DownloadResponse>()
            .await
            .map_err(|error| ProviderError::new(format!("decode download response: {error}")))?;
        let link = validated_download_url(&allocation.link)?;
        let response = self
            .client
            .get(link)
            .header(header::USER_AGENT, &self.credentials.user_agent)
            .send()
            .await
            .map_err(|error| ProviderError::new(format!("fetch subtitle file: {error}")))?;
        let mut response = require_success(response, "subtitle file fetch").await?;
        if response
            .content_length()
            .is_some_and(|size| size > MAX_DOWNLOAD_BYTES as u64)
        {
            return Err(ProviderError::new("subtitle file exceeds the 10 MiB limit"));
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|error| ProviderError::new(format!("read subtitle file: {error}")))?
        {
            if bytes.len().saturating_add(chunk.len()) > MAX_DOWNLOAD_BYTES {
                return Err(ProviderError::new("subtitle file exceeds the 10 MiB limit"));
            }
            bytes.extend_from_slice(&chunk);
        }
        Ok(bytes)
    }

    fn provider_headers(&self, request: reqwest::RequestBuilder) -> reqwest::RequestBuilder {
        request
            .header("Api-Key", &self.credentials.api_key)
            .header(header::USER_AGENT, &self.credentials.user_agent)
            .header(header::ACCEPT, "application/json")
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SubtitleMatch {
    pub provider_id: String,
    pub file_id: i64,
    pub file_name: String,
    pub language: String,
    pub release: String,
    pub download_count: i64,
    pub hearing_impaired: bool,
    pub hash_matched: bool,
    pub machine_translated: bool,
    pub ai_translated: bool,
}

#[derive(Debug, Deserialize)]
struct SearchResponse {
    #[serde(default)]
    data: Vec<SearchEntry>,
}

#[derive(Debug, Deserialize)]
struct SearchEntry {
    id: String,
    attributes: SearchAttributes,
}

#[derive(Clone, Debug, Deserialize)]
struct SearchAttributes {
    #[serde(default)]
    language: String,
    #[serde(default)]
    release: String,
    #[serde(default)]
    download_count: i64,
    #[serde(default)]
    hearing_impaired: bool,
    #[serde(default)]
    moviehash_match: bool,
    #[serde(default)]
    machine_translated: bool,
    #[serde(default)]
    ai_translated: bool,
    #[serde(default)]
    files: Vec<SearchFile>,
}

#[derive(Clone, Debug, Deserialize)]
struct SearchFile {
    file_id: i64,
    #[serde(default)]
    file_name: String,
}

#[derive(Debug, Deserialize)]
struct LoginResponse {
    token: String,
    base_url: Option<String>,
}

#[derive(Debug, Deserialize)]
struct DownloadResponse {
    link: String,
}

fn flatten_search_response(response: SearchResponse) -> Vec<SubtitleMatch> {
    response
        .data
        .into_iter()
        .flat_map(|entry| {
            entry
                .attributes
                .files
                .clone()
                .into_iter()
                .map(move |file| SubtitleMatch {
                    provider_id: entry.id.clone(),
                    file_id: file.file_id,
                    file_name: file.file_name,
                    language: entry.attributes.language.clone(),
                    release: entry.attributes.release.clone(),
                    download_count: entry.attributes.download_count,
                    hearing_impaired: entry.attributes.hearing_impaired,
                    hash_matched: entry.attributes.moviehash_match,
                    machine_translated: entry.attributes.machine_translated,
                    ai_translated: entry.attributes.ai_translated,
                })
        })
        .filter(|result| result.file_id > 0)
        .collect()
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

fn provider_base_url(value: &str) -> Result<Url, ProviderError> {
    let candidate = if value.contains("://") {
        value.to_string()
    } else {
        format!("https://{value}/api/v1/")
    };
    let mut url = Url::parse(&candidate).map_err(|error| {
        ProviderError::new(format!("provider returned invalid API URL: {error}"))
    })?;
    if url.scheme() != "https" || !is_opensubtitles_host(url.host_str()) {
        return Err(ProviderError::new(
            "provider returned an untrusted API origin",
        ));
    }
    if url.path() == "/" {
        url.set_path("/api/v1/");
    } else if !url.path().ends_with('/') {
        url.set_path(&format!("{}/", url.path()));
    }
    Ok(url)
}

fn validated_download_url(value: &str) -> Result<Url, ProviderError> {
    let url = Url::parse(value).map_err(|error| {
        ProviderError::new(format!("provider returned invalid download URL: {error}"))
    })?;
    if url.scheme() != "https" || !is_opensubtitles_host(url.host_str()) {
        return Err(ProviderError::new(
            "provider returned an untrusted download origin",
        ));
    }
    Ok(url)
}

fn is_opensubtitles_host(host: Option<&str>) -> bool {
    host.is_some_and(|host| host == "opensubtitles.com" || host.ends_with(".opensubtitles.com"))
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
        flatten_search_response, opensubtitles_movie_hash, validated_download_url, SearchResponse,
    };
    use std::io::Cursor;

    #[test]
    fn movie_hash_uses_little_endian_head_tail_words_and_file_size() {
        let mut bytes = vec![0_u8; 128 * 1024];
        bytes[..8].copy_from_slice(&[1, 2, 3, 4, 5, 6, 7, 8]);
        let tail = bytes.len() - 8;
        bytes[tail..].copy_from_slice(&[8, 7, 6, 5, 4, 3, 2, 1]);

        let hash = opensubtitles_movie_hash(&mut Cursor::new(bytes)).expect("movie hash");

        assert_eq!(hash.value, "09090909090b0909");
        assert_eq!(hash.byte_size, 128 * 1024);
    }

    #[test]
    fn movie_hash_rejects_files_without_distinct_head_and_tail_chunks() {
        let error = opensubtitles_movie_hash(&mut Cursor::new(vec![0_u8; 127 * 1024]))
            .expect_err("small files must be rejected");

        assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);
    }

    #[test]
    fn official_search_shape_is_flattened_to_downloadable_files() {
        let response = serde_json::from_value::<SearchResponse>(serde_json::json!({
            "data": [{
                "id": "10931262",
                "attributes": {
                    "language": "en",
                    "release": "Arrival.2016.BluRay",
                    "download_count": 230,
                    "hearing_impaired": true,
                    "moviehash_match": true,
                    "machine_translated": false,
                    "ai_translated": false,
                    "files": [{ "file_id": 12345, "file_name": "Arrival.en.srt" }]
                }
            }]
        }))
        .expect("search response");
        let results = flatten_search_response(response);
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].file_id, 12345);
        assert_eq!(results[0].language, "en");
        assert!(results[0].hearing_impaired);
        assert!(results[0].hash_matched);
    }

    #[test]
    fn provider_downloads_are_restricted_to_opensubtitles_https_origins() {
        assert!(validated_download_url("https://dl.opensubtitles.com/file/abc").is_ok());
        assert!(validated_download_url("http://dl.opensubtitles.com/file/abc").is_err());
        assert!(validated_download_url("https://opensubtitles.com.example/file/abc").is_err());
    }
}
