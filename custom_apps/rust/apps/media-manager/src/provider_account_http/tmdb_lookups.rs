use super::*;
use crate::tmdb::{TmdbClient, TmdbClientConfig};

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct TmdbSearchRequest {
    query: String,
    year: Option<u16>,
    media_type: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct TmdbDetailsRequest {
    tmdb_id: u32,
    media_type: String,
    season_number: Option<u32>,
    episode_number: Option<u32>,
}

pub(super) async fn search(
    State(state): State<ProviderBrokerState>,
    headers: HeaderMap,
    payload: Result<Json<TmdbSearchRequest>, JsonRejection>,
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
    if query.is_empty() || query.len() > 500 || query.contains('\0') {
        return ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "tmdb_query_invalid",
            "TMDB search requires a query between 1 and 500 characters.",
            request_id,
        )
        .into_response();
    }
    let media_type = request.media_type.as_deref().unwrap_or("auto");
    if !matches!(media_type, "movie" | "tv" | "auto") {
        return ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "tmdb_media_type_invalid",
            "mediaType must be movie, tv, or auto.",
            request_id,
        )
        .into_response();
    }
    let year = request.year.filter(|year| (1801..=2100).contains(year));
    let client = match client_for(&state, &identity, &request_id) {
        Ok(client) => client,
        Err(error) => return error.into_response(),
    };
    let mut results = Vec::new();
    if matches!(media_type, "movie" | "auto") {
        match client.search_movies(query, year).await {
            Ok(movies) => results.extend(movies.into_iter().map(|movie| {
                let release_year = movie
                    .release_date
                    .as_deref()
                    .and_then(|date| date.get(0..4))
                    .and_then(|value| value.parse::<u16>().ok());
                json!({
                    "mediaType": "movie",
                    "title": movie.title,
                    "year": release_year,
                    "overview": movie.overview,
                    "posterPath": movie.poster_path,
                    "backdropPath": movie.backdrop_path,
                    "voteAverage": movie.vote_average,
                    "voteCount": movie.vote_count,
                    "genres": movie.genre_ids,
                    "tmdbId": movie.id,
                })
            })),
            Err(_) => return provider_lookup_failed("TMDB movie search", request_id),
        }
    }
    if matches!(media_type, "tv" | "auto") {
        match client.search_tv_shows(query, year).await {
            Ok(shows) => results.extend(shows.into_iter().map(|show| {
                let first_air_year = show
                    .first_air_date
                    .as_deref()
                    .and_then(|date| date.get(0..4))
                    .and_then(|value| value.parse::<u16>().ok());
                json!({
                    "mediaType": "tv",
                    "title": show.name,
                    "year": first_air_year,
                    "overview": show.overview,
                    "posterPath": show.poster_path,
                    "backdropPath": show.backdrop_path,
                    "voteAverage": show.vote_average,
                    "voteCount": show.vote_count,
                    "genres": show.genre_ids,
                    "originCountry": show.origin_country,
                    "tmdbId": show.id,
                })
            })),
            Err(_) => return provider_lookup_failed("TMDB television search", request_id),
        }
    }
    results.sort_by(|left, right| {
        let left_votes = left.get("voteCount").and_then(Value::as_u64).unwrap_or(0);
        let right_votes = right.get("voteCount").and_then(Value::as_u64).unwrap_or(0);
        right_votes.cmp(&left_votes)
    });
    Json(json!({
        "provider": "tmdb",
        "results": results,
        "query": query,
        "year": year,
        "mediaType": media_type,
        "requestId": request_id,
    }))
    .into_response()
}

