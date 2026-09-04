use super::*;

struct VisibleMediaFolder {
    root_id: String,
    relative_path: String,
    category: String,
    has_direct_media: bool,
    has_season_directory: bool,
}

fn visible_media_folder(
    config: &AppConfig,
    identity: &Identity,
    query: &FolderMetadataQuery,
) -> Result<VisibleMediaFolder, ApiError> {
    if query.relative_path.is_empty() || query.relative_path.len() > 4096 {
        return Err(ApiError::without_request_id(
            StatusCode::BAD_REQUEST,
            "folder_path_invalid",
            "The selected folder path is invalid.",
        ));
    }
    let root = config
        .resolve_visible_root(identity, &query.root_id)
        .filter(|root| {
            ["videos", "music", "audiobooks", "podcasts", "books"].contains(&root.category.as_str())
        })
        .ok_or_else(|| {
            ApiError::without_request_id(
                StatusCode::FORBIDDEN,
                "folder_not_visible",
                "The selected folder is outside the caller's visible media roots.",
            )
        })?;
    let directory =
        open_directory_beneath(FilePath::new(&root.resolved_path), &query.relative_path).map_err(
            |_| {
                ApiError::without_request_id(
                    StatusCode::CONFLICT,
                    "folder_missing",
                    "The selected folder is no longer present in the media library.",
                )
            },
        )?;
    let (has_direct_media, has_season_directory) = inspect_media_folder(&directory, &root.category)
        .map_err(|_| {
            ApiError::without_request_id(
                StatusCode::CONFLICT,
                "folder_missing",
                "The selected folder is no longer present in the media library.",
            )
        })?;
    Ok(VisibleMediaFolder {
        root_id: root.id,
        relative_path: query.relative_path.clone(),
        category: root.category,
        has_direct_media,
        has_season_directory,
    })
}

fn inspect_media_folder(
    directory: &std::fs::File,
    category: &str,
) -> std::io::Result<(bool, bool)> {
    let mut has_direct_media = false;
    let mut has_season_directory = false;
    let directory_path = format!("/proc/self/fd/{}", directory.as_raw_fd());
    for (index, entry) in std::fs::read_dir(directory_path)?.enumerate() {
        if index >= 10_000 {
            break;
        }
        let entry = entry?;
        let file_type = entry.file_type()?;
        if file_type.is_symlink() {
            continue;
        }
        if file_type.is_dir() {
            let name = entry.file_name();
            if season_number_from_name(&name.to_string_lossy()).is_some() {
                has_season_directory = true;
            }
            continue;
        }
        if !file_type.is_file() {
            continue;
        }
        let extension = entry
            .path()
            .extension()
            .and_then(|value| value.to_str())
            .unwrap_or_default()
            .to_ascii_lowercase();
        if scanned_media_kind(category, &extension)
            .is_some_and(|kind| !matches!(kind, "artwork" | "subtitle"))
        {
            has_direct_media = true;
        }
    }
    Ok((has_direct_media, has_season_directory))
}

fn folder_media_type(folder: &VisibleMediaFolder) -> &'static str {
    if season_number_from_folder(&folder.relative_path).is_some() {
        return "season";
    }
    match folder.category.as_str() {
        "videos" if folder.has_season_directory => "series",
        "videos" if folder.has_direct_media => "movie",
        "music" if folder.has_direct_media => "music",
        "audiobooks" if folder.has_direct_media => "audiobook",
        "podcasts" if folder.has_direct_media => "podcast",
        "books" if folder.has_direct_media => "book",
        _ => "collection",
    }
}

fn season_number_from_folder(relative_path: &str) -> Option<u32> {
    season_number_from_name(relative_path.rsplit('/').next()?)
}

fn season_number_from_name(name: &str) -> Option<u32> {
    if name.eq_ignore_ascii_case("specials") {
        return Some(0);
    }
    let (prefix, number) = name.trim().split_once(' ')?;
    if !prefix.eq_ignore_ascii_case("season") {
        return None;
    }
    number.trim().parse().ok()
}

fn validate_metadata_request(request: &MetadataSidecarRequest) -> Result<(), ApiError> {
    if request.media_type.as_deref().is_some_and(|media_type| {
        ![
            "movie",
            "series",
            "season",
            "episode",
            "music",
            "audiobook",
            "book",
        ]
        .contains(&media_type)
    }) {
        return Err(ApiError::without_request_id(
            StatusCode::BAD_REQUEST,
            "metadata_type_invalid",
            "Choose a supported metadata type.",
        ));
    }
    if request.media_type.as_deref() == Some("episode")
        && (request.series.as_deref().is_none_or(str::is_empty)
            || request.season.is_none()
            || request.episode.is_none())
    {
        return Err(ApiError::without_request_id(
            StatusCode::BAD_REQUEST,
            "metadata_episode_fields_required",
            "TV episodes require series, season, and episode values.",
        ));
    }
    if !valid_metadata_value(&request.title, 500) || request.title.trim().is_empty() {
        return Err(ApiError::without_request_id(
            StatusCode::BAD_REQUEST,
            "metadata_title_required",
            "Metadata requires a non-empty title no longer than 500 characters.",
        ));
    }
    let scalar_fields = [
        (request.sort_title.as_deref(), 500usize),
        (request.description.as_deref(), 20_000usize),
        (request.publisher.as_deref(), 500usize),
        (request.series.as_deref(), 500usize),
        (request.volume_number.as_deref(), 32usize),
        (request.isbn.as_deref(), 64usize),
        (request.language.as_deref(), 15usize),
        (request.episode_title.as_deref(), 500usize),
        (request.premiere_date.as_deref(), 10usize),
        (request.official_rating.as_deref(), 64usize),
    ];
    if scalar_fields
        .iter()
        .any(|(value, maximum)| value.is_some_and(|value| !valid_metadata_value(value, *maximum)))
        || request.authors.len() > 32
        || request.narrators.len() > 32
        || request.genres.len() > 64
        || request.writers.len() > 64
        || request.provider_ids.len() > 32
        || request
            .authors
            .iter()
            .chain(&request.narrators)
            .chain(&request.genres)
            .chain(&request.writers)
            .any(|value| !valid_metadata_value(value, 500) || value.trim().is_empty())
    {
        return Err(ApiError::without_request_id(
            StatusCode::BAD_REQUEST,
            "metadata_fields_invalid",
            "One or more metadata fields exceed the supported size or contain invalid control characters.",
        ));
    }
    if request.year.is_some_and(|year| year == 0 || year > 2100) {
        return Err(ApiError::without_request_id(
            StatusCode::BAD_REQUEST,
            "metadata_year_invalid",
            "The release year must be omitted when unknown, or be between 1 and 2100.",
        ));
    }
    if request
        .runtime_minutes
        .is_some_and(|runtime| runtime == 0 || runtime > 100_000)
        || request
            .community_rating
            .is_some_and(|rating| !rating.is_finite() || !(0.0..=10.0).contains(&rating))
        || request.season.is_some_and(|season| season > 10_000)
        || request
            .episode
            .is_some_and(|episode| episode == 0 || episode > 100_000)
        || request
            .provider_ids
            .iter()
            .any(|(key, value)| !valid_metadata_value(key, 64) || !valid_metadata_value(value, 256))
    {
        return Err(ApiError::without_request_id(
            StatusCode::BAD_REQUEST,
            "metadata_fields_invalid",
            "One or more typed metadata fields are outside the supported range.",
        ));
    }
    if request.language.as_deref().is_some_and(|language| {
        normalized_subtitle_language(language).as_deref() != Some(language.trim())
    }) {
        return Err(ApiError::without_request_id(
            StatusCode::BAD_REQUEST,
            "metadata_language_invalid",
            "Use a lowercase two or three letter language code, optionally followed by a region.",
        ));
    }
    Ok(())
}

