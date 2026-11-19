//! TMDB television layouts for host system jobs (system socket only).
//!
//! Jellyfin numbers TV episodes from TMDB, so the DVD identifier checks its
//! episode numbering against the season layout returned here. The caller
//! names the person whose saved TMDB account to use (for a DVD, its
//! uploader); without one the answer is `no_account`. Layouts are public TMDB
//! data, so a cached layout serves every account.

use super::{tmdb_lookups, ProviderBrokerState};
use crate::tmdb::{ProviderError, TmdbClient, TmdbTvShow};
use axum::{
    extract::{rejection::JsonRejection, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use homelab_common::{request_id, sha256_hex};
use serde::Deserialize;
use serde_json::{json, Value};

const TV_LAYOUT_CACHE_SCOPE: &str = "system-tmdb-tv-layout";
/// Long-running soaps aside, no series this serves has more seasons.
const MAX_SEASONS: usize = 100;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct TvEpisodesRequest {
    owner: String,
    tmdb_id: Option<u32>,
    tvdb_id: Option<u64>,
    imdb_id: Option<String>,
    name: Option<String>,
    year: Option<u16>,
}

/// How the series is named, strongest identifier first.
#[derive(Debug)]
enum SeriesRef {
    Tmdb(u32),
    Tvdb(u64),
    Imdb(String),
    Name(String, Option<u16>),
}

impl SeriesRef {
    fn label(&self) -> String {
        match self {
            Self::Tmdb(id) => format!("tmdbid-{id}"),
            Self::Tvdb(id) => format!("tvdbid-{id}"),
            Self::Imdb(id) => format!("imdbid-{id}"),
            Self::Name(name, Some(year)) => format!("name:{name} ({year})"),
            Self::Name(name, None) => format!("name:{name}"),
        }
    }
}

/// Usernames as the account store records them.
fn valid_owner(owner: &str) -> bool {
    (1..=64).contains(&owner.len())
        && owner.bytes().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'.' | b'_' | b'-')
        })
}

fn validated(request: TvEpisodesRequest) -> Option<(String, SeriesRef)> {
    if !valid_owner(&request.owner) {
        return None;
    }
    let owner = request.owner.clone();
    series_ref(request).map(|series| (owner, series))
}

fn series_ref(request: TvEpisodesRequest) -> Option<SeriesRef> {
    if let Some(id) = request.tmdb_id {
        return (id > 0).then_some(SeriesRef::Tmdb(id));
    }
    if let Some(id) = request.tvdb_id {
        return (id > 0).then_some(SeriesRef::Tvdb(id));
    }
    if let Some(id) = request.imdb_id {
        let digits = id.strip_prefix("tt")?;
        let valid =
            (5..=10).contains(&digits.len()) && digits.bytes().all(|byte| byte.is_ascii_digit());
        return valid.then_some(SeriesRef::Imdb(id));
    }
    let name = request.name?.trim().to_string();
    let valid = (1..=200).contains(&name.chars().count()) && !name.chars().any(char::is_control);
    let year = request.year.filter(|year| (1900..=2100).contains(year));
    valid.then_some(SeriesRef::Name(name, year))
}