pub(super) async fn details(
    State(state): State<ProviderBrokerState>,
    headers: HeaderMap,
    payload: Result<Json<TmdbDetailsRequest>, JsonRejection>,
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
    let valid_scope = match request.media_type.as_str() {
        "movie" | "tv" => request.season_number.is_none() && request.episode_number.is_none(),
        "season" => {
            request.season_number.is_some_and(|number| number <= 10_000)
                && request.episode_number.is_none()
        }
        "episode" => {
            request.season_number.is_some_and(|number| number <= 10_000)
                && request
                    .episode_number
                    .is_some_and(|number| (1..=100_000).contains(&number))
        }
        _ => false,
    };
    if request.tmdb_id == 0 || !valid_scope {
        return ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "tmdb_details_invalid",
            "Supply a positive tmdbId and a valid movie, TV, season, or episode scope.",
            request_id,
        )
        .into_response();
    }
    let client = match client_for(&state, &identity, &request_id) {
        Ok(client) => client,
        Err(error) => return error.into_response(),
    };
    let details = match request.media_type.as_str() {
        "movie" => match client.get_movie_details(request.tmdb_id).await {
            Ok(details) => json!({
                "mediaType": "movie",
                "tmdbId": details.id,
                "title": details.title,
                "originalTitle": details.original_title,
                "overview": details.overview,
                "releaseDate": details.release_date,
                "year": details.release_date.as_deref().and_then(|date| date.get(0..4)).and_then(|value| value.parse::<u16>().ok()),
                "runtimeMinutes": details.runtime,
                "voteAverage": details.vote_average,
                "voteCount": details.vote_count,
                "posterPath": details.poster_path,
                "backdropPath": details.backdrop_path,
                "genres": details.genres.iter().map(|genre| genre.name.clone()).collect::<Vec<_>>(),
                "productionCompanies": details.production_companies.iter().map(|company| company.name.clone()).collect::<Vec<_>>(),
                "productionCountries": details.production_countries.iter().map(|country| country.name.clone()).collect::<Vec<_>>(),
                "spokenLanguages": details.spoken_languages.iter().map(|language| language.english_name.clone()).collect::<Vec<_>>(),
                "status": details.status,
                "tagline": details.tagline,
                "cast": details.credits.as_ref().map(|credits| credits.cast.iter().map(|member| json!({ "id": member.id, "name": member.name, "character": member.character })).collect::<Vec<_>>()).unwrap_or_default(),
                "crew": details.credits.as_ref().map(|credits| credits.crew.iter().map(|member| json!({ "id": member.id, "name": member.name, "job": member.job, "department": member.department })).collect::<Vec<_>>()).unwrap_or_default(),
                "keywords": details.keywords.as_ref().map(|keywords| keywords.keywords.iter().map(|keyword| keyword.name.clone()).collect::<Vec<_>>()).unwrap_or_default(),
                "externalIds": details.external_ids.as_ref().map(|ids| json!({ "imdbId": ids.imdb_id, "wikidataId": ids.wikidata_id })).unwrap_or_default(),
            }),
            Err(_) => return provider_lookup_failed("TMDB movie details", request_id),
        },
        "tv" => match client.get_tv_show_details(request.tmdb_id).await {
            Ok(details) => json!({
                "mediaType": "tv",
                "tmdbId": details.id,
                "title": details.name,
                "originalTitle": details.original_name,
                "overview": details.overview,
                "firstAirDate": details.first_air_date,
                "lastAirDate": details.last_air_date,
                "year": details.first_air_date.as_deref().and_then(|date| date.get(0..4)).and_then(|value| value.parse::<u16>().ok()),
                "numberOfSeasons": details.number_of_seasons,
                "numberOfEpisodes": details.number_of_episodes,
                "voteAverage": details.vote_average,
                "voteCount": details.vote_count,
                "posterPath": details.poster_path,
                "backdropPath": details.backdrop_path,
                "genres": details.genres.iter().map(|genre| genre.name.clone()).collect::<Vec<_>>(),
                "productionCompanies": details.production_companies.iter().map(|company| company.name.clone()).collect::<Vec<_>>(),
                "productionCountries": details.production_countries.iter().map(|country| country.name.clone()).collect::<Vec<_>>(),
                "spokenLanguages": details.spoken_languages.iter().map(|language| language.english_name.clone()).collect::<Vec<_>>(),
                "status": details.status,
                "type": details.show_type,
                "inProduction": details.in_production,
                "episodeRunTime": details.episode_run_time,
                "cast": details.credits.as_ref().map(|credits| credits.cast.iter().map(|member| json!({ "id": member.id, "name": member.name, "character": member.character })).collect::<Vec<_>>()).unwrap_or_default(),
                "crew": details.credits.as_ref().map(|credits| credits.crew.iter().map(|member| json!({ "id": member.id, "name": member.name, "job": member.job, "department": member.department })).collect::<Vec<_>>()).unwrap_or_default(),
                "keywords": details.keywords.as_ref().map(|keywords| keywords.keywords.iter().map(|keyword| keyword.name.clone()).collect::<Vec<_>>()).unwrap_or_default(),
                "externalIds": details.external_ids.as_ref().map(|ids| json!({ "imdbId": ids.imdb_id, "wikidataId": ids.wikidata_id })).unwrap_or_default(),
            }),
            Err(_) => return provider_lookup_failed("TMDB television details", request_id),
        },
        "season" => match client
            .get_tv_season_details(request.tmdb_id, request.season_number.unwrap_or_default())
            .await
        {
            Ok(details) if Some(details.season_number) == request.season_number => json!({
                "mediaType": "season",
                "seriesTmdbId": request.tmdb_id,
                "tmdbId": details.id,
                "title": details.name,
                "overview": details.overview,
                "airDate": details.air_date,
                "year": details.air_date.as_deref().and_then(|date| date.get(0..4)).and_then(|value| value.parse::<u16>().ok()),
                "season": details.season_number,
                "posterPath": details.poster_path,
                "voteAverage": details.vote_average,
                "episodeCount": details.episodes.len(),
                "episodes": details.episodes.iter().map(|episode| json!({
                    "tmdbId": episode.id,
                    "title": episode.name,
                    "airDate": episode.air_date,
                    "season": episode.season_number,
                    "episode": episode.episode_number,
                    "stillPath": episode.still_path,
                })).collect::<Vec<_>>(),
                "externalIds": details.external_ids.as_ref().map(|ids| json!({ "imdbId": ids.imdb_id, "wikidataId": ids.wikidata_id })).unwrap_or_default(),
            }),
            Ok(_) | Err(_) => return provider_lookup_failed("TMDB season details", request_id),
        },
        "episode" => match client
            .get_tv_episode_details(
                request.tmdb_id,
                request.season_number.unwrap_or_default(),
                request.episode_number.unwrap_or_default(),
            )
            .await
        {
            Ok(details)
                if Some(details.season_number) == request.season_number
                    && Some(details.episode_number) == request.episode_number =>
            {
                json!({
                    "mediaType": "episode",
                    "seriesTmdbId": request.tmdb_id,
                    "tmdbId": details.id,
                    "title": details.name,
                    "episodeTitle": details.name,
                    "overview": details.overview,
                    "airDate": details.air_date,
                    "year": details.air_date.as_deref().and_then(|date| date.get(0..4)).and_then(|value| value.parse::<u16>().ok()),
                    "season": details.season_number,
                    "episode": details.episode_number,
                    "runtimeMinutes": details.runtime,
                    "voteAverage": details.vote_average,
                    "voteCount": details.vote_count,
                    "stillPath": details.still_path,
                    "cast": details.guest_stars.iter().map(|member| json!({ "id": member.id, "name": member.name, "character": member.character })).collect::<Vec<_>>(),
                    "crew": details.crew.iter().map(|member| json!({ "id": member.id, "name": member.name, "job": member.job, "department": member.department })).collect::<Vec<_>>(),
                    "externalIds": details.external_ids.as_ref().map(|ids| json!({ "imdbId": ids.imdb_id, "wikidataId": ids.wikidata_id })).unwrap_or_default(),
                })
            }
            Ok(_) | Err(_) => return provider_lookup_failed("TMDB episode details", request_id),
        },
        _ => unreachable!(),
    };
    Json(json!({
        "provider": "tmdb",
        "details": details,
        "requestId": request_id,
    }))
    .into_response()
}

