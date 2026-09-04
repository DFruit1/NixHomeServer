use super::*;

async fn broker_acoustid_lookup(
    config: &AppConfig,
    identity: &Identity,
    fingerprint: &str,
    duration: u32,
) -> Result<Vec<String>, String> {
    let base = config
        .provider_broker_base_url
        .as_deref()
        .ok_or_else(|| "provider broker is unavailable".to_string())?;
    let mut base =
        reqwest::Url::parse(base).map_err(|_| "provider broker address is invalid".to_string())?;
    if base.scheme() != "http"
        || !base
            .host_str()
            .is_some_and(|host| matches!(host, "localhost" | "127.0.0.1" | "::1"))
    {
        return Err("provider broker address is not loopback".to_string());
    }
    if !base.path().ends_with('/') {
        base.set_path(&format!("{}/", base.path()));
    }
    let client = reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(5))
        .timeout(Duration::from_secs(35))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|_| "provider broker client could not be created".to_string())?;
    let response = broker_provider_request(
        &base,
        &client,
        identity,
        "acoustid/lookup",
        json!({ "fingerprint": fingerprint, "duration": duration }),
    )
    .await?;
    if response
        .content_length()
        .is_some_and(|length| length > 256 * 1024)
    {
        return Err("provider broker response exceeded the size limit".to_string());
    }
    let bytes = response
        .bytes()
        .await
        .map_err(|_| "provider broker response could not be read".to_string())?;
    if bytes.len() > 256 * 1024 {
        return Err("provider broker response exceeded the size limit".to_string());
    }
    let payload = serde_json::from_slice::<BrokerAcoustidResponse>(&bytes)
        .map_err(|_| "provider broker returned an invalid response".to_string())?;
    Ok(payload.release_group_ids)
}

fn musicbrainz_client(config: &AppConfig, request_id: &str) -> Result<MusicBrainzClient, ApiError> {
    let acoustid_api_key = match config
        .acoustid_api_key_file
        .as_deref()
        .filter(|path| path.is_file())
    {
        Some(path) => match AcoustidCredentials::from_file(path) {
            Ok(credentials) => Some(credentials.acoustid_api_key),
            Err(error) => {
                log_event(
                    "musicbrainz_credentials_invalid",
                    request_id,
                    json!({ "error": error.to_string() }),
                );
                return Err(ApiError::new(
                    StatusCode::SERVICE_UNAVAILABLE,
                    "musicbrainz_lookup_unconfigured",
                    "The AcoustID API key is not valid on this server.",
                    request_id.to_string(),
                ));
            }
        },
        None => None,
    };
    let fpcalc_path = config
        .fpcalc_path
        .clone()
        .unwrap_or_else(|| std::path::PathBuf::from("fpcalc"));
    let client_config = MusicBrainzClientConfig {
        acoustid_api_key,
        fpcalc_path,
        musicbrainz_api_base: config
            .musicbrainz_api_base
            .clone()
            .unwrap_or_else(|| MUSICBRAINZ_API_BASE.to_string()),
        acoustid_api_base: config
            .acoustid_api_base
            .clone()
            .unwrap_or_else(|| ACOUSTID_API_BASE.to_string()),
        request_gap: std::time::Duration::from_millis(config.musicbrainz_request_gap_ms),
        user_agent: "NixHomeServer Media Manager/0.1 (home server; music metadata lookup)"
            .to_string(),
    };
    MusicBrainzClient::new(client_config).map_err(|error| {
        log_event(
            "musicbrainz_client_failed",
            request_id,
            json!({ "error": error.to_string() }),
        );
        ApiError::internal(request_id.to_string())
    })
}