fn valid_metadata_value(value: &str, maximum: usize) -> bool {
    !value.is_empty()
        && value.len() <= maximum
        && value
            .chars()
            .all(|character| !character.is_control() || matches!(character, '\n' | '\r' | '\t'))
}

fn xml_text(value: &str) -> String {
    value
        .trim()
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

fn xml_element(name: &str, value: Option<&str>) -> String {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(|value| format!("  <{name}>{}</{name}>\n", xml_text(value)))
        .unwrap_or_default()
}

fn metadata_sidecar(
    item: &CatalogItem,
    request: &MetadataSidecarRequest,
) -> (String, &'static str, String) {
    let media_type = request
        .media_type
        .as_deref()
        .unwrap_or(match item.media_kind.as_str() {
            "music" => "music",
            "audiobook" => "audiobook",
            "book" => "book",
            _ => "movie",
        });
    let stem = item
        .relative_path
        .rsplit_once('.')
        .map(|(stem, _)| stem)
        .unwrap_or(&item.relative_path);
    if item.media_kind == "video" || item.media_kind == "music" {
        let root = if item.media_kind == "video" {
            if media_type == "episode" {
                "episodedetails"
            } else {
                "movie"
            }
        } else {
            "album"
        };
        let destination = if item.media_kind == "video" {
            format!("{stem}.nfo")
        } else {
            item.relative_path
                .rsplit_once('/')
                .map(|(parent, _)| format!("{parent}/album.nfo"))
                .unwrap_or_else(|| "album.nfo".to_string())
        };
        let mut xml = format!("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<{root}>\n");
        xml.push_str(&xml_element(
            "title",
            request.episode_title.as_deref().or(Some(&request.title)),
        ));
        xml.push_str(&xml_element("sorttitle", request.sort_title.as_deref()));
        if let Some(year) = request.year {
            xml.push_str(&format!("  <year>{year}</year>\n"));
        }
        xml.push_str(&xml_element(
            if item.media_kind == "video" {
                "plot"
            } else {
                "review"
            },
            request.description.as_deref(),
        ));
        xml.push_str(&xml_element("studio", request.publisher.as_deref()));
        xml.push_str(&xml_element("language", request.language.as_deref()));
        if media_type == "episode" {
            xml.push_str(&xml_element("showtitle", request.series.as_deref()));
            if let Some(season) = request.season {
                xml.push_str(&format!("  <season>{season}</season>\n"));
            }
            if let Some(episode) = request.episode {
                xml.push_str(&format!("  <episode>{episode}</episode>\n"));
            }
        }
        xml.push_str(&xml_element("premiered", request.premiere_date.as_deref()));
        xml.push_str(&xml_element("mpaa", request.official_rating.as_deref()));
        if let Some(runtime) = request.runtime_minutes {
            xml.push_str(&format!("  <runtime>{runtime}</runtime>\n"));
        }
        if let Some(rating) = request.community_rating {
            xml.push_str(&format!("  <rating>{rating}</rating>\n"));
        }
        for author in &request.authors {
            xml.push_str(&xml_element("artist", Some(author)));
        }
        for genre in &request.genres {
            xml.push_str(&xml_element("genre", Some(genre)));
        }
        for writer in &request.writers {
            xml.push_str(&xml_element("writer", Some(writer)));
        }
        for (provider, id) in &request.provider_ids {
            xml.push_str(&format!(
                "  <uniqueid type=\"{}\">{}</uniqueid>\n",
                xml_text(provider),
                xml_text(id)
            ));
        }
        xml.push_str(&format!("</{root}>\n"));
        return (destination, "nfo", xml);
    }

    let destination = if item.media_kind == "audiobook" {
        item.relative_path
            .rsplit_once('/')
            .map(|(parent, _)| format!("{parent}/metadata.opf"))
            .unwrap_or_else(|| "metadata.opf".to_string())
    } else {
        format!("{stem}.opf")
    };
    let mut xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\">\n <metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">\n".to_string();
    xml.push_str(&xml_element("dc:title", Some(&request.title)));
    for author in &request.authors {
        xml.push_str(&xml_element("dc:creator", Some(author)));
    }
    xml.push_str(&xml_element(
        "dc:description",
        request.description.as_deref(),
    ));
    xml.push_str(&xml_element("dc:publisher", request.publisher.as_deref()));
    xml.push_str(&xml_element("dc:language", request.language.as_deref()));
    if let Some(year) = request.year {
        xml.push_str(&format!("  <dc:date>{year}</dc:date>\n"));
    }
    if let Some(isbn) = request.isbn.as_deref() {
        xml.push_str(&format!(
            "  <dc:identifier id=\"isbn\">{}</dc:identifier>\n",
            xml_text(isbn)
        ));
    }
    for genre in &request.genres {
        xml.push_str(&xml_element("dc:subject", Some(genre)));
    }
    if let Some(series) = request.series.as_deref() {
        xml.push_str(&format!(
            "  <meta name=\"calibre:series\" content=\"{}\"/>\n",
            xml_text(series)
        ));
    }
    if let Some(volume) = request.volume_number.as_deref() {
        xml.push_str(&format!(
            "  <meta name=\"calibre:series_index\" content=\"{}\"/>\n",
            xml_text(volume)
        ));
    }
    for narrator in &request.narrators {
        xml.push_str(&format!(
            "  <meta name=\"narrator\" content=\"{}\"/>\n",
            xml_text(narrator)
        ));
    }
    xml.push_str(" </metadata>\n</package>\n");
    (destination, "opf", xml)
}

fn comicinfo_sidecar(request: &MetadataSidecarRequest) -> String {
    let mut xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<ComicInfo>\n".to_string();
    xml.push_str(&xml_element("Title", Some(&request.title)));
    xml.push_str(&xml_element("Series", request.series.as_deref()));
    xml.push_str(&xml_element("Number", request.volume_number.as_deref()));
    xml.push_str(&xml_element("Summary", request.description.as_deref()));
    if let Some(year) = request.year {
        xml.push_str(&format!("  <Year>{year}</Year>\n"));
    }
    let writers = if request.writers.is_empty() {
        &request.authors
    } else {
        &request.writers
    };
    if !writers.is_empty() {
        xml.push_str(&xml_element("Writer", Some(&writers.join(", "))));
    }
    xml.push_str(&xml_element("Publisher", request.publisher.as_deref()));
    if !request.genres.is_empty() {
        xml.push_str(&xml_element("Genre", Some(&request.genres.join(", "))));
    }
    xml.push_str(&xml_element("LanguageISO", request.language.as_deref()));
    if let Some(web) = request
        .provider_ids
        .get("web")
        .or_else(|| request.provider_ids.get("comicVine"))
    {
        xml.push_str(&xml_element("Web", Some(web)));
    }
    xml.push_str("</ComicInfo>\n");
    xml
}

fn folder_metadata_sidecar(
    folder: &VisibleMediaFolder,
    request: &MetadataSidecarRequest,
) -> (String, &'static str, String) {
    let media_type = request
        .media_type
        .as_deref()
        .unwrap_or_else(|| folder_media_type(folder));
    if matches!(media_type, "series" | "season") {
        let root_tag = if media_type == "series" {
            "tvshow"
        } else {
            "season"
        };
        let filename = if media_type == "series" {
            "tvshow.nfo"
        } else {
            "season.nfo"
        };
        let mut xml = format!("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<{root_tag}>\n");
        xml.push_str(&xml_element("title", Some(&request.title)));
        xml.push_str(&xml_element("sorttitle", request.sort_title.as_deref()));
        if let Some(year) = request.year {
            xml.push_str(&format!("  <year>{year}</year>\n"));
        }
        xml.push_str(&xml_element("plot", request.description.as_deref()));
        xml.push_str(&xml_element("studio", request.publisher.as_deref()));
        xml.push_str(&xml_element("language", request.language.as_deref()));
        xml.push_str(&xml_element("premiered", request.premiere_date.as_deref()));
        xml.push_str(&xml_element("mpaa", request.official_rating.as_deref()));
        if let Some(rating) = request.community_rating {
            xml.push_str(&format!("  <rating>{rating}</rating>\n"));
        }
        for genre in &request.genres {
            xml.push_str(&xml_element("genre", Some(genre)));
        }
        for writer in &request.writers {
            xml.push_str(&xml_element("writer", Some(writer)));
        }
        for (provider, id) in &request.provider_ids {
            xml.push_str(&format!(
                "  <uniqueid type=\"{}\">{}</uniqueid>\n",
                xml_text(provider),
                xml_text(id)
            ));
        }
        xml.push_str(&format!("</{root_tag}>\n"));
        return (format!("{}/{filename}", folder.relative_path), "nfo", xml);
    }

    let (media_kind, placeholder) = match folder.category.as_str() {
        "music" => ("music", "album-track.mp3"),
        "audiobooks" => ("audiobook", "book.m4b"),
        "books" => ("audiobook", "book.epub"),
        _ => ("video", "movie.mkv"),
    };
    let pseudo_item = CatalogItem {
        id: String::new(),
        root_id: folder.root_id.clone(),
        owner_username: None,
        relative_path: format!("{}/{placeholder}", folder.relative_path),
        media_kind: media_kind.to_string(),
        size_bytes: 0,
        modified_ns: 0,
        fingerprint: String::new(),
    };
    metadata_sidecar(&pseudo_item, request)
}

struct PreparedMetadataAction {
    action: BrokerAction,
    staging_path: std::path::PathBuf,
}

async fn prepare_embedded_metadata_action(
    config: &AppConfig,
    identity: &Identity,
    item: &CatalogItem,
    extension: &str,
    generated: &str,
    request_id: &str,
) -> Result<PreparedMetadataAction, ApiError> {
    const MAX_EDITABLE_CONTAINER_BYTES: u64 = 512 * 1024 * 1024;
    let root = config
        .resolve_visible_root(identity, &item.root_id)
        .ok_or_else(|| ApiError::internal(request_id.to_string()))?;
    let source = open_regular_file_beneath(FilePath::new(&root.resolved_path), &item.relative_path)
        .map_err(|_| {
            ApiError::new(
                StatusCode::CONFLICT,
                "unsafe_embedded_metadata_source",
                "The book container could not be opened safely.",
                request_id.to_string(),
            )
        })?;
    let metadata = source
        .metadata()
        .map_err(|_| ApiError::internal(request_id.to_string()))?;
    if metadata.len() > MAX_EDITABLE_CONTAINER_BYTES {
        return Err(ApiError::new(
            StatusCode::PAYLOAD_TOO_LARGE,
            "book_container_too_large",
            "The book container exceeds the 512 MiB safe rewrite limit.",
            request_id.to_string(),
        ));
    }
    let expected_source =
        opened_file_fingerprint(&source).map_err(|_| ApiError::internal(request_id.to_string()))?;
    let staging_directory = config.state_dir.join("provider-staging");
    tokio::fs::create_dir_all(&staging_directory)
        .await
        .map_err(|_| ApiError::internal(request_id.to_string()))?;
    let staging_filename = format!("embedded-{request_id}.{extension}");
    let staging_path = staging_directory.join(&staging_filename);
    let output = std::fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o660)
        .open(&staging_path)
        .map_err(|_| ApiError::internal(request_id.to_string()))?;
    let generated = generated.to_string();
    let extension_owned = extension.to_string();
    let rewrite = tokio::task::spawn_blocking(move || {
        rewrite_embedded_metadata(source, output, &extension_owned, &generated)
    })
    .await;
    if let Err(message) = rewrite
        .map_err(|_| "embedded metadata rewrite did not complete".to_string())
        .and_then(|result| result)
    {
        let _ = tokio::fs::remove_file(&staging_path).await;
        return Err(ApiError::new(
            StatusCode::CONFLICT,
            "embedded_metadata_rewrite_failed",
            message,
            request_id.to_string(),
        ));
    }
    let source_path = FilePath::new(&root.resolved_path).join(&item.relative_path);
    let final_source = file_fingerprint(&source_path).map_err(|_| {
        ApiError::new(
            StatusCode::CONFLICT,
            "book_container_changed",
            "The book container changed while the preview was being prepared.",
            request_id.to_string(),
        )
    })?;
    if final_source != expected_source {
        let _ = tokio::fs::remove_file(&staging_path).await;
        return Err(ApiError::new(
            StatusCode::CONFLICT,
            "book_container_changed",
            "The book container changed while the preview was being prepared.",
            request_id.to_string(),
        ));
    }
    let expected_replacement =
        file_fingerprint(&staging_path).map_err(|_| ApiError::internal(request_id.to_string()))?;
    let (parent, filename) = item
        .relative_path
        .rsplit_once('/')
        .unwrap_or(("", item.relative_path.as_str()));
    let stem = filename
        .rsplit_once('.')
        .map(|(stem, _)| stem)
        .unwrap_or(filename);
    let archived_relative_path = join_relative(
        parent,
        &format!("superseded/{stem}-{request_id}.{extension}"),
    );
    Ok(PreparedMetadataAction {
        action: BrokerAction::ReplaceEmbeddedMetadata(ReplaceEmbeddedMetadataAction {
            staging_filename,
            root_id: item.root_id.clone(),
            source_relative_path: item.relative_path.clone(),
            archived_relative_path,
            replacement_relative_path: item.relative_path.clone(),
            expected_source,
            expected_replacement,
        }),
        staging_path,
    })
}

