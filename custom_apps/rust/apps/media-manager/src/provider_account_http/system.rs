//! Routes for host system jobs, served only on the broker's opt-in Unix socket.
//!
//! The socket's directory group is the authorization boundary: forwarded
//! identity headers are never read here. A job names the user whose saved
//! provider account it acts for (for example, the person who uploaded a DVD),
//! and the broker uses that user's stored identity. Responses never include
//! credentials.

use super::{no_store_responses, opensubtitles_client_for, ProviderBrokerState};
use crate::subtitles::{ProviderError, SubtitleMatch};
use axum::{
    extract::{rejection::JsonRejection, DefaultBodyLimit, State},
    http::StatusCode,
    middleware,
    response::{IntoResponse, Response},
    routing::post,
    Json, Router,
};
use homelab_common::{request_id, sha256_hex};
use serde::Deserialize;
use serde_json::{json, Value};

/// Dialogue for content matching; a full episode is usually 20-60 KB.
const MAX_EPISODE_TEXT_BYTES: usize = 200 * 1024;
const EPISODE_TEXT_CACHE_SCOPE: &str = "system-opensubtitles-episode-text";

pub fn provider_system_router(state: ProviderBrokerState) -> Router {
    let router = Router::new()
        .route(
            "/system/v1/opensubtitles/episode-text",
            post(opensubtitles_episode_text),
        )
        .route(
            "/system/v1/tmdb/tv-episodes",
            post(super::system_tmdb::tv_episodes),
        )
        .route(
            "/system/v1/audible/search",
            post(super::system_audible::search),
        )
        .route(
            "/system/v1/audible/cover",
            post(super::system_audible::cover),
        )
        .route(
            "/system/v1/acoustid/release-groups",
            post(super::system_music::acoustid_release_groups),
        )
        .route(
            "/system/v1/musicbrainz/release-group",
            post(super::system_music::musicbrainz_release_group),
        )
        // A Chromaprint fingerprint of a long track runs to several kilobytes.
        .layer(DefaultBodyLimit::max(24 * 1024))
        .layer(middleware::from_fn(no_store_responses))
        .with_state(state);
    homelab_common::work::isolate_handlers(router, 4)
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct EpisodeTextRequest {
    owner: String,
    parent_imdb_id: String,
    season: u16,
    episode: u16,
    language: String,
    /// Answer only from the cache; never contact OpenSubtitles. The caller
    /// uses this once its own download budget is spent.
    #[serde(default)]
    cache_only: bool,
}

struct EpisodeQuery {
    owner: String,
    imdb_id: String,
    imdb_number: u64,
    season: u16,
    episode: u16,
    language: String,
    cache_only: bool,
}

fn validated(request: EpisodeTextRequest) -> Option<EpisodeQuery> {
    let owner_valid = (1..=64).contains(&request.owner.len())
        && request.owner.bytes().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'.' | b'_' | b'-')
        });
    let digits = request.parent_imdb_id.strip_prefix("tt")?;
    let imdb_valid =
        (5..=10).contains(&digits.len()) && digits.bytes().all(|byte| byte.is_ascii_digit());
    let language_valid = request.language.len() == 2
        && request
            .language
            .bytes()
            .all(|byte| byte.is_ascii_lowercase());
    if !owner_valid
        || !imdb_valid
        || !language_valid
        || request.season > 999
        || request.episode > 999
    {
        return None;
    }
    Some(EpisodeQuery {
        imdb_number: digits.parse().ok()?,
        imdb_id: request.parent_imdb_id,
        owner: request.owner,
        season: request.season,
        episode: request.episode,
        language: request.language,
        cache_only: request.cache_only,
    })
}