pub(super) async fn lookup_music_metadata(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(item_id): Path<String>,
    Json(request): Json<MusicLookupRequest>,
) -> Response {
    let request_id = request_id();
    let identity = match editor_identity(&state.config, &headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    let mode = match LookupMode::parse(request.mode.as_deref()) {
        Some(mode) => mode,
        None => {
            return ApiError::new(
                StatusCode::BAD_REQUEST,
                "musicbrainz_mode_invalid",
                "Choose auto, fingerprint, or search lookup mode.",
                request_id,
            )
            .into_response()
        }
    };
    let artist = request
        .artist
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());
    let mut title = request
        .title
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());
    for (label, value) in [("Artist", &artist), ("Title", &title)] {
        if value
            .as_ref()
            .is_some_and(|value| value.len() > 500 || value.contains('\0'))
        {
            return ApiError::new(
                StatusCode::BAD_REQUEST,
                "musicbrainz_query_invalid",
                format!("{label} must contain between 1 and 500 characters."),
                request_id,
            )
            .into_response();
        }
    }
    if artist.is_none() && title.is_none() && mode == LookupMode::Search {
        return ApiError::new(
            StatusCode::BAD_REQUEST,
            "musicbrainz_query_required",
            "An artist or title is required to search MusicBrainz.",
            request_id,
        )
        .into_response();
    }
    let catalog = match state.catalog.open() {
        Ok(catalog) => catalog,
        Err(error) => {
            log_event(
                "catalog_open_failed",
                &request_id,
                json!({ "error": error.to_string() }),
            );
            return ApiError::internal(request_id).into_response();
        }
    };
    let item = match visible_catalog_item(&state.config, &identity, &catalog, &item_id) {
        Ok(item) if item.media_kind == "music" => item,
        Ok(_) => {
            return ApiError::new(
                StatusCode::CONFLICT,
                "music_item_required",
                "MusicBrainz lookup requires a cataloged music file.",
                request_id,
            )
            .into_response()
        }
        Err(error) => return error.with_request_id(request_id).into_response(),
    };
    let client = match musicbrainz_client(&state.config, &request_id) {
        Ok(client) => client,
        Err(error) => return error.into_response(),
    };
    let runtime_acoustid = state.config.provider_broker_base_url.is_some()
        && provider_account_configured(&state.config, &identity, "acoustid").await;
    if mode == LookupMode::Fingerprint && !client.has_fingerprint() && !runtime_acoustid {
        return ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "musicbrainz_lookup_unconfigured",
            "Configure your AcoustID account from Accounts to use fingerprint lookup.",
            request_id,
        )
        .into_response();
    }
    if title.is_none() {
        title = music_title_from_relative_path(&item.relative_path);
    }
    let root = match state.config.resolve_visible_root(&identity, &item.root_id) {
        Some(root) => root,
        None => return ApiError::internal(request_id).into_response(),
    };
    let root_path = root.resolved_path;
    let relative_path = item.relative_path.clone();
    let file_path = match tokio::task::spawn_blocking(move || {
        let file = open_regular_file_beneath(FilePath::new(&root_path), &relative_path)
            .map_err(|error| error.to_string())?;
        drop(file);
        let path = FilePath::new(&root_path).join(&relative_path);
        let metadata = std::fs::symlink_metadata(&path)
            .map_err(|error| format!("stat media file: {error}"))?;
        if !metadata.file_type().is_file() || metadata.file_type().is_symlink() {
            return Err("media file is not a regular file".to_string());
        }
        Ok(path)
    })
    .await
    {
        Ok(Ok(path)) => path,
        Ok(Err(error)) => {
            log_event(
                "musicbrainz_file_unavailable",
                &request_id,
                json!({ "error": error, "itemId": item.id }),
            );
            return ApiError::new(
                StatusCode::CONFLICT,
                "music_file_unavailable",
                "The selected audio changed or can no longer be read safely. Scan the library again.",
                request_id,
            )
            .into_response();
        }
        Err(error) => {
            log_event(
                "musicbrainz_file_task_failed",
                &request_id,
                json!({ "error": error.to_string(), "itemId": item.id }),
            );
            return ApiError::internal(request_id).into_response();
        }
    };
    let lookup = if runtime_acoustid && mode != LookupMode::Search {
        match client.fingerprint_file(&file_path).await {
            Ok((fingerprint, duration)) => {
                match broker_acoustid_lookup(&state.config, &identity, &fingerprint, duration).await
                {
                    Ok(ids) if !ids.is_empty() => client.release_groups_from_ids(&ids).await,
                    Ok(_) if mode == LookupMode::Auto => {
                        client
                            .lookup_music(
                                &file_path,
                                artist.as_deref(),
                                title.as_deref(),
                                LookupMode::Search,
                            )
                            .await
                    }
                    Ok(_) => Ok(Vec::new()),
                    Err(_) if mode == LookupMode::Auto => {
                        client
                            .lookup_music(
                                &file_path,
                                artist.as_deref(),
                                title.as_deref(),
                                LookupMode::Search,
                            )
                            .await
                    }
                    Err(error) => {
                        log_event(
                            "acoustid_broker_lookup_failed",
                            &request_id,
                            json!({ "error": error, "itemId": item.id }),
                        );
                        return ApiError::new(
                            StatusCode::BAD_GATEWAY,
                            "acoustid_lookup_failed",
                            "AcoustID could not complete the fingerprint lookup.",
                            request_id,
                        )
                        .into_response();
                    }
                }
            }
            Err(error) => Err(error),
        }
    } else {
        client
            .lookup_music(&file_path, artist.as_deref(), title.as_deref(), mode)
            .await
    };
    let candidates = match lookup {
        Ok(candidates) => candidates,
        Err(error) => {
            log_event(
                "musicbrainz_lookup_failed",
                &request_id,
                json!({ "error": error.to_string(), "itemId": item.id }),
            );
            return ApiError::new(
                StatusCode::BAD_GATEWAY,
                "musicbrainz_lookup_failed",
                "MusicBrainz could not complete the metadata lookup.",
                request_id,
            )
            .into_response();
        }
    };
    Json(json!({
        "candidates": candidates,
        "requestId": request_id,
    }))
    .into_response()
}

