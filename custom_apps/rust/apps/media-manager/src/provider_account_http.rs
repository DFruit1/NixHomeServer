use crate::{
    artwork::sniff_image_content_type,
    config::Identity,
    open_library,
    provider_accounts::{ProviderAccountError, ProviderAccountStore, ProviderAccountSummary},
    subtitles::{MovieHash, OpenSubtitlesClient, OpenSubtitlesCredentials},
};
use axum::{
    extract::{rejection::JsonRejection, DefaultBodyLimit, Path, Query, State},
    http::{header, HeaderMap, HeaderValue, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::get,
    Json, Router,
};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, BTreeSet},
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    },
    time::{SystemTime, UNIX_EPOCH},
};
use zeroize::Zeroize;

mod artwork_lookups;
mod google_books;
mod tmdb_lookups;

static REQUEST_SEQUENCE: AtomicU64 = AtomicU64::new(1);
const MAX_CREDENTIAL_FIELDS: usize = 8;
const MAX_CREDENTIAL_VALUE_BYTES: usize = 8192;

#[derive(Clone)]
pub struct ProviderBrokerState {
    pub store: Arc<ProviderAccountStore>,
    client: reqwest::Client,
    endpoints: ProviderTestEndpoints,
    open_library_gate: open_library::RequestGate,
}

#[derive(Clone, Debug)]
pub struct ProviderTestEndpoints {
    pub tmdb_api_base: String,
    pub opensubtitles_api_base: String,
    pub acoustid_api_base: String,
    pub open_library_api_base: String,
    pub open_library_covers_base: String,
    pub tmdb_images_base: String,
    pub cover_art_archive_base: String,
    pub google_books_api_base: String,
}

impl Default for ProviderTestEndpoints {
    fn default() -> Self {
        Self {
            tmdb_api_base: "https://api.themoviedb.org/3/".to_string(),
            opensubtitles_api_base: "https://api.opensubtitles.com/api/v1/".to_string(),
            acoustid_api_base: "https://api.acoustid.org/v2/".to_string(),
            open_library_api_base: "https://openlibrary.org/".to_string(),
            open_library_covers_base: "https://covers.openlibrary.org/".to_string(),
            tmdb_images_base: "https://image.tmdb.org/t/p/".to_string(),
            cover_art_archive_base: "https://coverartarchive.org/".to_string(),
            google_books_api_base: "https://www.googleapis.com/books/v1/".to_string(),
        }
    }
}

impl ProviderBrokerState {
    pub fn new(store: Arc<ProviderAccountStore>) -> Result<Self, String> {
        Self::with_test_endpoints(store, ProviderTestEndpoints::default())
    }

    pub fn with_test_endpoints(
        store: Arc<ProviderAccountStore>,
        endpoints: ProviderTestEndpoints,
    ) -> Result<Self, String> {
        for (label, endpoint) in [
            ("TMDB", endpoints.tmdb_api_base.as_str()),
            ("OpenSubtitles", endpoints.opensubtitles_api_base.as_str()),
            ("AcoustID", endpoints.acoustid_api_base.as_str()),
            ("Open Library", endpoints.open_library_api_base.as_str()),
            (
                "Open Library Covers",
                endpoints.open_library_covers_base.as_str(),
            ),
            ("TMDB Images", endpoints.tmdb_images_base.as_str()),
            (
                "Cover Art Archive",
                endpoints.cover_art_archive_base.as_str(),
            ),
            ("Google Books", endpoints.google_books_api_base.as_str()),
        ] {
            trusted_provider_base(endpoint)
                .map_err(|error| format!("invalid {label} test endpoint: {error}"))?;
        }
        let client = reqwest::Client::builder()
            .connect_timeout(std::time::Duration::from_secs(5))
            .timeout(std::time::Duration::from_secs(15))
            .redirect(reqwest::redirect::Policy::none())
            .user_agent("NixHomeServer Media Manager/0.1.0")
            .build()
            .map_err(|error| format!("build provider test client: {error}"))?;
        Ok(Self {
            store,
            client,
            endpoints,
            open_library_gate: open_library::RequestGate::default(),
        })
    }
}

#[derive(Clone, Copy, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
enum SetupKind {
    Public,
    ApiKey,
    Account,
}

#[derive(Clone, Copy, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
enum ImplementationStatus {
    Active,
    Planned,
}

#[derive(Clone, Copy)]
enum ConnectionTestAdapter {
    Tmdb,
    OpenSubtitles,
}

#[derive(Clone, Copy, Serialize)]
#[serde(rename_all = "camelCase")]
struct CredentialFieldDefinition {
    id: &'static str,
    label: &'static str,
    input_type: &'static str,
    is_required: bool,
    help: &'static str,
}

#[derive(Clone, Copy)]
struct ProviderDefinition {
    id: &'static str,
    name: &'static str,
    media_domains: &'static [&'static str],
    setup_kind: SetupKind,
    implementation_status: ImplementationStatus,
    connection_test: Option<ConnectionTestAdapter>,
    capabilities: &'static [&'static str],
    credential_fields: &'static [CredentialFieldDefinition],
    setup_url: &'static str,
    documentation_url: &'static str,
    notes: &'static str,
}

impl ProviderDefinition {
    fn can_configure(self) -> bool {
        self.implementation_status == ImplementationStatus::Active
            && !self.credential_fields.is_empty()
    }

    fn can_test(self) -> bool {
        self.can_configure() && self.connection_test.is_some()
    }
}

const API_KEY_FIELD: [CredentialFieldDefinition; 1] = [CredentialFieldDefinition {
    id: "apiKey",
    label: "API key",
    input_type: "password",
    is_required: true,
    help: "Paste the key from the provider's developer or account settings.",
}];

const TMDB_TOKEN_FIELD: [CredentialFieldDefinition; 1] = [CredentialFieldDefinition {
    id: "apiKey",
    label: "API Read Access Token",
    input_type: "password",
    is_required: true,
    help: "Paste the v4 API Read Access Token from TMDB API settings; it is used as a bearer token for v3 and v4 requests.",
}];

const OPENSUBTITLES_FIELDS: [CredentialFieldDefinition; 4] = [
    CredentialFieldDefinition {
        id: "apiKey",
        label: "Application API key",
        input_type: "password",
        is_required: true,
        help: "Create an OpenSubtitles REST API consumer and paste its key.",
    },
    CredentialFieldDefinition {
        id: "username",
        label: "Account username",
        input_type: "text",
        is_required: true,
        help: "Your OpenSubtitles.com account username.",
    },
    CredentialFieldDefinition {
        id: "password",
        label: "Account password",
        input_type: "password",
        is_required: true,
        help: "Use the value saved in your password manager.",
    },
    CredentialFieldDefinition {
        id: "userAgent",
        label: "Application user agent",
        input_type: "text",
        is_required: false,
        help: "Optional registered application name; Media Manager supplies a safe default.",
    },
];