async fn opensubtitles_episode_text(
    State(state): State<ProviderBrokerState>,
    payload: Result<Json<EpisodeTextRequest>, JsonRejection>,
) -> Response {
    let request_id = request_id();
    let Some(query) = payload.ok().and_then(|Json(request)| validated(request)) else {
        return outcome(
            &request_id,
            None,
            StatusCode::BAD_REQUEST,
            "invalid_request",
        );
    };
    let identity = match state
        .store
        .account_identity_for_username("opensubtitles", &query.owner)
    {
        Ok(Some(identity)) => identity,
        Ok(None) => {
            return outcome(
                &request_id,
                Some(&query),
                StatusCode::NOT_FOUND,
                "no_account",
            )
        }
        Err(_) => {
            return outcome(
                &request_id,
                Some(&query),
                StatusCode::INTERNAL_SERVER_ERROR,
                "storage_error",
            )
        }
    };
    // Downloads spend the owner's daily quota, so one fetched episode serves
    // every later identification of the same series, season and episode.
    let cache_key = sha256_hex(
        format!(
            "{EPISODE_TEXT_CACHE_SCOPE}:v1\0{}\0{}\0{}\0{}",
            query.imdb_id, query.season, query.episode, query.language
        )
        .as_bytes(),
    );
    if let Some(mut cached) = state.lookup_cache.get(&cache_key).await
        && cached["text"].is_string()
    {
        log(&request_id, &query, "cache_hit");
        // Tell the caller this spent no download, so its budget is kept.
        cached["cached"] = json!(true);
        return Json(cached).into_response();
    }
    if query.cache_only {
        return outcome(
            &request_id,
            Some(&query),
            StatusCode::NOT_FOUND,
            "not_cached",
        );
    }
    let client = match opensubtitles_client_for(&state, &identity, &request_id) {
        Ok(client) => client,
        Err(error) if error.status() == StatusCode::UNPROCESSABLE_ENTITY => {
            return outcome(
                &request_id,
                Some(&query),
                StatusCode::NOT_FOUND,
                "no_account",
            )
        }
        Err(_) => {
            return outcome(
                &request_id,
                Some(&query),
                StatusCode::BAD_GATEWAY,
                "provider_error",
            )
        }
    };
    let results = match client
        .search_by_episode(
            query.imdb_number,
            query.season,
            query.episode,
            &query.language,
        )
        .await
    {
        Ok(results) => results,
        Err(error) => return provider_failure(&request_id, &query, &error),
    };
    let Some(best) = best_episode_subtitle(results, &query.language) else {
        return outcome(
            &request_id,
            Some(&query),
            StatusCode::NOT_FOUND,
            "not_found",
        );
    };
    let bytes = match client.download(best.file_id).await {
        Ok(bytes) => bytes,
        Err(error) => return provider_failure(&request_id, &query, &error),
    };
    let text = plain_dialogue(&String::from_utf8_lossy(&bytes));
    if text.is_empty() {
        return outcome(
            &request_id,
            Some(&query),
            StatusCode::NOT_FOUND,
            "not_found",
        );
    }
    let body = json!({
        "text": text,
        "release": best.release,
        "fileId": best.file_id,
    });
    state
        .lookup_cache
        .put(cache_key, EPISODE_TEXT_CACHE_SCOPE, "system", body.clone())
        .await;
    log(&request_id, &query, "downloaded");
    let mut body = body;
    body["cached"] = json!(false);
    Json(body).into_response()
}

/// The most-downloaded human subtitle in the requested language, preferring
/// plain dialogue over hearing-impaired captions.
fn best_episode_subtitle(results: Vec<SubtitleMatch>, language: &str) -> Option<SubtitleMatch> {
    results
        .into_iter()
        .filter(|result| {
            !result.ai_translated
                && !result.machine_translated
                && result
                    .language
                    .split(['-', '_'])
                    .next()
                    .is_some_and(|code| code.eq_ignore_ascii_case(language))
        })
        .max_by_key(|result| (!result.hearing_impaired, result.download_count))
}

/// SRT reduced to its spoken lines: no cue numbers, timings, markup or
/// bracketed sound descriptions, one cue per line, capped in size.
fn plain_dialogue(srt: &str) -> String {
    let mut text = String::new();
    let mut cue = String::new();
    let flush = |cue: &mut String, text: &mut String| {
        let line = cue.split_whitespace().collect::<Vec<_>>().join(" ");
        if !line.is_empty() {
            text.push_str(&line);
            text.push('\n');
        }
        cue.clear();
    };
    for raw in srt.trim_start_matches('\u{feff}').lines() {
        let line = raw.trim();
        if line.is_empty() {
            flush(&mut cue, &mut text);
        } else if line.contains("-->") || line.bytes().all(|byte| byte.is_ascii_digit()) {
            continue;
        } else {
            cue.push(' ');
            cue.push_str(&strip_markup(line));
        }
        if text.len() >= MAX_EPISODE_TEXT_BYTES {
            break;
        }
    }
    flush(&mut cue, &mut text);
    if text.len() > MAX_EPISODE_TEXT_BYTES {
        let mut end = MAX_EPISODE_TEXT_BYTES;
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        text.truncate(end);
    }
    text.trim_end().to_owned()
}

fn strip_markup(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut closing = None;
    for character in line.chars() {
        match (closing, character) {
            (Some(end), _) if character == end => closing = None,
            (Some(_), _) => {}
            (None, '<') => closing = Some('>'),
            (None, '{') => closing = Some('}'),
            (None, '[') => closing = Some(']'),
            (None, _) => out.push(character),
        }
    }
    // A leading dash marks a change of speaker, not dialogue.
    out.trim().trim_start_matches('-').trim().to_owned()
}

fn provider_failure(request_id: &str, query: &EpisodeQuery, error: &ProviderError) -> Response {
    if error.is_quota() {
        outcome(
            request_id,
            Some(query),
            StatusCode::TOO_MANY_REQUESTS,
            "quota",
        )
    } else {
        outcome(
            request_id,
            Some(query),
            StatusCode::BAD_GATEWAY,
            "provider_error",
        )
    }
}

fn outcome(
    request_id: &str,
    query: Option<&EpisodeQuery>,
    status: StatusCode,
    error: &'static str,
) -> Response {
    match query {
        Some(query) => log(request_id, query, error),
        None => eprintln!(
            "{}",
            json!({
                "level": "info",
                "service": "media-manager-provider-broker",
                "event": "system_episode_text",
                "requestId": request_id,
                "outcome": error,
            })
        ),
    }
    (status, Json(json!({ "error": error }))).into_response()
}

fn log(request_id: &str, query: &EpisodeQuery, outcome: &str) {
    let fields: Value = json!({
        "level": "info",
        "service": "media-manager-provider-broker",
        "event": "system_episode_text",
        "requestId": request_id,
        "owner": query.owner,
        "parentImdbId": query.imdb_id,
        "season": query.season,
        "episode": query.episode,
        "language": query.language,
        "outcome": outcome,
    });
    eprintln!("{fields}");
}