pub(super) async fn search_tmdb_metadata(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(request): Json<TmdbSearchRequest>,
) -> Response {
    let request_id = request_id();
    let _identity = match editor_identity(&state.config, &headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };

    if request.query.trim().is_empty() {
        return ApiError::new(
            StatusCode::BAD_REQUEST,
            "tmdb_query_empty",
            "TMDB search requires a non-empty query.",
            request_id,
        )
        .into_response();
    }

    if request.query.len() > 500 {
        return ApiError::new(
            StatusCode::BAD_REQUEST,
            "tmdb_query_too_long",
            "Query must be 500 characters or less.",
            request_id,
        )
        .into_response();
    }

    let tmdb_client = match &state.tmdb_client {
        Some(client) => client,
        None => {
            return ApiError::new(
                StatusCode::SERVICE_UNAVAILABLE,
                "tmdb_unconfigured",
                "TMDB API key is not configured on this server. Set MEDIA_MANAGER_TMDB_API_KEY_FILE to enable TMDB search.",
                request_id,
            )
            .into_response();
        }
    };

    let media_type = request.media_type.as_deref().unwrap_or("auto");
    let year = request.year.filter(|y| *y > 1800 && *y <= 2100);

    let mut all_results = Vec::new();

    match media_type {
        "movie" | "auto" => match tmdb_client.search_movies(&request.query, year).await {
            Ok(movies) => {
                for movie in movies {
                    let release_year = movie
                        .release_date
                        .as_ref()
                        .and_then(|d| d.get(0..4))
                        .and_then(|y| y.parse::<u16>().ok());
                    let item = json!({
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
                    });
                    all_results.push(item);
                }
            }
            Err(error) => {
                log_event(
                    "tmdb_movie_search_failed",
                    &request_id,
                    json!({ "error": error.to_string(), "query": request.query }),
                );
            }
        },
        "tv" => {}
        _ => {}
    }

    if media_type == "tv" || media_type == "auto" {
        match tmdb_client.search_tv_shows(&request.query, year).await {
            Ok(shows) => {
                for show in shows {
                    let first_air_year = show
                        .first_air_date
                        .as_ref()
                        .and_then(|d| d.get(0..4))
                        .and_then(|y| y.parse::<u16>().ok());
                    let item = json!({
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
                    });
                    all_results.push(item);
                }
            }
            Err(error) => {
                log_event(
                    "tmdb_tv_search_failed",
                    &request_id,
                    json!({ "error": error.to_string(), "query": request.query }),
                );
            }
        }
    }

    all_results.sort_by(|a, b| {
        let a_pop = a.get("voteCount").and_then(|v| v.as_u64()).unwrap_or(0);
        let b_pop = b.get("voteCount").and_then(|v| v.as_u64()).unwrap_or(0);
        b_pop.cmp(&a_pop)
    });

    Json(json!({
        "results": all_results,
        "query": request.query,
        "year": year,
        "mediaType": media_type,
        "requestId": request_id,
    }))
    .into_response()
}