const TVDB_FIELDS: [CredentialFieldDefinition; 2] = [
    CredentialFieldDefinition {
        id: "apiKey",
        label: "API key",
        input_type: "password",
        is_required: true,
        help: "The project API key issued by TheTVDB.",
    },
    CredentialFieldDefinition {
        id: "pin",
        label: "Subscriber PIN",
        input_type: "password",
        is_required: false,
        help: "Required only for TheTVDB accounts whose API access uses a subscriber PIN.",
    },
];

const PODCAST_INDEX_FIELDS: [CredentialFieldDefinition; 2] = [
    CredentialFieldDefinition {
        id: "apiKey",
        label: "API key",
        input_type: "password",
        is_required: true,
        help: "The API key issued by Podcast Index.",
    },
    CredentialFieldDefinition {
        id: "apiSecret",
        label: "API secret",
        input_type: "password",
        is_required: true,
        help: "The matching Podcast Index API secret.",
    },
];

const PROVIDERS: &[ProviderDefinition] = &[
    ProviderDefinition {
        id: "tmdb",
        name: "The Movie Database (TMDB)",
        media_domains: &["movies", "television"],
        setup_kind: SetupKind::ApiKey,
        implementation_status: ImplementationStatus::Active,
        connection_test: Some(ConnectionTestAdapter::Tmdb),
        capabilities: &[
            "search",
            "details",
            "seasons",
            "episodes",
            "people",
            "images",
            "external-ids",
        ],
        credential_fields: &TMDB_TOKEN_FIELD,
        setup_url: "https://www.themoviedb.org/settings/api",
        documentation_url: "https://developer.themoviedb.org/docs/getting-started",
        notes: "Rich movie and television matching. TMDB attribution is required when its data is displayed.",
    },
    ProviderDefinition {
        id: "opensubtitles",
        name: "OpenSubtitles",
        media_domains: &["subtitles"],
        setup_kind: SetupKind::Account,
        implementation_status: ImplementationStatus::Active,
        connection_test: Some(ConnectionTestAdapter::OpenSubtitles),
        capabilities: &["subtitle-search", "movie-hash-match", "subtitle-download"],
        credential_fields: &OPENSUBTITLES_FIELDS,
        setup_url: "https://www.opensubtitles.com/consumers",
        documentation_url: "https://opensubtitles.stoplight.io/docs/opensubtitles-api",
        notes: "Uses an exact local movie hash before title fallback; media contents are not uploaded.",
    },
    ProviderDefinition {
        id: "acoustid",
        name: "AcoustID",
        media_domains: &["music"],
        setup_kind: SetupKind::ApiKey,
        implementation_status: ImplementationStatus::Active,
        connection_test: None,
        capabilities: &["audio-fingerprint", "musicbrainz-id"],
        credential_fields: &API_KEY_FIELD,
        setup_url: "https://acoustid.org/settings",
        documentation_url: "https://acoustid.org/webservice",
        notes: "Resolves locally calculated Chromaprint fingerprints without uploading audio files.",
    },
    ProviderDefinition {
        id: "musicbrainz",
        name: "MusicBrainz",
        media_domains: &["music"],
        setup_kind: SetupKind::Public,
        implementation_status: ImplementationStatus::Active,
        connection_test: None,
        capabilities: &[
            "search",
            "releases",
            "release-groups",
            "recordings",
            "stable-ids",
        ],
        credential_fields: &[],
        setup_url: "https://musicbrainz.org/",
        documentation_url: "https://musicbrainz.org/doc/MusicBrainz_API",
        notes: "Public lookup with a descriptive user agent and a shared one-request-per-second limit.",
    },
    ProviderDefinition {
        id: "cover-art-archive",
        name: "Cover Art Archive",
        media_domains: &["music"],
        setup_kind: SetupKind::Public,
        implementation_status: ImplementationStatus::Active,
        connection_test: None,
        capabilities: &["cover-art"],
        credential_fields: &[],
        setup_url: "https://coverartarchive.org/",
        documentation_url: "https://musicbrainz.org/doc/Cover_Art_Archive/API",
        notes: "Release-linked artwork using MusicBrainz identifiers.",
    },
    ProviderDefinition {
        id: "open-library",
        name: "Open Library",
        media_domains: &["books", "audiobooks"],
        setup_kind: SetupKind::Public,
        implementation_status: ImplementationStatus::Active,
        connection_test: None,
        capabilities: &["search", "isbn", "editions", "covers", "bibliographic-metadata"],
        credential_fields: &[],
        setup_url: "https://openlibrary.org/",
        documentation_url: "https://openlibrary.org/developers/api",
        notes: "Public, human-triggered bibliographic search with normalized editions, identifiers, and cover links.",
    },
    ProviderDefinition {
        id: "wikidata",
        name: "Wikidata",
        media_domains: &["movies", "television", "music", "books", "people"],
        setup_kind: SetupKind::Public,
        implementation_status: ImplementationStatus::Planned,
        connection_test: None,
        capabilities: &["external-ids", "cross-provider-links"],
        credential_fields: &[],
        setup_url: "https://www.wikidata.org/",
        documentation_url: "https://www.wikidata.org/wiki/Wikidata:Data_access",
        notes: "Useful for reconciling identifiers across otherwise disconnected providers.",
    },
    ProviderDefinition {
        id: "audnexus",
        name: "Audnexus",
        media_domains: &["audiobooks"],
        setup_kind: SetupKind::Public,
        implementation_status: ImplementationStatus::Planned,
        connection_test: None,
        capabilities: &["audiobook-search", "authors", "narrators", "series"],
        credential_fields: &[],
        setup_url: "https://audnex.us/",
        documentation_url: "https://api.audnex.us/",
        notes: "Audiobook-focused enrichment where provider availability and terms permit it.",
    },
    ProviderDefinition {
        id: "tvdb",
        name: "TheTVDB",
        media_domains: &["television", "movies"],
        setup_kind: SetupKind::Account,
        implementation_status: ImplementationStatus::Planned,
        connection_test: None,
        capabilities: &["search", "episodes", "artwork", "translations"],
        credential_fields: &TVDB_FIELDS,
        setup_url: "https://thetvdb.com/api-information",
        documentation_url: "https://github.com/thetvdb/v4-api",
        notes: "A second episodic source for disambiguation and alternate ordering.",
    },
    ProviderDefinition {
        id: "omdb",
        name: "OMDb API",
        media_domains: &["movies", "television"],
        setup_kind: SetupKind::ApiKey,
        implementation_status: ImplementationStatus::Planned,
        connection_test: None,
        capabilities: &["imdb-lookup", "ratings", "search"],
        credential_fields: &API_KEY_FIELD,
        setup_url: "https://www.omdbapi.com/apikey.aspx",
        documentation_url: "https://www.omdbapi.com/",
        notes: "Compact IMDb-oriented lookup and rating cross-checks.",
    },
    ProviderDefinition {
        id: "fanart",
        name: "Fanart.tv",
        media_domains: &["movies", "television", "music"],
        setup_kind: SetupKind::ApiKey,
        implementation_status: ImplementationStatus::Planned,
        connection_test: None,
        capabilities: &["artwork", "logos", "backgrounds"],
        credential_fields: &API_KEY_FIELD,
        setup_url: "https://fanart.tv/get-an-api-key/",
        documentation_url: "https://fanart.tv/api-docs/",
        notes: "Artwork supplement after a title has been matched to a stable provider ID.",
    },
    ProviderDefinition {
        id: "discogs",
        name: "Discogs",
        media_domains: &["music"],
        setup_kind: SetupKind::ApiKey,
        implementation_status: ImplementationStatus::Planned,
        connection_test: None,
        capabilities: &["release-search", "labels", "catalog-numbers", "artwork"],
        credential_fields: &API_KEY_FIELD,
        setup_url: "https://www.discogs.com/settings/developers",
        documentation_url: "https://www.discogs.com/developers/",
        notes: "Release and pressing details that complement MusicBrainz.",
    },
    ProviderDefinition {
        id: "theaudiodb",
        name: "TheAudioDB",
        media_domains: &["music"],
        setup_kind: SetupKind::ApiKey,
        implementation_status: ImplementationStatus::Planned,
        connection_test: None,
        capabilities: &["artist-details", "album-details", "artwork"],
        credential_fields: &API_KEY_FIELD,
        setup_url: "https://www.theaudiodb.com/api_apply.php",
        documentation_url: "https://www.theaudiodb.com/api_guide.php",
        notes: "Artist biographies and artwork as a supplement to stable MusicBrainz IDs.",
    },
    ProviderDefinition {
        id: "google-books",
        name: "Google Books",
        media_domains: &["books"],
        setup_kind: SetupKind::ApiKey,
        implementation_status: ImplementationStatus::Active,
        connection_test: None,
        capabilities: &["search", "isbn", "descriptions", "covers"],
        credential_fields: &API_KEY_FIELD,
        setup_url: "https://console.cloud.google.com/apis/library/books.googleapis.com",
        documentation_url: "https://developers.google.com/books/docs/v1/using",
        notes: "Broad edition search; the configured key avoids relying on anonymous quota.",
    },
    ProviderDefinition {
        id: "comic-vine",
        name: "Comic Vine",
        media_domains: &["comics", "manga"],
        setup_kind: SetupKind::ApiKey,
        implementation_status: ImplementationStatus::Planned,
        connection_test: None,
        capabilities: &["issues", "volumes", "people", "covers"],
        credential_fields: &API_KEY_FIELD,
        setup_url: "https://comicvine.gamespot.com/api/",
        documentation_url: "https://comicvine.gamespot.com/api/documentation",
        notes: "Comic issue and volume metadata for ComicInfo.xml workflows.",
    },
    ProviderDefinition {
        id: "isbndb",
        name: "ISBNdb",
        media_domains: &["books", "audiobooks"],
        setup_kind: SetupKind::ApiKey,
        implementation_status: ImplementationStatus::Planned,
        connection_test: None,
        capabilities: &["isbn", "editions", "publishers"],
        credential_fields: &API_KEY_FIELD,
        setup_url: "https://isbndb.com/isbn-database",
        documentation_url: "https://isbndb.com/apidocs/v2",
        notes: "Optional paid bibliographic cross-check for difficult ISBN and edition matches.",
    },
    ProviderDefinition {
        id: "podcast-index",
        name: "Podcast Index",
        media_domains: &["podcasts"],
        setup_kind: SetupKind::Account,
        implementation_status: ImplementationStatus::Planned,
        connection_test: None,
        capabilities: &["podcast-search", "feeds", "episodes", "podcast-namespace"],
        credential_fields: &PODCAST_INDEX_FIELDS,
        setup_url: "https://api.podcastindex.org/",
        documentation_url: "https://podcastindex-org.github.io/docs-api/",
        notes: "Feed and episode discovery while portable podcast writes remain inspection-only.",
    },
    ProviderDefinition {
        id: "subdl",
        name: "SubDL",
        media_domains: &["subtitles"],
        setup_kind: SetupKind::ApiKey,
        implementation_status: ImplementationStatus::Planned,
        connection_test: None,
        capabilities: &["subtitle-search", "subtitle-download"],
        credential_fields: &API_KEY_FIELD,
        setup_url: "https://subdl.com/panel/api",
        documentation_url: "https://subdl.com/api-doc",
        notes: "Optional subtitle fallback; results still require review and staged installation.",
    },
];

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SaveProviderAccountRequest {
    credentials: BTreeMap<String, String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct OpenSubtitlesSearchRequest {
    movie_hash: Option<String>,
    movie_byte_size: Option<u64>,
    query: String,
    languages: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct OpenSubtitlesDownloadRequest {
    file_id: i64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct AcoustidLookupRequest {
    fingerprint: String,
    duration: u32,
}

#[derive(Debug, Deserialize)]
struct AcoustidLookupResponse {
    status: String,
    #[serde(default)]
    results: Vec<AcoustidResult>,
}

#[derive(Debug, Deserialize)]
struct AcoustidResult {
    #[serde(default)]
    recordings: Vec<AcoustidRecording>,
}

#[derive(Debug, Deserialize)]
struct AcoustidRecording {
    #[serde(default)]
    releasegroups: Vec<AcoustidReleaseGroup>,
}

#[derive(Debug, Deserialize)]
struct AcoustidReleaseGroup {
    id: String,
}

pub fn provider_account_router(state: ProviderBrokerState) -> Router {
    Router::new()
        .route("/api/v1/provider-accounts", get(list_provider_accounts))
        .route(
            "/api/v1/provider-accounts/{provider_id}",
            axum::routing::put(save_provider_account).delete(delete_provider_account),
        )
        .route(
            "/api/v1/provider-accounts/{provider_id}/test",
            axum::routing::post(test_provider_account),
        )
        .route(
            "/api/v1/provider-lookups/tmdb/search",
            axum::routing::post(tmdb_lookups::search),
        )
        .route(
            "/api/v1/provider-lookups/tmdb/details",
            axum::routing::post(tmdb_lookups::details),
        )
        .route(
            "/api/v1/provider-lookups/tmdb/images/{size}/{file_name}",
            get(artwork_lookups::tmdb_image),
        )
        .route(
            "/api/v1/provider-lookups/cover-art-archive/releases/{release_id}/front",
            get(artwork_lookups::cover_art_archive_front),
        )
        .route(
            "/api/v1/provider-lookups/google-books/search",
            axum::routing::post(google_books::search),
        )
        .route(
            "/api/v1/provider-lookups/google-books/volumes/{volume_id}/cover",
            get(google_books::cover),
        )
        .route(
            "/api/v1/provider-lookups/opensubtitles/search",
            axum::routing::post(search_opensubtitles),
        )
        .route(
            "/api/v1/provider-lookups/opensubtitles/download",
            axum::routing::post(download_opensubtitles),
        )
        .route(
            "/api/v1/provider-lookups/acoustid/lookup",
            axum::routing::post(lookup_acoustid),
        )
        .route(
            "/api/v1/provider-lookups/open-library/search",
            axum::routing::post(search_open_library),
        )
        .route(
            "/api/v1/provider-lookups/open-library/works/{work_id}/editions",
            get(open_library_editions),
        )
        .route(
            "/api/v1/provider-lookups/open-library/covers/{cover_id}",
            get(open_library_cover),
        )
        .layer(DefaultBodyLimit::max(64 * 1024))
        .layer(middleware::from_fn(no_store_responses))
        .with_state(state)
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct OpenLibrarySearchRequest {
    query: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct OpenLibraryEditionsQuery {
    #[serde(default)]
    offset: u32,
    #[serde(default = "default_open_library_edition_limit")]
    limit: u8,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct OpenLibraryEditionsResponse {
    provider: &'static str,
    work_id: String,
    request_id: String,
    #[serde(flatten)]
    page: open_library::NormalizedEditions,
}

fn default_open_library_edition_limit() -> u8 {
    12
}

async fn search_open_library(
    State(state): State<ProviderBrokerState>,
    headers: HeaderMap,
    payload: Result<Json<OpenLibrarySearchRequest>, JsonRejection>,
) -> Response {
    let request_id = request_id();
    if let Err(error) = authenticated_identity(&headers, &request_id) {
        return error.into_response();
    }
    let request = match payload {
        Ok(Json(request)) => request,
        Err(_) => return invalid_json(&request_id).into_response(),
    };
    let query = request.query.trim();
    if query.is_empty()
        || query.chars().count() > 500
        || query
            .chars()
            .any(|character| character.is_control() && !character.is_whitespace())
    {
        return ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "open_library_query_invalid",
            "Open Library search requires a query between 1 and 500 characters.",
            request_id,
        )
        .into_response();
    }
    let url = match provider_test_url(&state.endpoints.open_library_api_base, "search.json") {
        Ok(url) => url,
        Err(_) => {
            return ApiError::new(
                StatusCode::SERVICE_UNAVAILABLE,
                "provider_adapter_unavailable",
                "The Open Library adapter could not be initialized.",
                request_id,
            )
            .into_response()
        }
    };
    let provider_query = open_library::normalized_query(query);
    state.open_library_gate.wait().await;
    let response = state
        .client
        .get(url)
        .query(&[
            ("q", provider_query.as_str()),
            ("fields", open_library::SEARCH_FIELDS),
            ("limit", "12"),
        ])
        .send()
        .await;
    let response = match response {
        Ok(response) if response.status().is_success() => response,
        _ => return provider_lookup_failed("Open Library search", request_id),
    };
    let payload = match bounded_provider_json::<open_library::SearchResponse>(response).await {
        Ok(payload) => payload,
        Err(_) => return provider_lookup_failed("Open Library search", request_id),
    };
    Json(json!({
        "provider": "open-library",
        "query": query,
        "results": open_library::normalize_response(payload),
        "requestId": request_id,
    }))
    .into_response()
}

async fn open_library_editions(
    State(state): State<ProviderBrokerState>,
    Path(work_id): Path<String>,
    Query(query): Query<OpenLibraryEditionsQuery>,
    headers: HeaderMap,
) -> Response {
    let request_id = request_id();
    if let Err(error) = authenticated_identity(&headers, &request_id) {
        return error.into_response();
    }
    let Some(work_id) = open_library::normalized_work_id(&work_id) else {
        return ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "open_library_work_id_invalid",
            "Supply a valid Open Library work ID.",
            request_id,
        )
        .into_response();
    };
    if query.limit == 0 || query.limit > 20 || query.offset > 10_000 {
        return ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "open_library_editions_page_invalid",
            "Edition pages require a limit from 1 to 20 and an offset no greater than 10000.",
            request_id,
        )
        .into_response();
    }
    let path = format!("works/{work_id}/editions.json");
    let url = match provider_test_url(&state.endpoints.open_library_api_base, &path) {
        Ok(url) => url,
        Err(_) => {
            return ApiError::new(
                StatusCode::SERVICE_UNAVAILABLE,
                "provider_adapter_unavailable",
                "The Open Library adapter could not be initialized.",
                request_id,
            )
            .into_response()
        }
    };
    state.open_library_gate.wait().await;
    let response = state
        .client
        .get(url)
        .query(&[
            ("offset", query.offset.to_string()),
            ("limit", query.limit.to_string()),
        ])
        .send()
        .await;
    let response = match response {
        Ok(response) if response.status().is_success() => response,
        _ => return provider_lookup_failed("Open Library edition lookup", request_id),
    };
    let payload = match bounded_provider_json::<open_library::EditionsResponse>(response).await {
        Ok(payload) => payload,
        Err(_) => return provider_lookup_failed("Open Library edition lookup", request_id),
    };
    Json(OpenLibraryEditionsResponse {
        provider: "open-library",
        work_id,
        request_id,
        page: open_library::normalize_editions(payload, query.offset, query.limit),
    })
    .into_response()
}

async fn open_library_cover(
    State(state): State<ProviderBrokerState>,
    Path(cover_id): Path<String>,
    headers: HeaderMap,
) -> Response {
    let request_id = request_id();
    if let Err(error) = authenticated_identity(&headers, &request_id) {
        return error.into_response();
    }
    let cover_id = match cover_id.parse::<u64>() {
        Ok(cover_id) if cover_id > 0 && cover_id <= i64::MAX as u64 => cover_id,
        _ => {
            return ApiError::new(
                StatusCode::UNPROCESSABLE_ENTITY,
                "open_library_cover_id_invalid",
                "Supply a positive Open Library cover ID.",
                request_id,
            )
            .into_response()
        }
    };
    let path = format!("b/id/{cover_id}-L.jpg");
    let url = match provider_test_url(&state.endpoints.open_library_covers_base, &path) {
        Ok(url) => url,
        Err(_) => {
            return ApiError::new(
                StatusCode::SERVICE_UNAVAILABLE,
                "provider_adapter_unavailable",
                "The Open Library cover adapter could not be initialized.",
                request_id,
            )
            .into_response()
        }
    };
    state.open_library_gate.wait().await;
    let response = state
        .client
        .get(url)
        .query(&[("default", "false")])
        .send()
        .await;
    let response = match response {
        Ok(response) if response.status() == reqwest::StatusCode::NOT_FOUND => {
            return ApiError::new(
                StatusCode::NOT_FOUND,
                "open_library_cover_not_found",
                "Open Library does not have that cover image.",
                request_id,
            )
            .into_response()
        }
        Ok(response) if response.status().is_success() => response,
        _ => return provider_lookup_failed("Open Library cover lookup", request_id),
    };
    let content_type = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split(';').next())
        .unwrap_or("")
        .trim()
        .to_ascii_lowercase();
    if !matches!(
        content_type.as_str(),
        "image/jpeg" | "image/png" | "image/gif" | "image/webp"
    ) {
        return provider_lookup_failed("Open Library cover lookup", request_id);
    }
    let bytes = match bounded_provider_bytes(response, 16 * 1024 * 1024).await {
        Ok(bytes) if !bytes.is_empty() => bytes,
        _ => return provider_lookup_failed("Open Library cover lookup", request_id),
    };
    let Some(sniffed_content_type) = sniff_image_content_type(&bytes) else {
        return provider_lookup_failed("Open Library cover lookup", request_id);
    };
    if sniffed_content_type != content_type {
        return provider_lookup_failed("Open Library cover lookup", request_id);
    }
    (
        StatusCode::OK,
        [
            (header::CONTENT_TYPE, sniffed_content_type.to_string()),
            (
                header::HeaderName::from_static("x-content-type-options"),
                "nosniff".to_string(),
            ),
        ],
        bytes,
    )
        .into_response()
}

async fn lookup_acoustid(
    State(state): State<ProviderBrokerState>,
    headers: HeaderMap,
    payload: Result<Json<AcoustidLookupRequest>, JsonRejection>,
) -> Response {
    let request_id = request_id();
    let identity = match authenticated_identity(&headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    let request = match payload {
        Ok(Json(request)) => request,
        Err(_) => return invalid_json(&request_id).into_response(),
    };
    if request.duration == 0
        || request.duration > 24 * 60 * 60
        || request.fingerprint.len() < 4
        || request.fingerprint.len() > 16 * 1024
        || !request
            .fingerprint
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
    {
        return ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "acoustid_fingerprint_invalid",
            "Supply a valid local Chromaprint fingerprint and duration.",
            request_id,
        )
        .into_response();
    }
    let mut credentials = match state.store.load_credentials(&identity, "acoustid") {
        Ok(Some(credentials)) => credentials,
        Ok(None) => {
            return ApiError::new(
                StatusCode::PRECONDITION_REQUIRED,
                "provider_account_required",
                "Configure your AcoustID account before using fingerprint lookup.",
                request_id,
            )
            .into_response()
        }
        Err(error) => return storage_failure(error, &request_id).into_response(),
    };
    let Some(api_key) = credentials.get("apiKey") else {
        zeroize_credentials(&mut credentials);
        return ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "provider_account_invalid",
            "Replace the saved AcoustID account before using fingerprint lookup.",
            request_id,
        )
        .into_response();
    };
    let url = match provider_test_url(&state.endpoints.acoustid_api_base, "lookup") {
        Ok(url) => url,
        Err(_) => {
            zeroize_credentials(&mut credentials);
            return ApiError::new(
                StatusCode::SERVICE_UNAVAILABLE,
                "provider_adapter_unavailable",
                "The AcoustID adapter could not be initialized.",
                request_id,
            )
            .into_response();
        }
    };
    let duration = request.duration.to_string();
    let response = state
        .client
        .get(url)
        .query(&[
            ("client", api_key.as_str()),
            ("fingerprint", request.fingerprint.as_str()),
            ("duration", duration.as_str()),
            ("meta", "recordingids+releasegroups"),
        ])
        .send()
        .await;
    zeroize_credentials(&mut credentials);
    let response = match response {
        Ok(response) if response.status().is_success() => response,
        _ => return provider_lookup_failed("AcoustID fingerprint lookup", request_id),
    };
    let payload = match bounded_provider_json::<AcoustidLookupResponse>(response).await {
        Ok(payload) if payload.status == "ok" => payload,
        _ => return provider_lookup_failed("AcoustID fingerprint lookup", request_id),
    };
    let release_group_ids = payload
        .results
        .into_iter()
        .flat_map(|result| result.recordings)
        .flat_map(|recording| recording.releasegroups)
        .map(|group| group.id)
        .filter(|id| valid_mbid(id))
        .collect::<BTreeSet<_>>()
        .into_iter()
        .take(12)
        .collect::<Vec<_>>();
    Json(json!({
        "provider": "acoustid",
        "releaseGroupIds": release_group_ids,
        "requestId": request_id,
    }))
    .into_response()
}

async fn bounded_provider_json<T: DeserializeOwned>(
    mut response: reqwest::Response,
) -> Result<T, String> {
    const MAX_PROVIDER_JSON_BYTES: usize = 2 * 1024 * 1024;
    if response
        .content_length()
        .is_some_and(|length| length > MAX_PROVIDER_JSON_BYTES as u64)
    {
        return Err("provider response exceeded the size limit".to_string());
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| "provider response could not be read safely".to_string())?
    {
        if bytes.len().saturating_add(chunk.len()) > MAX_PROVIDER_JSON_BYTES {
            return Err("provider response exceeded the size limit".to_string());
        }
        bytes.extend_from_slice(&chunk);
    }
    serde_json::from_slice(&bytes).map_err(|_| "provider returned invalid JSON".to_string())
}

async fn bounded_provider_bytes(
    mut response: reqwest::Response,
    maximum_bytes: usize,
) -> Result<Vec<u8>, String> {
    if response
        .content_length()
        .is_some_and(|length| length > maximum_bytes as u64)
    {
        return Err("provider response exceeded the size limit".to_string());
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| "provider response could not be read safely".to_string())?
    {
        if bytes.len().saturating_add(chunk.len()) > maximum_bytes {
            return Err("provider response exceeded the size limit".to_string());
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok(bytes)
}

fn valid_mbid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        })
}

