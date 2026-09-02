use crate::{
    config::Identity,
    provider_accounts::{ProviderAccountError, ProviderAccountStore, ProviderAccountSummary},
};
use axum::{
    body::Body,
    extract::{DefaultBodyLimit, Path, State},
    http::{header, HeaderMap, HeaderValue, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::get,
    Json, Router,
};
use serde::{Deserialize, Serialize};
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

static REQUEST_SEQUENCE: AtomicU64 = AtomicU64::new(1);
const MAX_CREDENTIAL_FIELDS: usize = 8;
const MAX_CREDENTIAL_VALUE_BYTES: usize = 8192;

#[derive(Clone)]
pub struct ProviderBrokerState {
    pub store: Arc<ProviderAccountStore>,
}

#[derive(Clone, Copy, Serialize)]
#[serde(rename_all = "camelCase")]
enum SetupKind {
    Public,
    ApiKey,
    Account,
}

#[derive(Clone, Copy, Serialize)]
#[serde(rename_all = "camelCase")]
enum ImplementationStatus {
    Active,
    Planned,
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
    capabilities: &'static [&'static str],
    credential_fields: &'static [CredentialFieldDefinition],
    setup_url: &'static str,
    documentation_url: &'static str,
    notes: &'static str,
}

const API_KEY_FIELD: [CredentialFieldDefinition; 1] = [CredentialFieldDefinition {
    id: "apiKey",
    label: "API key",
    input_type: "password",
    is_required: true,
    help: "Paste the key from the provider's developer or account settings.",
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
        input_type: "password",
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
        input_type: "password",
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
        capabilities: &["search", "details", "people", "images", "external-ids"],
        credential_fields: &API_KEY_FIELD,
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
        capabilities: &["search", "release-groups", "recordings", "stable-ids"],
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
        implementation_status: ImplementationStatus::Planned,
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
        implementation_status: ImplementationStatus::Planned,
        capabilities: &["search", "isbn", "editions", "covers"],
        credential_fields: &[],
        setup_url: "https://openlibrary.org/",
        documentation_url: "https://openlibrary.org/developers/api",
        notes: "Public bibliographic records, editions and cover images.",
    },
    ProviderDefinition {
        id: "wikidata",
        name: "Wikidata",
        media_domains: &["movies", "television", "music", "books", "people"],
        setup_kind: SetupKind::Public,
        implementation_status: ImplementationStatus::Planned,
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
        implementation_status: ImplementationStatus::Planned,
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

pub fn provider_account_router(state: ProviderBrokerState) -> Router {
    Router::new()
        .route(
            "/api/v1/provider-accounts",
            get(list_provider_accounts),
        )
        .route(
            "/api/v1/provider-accounts/{provider_id}",
            axum::routing::put(save_provider_account).delete(delete_provider_account),
        )
        .layer(DefaultBodyLimit::max(64 * 1024))
        .layer(middleware::from_fn(no_store_responses))
        .with_state(state)
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
    Json(mut request): Json<SaveProviderAccountRequest>,
) -> Response {
    let request_id = request_id();
    let identity = match authenticated_identity(&headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
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
    let result = state
        .store
        .save(&identity, definition.id, &request.credentials, unix_timestamp());
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
    if credentials.keys().any(|key| !allowed.contains(key.as_str())) {
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
            return Err(format!("{} contains unsupported control characters.", field.label));
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

#[allow(dead_code)]
fn _body_type_boundary(_: Body) {}