pub(super) fn client_for(
    state: &ProviderBrokerState,
    identity: &Identity,
    request_id: &str,
) -> Result<TmdbClient, ApiError> {
    let mut credentials = state
        .store
        .load_credentials(identity, "tmdb")
        .map_err(|error| storage_failure(error, request_id))?
        .ok_or_else(|| {
            ApiError::new(
                StatusCode::PRECONDITION_REQUIRED,
                "provider_account_required",
                "Configure your TMDB account before using this lookup.",
                request_id.to_string(),
            )
        })?;
    let api_key = credentials.get("apiKey").cloned().ok_or_else(|| {
        ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "provider_account_invalid",
            "Replace the saved TMDB account before using this lookup.",
            request_id.to_string(),
        )
    })?;
    let client = TmdbClient::new(TmdbClientConfig {
        api_key: Some(api_key),
        tmdb_api_base: state.endpoints.tmdb_api_base.clone(),
        request_gap: std::time::Duration::from_millis(250),
        user_agent: "NixHomeServer Media Manager/0.1.0".to_string(),
    })
    .map_err(|_| {
        ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "provider_adapter_unavailable",
            "The TMDB adapter could not be initialized.",
            request_id.to_string(),
        )
    });
    zeroize_credentials(&mut credentials);
    client
}