async fn search_opensubtitles(
    State(state): State<ProviderBrokerState>,
    headers: HeaderMap,
    payload: Result<Json<OpenSubtitlesSearchRequest>, JsonRejection>,
) -> Response {
    let request_id = request_id();
    let identity = match authenticated_identity(&headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    let request = match payload {
        Ok(Json(request)) => request,
        Err(_) => return invalid_json(&request_id).into_response(),
    };
    let query = request.query.trim();
    if query.is_empty() || query.len() > 200 || query.contains('\0') {
        return ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "subtitle_query_invalid",
            "Subtitle search requires a query between 1 and 200 characters.",
            request_id,
        )
        .into_response();
    }
    let Some(languages) = normalized_languages(&request.languages) else {
        return ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "subtitle_languages_invalid",
            "Supply one to five comma-separated language codes.",
            request_id,
        )
        .into_response();
    };
    let movie_hash = match (request.movie_hash.as_deref(), request.movie_byte_size) {
        (None, None) => None,
        (Some(value), Some(byte_size))
            if value.len() == 16
                && value.bytes().all(|byte| byte.is_ascii_hexdigit())
                && byte_size >= 128 * 1024 =>
        {
            Some(MovieHash {
                value: value.to_ascii_lowercase(),
                byte_size,
            })
        }
        _ => {
            return ApiError::new(
                StatusCode::UNPROCESSABLE_ENTITY,
                "subtitle_hash_invalid",
                "movieHash and movieByteSize must be a valid local OpenSubtitles hash pair.",
                request_id,
            )
            .into_response()
        }
    };
    let client = match opensubtitles_client_for(&state, &identity, &request_id) {
        Ok(client) => client,
        Err(error) => return error.into_response(),
    };
    if let Some(movie_hash) = movie_hash.as_ref() {
        match client.search_by_hash(movie_hash, &languages).await {
            Ok(results) => {
                let exact = results
                    .into_iter()
                    .filter(|result| result.hash_matched)
                    .collect::<Vec<_>>();
                if !exact.is_empty() {
                    return Json(json!({
                        "provider": "opensubtitles",
                        "matchMethod": "movie-hash",
                        "results": exact,
                        "requestId": request_id,
                    }))
                    .into_response();
                }
            }
            Err(_) => return provider_lookup_failed("OpenSubtitles hash search", request_id),
        }
    }
    match client.search_by_query(query, &languages).await {
        Ok(results) => Json(json!({
            "provider": "opensubtitles",
            "matchMethod": "title-fallback",
            "results": results,
            "requestId": request_id,
        }))
        .into_response(),
        Err(_) => provider_lookup_failed("OpenSubtitles title search", request_id),
    }
}