pub(super) async fn tv_episodes(
    State(state): State<ProviderBrokerState>,
    payload: Result<Json<TvEpisodesRequest>, JsonRejection>,
) -> Response {
    let request_id = request_id();
    let Some((owner, series)) = payload.ok().and_then(|Json(request)| validated(request)) else {
        return outcome(
            &request_id,
            None,
            StatusCode::BAD_REQUEST,
            "invalid_request",
            None,
        );
    };
    let no_account = |request_id: &str, series: &SeriesRef| {
        outcome(
            request_id,
            Some(series),
            StatusCode::NOT_FOUND,
            "no_account",
            None,
        )
    };
    let identity = match state.store.account_identity_for_username("tmdb", &owner) {
        Ok(Some(identity)) => identity,
        Ok(None) => return no_account(&request_id, &series),
        Err(_) => {
            return outcome(
                &request_id,
                Some(&series),
                StatusCode::INTERNAL_SERVER_ERROR,
                "storage_error",
                None,
            )
        }
    };
    let client = match tmdb_lookups::client_for(&state, &identity, &request_id) {
        Ok(client) => client,
        Err(error)
            if matches!(
                error.status(),
                StatusCode::PRECONDITION_REQUIRED | StatusCode::UNPROCESSABLE_ENTITY
            ) =>
        {
            return no_account(&request_id, &series)
        }
        Err(_) => {
            return outcome(
                &request_id,
                Some(&series),
                StatusCode::BAD_GATEWAY,
                "provider_error",
                None,
            )
        }
    };
    let tmdb_id = match resolve(&state, &client, &series).await {
        Ok(Resolved::Found(id)) => id,
        Ok(Resolved::NotFound) => {
            return outcome(
                &request_id,
                Some(&series),
                StatusCode::NOT_FOUND,
                "not_found",
                None,
            )
        }
        Ok(Resolved::Ambiguous(candidates)) => {
            return outcome(
                &request_id,
                Some(&series),
                StatusCode::CONFLICT,
                "ambiguous",
                Some(candidates),
            )
        }
        Err(error) => return provider_failure(&request_id, &series, &error),
    };
    let cache_key = sha256_hex(format!("{TV_LAYOUT_CACHE_SCOPE}:v1\0{tmdb_id}").as_bytes());
    if let Some(cached) = state.lookup_cache.get(&cache_key).await
        && cached["seasons"].is_array()
    {
        log(&request_id, &series, "cache_hit");
        return Json(cached).into_response();
    }
    let body = match layout(&client, tmdb_id).await {
        Ok(body) => body,
        Err(error) => return provider_failure(&request_id, &series, &error),
    };
    state
        .lookup_cache
        .put(cache_key, TV_LAYOUT_CACHE_SCOPE, "system", body.clone())
        .await;
    log(&request_id, &series, "fetched");
    Json(body).into_response()
}

enum Resolved {
    Found(u32),
    NotFound,
    Ambiguous(Value),
}

async fn resolve(
    state: &ProviderBrokerState,
    client: &TmdbClient,
    series: &SeriesRef,
) -> Result<Resolved, ProviderError> {
    let (external_id, source) = match series {
        SeriesRef::Tmdb(id) => return Ok(Resolved::Found(*id)),
        SeriesRef::Tvdb(id) => (id.to_string(), "tvdb_id"),
        SeriesRef::Imdb(id) => (id.clone(), "imdb_id"),
        SeriesRef::Name(name, year) => {
            let shows = client.search_tv_shows(name, *year).await?;
            return Ok(choose_by_name(name, *year, shows));
        }
    };
    // External ids never move between TMDB series, so the answer is cached.
    let cache_key =
        sha256_hex(format!("{TV_LAYOUT_CACHE_SCOPE}:find:v1\0{source}\0{external_id}").as_bytes());
    if let Some(cached) = state.lookup_cache.get(&cache_key).await
        && let Some(id) = cached["tmdbId"]
            .as_u64()
            .and_then(|id| u32::try_from(id).ok())
    {
        return Ok(Resolved::Found(id));
    }
    match client.find_tv_show(&external_id, source).await {
        Ok(Some(show)) => {
            state
                .lookup_cache
                .put(
                    cache_key,
                    TV_LAYOUT_CACHE_SCOPE,
                    "system",
                    json!({ "tmdbId": show.id }),
                )
                .await;
            Ok(Resolved::Found(show.id))
        }
        Ok(None) => Ok(Resolved::NotFound),
        Err(error) if error.is_not_found() => Ok(Resolved::NotFound),
        Err(error) => Err(error),
    }
}