async fn prepare_metadata_action(
    config: &AppConfig,
    identity: &Identity,
    root_id: &str,
    destination_relative_path: String,
    extension: &str,
    generated: &str,
    request_id: &str,
) -> Result<PreparedMetadataAction, ApiError> {
    const MAX_EDITABLE_SIDECAR_BYTES: u64 = 1024 * 1024;
    let root = config
        .resolve_visible_root(identity, root_id)
        .ok_or_else(|| ApiError::internal(request_id.to_string()))?;
    let destination_path = FilePath::new(&root.resolved_path).join(&destination_relative_path);
    let existing = match std::fs::symlink_metadata(&destination_path) {
        Ok(metadata) => {
            if metadata.file_type().is_symlink() || !metadata.file_type().is_file() {
                return Err(ApiError::new(
                    StatusCode::CONFLICT,
                    "unsafe_metadata_destination",
                    "The existing metadata destination is not a regular contained file.",
                    request_id.to_string(),
                ));
            }
            if metadata.len() > MAX_EDITABLE_SIDECAR_BYTES {
                return Err(ApiError::new(
                    StatusCode::PAYLOAD_TOO_LARGE,
                    "metadata_sidecar_too_large",
                    "The existing metadata sidecar is too large for a safe in-app edit.",
                    request_id.to_string(),
                ));
            }
            let mut file = open_regular_file_beneath(
                FilePath::new(&root.resolved_path),
                &destination_relative_path,
            )
            .map_err(|_| {
                ApiError::new(
                    StatusCode::CONFLICT,
                    "unsafe_metadata_destination",
                    "The existing metadata sidecar could not be opened safely.",
                    request_id.to_string(),
                )
            })?;
            let initial_fingerprint = opened_file_fingerprint(&file)
                .map_err(|_| ApiError::internal(request_id.to_string()))?;
            let mut bytes = Vec::with_capacity(metadata.len() as usize);
            file.by_ref()
                .take(MAX_EDITABLE_SIDECAR_BYTES + 1)
                .read_to_end(&mut bytes)
                .map_err(|_| ApiError::internal(request_id.to_string()))?;
            let text = String::from_utf8(bytes).map_err(|_| {
                ApiError::new(
                    StatusCode::CONFLICT,
                    "metadata_sidecar_not_utf8",
                    "The existing metadata sidecar is not UTF-8 XML and cannot be edited safely.",
                    request_id.to_string(),
                )
            })?;
            let final_fingerprint = opened_file_fingerprint(&file)
                .map_err(|_| ApiError::internal(request_id.to_string()))?;
            let path_fingerprint = file_fingerprint(&destination_path).map_err(|_| {
                ApiError::new(
                    StatusCode::CONFLICT,
                    "metadata_sidecar_changed",
                    "The metadata sidecar changed while the preview was being prepared. Reload it and try again.",
                    request_id.to_string(),
                )
            })?;
            if initial_fingerprint != final_fingerprint || final_fingerprint != path_fingerprint {
                return Err(ApiError::new(
                    StatusCode::CONFLICT,
                    "metadata_sidecar_changed",
                    "The metadata sidecar changed while the preview was being prepared. Reload it and try again.",
                    request_id.to_string(),
                ));
            }
            Some((text, final_fingerprint))
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
        Err(_) => return Err(ApiError::internal(request_id.to_string())),
    };
    let contents = match existing.as_ref() {
        Some((existing, _)) => merge_managed_sidecar(existing, generated).map_err(|message| {
            ApiError::new(
                StatusCode::CONFLICT,
                "metadata_sidecar_merge_failed",
                message,
                request_id.to_string(),
            )
        })?,
        None => generated.to_string(),
    };
    let staged = stage_sidecar(config, extension, contents.as_bytes(), request_id).await?;
    let action = if let Some((_, expected_source)) = existing {
        let (parent, filename) = destination_relative_path
            .rsplit_once('/')
            .unwrap_or(("", destination_relative_path.as_str()));
        let stem = filename
            .rsplit_once('.')
            .map(|(stem, _)| stem)
            .unwrap_or(filename);
        let archived_relative_path = join_relative(
            parent,
            &format!("superseded/{stem}-{request_id}.{extension}"),
        );
        BrokerAction::ReplaceMetadataSidecar(ReplaceMetadataSidecarAction {
            staging_filename: staged.filename,
            root_id: root_id.to_string(),
            source_relative_path: destination_relative_path.clone(),
            archived_relative_path,
            replacement_relative_path: destination_relative_path,
            expected_source,
            expected_replacement: staged.expected,
        })
    } else {
        BrokerAction::InstallMetadataSidecar(InstallMetadataSidecarAction {
            staging_filename: staged.filename,
            destination_root_id: root_id.to_string(),
            destination_relative_path,
            expected: staged.expected,
        })
    };
    Ok(PreparedMetadataAction {
        action,
        staging_path: staged.path,
    })
}

fn create_metadata_plan(
    state: &AppState,
    identity: &Identity,
    catalog: &mut Catalog,
    item: &CatalogItem,
    request: &MetadataSidecarRequest,
    broker_action: BrokerAction,
    request_id: String,
) -> Result<Response, ApiError> {
    let expires_at = unix_timestamp().saturating_add(30 * 60);
    let canonical = serde_json::to_vec(&json!({
        "actor": identity.username,
        "itemId": item.id,
        "request": request,
        "action": broker_action,
        "expiresAt": expires_at,
    }))
    .map_err(|_| ApiError::internal(request_id.clone()))?;
    let digest = sha256_hex(&canonical);
    let plan_id = format!("plan-{request_id}");
    catalog
        .create_mutation_plan(&MutationPlanDraft {
            id: plan_id.clone(),
            owner_username: identity.username.clone(),
            digest: digest.clone(),
            request_json: serde_json::to_string(request)
                .map_err(|_| ApiError::internal(request_id.clone()))?,
            expires_at,
            actions: vec![broker_action.clone()],
        })
        .map_err(|error| {
            log_event(
                "mutation_plan_write_failed",
                &request_id,
                json!({ "error": error.to_string() }),
            );
            ApiError::internal(request_id.clone())
        })?;
    catalog
        .insert_audit_event(
            &request_id,
            &identity.username,
            "metadata_sidecar_previewed",
            Some(&plan_id),
            &json!({ "digest": digest, "itemId": item.id }).to_string(),
        )
        .map_err(|error| {
            log_event(
                "audit_write_failed",
                &request_id,
                json!({ "error": error.to_string() }),
            );
            ApiError::internal(request_id.clone())
        })?;

    let embedded = matches!(&broker_action, BrokerAction::ReplaceEmbeddedMetadata(_));
    let replacing = matches!(&broker_action, BrokerAction::ReplaceMetadataSidecar(_));
    let mut warnings = if embedded {
        vec![
            "The staged EPUB or CBZ was rebuilt and parsed before this preview was created.",
            "The original book will be archived in its superseded subfolder before the replacement is installed.",
            "All non-metadata ZIP entries are copied verbatim; unknown XML elements in the metadata document are retained.",
        ]
    } else {
        vec![
            "Metadata is written as an application-compatible NFO or OPF sidecar; media streams are not re-encoded.",
            if replacing {
                "The current sidecar will be archived in its superseded subfolder before the XML-preserving replacement is installed."
            } else {
                "The sidecar is installed with no-overwrite filesystem semantics."
            },
            "Unknown XML elements and attributes from an existing sidecar are retained in the staged replacement.",
        ]
    };
    if state.config.mutation_mode == MutationMode::ReadOnly {
        warnings.push("The service is in read-only mode; this plan cannot be confirmed.");
    }
    let consumer_kind = match request.media_type.as_deref() {
        Some("audiobook") => "audiobook",
        Some("book") => "book",
        Some("music") => "music",
        Some("movie" | "episode" | "series" | "season") => "video",
        _ => item.media_kind.as_str(),
    };
    let affected_consumers = consumer_effects(&state.config, consumer_kind);
    Ok((
        StatusCode::CREATED,
        Json(json!({
            "id": plan_id,
            "digest": digest,
            "state": "previewed",
            "actions": [broker_action],
            "expiresAt": expires_at,
            "mutationMode": state.config.mutation_mode,
            "warnings": warnings,
            "affectedConsumers": affected_consumers,
            "requestId": request_id,
        })),
    )
        .into_response())
}

pub(super) async fn preview_metadata_sidecar(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(item_id): Path<String>,
    Json(request): Json<MetadataSidecarRequest>,
) -> Response {
    let request_id = request_id();
    let identity = match editor_identity(&state.config, &headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    if let Err(error) = validate_metadata_request(&request) {
        return error.with_request_id(request_id).into_response();
    }
    let mut catalog = match state.catalog.open() {
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
        Ok(item) if ["video", "music", "audiobook", "book"].contains(&item.media_kind.as_str()) => {
            item
        }
        Ok(_) => {
            return ApiError::new(
                StatusCode::CONFLICT,
                "metadata_item_unsupported",
                "Metadata sidecars require a video, music, audiobook, or book item. Podcast tags are currently inspection-only.",
                request_id,
            )
            .into_response()
        }
        Err(error) => return error.with_request_id(request_id).into_response(),
    };
    let type_matches_item = matches!(
        (item.media_kind.as_str(), request.media_type.as_deref()),
        (_, None)
            | ("video", Some("movie" | "episode"))
            | ("music", Some("music"))
            | ("audiobook", Some("audiobook"))
            | ("book", Some("book"))
    );
    if !type_matches_item {
        return ApiError::new(
            StatusCode::CONFLICT,
            "metadata_type_mismatch",
            "The metadata type does not match the catalog item.",
            request_id,
        )
        .into_response();
    }
    if item.media_kind == "book" {
        let extension = item
            .relative_path
            .rsplit_once('.')
            .map(|(_, extension)| extension.to_ascii_lowercase())
            .unwrap_or_default();
        if !matches!(extension.as_str(), "epub" | "cbz") {
            return ApiError::new(
                StatusCode::CONFLICT,
                "embedded_book_metadata_read_only",
                "PDF and CBR metadata are inspection-only. Portable in-app edits are limited to EPUB and CBZ containers.",
                request_id,
            )
            .into_response();
        }
        let generated = if extension == "epub" {
            metadata_sidecar(&item, &request).2
        } else {
            comicinfo_sidecar(&request)
        };
        let prepared = match prepare_embedded_metadata_action(
            &state.config,
            &identity,
            &item,
            &extension,
            &generated,
            &request_id,
        )
        .await
        {
            Ok(prepared) => prepared,
            Err(error) => return error.into_response(),
        };
        return match create_metadata_plan(
            &state,
            &identity,
            &mut catalog,
            &item,
            &request,
            prepared.action,
            request_id.clone(),
        ) {
            Ok(response) => response,
            Err(error) => {
                let _ = tokio::fs::remove_file(prepared.staging_path).await;
                error.into_response()
            }
        };
    }
    let (destination_relative_path, extension, contents) = metadata_sidecar(&item, &request);
    let prepared = match prepare_metadata_action(
        &state.config,
        &identity,
        &item.root_id,
        destination_relative_path,
        extension,
        &contents,
        &request_id,
    )
    .await
    {
        Ok(prepared) => prepared,
        Err(error) => return error.into_response(),
    };
    match create_metadata_plan(
        &state,
        &identity,
        &mut catalog,
        &item,
        &request,
        prepared.action,
        request_id.clone(),
    ) {
        Ok(response) => response,
        Err(error) => {
            let _ = tokio::fs::remove_file(prepared.staging_path).await;
            error.into_response()
        }
    }
}

pub(super) async fn item_metadata(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(item_id): Path<String>,
) -> Response {
    let request_id = request_id();
    let identity = match identity_from_headers(&headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    let catalog = match state.catalog.open() {
        Ok(catalog) => catalog,
        Err(_) => return ApiError::internal(request_id).into_response(),
    };
    let item = match visible_catalog_item(&state.config, &identity, &catalog, &item_id) {
        Ok(item)
            if ["video", "music", "audiobook", "podcast", "book"]
                .contains(&item.media_kind.as_str()) =>
        {
            item
        }
        Ok(_) => {
            return ApiError::new(
                StatusCode::CONFLICT,
                "metadata_item_unsupported",
                "Metadata is available for video, music, audiobook, podcast, or book items.",
                request_id,
            )
            .into_response()
        }
        Err(error) => return error.with_request_id(request_id).into_response(),
    };

    let response = item_metadata_value(&state, &identity, &item, None).await;
    let mut result = Json(response).into_response();
    result.headers_mut().insert(
        CACHE_CONTROL,
        "private, no-store".parse().expect("cache header"),
    );
    result
}

async fn item_metadata_value(
    state: &AppState,
    identity: &Identity,
    item: &CatalogItem,
    application_caches: Option<&ApplicationMetadataCaches>,
) -> Value {
    let mut response = filename_metadata(item);
    let mut observations = vec![filename_observation(&response)];
    let mut field_sources = initial_field_sources(&response, "filename");
    let mut inspection_warnings = Vec::new();
    if let Some(root) = state.config.resolve_visible_root(&identity, &item.root_id) {
        let root_path = root.resolved_path;
        let inspected_item = item.clone();
        match tokio::task::spawn_blocking(move || {
            inspect_embedded_metadata(FilePath::new(&root_path), &inspected_item)
        })
        .await
        {
            Ok(Ok(Some(observation))) => {
                merge_metadata(
                    &mut response,
                    &observation.fields,
                    &observation.source,
                    &mut field_sources,
                );
                observations.push(observation);
            }
            Ok(Ok(None)) => {}
            Ok(Err(message)) => inspection_warnings.push(message),
            Err(_) => inspection_warnings
                .push("Embedded metadata inspection did not complete.".to_string()),
        }
    }
    if let Some(cache_file) = &state.config.jellyfin_metadata_cache_file {
        let entry = match application_caches {
            Some(caches) => caches
                .jellyfin
                .as_ref()
                .and_then(|cache| cached_application_metadata_entry(cache, item, false)),
            None => cached_application_metadata(cache_file, item, false).await,
        };
        if let Some(entry) = entry {
            observations.push(application_observation("jellyfin", "Jellyfin", &entry));
            merge_metadata(&mut response, &entry, "jellyfin", &mut field_sources);
        }
    }
    if matches!(item.media_kind.as_str(), "audiobook" | "podcast") {
        if let Some(cache_file) = &state.config.audiobookshelf_metadata_cache_file {
            let entry = match application_caches {
                Some(caches) => caches
                    .audiobookshelf
                    .as_ref()
                    .and_then(|cache| cached_application_metadata_entry(cache, item, true)),
                None => cached_application_metadata(cache_file, item, true).await,
            };
            if let Some(entry) = entry {
                observations.push(application_observation(
                    "audiobookshelf",
                    "Audiobookshelf",
                    &entry,
                ));
                merge_metadata(&mut response, &entry, "audiobookshelf", &mut field_sources);
            }
        }
    }
    if item.media_kind == "book" {
        if let Some(cache_file) = &state.config.kavita_metadata_cache_file {
            let entry = match application_caches {
                Some(caches) => caches
                    .kavita
                    .as_ref()
                    .and_then(|cache| cached_application_metadata_entry(cache, item, true)),
                None => cached_application_metadata(cache_file, item, true).await,
            };
            if let Some(entry) = entry {
                observations.push(application_observation("kavita", "Kavita", &entry));
                merge_metadata(&mut response, &entry, "kavita", &mut field_sources);
            }
        }
    }
    let media_type = response
        .get("mediaType")
        .and_then(Value::as_str)
        .unwrap_or("movie");
    let (sidecar_path, sidecar_format) = item_sidecar_path(&item, media_type);
    let consumer_effective = !matches!(item.media_kind.as_str(), "book" | "podcast");
    let root = state.config.resolve_visible_root(&identity, &item.root_id);
    let (sidecar, sidecar_observation) = root
        .as_ref()
        .map(|root| {
            inspect_sidecar(
                FilePath::new(&root.resolved_path),
                sidecar_path.clone(),
                sidecar_format,
                consumer_effective,
            )
        })
        .unwrap_or_else(|| {
            inspect_sidecar(
                FilePath::new("/nonexistent"),
                sidecar_path,
                sidecar_format,
                consumer_effective,
            )
        });
    if let Some(observation) = sidecar_observation {
        if consumer_effective {
            merge_metadata(
                &mut response,
                &observation.fields,
                "sidecar",
                &mut field_sources,
            );
        }
        observations.push(observation);
    }
    let sources = observations
        .iter()
        .map(|observation| observation.source.clone())
        .collect::<Vec<_>>();
    response["sources"] = json!(sources);
    response["observations"] = json!(observations);
    response["fieldSources"] = json!(field_sources);
    response["sidecar"] = json!(sidecar);
    let extension = item
        .relative_path
        .rsplit_once('.')
        .map(|(_, extension)| extension.to_ascii_lowercase())
        .unwrap_or_default();
    let mut consumers = consumer_effects(&state.config, &item.media_kind);
    if item.media_kind == "book" && matches!(extension.as_str(), "epub" | "cbz") {
        for consumer in &mut consumers {
            consumer.effect = "read-after-refresh".to_string();
            consumer.portable_write_supported = true;
            consumer.message =
                "Kavita reads the metadata embedded in this EPUB or CBZ after a library refresh."
                    .to_string();
        }
    }
    let application_available = consumers.iter().any(|consumer| consumer.available);
    response["consumers"] = json!(consumers);
    response["health"] = json!(health_issues(&item.media_kind, &response, &observations));
    response["modificationTargets"] = json!(modification_targets(
        &item.media_kind,
        &extension,
        application_available
    ));
    response["inspectionWarnings"] = json!(inspection_warnings);
    response
}

pub(super) async fn metadata_issues(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(query): Query<MetadataIssuesQuery>,
) -> Response {
    const DEFAULT_PAGE_SIZE: usize = 20;
    const MAX_PAGE_SIZE: usize = 50;
    const MAX_CURSOR_BYTES: usize = 4096;

    let request_id = request_id();
    let identity = match identity_from_headers(&headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    let root = match state
        .config
        .resolve_visible_root(&identity, query.root_id.as_str())
    {
        Some(root) => root,
        None => {
            return ApiError::new(
                StatusCode::FORBIDDEN,
                "root_not_visible",
                "The requested root is not visible to this identity.",
                request_id,
            )
            .into_response()
        }
    };
    let page_size = query.page_size.unwrap_or(DEFAULT_PAGE_SIZE);
    if page_size == 0 || page_size > MAX_PAGE_SIZE {
        return ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_page_size",
            format!("pageSize must be between 1 and {MAX_PAGE_SIZE}."),
            request_id,
        )
        .into_response();
    }
    if query
        .cursor
        .as_ref()
        .is_some_and(|cursor| cursor.len() > MAX_CURSOR_BYTES)
    {
        return ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_cursor",
            "The metadata issues cursor is too long.",
            request_id,
        )
        .into_response();
    }

    let owner = (root.scope == RootScope::Personal).then_some(identity.username.as_str());
    if query.cursor.is_none() {
        let scan_root_spec = ScanRoot {
            id: root.id.clone(),
            owner_username: owner.map(str::to_string),
            path: root.resolved_path.clone().into(),
            category: root.category.clone(),
        };
        let catalog_handle = state.catalog.clone();
        match tokio::task::spawn_blocking(move || rescan_root(&catalog_handle, &scan_root_spec))
            .await
        {
            Ok(Ok(_)) => {}
            Ok(Err(error)) => {
                log_event(
                    "metadata_health_scan_failed",
                    &request_id,
                    json!({ "rootId": root.id, "error": error }),
                );
                return ApiError::new(
                    StatusCode::BAD_GATEWAY,
                    "scan_failed",
                    "The selected media root could not be cataloged.",
                    request_id,
                )
                .into_response();
            }
            Err(error) => {
                log_event(
                    "metadata_health_scan_task_failed",
                    &request_id,
                    json!({ "rootId": root.id, "error": error.to_string() }),
                );
                return ApiError::internal(request_id).into_response();
            }
        }
    }

    let catalog = match state.catalog.open() {
        Ok(catalog) => catalog,
        Err(_) => return ApiError::internal(request_id).into_response(),
    };
    let mut page = match catalog.list_items_after(
        &root.id,
        owner,
        query.cursor.as_deref(),
        page_size.saturating_add(1),
    ) {
        Ok(items) => items,
        Err(_) => return ApiError::internal(request_id).into_response(),
    };
    let has_more = page.len() > page_size;
    page.truncate(page_size);
    let next_cursor = has_more
        .then(|| page.last().map(|item| item.relative_path.clone()))
        .flatten();

    let application_caches = ApplicationMetadataCaches::load(&state.config, &page).await;
    let mut results = Vec::new();
    let mut inspected_items = 0usize;
    let mut issue_count = 0usize;
    let mut severity_counts =
        HashMap::from([("error", 0usize), ("warning", 0usize), ("info", 0usize)]);
    for item in page {
        if !["video", "music", "audiobook", "podcast", "book"].contains(&item.media_kind.as_str()) {
            continue;
        }
        inspected_items += 1;
        let metadata =
            item_metadata_value(&state, &identity, &item, Some(&application_caches)).await;
        let health = metadata
            .get("health")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        if health.is_empty() {
            continue;
        }
        issue_count += health.len();
        for issue in &health {
            if let Some(count) = issue
                .get("severity")
                .and_then(Value::as_str)
                .and_then(|severity| severity_counts.get_mut(severity))
            {
                *count += 1;
            }
        }
        results.push(json!({
            "itemId": item.id,
            "rootId": item.root_id,
            "relativePath": item.relative_path,
            "mediaKind": item.media_kind,
            "health": health,
        }));
    }

    let mut result = Json(json!({
        "rootId": root.id,
        "results": results,
        "inspectedItems": inspected_items,
        "issueCount": issue_count,
        "severityCounts": severity_counts,
        "nextCursor": next_cursor,
    }))
    .into_response();
    result.headers_mut().insert(
        CACHE_CONTROL,
        "private, no-store".parse().expect("cache header"),
    );
    result
}

pub(super) async fn folder_metadata(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(query): Query<FolderMetadataQuery>,
) -> Response {
    let request_id = request_id();
    let identity = match identity_from_headers(&headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    let folder = match visible_media_folder(&state.config, &identity, &query) {
        Ok(folder) => folder,
        Err(error) => return error.with_request_id(request_id).into_response(),
    };
    let folder_name = folder
        .relative_path
        .rsplit('/')
        .next()
        .unwrap_or(&folder.relative_path);
    let (title, year) = strip_trailing_year(folder_name);
    let media_type = folder_media_type(&folder);
    let mut response = json!({
        "mediaType": media_type,
        "title": title,
        "year": year,
        "series": null,
        "season": season_number_from_folder(&folder.relative_path),
        "episode": null,
        "episodeTitle": null,
        "description": null,
        "publisher": null,
        "language": null,
        "genres": [],
        "writers": [],
        "premiereDate": null,
        "runtimeMinutes": null,
        "officialRating": null,
        "communityRating": null,
        "providerIds": {},
        "videoStreams": [],
        "audioStreams": [],
        "subtitleStreams": [],
        "sources": ["folder"]
    });
    let mut observations = vec![MetadataObservation {
        source: "folder".to_string(),
        label: "Folder name".to_string(),
        observed_at: None,
        relative_path: Some(folder.relative_path.clone()),
        format: None,
        app_item_id: None,
        storage: "folder-name".to_string(),
        consumed_by: Vec::new(),
        survives_rescan: true,
        writable: false,
        locked: None,
        fields: crate::metadata::metadata_fields(&response),
        raw_preview: None,
    }];
    let mut field_sources = initial_field_sources(&response, "folder");
    let (sidecar_path, sidecar_format) = folder_sidecar_path(&folder.relative_path, media_type);
    let consumer_kind = match folder.category.as_str() {
        "videos" => "video",
        "music" => "music",
        "audiobooks" => "audiobook",
        "podcasts" => "podcast",
        "books" => "book",
        _ => "",
    };
    let consumer_effective = !matches!(consumer_kind, "book" | "podcast");
    let root = state
        .config
        .resolve_visible_root(&identity, &folder.root_id);
    let (sidecar, sidecar_observation) = root
        .as_ref()
        .map(|root| {
            inspect_sidecar(
                FilePath::new(&root.resolved_path),
                sidecar_path.clone(),
                sidecar_format,
                consumer_effective,
            )
        })
        .unwrap_or_else(|| {
            inspect_sidecar(
                FilePath::new("/nonexistent"),
                sidecar_path,
                sidecar_format,
                consumer_effective,
            )
        });
    if let Some(observation) = sidecar_observation {
        if consumer_effective {
            merge_metadata(
                &mut response,
                &observation.fields,
                "sidecar",
                &mut field_sources,
            );
        }
        observations.push(observation);
    }
    response["sources"] = json!(observations
        .iter()
        .map(|observation| observation.source.clone())
        .collect::<Vec<_>>());
    response["observations"] = json!(observations);
    response["fieldSources"] = json!(field_sources);
    response["sidecar"] = json!(sidecar);
    let consumers = consumer_effects(&state.config, consumer_kind);
    let application_available = consumers.iter().any(|consumer| consumer.available);
    response["consumers"] = json!(consumers);
    response["health"] = json!(health_issues(consumer_kind, &response, &observations));
    response["modificationTargets"] = json!(modification_targets(
        consumer_kind,
        "folder",
        application_available
    ));
    response["inspectionWarnings"] = json!([]);
    let mut result = Json(response).into_response();
    result.headers_mut().insert(
        CACHE_CONTROL,
        "private, no-store".parse().expect("cache header"),
    );
    result
}

pub(super) async fn preview_folder_metadata_sidecar(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(query): Query<FolderMetadataQuery>,
    Json(request): Json<MetadataSidecarRequest>,
) -> Response {
    let request_id = request_id();
    let identity = match editor_identity(&state.config, &headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    let folder = match visible_media_folder(&state.config, &identity, &query) {
        Ok(folder) => folder,
        Err(error) => return error.with_request_id(request_id).into_response(),
    };
    let expected_media_type = folder_media_type(&folder);
    if expected_media_type == "collection" {
        return ApiError::new(
            StatusCode::CONFLICT,
            "folder_sidecar_unsupported",
            "This folder groups other media folders and does not have a media sidecar of its own.",
            request_id,
        )
        .into_response();
    }
    if expected_media_type == "book" {
        return ApiError::new(
            StatusCode::CONFLICT,
            "embedded_book_metadata_required",
            "Kavita ignores external OPF sidecars. Edit the metadata embedded in the EPUB, comic archive, or PDF with a compatible tool.",
            request_id,
        )
        .into_response();
    }
    if let Err(error) = validate_metadata_request(&request) {
        return error.with_request_id(request_id).into_response();
    }
    if request.media_type.as_deref().unwrap_or(expected_media_type) != expected_media_type {
        return ApiError::new(
            StatusCode::CONFLICT,
            "metadata_type_mismatch",
            "The metadata type does not match the selected folder.",
            request_id,
        )
        .into_response();
    }
    let (destination_relative_path, extension, contents) =
        folder_metadata_sidecar(&folder, &request);
    let prepared = match prepare_metadata_action(
        &state.config,
        &identity,
        &folder.root_id,
        destination_relative_path,
        extension,
        &contents,
        &request_id,
    )
    .await
    {
        Ok(prepared) => prepared,
        Err(error) => return error.into_response(),
    };
    let pseudo_item = CatalogItem {
        id: format!("folder:{}:{}", folder.root_id, folder.relative_path),
        root_id: folder.root_id,
        owner_username: None,
        relative_path: folder.relative_path,
        media_kind: folder.category,
        size_bytes: 0,
        modified_ns: 0,
        fingerprint: String::new(),
    };
    let mut catalog = match state.catalog.open() {
        Ok(catalog) => catalog,
        Err(_) => {
            let _ = tokio::fs::remove_file(prepared.staging_path).await;
            return ApiError::internal(request_id).into_response();
        }
    };
    match create_metadata_plan(
        &state,
        &identity,
        &mut catalog,
        &pseudo_item,
        &request,
        prepared.action,
        request_id.clone(),
    ) {
        Ok(response) => response,
        Err(error) => {
            let _ = tokio::fs::remove_file(prepared.staging_path).await;
            error.into_response()
        }
    }
}

fn filename_metadata(item: &CatalogItem) -> Value {
    let filename = item
        .relative_path
        .rsplit('/')
        .next()
        .unwrap_or(&item.relative_path);
    let stem = filename
        .rsplit_once('.')
        .map(|(stem, _)| stem)
        .unwrap_or(filename);
    let mut title = stem.to_string();
    let mut year = Value::Null;
    let mut media_type = match item.media_kind.as_str() {
        "music" => "music",
        "audiobook" => "audiobook",
        "podcast" => "podcast",
        "book" => "book",
        _ => "movie",
    };
    let mut series = Value::Null;
    let mut season = Value::Null;
    let mut episode = Value::Null;
    let mut episode_title = Value::Null;
    if item.media_kind == "video" {
        if let Some((marker_start, marker_end)) = split_episode_marker(stem) {
            media_type = "episode";
            let marker = &stem[marker_start..marker_end];
            let digits = marker.trim_start_matches(['S', 's']);
            if let Some((season_text, episode_text)) = digits.split_once(['E', 'e']) {
                season = season_text
                    .parse::<u32>()
                    .map(Value::from)
                    .unwrap_or(Value::Null);
                episode = episode_text
                    .parse::<u32>()
                    .map(Value::from)
                    .unwrap_or(Value::Null);
            }
            let prefix = stem[..marker_start].trim().trim_end_matches('-').trim();
            let suffix_title = stem[marker_end..].trim().trim_start_matches('-').trim();
            let (series_title, parsed_year) = strip_trailing_year(prefix);
            series = Value::String(series_title.to_string());
            title = if suffix_title.is_empty() {
                series_title.to_string()
            } else {
                suffix_title.to_string()
            };
            episode_title = Value::String(title.clone());
            year = parsed_year.map(Value::from).unwrap_or(Value::Null);
        } else {
            let (parsed_title, parsed_year) = strip_trailing_year(stem);
            title = parsed_title.to_string();
            year = parsed_year.map(Value::from).unwrap_or(Value::Null);
        }
    }
    json!({
        "mediaType": media_type, "title": title, "year": year, "series": series,
        "season": season, "episode": episode, "episodeTitle": episode_title,
        "description": null, "publisher": null, "language": null, "genres": [],
        "writers": [], "premiereDate": null, "runtimeMinutes": null,
        "officialRating": null, "communityRating": null, "providerIds": {},
        "videoStreams": [], "audioStreams": [], "subtitleStreams": [],
        "sources": ["filename"]
    })
}

fn split_episode_marker(stem: &str) -> Option<(usize, usize)> {
    let bytes = stem.as_bytes();
    for index in 0..bytes.len() {
        if !matches!(bytes[index], b'S' | b's') {
            continue;
        }
        let season_start = index + 1;
        let mut cursor = season_start;
        while cursor < bytes.len() && bytes[cursor].is_ascii_digit() && cursor - season_start < 3 {
            cursor += 1;
        }
        if cursor == season_start || cursor >= bytes.len() || !matches!(bytes[cursor], b'E' | b'e')
        {
            continue;
        }
        cursor += 1;
        let episode_start = cursor;
        while cursor < bytes.len() && bytes[cursor].is_ascii_digit() && cursor - episode_start < 4 {
            cursor += 1;
        }
        if cursor > episode_start {
            return Some((index, cursor));
        }
    }
    None
}

fn strip_trailing_year(value: &str) -> (&str, Option<u16>) {
    if value.len() >= 7 && value.ends_with(')') {
        let start = value.len() - 6;
        if value.as_bytes().get(start) == Some(&b'(') {
            if let Ok(year) = value[start + 1..value.len() - 1].parse::<u16>() {
                return (value[..start].trim(), Some(year));
            }
        }
    }
    (value.trim(), None)
}

pub(super) async fn cached_application_metadata(
    cache_file: &FilePath,
    item: &CatalogItem,
    allow_folder_prefix: bool,
) -> Option<Value> {
    let cache = load_application_metadata_cache(cache_file).await?;
    cached_application_metadata_entry(&cache, item, allow_folder_prefix)
}

struct ApplicationMetadataCaches {
    jellyfin: Option<Value>,
    audiobookshelf: Option<Value>,
    kavita: Option<Value>,
}

impl ApplicationMetadataCaches {
    async fn load(config: &AppConfig, items: &[CatalogItem]) -> Self {
        let uses_jellyfin = items.iter().any(|item| {
            ["video", "music", "audiobook", "podcast", "book"].contains(&item.media_kind.as_str())
        });
        let uses_audiobookshelf = items
            .iter()
            .any(|item| matches!(item.media_kind.as_str(), "audiobook" | "podcast"));
        let uses_kavita = items.iter().any(|item| item.media_kind == "book");
        let jellyfin = async {
            match (
                uses_jellyfin,
                config.jellyfin_metadata_cache_file.as_deref(),
            ) {
                (true, Some(path)) => load_application_metadata_cache(path).await,
                _ => None,
            }
        };
        let audiobookshelf = async {
            match (
                uses_audiobookshelf,
                config.audiobookshelf_metadata_cache_file.as_deref(),
            ) {
                (true, Some(path)) => load_application_metadata_cache(path).await,
                _ => None,
            }
        };
        let kavita = async {
            match (uses_kavita, config.kavita_metadata_cache_file.as_deref()) {
                (true, Some(path)) => load_application_metadata_cache(path).await,
                _ => None,
            }
        };
        let (jellyfin, audiobookshelf, kavita) = tokio::join!(jellyfin, audiobookshelf, kavita);
        Self {
            jellyfin,
            audiobookshelf,
            kavita,
        }
    }
}

async fn load_application_metadata_cache(cache_file: &FilePath) -> Option<Value> {
    const MAX_CACHE_BYTES: u64 = 16 * 1024 * 1024;
    const MAX_CACHE_AGE_SECONDS: u64 = 2 * 60 * 60;
    let metadata = tokio::fs::symlink_metadata(cache_file).await.ok()?;
    if metadata.file_type().is_symlink() || !metadata.is_file() || metadata.len() > MAX_CACHE_BYTES
    {
        return None;
    }
    if SystemTime::now()
        .duration_since(metadata.modified().ok()?)
        .ok()?
        .as_secs()
        > MAX_CACHE_AGE_SECONDS
    {
        return None;
    }
    let bytes = tokio::fs::read(cache_file).await.ok()?;
    let cache: Value = serde_json::from_slice(&bytes).ok()?;
    if cache.get("schemaVersion")?.as_u64()? != 1 {
        return None;
    }
    cache.get("entries")?.as_array()?;
    Some(cache)
}

fn cached_application_metadata_entry(
    cache: &Value,
    item: &CatalogItem,
    allow_folder_prefix: bool,
) -> Option<Value> {
    cache
        .get("entries")?
        .as_array()?
        .iter()
        .filter(|entry| {
            entry.get("rootId").and_then(Value::as_str) == Some(item.root_id.as_str())
                && entry.get("ownerUsername").and_then(Value::as_str)
                    == item.owner_username.as_deref()
        })
        .filter(|entry| {
            let Some(relative_path) = entry.get("relativePath").and_then(Value::as_str) else {
                return false;
            };
            relative_path == item.relative_path
                || (allow_folder_prefix
                    && !relative_path.is_empty()
                    && item
                        .relative_path
                        .strip_prefix(relative_path)
                        .is_some_and(|suffix| suffix.starts_with('/')))
        })
        .max_by_key(|entry| {
            entry
                .get("relativePath")
                .and_then(Value::as_str)
                .map(str::len)
                .unwrap_or_default()
        })
        .cloned()
}

fn merge_metadata(
    base: &mut Value,
    entry: &Value,
    source: &str,
    field_sources: &mut std::collections::BTreeMap<String, String>,
) {
    let Some(base) = base.as_object_mut() else {
        return;
    };
    let Some(entry) = entry.as_object() else {
        return;
    };
    const FIELDS: &[&str] = &[
        "mediaType",
        "title",
        "subtitle",
        "year",
        "authors",
        "narrators",
        "series",
        "volumeNumber",
        "isbn",
        "season",
        "episode",
        "episodeTitle",
        "description",
        "publisher",
        "language",
        "genres",
        "writers",
        "premiereDate",
        "runtimeMinutes",
        "officialRating",
        "communityRating",
        "providerIds",
        "trackNumber",
        "trackTotal",
        "discNumber",
        "discTotal",
        "tags",
        "chapters",
        "audioFiles",
        "ebookFile",
        "publishedDate",
        "explicit",
        "ageRating",
        "publicationStatus",
        "fieldLocks",
        "videoStreams",
        "audioStreams",
        "subtitleStreams",
    ];
    for field in FIELDS {
        if let Some(value) = entry.get(*field).filter(|value| !value.is_null()) {
            base.insert((*field).to_string(), value.clone());
            field_sources.insert((*field).to_string(), source.to_string());
        }
    }
}