async fn download_opensubtitles(
    State(state): State<ProviderBrokerState>,
    headers: HeaderMap,
    payload: Result<Json<OpenSubtitlesDownloadRequest>, JsonRejection>,
) -> Response {
    let request_id = request_id();
    let identity = match authenticated_identity(&headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    let request = match payload {
        Ok(Json(request)) if request.file_id > 0 => request,
        Ok(_) => {
            return ApiError::new(
                StatusCode::UNPROCESSABLE_ENTITY,
                "subtitle_file_id_invalid",
                "Supply a positive OpenSubtitles file ID.",
                request_id,
            )
            .into_response()
        }
        Err(_) => return invalid_json(&request_id).into_response(),
    };
    let client = match opensubtitles_client_for(&state, &identity, &request_id) {
        Ok(client) => client,
        Err(error) => return error.into_response(),
    };
    match client.download(request.file_id).await {
        Ok(bytes) => ([(header::CONTENT_TYPE, "application/x-subrip")], bytes).into_response(),
        Err(_) => provider_lookup_failed("OpenSubtitles download", request_id),
    }
}

fn opensubtitles_client_for(
    state: &ProviderBrokerState,
    identity: &Identity,
    request_id: &str,
) -> Result<OpenSubtitlesClient, ApiError> {
    let mut saved = state
        .store
        .load_credentials(identity, "opensubtitles")
        .map_err(|error| storage_failure(error, request_id))?
        .ok_or_else(|| {
            ApiError::new(
                StatusCode::PRECONDITION_REQUIRED,
                "provider_account_required",
                "Configure your OpenSubtitles account before using this lookup.",
                request_id.to_string(),
            )
        })?;
    let credentials = match (
        saved.get("apiKey"),
        saved.get("username"),
        saved.get("password"),
    ) {
        (Some(api_key), Some(username), Some(password)) => OpenSubtitlesCredentials {
            api_key: api_key.clone(),
            username: username.clone(),
            password: password.clone(),
            user_agent: saved
                .get("userAgent")
                .filter(|value| !value.trim().is_empty())
                .cloned()
                .unwrap_or_else(|| "NixHomeServer Media Manager v0.1".to_string()),
        },
        _ => {
            zeroize_credentials(&mut saved);
            return Err(ApiError::new(
                StatusCode::UNPROCESSABLE_ENTITY,
                "provider_account_invalid",
                "Replace the saved OpenSubtitles account before using this lookup.",
                request_id.to_string(),
            ));
        }
    };
    let client = OpenSubtitlesClient::new_with_api_base(
        credentials,
        &state.endpoints.opensubtitles_api_base,
    )
    .map_err(|_| {
        ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "provider_adapter_unavailable",
            "The OpenSubtitles adapter could not be initialized.",
            request_id.to_string(),
        )
    });
    zeroize_credentials(&mut saved);
    client
}