pub(super) async fn get_tmdb_details(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(request): Json<TmdbDetailsRequest>,
) -> Response {
    let request_id = request_id();
    let _identity = match editor_identity(&state.config, &headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };

    let tmdb_client = match &state.tmdb_client {
        Some(client) => client,
        None => {
            return ApiError::new(
                StatusCode::SERVICE_UNAVAILABLE,
                "tmdb_unconfigured",
                "TMDB API key is not configured on this server. Set MEDIA_MANAGER_TMDB_API_KEY_FILE to enable TMDB search.",
                request_id,
            )
            .into_response();
        }
    };

    let result = match request.media_type.as_str() {
        "movie" => match tmdb_client.get_movie_details(request.tmdb_id).await {
            Ok(details) => json!({
                "mediaType": "movie",
                "tmdbId": details.id,
                "title": details.title,
                "originalTitle": details.original_title,
                "overview": details.overview,
                "releaseDate": details.release_date,
                "year": details.release_date.as_ref().and_then(|d| d.get(0..4)).and_then(|y| y.parse::<u16>().ok()),
                "runtimeMinutes": details.runtime,
                "voteAverage": details.vote_average,
                "voteCount": details.vote_count,
                "posterPath": details.poster_path,
                "backdropPath": details.backdrop_path,
                "genres": details.genres.iter().map(|g| g.name.clone()).collect::<Vec<_>>(),
                "productionCompanies": details.production_companies.iter().map(|c| c.name.clone()).collect::<Vec<_>>(),
                "productionCountries": details.production_countries.iter().map(|c| c.name.clone()).collect::<Vec<_>>(),
                "spokenLanguages": details.spoken_languages.iter().map(|l| l.english_name.clone()).collect::<Vec<_>>(),
                "status": details.status,
                "tagline": details.tagline,
                "cast": details.credits.as_ref().map(|c| c.cast.iter().map(|m| json!({
                    "id": m.id,
                    "name": m.name,
                    "character": m.character,
                })).collect::<Vec<_>>()).unwrap_or_default(),
                "crew": details.credits.as_ref().map(|c| c.crew.iter().map(|m| json!({
                    "id": m.id,
                    "name": m.name,
                    "job": m.job,
                    "department": m.department,
                })).collect::<Vec<_>>()).unwrap_or_default(),
                "keywords": details.keywords.as_ref().map(|k| k.keywords.iter().map(|kw| kw.name.clone()).collect::<Vec<_>>()).unwrap_or_default(),
                "externalIds": details.external_ids.as_ref().map(|e| json!({
                    "imdbId": e.imdb_id,
                    "wikidataId": e.wikidata_id,
                })).unwrap_or_default(),
            }),
            Err(error) => {
                log_event(
                    "tmdb_movie_details_failed",
                    &request_id,
                    json!({ "error": error.to_string(), "tmdbId": request.tmdb_id }),
                );
                return ApiError::new(
                    StatusCode::BAD_GATEWAY,
                    "tmdb_details_failed",
                    "TMDB could not fetch movie details.",
                    request_id,
                )
                .into_response();
            }
        },
        "tv" => match tmdb_client.get_tv_show_details(request.tmdb_id).await {
            Ok(details) => json!({
                "mediaType": "tv",
                "tmdbId": details.id,
                "title": details.name,
                "originalTitle": details.original_name,
                "overview": details.overview,
                "firstAirDate": details.first_air_date,
                "lastAirDate": details.last_air_date,
                "year": details.first_air_date.as_ref().and_then(|d| d.get(0..4)).and_then(|y| y.parse::<u16>().ok()),
                "numberOfSeasons": details.number_of_seasons,
                "numberOfEpisodes": details.number_of_episodes,
                "voteAverage": details.vote_average,
                "voteCount": details.vote_count,
                "posterPath": details.poster_path,
                "backdropPath": details.backdrop_path,
                "genres": details.genres.iter().map(|g| g.name.clone()).collect::<Vec<_>>(),
                "productionCompanies": details.production_companies.iter().map(|c| c.name.clone()).collect::<Vec<_>>(),
                "productionCountries": details.production_countries.iter().map(|c| c.name.clone()).collect::<Vec<_>>(),
                "spokenLanguages": details.spoken_languages.iter().map(|l| l.english_name.clone()).collect::<Vec<_>>(),
                "status": details.status,
                "type": details.show_type,
                "inProduction": details.in_production,
                "episodeRunTime": details.episode_run_time,
                "cast": details.credits.as_ref().map(|c| c.cast.iter().map(|m| json!({
                    "id": m.id,
                    "name": m.name,
                    "character": m.character,
                })).collect::<Vec<_>>()).unwrap_or_default(),
                "crew": details.credits.as_ref().map(|c| c.crew.iter().map(|m| json!({
                    "id": m.id,
                    "name": m.name,
                    "job": m.job,
                    "department": m.department,
                })).collect::<Vec<_>>()).unwrap_or_default(),
                "keywords": details.keywords.as_ref().map(|k| k.keywords.iter().map(|kw| kw.name.clone()).collect::<Vec<_>>()).unwrap_or_default(),
                "externalIds": details.external_ids.as_ref().map(|e| json!({
                    "imdbId": e.imdb_id,
                    "wikidataId": e.wikidata_id,
                })).unwrap_or_default(),
            }),
            Err(error) => {
                log_event(
                    "tmdb_tv_details_failed",
                    &request_id,
                    json!({ "error": error.to_string(), "tmdbId": request.tmdb_id }),
                );
                return ApiError::new(
                    StatusCode::BAD_GATEWAY,
                    "tmdb_details_failed",
                    "TMDB could not fetch TV show details.",
                    request_id,
                )
                .into_response();
            }
        },
        _ => {
            return ApiError::new(
                StatusCode::BAD_REQUEST,
                "tmdb_media_type_invalid",
                "mediaType must be 'movie' or 'tv'.",
                request_id,
            )
            .into_response();
        }
    };

    Json(json!({
        "details": result,
        "requestId": request_id,
    }))
    .into_response()
}

fn music_title_from_relative_path(relative_path: &str) -> Option<String> {
    let filename = relative_path
        .rsplit_once('/')
        .map(|(_, filename)| filename)
        .unwrap_or(relative_path);
    let stem = filename
        .rsplit_once('.')
        .map(|(stem, _)| stem)
        .unwrap_or(filename);
    let stem = stem.trim();
    (!stem.is_empty() && stem.len() <= 500).then(|| stem.to_string())
}