fn comparable(name: &str) -> String {
    name.chars()
        .filter(|character| character.is_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect()
}

fn first_year(date: Option<&str>) -> Option<u16> {
    date.and_then(|date| date.get(0..4))
        .and_then(|year| year.parse().ok())
}

/// The one search result whose name (and year, when given) is exact; a name
/// alone never chooses between two series that share it.
fn choose_by_name(name: &str, year: Option<u16>, shows: Vec<TmdbTvShow>) -> Resolved {
    let wanted = comparable(name);
    let matches: Vec<TmdbTvShow> = shows
        .into_iter()
        .filter(|show| {
            comparable(&show.name) == wanted || comparable(&show.original_name) == wanted
        })
        .filter(|show| {
            year.is_none_or(|year| first_year(show.first_air_date.as_deref()) == Some(year))
        })
        .collect();
    match matches.as_slice() {
        [] => Resolved::NotFound,
        [show] => Resolved::Found(show.id),
        _ => Resolved::Ambiguous(Value::Array(
            matches
                .iter()
                .map(|show| {
                    json!({
                        "tmdbId": show.id,
                        "name": show.name,
                        "year": first_year(show.first_air_date.as_deref()),
                    })
                })
                .collect(),
        )),
    }
}

/// Every season TMDB lists, specials (season 0) included, in order.
async fn layout(client: &TmdbClient, tmdb_id: u32) -> Result<Value, ProviderError> {
    let details = client.get_tv_show_details(tmdb_id).await?;
    let mut numbers: Vec<u32> = details
        .seasons
        .iter()
        .map(|season| season.season_number)
        .collect();
    numbers.sort_unstable();
    numbers.dedup();
    numbers.truncate(MAX_SEASONS);
    let mut seasons = Vec::with_capacity(numbers.len());
    for number in numbers {
        let season = client.get_tv_season_details(tmdb_id, number).await?;
        let mut episodes: Vec<Value> = season
            .episodes
            .iter()
            .filter(|episode| episode.episode_number > 0)
            .map(|episode| {
                json!({
                    "episode": episode.episode_number,
                    "name": episode.name.trim(),
                    "airdate": episode.air_date.as_deref().filter(|date| !date.is_empty()),
                    "runtime": episode.runtime.filter(|minutes| *minutes > 0),
                })
            })
            .collect();
        episodes.sort_by_key(|episode| episode["episode"].as_u64());
        seasons.push(json!({ "season": number, "episodes": episodes }));
    }
    let external = details.external_ids.as_ref();
    Ok(json!({
        "series": {
            "tmdbId": details.id,
            "name": details.name,
            "year": first_year(details.first_air_date.as_deref()),
            "tvdbId": external.and_then(|ids| ids.tvdb_id),
            "imdbId": external.and_then(|ids| ids.imdb_id.clone()).filter(|id| id.starts_with("tt")),
        },
        "seasons": seasons,
    }))
}

fn provider_failure(request_id: &str, series: &SeriesRef, error: &ProviderError) -> Response {
    if error.is_not_found() {
        return outcome(
            request_id,
            Some(series),
            StatusCode::NOT_FOUND,
            "not_found",
            None,
        );
    }
    outcome(
        request_id,
        Some(series),
        StatusCode::BAD_GATEWAY,
        "provider_error",
        None,
    )
}

fn outcome(
    request_id: &str,
    series: Option<&SeriesRef>,
    status: StatusCode,
    error: &'static str,
    candidates: Option<Value>,
) -> Response {
    match series {
        Some(series) => log(request_id, series, error),
        None => log_fields(request_id, None, error),
    }
    let mut body = json!({ "error": error });
    if let Some(candidates) = candidates {
        body["candidates"] = candidates;
    }
    (status, Json(body)).into_response()
}

fn log(request_id: &str, series: &SeriesRef, outcome: &str) {
    log_fields(request_id, Some(series.label()), outcome);
}

fn log_fields(request_id: &str, series: Option<String>, outcome: &str) {
    eprintln!(
        "{}",
        json!({
            "level": "info",
            "service": "media-manager-provider-broker",
            "event": "system_tmdb_tv_episodes",
            "requestId": request_id,
            "series": series,
            "outcome": outcome,
        })
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    fn show(id: u32, name: &str, first_air_date: &str) -> TmdbTvShow {
        TmdbTvShow {
            id,
            name: name.into(),
            original_name: name.into(),
            first_air_date: Some(first_air_date.into()),
            ..TmdbTvShow::default()
        }
    }

    #[test]
    fn a_shared_name_needs_the_year_to_choose() {
        let shows = || {
            vec![
                show(799, "Sherlock Holmes", "1984-04-24"),
                show(1000, "Sherlock Holmes", "1954-10-18"),
                show(19885, "Sherlock", "2010-07-25"),
            ]
        };
        assert!(matches!(
            choose_by_name("Sherlock Holmes", None, shows()),
            Resolved::Ambiguous(_)
        ));
        assert!(matches!(
            choose_by_name("Sherlock Holmes", Some(1984), shows()),
            Resolved::Found(799)
        ));
        assert!(matches!(
            choose_by_name("Sherlock Holmes", Some(1999), shows()),
            Resolved::NotFound
        ));
    }
}