fn normalized_languages(value: &str) -> Option<String> {
    let mut languages = value
        .split(',')
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(|value| value.to_ascii_lowercase())
        .collect::<Vec<_>>();
    if languages.is_empty()
        || languages.len() > 5
        || languages.iter().any(|value| {
            value.len() > 8
                || !value
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        })
    {
        return None;
    }
    languages.sort();
    languages.dedup();
    Some(languages.join(","))
}

fn provider_lookup_failed(operation: &str, request_id: String) -> Response {
    ApiError::new(
        StatusCode::BAD_GATEWAY,
        "provider_lookup_failed",
        format!("{operation} could not be completed. Check the account status and try again."),
        request_id,
    )
    .into_response()
}

fn invalid_json(request_id: &str) -> ApiError {
    ApiError::new(
        StatusCode::BAD_REQUEST,
        "invalid_json",
        "Supply a valid request document.",
        request_id.to_string(),
    )
}

async fn list_provider_accounts(
    State(state): State<ProviderBrokerState>,
    headers: HeaderMap,
) -> Response {
    let request_id = request_id();
    let identity = match authenticated_identity(&headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    let summaries = match state.store.list(&identity) {
        Ok(summaries) => summaries,
        Err(error) => return storage_failure(error, &request_id).into_response(),
    };
    Json(json!({
        "schemaVersion": 1,
        "providers": provider_views(&summaries),
        "recoveryAdvice": "Saved credentials cannot be viewed again. Keep the recovery copy in Vaultwarden, KeePassXC, or another password manager.",
        "requestId": request_id,
    }))
    .into_response()
}

async fn save_provider_account(
    State(state): State<ProviderBrokerState>,
    headers: HeaderMap,
    Path(provider_id): Path<String>,
    payload: Result<Json<SaveProviderAccountRequest>, JsonRejection>,
) -> Response {
    let request_id = request_id();
    let identity = match authenticated_identity(&headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    let mut request = match payload {
        Ok(Json(request)) => request,
        Err(_) => {
            return ApiError::new(
                StatusCode::BAD_REQUEST,
                "invalid_json",
                "Supply a valid provider credential document.",
                request_id,
            )
            .into_response()
        }
    };
    let Some(definition) = provider_definition(&provider_id) else {
        zeroize_credentials(&mut request.credentials);
        return ApiError::new(
            StatusCode::NOT_FOUND,
            "provider_not_found",
            "The requested metadata provider is not in the provider catalog.",
            request_id,
        )
        .into_response();
    };
    if definition.implementation_status != ImplementationStatus::Active {
        zeroize_credentials(&mut request.credentials);
        return ApiError::new(
            StatusCode::CONFLICT,
            "provider_adapter_unavailable",
            "Credentials cannot be saved until this provider's lookup adapter is available.",
            request_id,
        )
        .into_response();
    }
    if definition.credential_fields.is_empty() {
        zeroize_credentials(&mut request.credentials);
        return ApiError::new(
            StatusCode::CONFLICT,
            "provider_account_not_required",
            "This provider does not require a saved account.",
            request_id,
        )
        .into_response();
    }
    if let Err(message) = validate_credentials(definition, &request.credentials) {
        zeroize_credentials(&mut request.credentials);
        return ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "credential_validation_failed",
            message,
            request_id,
        )
        .into_response();
    }
    let result = state.store.save(
        &identity,
        definition.id,
        &request.credentials,
        unix_timestamp(),
    );
    zeroize_credentials(&mut request.credentials);
    if let Err(error) = result {
        return storage_failure(error, &request_id).into_response();
    }
    let summary = match state.store.list(&identity) {
        Ok(summaries) => summaries
            .into_iter()
            .find(|summary| summary.provider_id == definition.id),
        Err(error) => return storage_failure(error, &request_id).into_response(),
    };
    Json(json!({
        "provider": provider_view(definition, summary.as_ref()),
        "requestId": request_id,
    }))
    .into_response()
}

async fn delete_provider_account(
    State(state): State<ProviderBrokerState>,
    headers: HeaderMap,
    Path(provider_id): Path<String>,
) -> Response {
    let request_id = request_id();
    let identity = match authenticated_identity(&headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    if provider_definition(&provider_id).is_none() {
        return ApiError::new(
            StatusCode::NOT_FOUND,
            "provider_not_found",
            "The requested metadata provider is not in the provider catalog.",
            request_id,
        )
        .into_response();
    }
    match state.store.delete(&identity, &provider_id) {
        Ok(_) => StatusCode::NO_CONTENT.into_response(),
        Err(error) => storage_failure(error, &request_id).into_response(),
    }
}

async fn test_provider_account(
    State(state): State<ProviderBrokerState>,
    headers: HeaderMap,
    Path(provider_id): Path<String>,
) -> Response {
    let request_id = request_id();
    let identity = match authenticated_identity(&headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    let Some(definition) = provider_definition(&provider_id) else {
        return ApiError::new(
            StatusCode::NOT_FOUND,
            "provider_not_found",
            "The requested metadata provider is not in the provider catalog.",
            request_id,
        )
        .into_response();
    };
    if definition.credential_fields.is_empty() {
        return ApiError::new(
            StatusCode::CONFLICT,
            "provider_test_not_required",
            "This public provider does not have a saved account to test.",
            request_id,
        )
        .into_response();
    }
    let Some(connection_test) = definition.connection_test.filter(|_| definition.can_test()) else {
        return ApiError::new(
            StatusCode::CONFLICT,
            "provider_test_unavailable",
            "A live connection test will be enabled with this provider's lookup adapter.",
            request_id,
        )
        .into_response();
    };
    let mut credentials = match state.store.load_credentials(&identity, definition.id) {
        Ok(Some(credentials)) => credentials,
        Ok(None) => {
            return ApiError::new(
                StatusCode::NOT_FOUND,
                "provider_account_not_found",
                "No configured provider account exists for this identity.",
                request_id,
            )
            .into_response()
        }
        Err(error) => return storage_failure(error, &request_id).into_response(),
    };
    let outcome = test_live_provider(&state, connection_test, &credentials).await;
    zeroize_credentials(&mut credentials);
    if let Err(error) = state.store.record_test_result(
        &identity,
        definition.id,
        outcome.status,
        outcome.message,
        unix_timestamp(),
    ) {
        return storage_failure(error, &request_id).into_response();
    }
    Json(json!({
        "providerId": definition.id,
        "status": outcome.status,
        "message": outcome.message,
        "requestId": request_id,
    }))
    .into_response()
}

struct ProviderTestOutcome {
    status: &'static str,
    message: &'static str,
}

async fn test_live_provider(
    state: &ProviderBrokerState,
    adapter: ConnectionTestAdapter,
    credentials: &BTreeMap<String, String>,
) -> ProviderTestOutcome {
    let response = match adapter {
        ConnectionTestAdapter::Tmdb => {
            let url = provider_test_url(&state.endpoints.tmdb_api_base, "authentication");
            match (url, credentials.get("apiKey")) {
                (Ok(url), Some(api_key)) => state.client.get(url).bearer_auth(api_key).send().await,
                _ => return invalid_saved_credentials(),
            }
        }
        ConnectionTestAdapter::OpenSubtitles => {
            let url = provider_test_url(&state.endpoints.opensubtitles_api_base, "login");
            match (
                url,
                credentials.get("apiKey"),
                credentials.get("username"),
                credentials.get("password"),
            ) {
                (Ok(url), Some(api_key), Some(username), Some(password)) => {
                    let user_agent = credentials
                        .get("userAgent")
                        .map(String::as_str)
                        .filter(|value| !value.trim().is_empty())
                        .unwrap_or("NixHomeServer Media Manager");
                    state
                        .client
                        .post(url)
                        .header("api-key", api_key)
                        .header(reqwest::header::USER_AGENT, user_agent)
                        .json(&json!({ "username": username, "password": password }))
                        .send()
                        .await
                }
                _ => return invalid_saved_credentials(),
            }
        }
    };
    match response {
        Ok(response) if response.status().is_success() => ProviderTestOutcome {
            status: "ready",
            message: "The provider accepted this account.",
        },
        Ok(response)
            if matches!(
                response.status(),
                reqwest::StatusCode::UNAUTHORIZED | reqwest::StatusCode::FORBIDDEN
            ) =>
        {
            ProviderTestOutcome {
                status: "rejected",
                message: "The provider rejected the saved account.",
            }
        }
        Ok(response) if response.status() == reqwest::StatusCode::TOO_MANY_REQUESTS => {
            ProviderTestOutcome {
                status: "rateLimited",
                message: "The provider rate limit was reached; try again later.",
            }
        }
        Ok(_) | Err(_) => ProviderTestOutcome {
            status: "unavailable",
            message: "The provider could not be reached or did not accept the test request.",
        },
    }
}

fn invalid_saved_credentials() -> ProviderTestOutcome {
    ProviderTestOutcome {
        status: "rejected",
        message: "The saved credential document is incomplete.",
    }
}

fn provider_test_url(base: &str, path: &str) -> Result<reqwest::Url, String> {
    trusted_provider_base(base)?
        .join(path)
        .map_err(|error| error.to_string())
}

fn trusted_provider_base(base: &str) -> Result<reqwest::Url, String> {
    let url = reqwest::Url::parse(base).map_err(|error| error.to_string())?;
    let trusted = url.scheme() == "https"
        || (url.scheme() == "http"
            && url
                .host_str()
                .is_some_and(|host| matches!(host, "localhost" | "127.0.0.1" | "::1")));
    if trusted {
        Ok(url)
    } else {
        Err("provider endpoints must use HTTPS or a loopback test mirror".to_string())
    }
}

fn provider_views(summaries: &[ProviderAccountSummary]) -> Vec<Value> {
    let summaries = summaries
        .iter()
        .map(|summary| (summary.provider_id.as_str(), summary))
        .collect::<BTreeMap<_, _>>();
    PROVIDERS
        .iter()
        .map(|definition| provider_view(definition, summaries.get(definition.id).copied()))
        .collect()
}

fn provider_view(
    definition: &ProviderDefinition,
    summary: Option<&ProviderAccountSummary>,
) -> Value {
    let account = if definition.credential_fields.is_empty() {
        json!({ "state": "notRequired" })
    } else if let Some(summary) = summary {
        json!({
            "state": "configured",
            "configuredAt": summary.configured_at,
            "updatedAt": summary.updated_at,
            "lastTestedAt": summary.last_tested_at,
            "lastTestStatus": summary.last_test_status,
            "lastTestMessage": summary.last_test_message,
        })
    } else {
        json!({ "state": "notConfigured" })
    };
    json!({
        "id": definition.id,
        "name": definition.name,
        "mediaDomains": definition.media_domains,
        "setupKind": definition.setup_kind,
        "implementationStatus": definition.implementation_status,
        "canConfigure": definition.can_configure(),
        "canTest": definition.can_test(),
        "capabilities": definition.capabilities,
        "credentialFields": definition.credential_fields,
        "setupUrl": definition.setup_url,
        "documentationUrl": definition.documentation_url,
        "notes": definition.notes,
        "account": account,
    })
}

fn provider_definition(provider_id: &str) -> Option<&'static ProviderDefinition> {
    PROVIDERS
        .iter()
        .find(|definition| definition.id == provider_id)
}

fn validate_credentials(
    definition: &ProviderDefinition,
    credentials: &BTreeMap<String, String>,
) -> Result<(), String> {
    if credentials.len() > MAX_CREDENTIAL_FIELDS {
        return Err("The credential document contains too many fields.".to_string());
    }
    let allowed = definition
        .credential_fields
        .iter()
        .map(|field| field.id)
        .collect::<BTreeSet<_>>();
    if credentials
        .keys()
        .any(|key| !allowed.contains(key.as_str()))
    {
        return Err("The credential document contains an unexpected field.".to_string());
    }
    for field in definition.credential_fields {
        let value = credentials.get(field.id).map(|value| value.trim());
        if field.is_required && value.is_none_or(str::is_empty) {
            return Err(format!("{} is required.", field.label));
        }
        if value.is_some_and(|value| value.len() > MAX_CREDENTIAL_VALUE_BYTES) {
            return Err(format!("{} is too long.", field.label));
        }
        if value.is_some_and(|value| value.chars().any(char::is_control)) {
            return Err(format!(
                "{} contains unsupported control characters.",
                field.label
            ));
        }
    }
    Ok(())
}

fn zeroize_credentials(credentials: &mut BTreeMap<String, String>) {
    for value in credentials.values_mut() {
        value.zeroize();
    }
}

fn authenticated_identity(headers: &HeaderMap, request_id: &str) -> Result<Identity, ApiError> {
    Identity::try_from_forwarded_headers(headers).map_err(|_| {
        ApiError::new(
            StatusCode::UNAUTHORIZED,
            "identity_required",
            "A valid authenticated identity is required.",
            request_id.to_string(),
        )
    })
}

async fn no_store_responses(request: axum::extract::Request, next: Next) -> Response {
    let mut response = next.run(request).await;
    response.headers_mut().insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("no-store, max-age=0"),
    );
    response
        .headers_mut()
        .insert(header::PRAGMA, HeaderValue::from_static("no-cache"));
    response.headers_mut().insert(
        header::REFERRER_POLICY,
        HeaderValue::from_static("no-referrer"),
    );
    response
}

fn storage_failure(error: ProviderAccountError, request_id: &str) -> ApiError {
    eprintln!(
        "{}",
        json!({
            "level": "error",
            "service": "media-manager-provider-broker",
            "event": "provider_account_storage_failed",
            "requestId": request_id,
            "error": error.to_string(),
        })
    );
    ApiError::new(
        StatusCode::INTERNAL_SERVER_ERROR,
        "internal_error",
        "The provider account request could not be completed.",
        request_id.to_string(),
    )
}

fn request_id() -> String {
    let micros = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_micros();
    let sequence = REQUEST_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    format!("pa{micros:x}-{sequence:x}")
}

fn unix_timestamp() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
        .min(i64::MAX as u64) as i64
}

struct ApiError {
    status: StatusCode,
    code: &'static str,
    message: String,
    request_id: String,
}

impl ApiError {
    fn new(
        status: StatusCode,
        code: &'static str,
        message: impl Into<String>,
        request_id: String,
    ) -> Self {
        Self {
            status,
            code,
            message: message.into(),
            request_id,
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (
            self.status,
            Json(json!({
                "error": {
                    "code": self.code,
                    "message": self.message,
                    "requestId": self.request_id,
                }
            })),
        )
            .into_response()
    }
}
