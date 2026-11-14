use std::path::{Path, PathBuf};

use serde_json::{Map, Value};

use super::ExtractedDocument;
use crate::config::SourceConfig;
use crate::timeutil::{parse_date, sha256_hex};

/// Upper bound on a single document body. Media descriptions are already
/// bounded by the exporting services, but a malformed snapshot must never
/// inflate the index or a query's memory use.
const BODY_LIMIT: usize = 2_000_000;

/// Indexes a Media Manager metadata snapshot.
///
/// Media Manager already exports bounded, read-only JSON snapshots of the
/// Jellyfin, Audiobookshelf, and Kavita libraries (titles, descriptions,
/// authors, narrators, genres, tags, …). Reading those snapshots lets Search
/// pick up catalogue metadata from every media application without needing
/// per-application credentials, APIs, or direct database access.
/// Kavita snapshots also locate book files beneath configured read-only roots.
///
/// All three snapshots share the same envelope:
/// `{ "schemaVersion": 1, "observedAt": <epoch>, "entries": [ … ] }`.
pub struct MediaSnapshotExtractor {
    pub pdftotext: Option<PathBuf>,
}

/// Reads one scalar metadata field as a trimmed, non-empty string.
fn string_field(entry: &Value, key: &str) -> Option<String> {
    entry
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

/// Reads an integer metadata field, tolerating numeric strings.
fn number_field(entry: &Value, key: &str) -> Option<i64> {
    match entry.get(key) {
        Some(Value::Number(number)) => number.as_i64(),
        Some(Value::String(text)) => text.trim().parse().ok(),
        _ => None,
    }
}

/// Reads a list field whose items are strings or `{ "name": … }` objects,
/// deduplicated and trimmed. Handles the shape differences between the
/// Jellyfin (`writers`, `genres`), Audiobookshelf (`authors`, `narrators`),
/// and Kavita (`authors`, `writers`, `genres`, `tags`) exports.
fn string_list(entry: &Value, key: &str) -> Vec<String> {
    string_list_by(entry, key, "name")
}

/// As `string_list`, naming the object field that holds each item's text.
fn string_list_by(entry: &Value, key: &str, field: &str) -> Vec<String> {
    let Some(items) = entry.get(key).and_then(Value::as_array) else {
        return Vec::new();
    };
    let mut values: Vec<String> = Vec::new();
    for item in items {
        let value = match item {
            Value::String(text) => text.trim().to_string(),
            Value::Object(map) => map
                .get(field)
                .and_then(Value::as_str)
                .map(str::trim)
                .unwrap_or_default()
                .to_string(),
            _ => continue,
        };
        if !value.is_empty() && !values.contains(&value) {
            values.push(value);
        }
    }
    values
}

/// The publication year. Some exporters write a full `YYYYMMDD` date into the
/// year field; read its year rather than indexing "the year 20130301".
fn publication_year(entry: &Value) -> Option<i64> {
    let raw = number_field(entry, "year")?;
    let year = if (10_000_101..=99_991_231).contains(&raw) {
        raw / 10_000
    } else {
        raw
    };
    (1000..=2200).contains(&year).then_some(year)
}

/// English names for the language codes media files carry (ISO 639-1 and both
/// ISO 639-2 forms), so "english subtitles" finds a stream tagged `eng`.
fn language_name(code: &str) -> Option<&'static str> {
    Some(match code.trim().to_ascii_lowercase().as_str() {
        "en" | "eng" => "English",
        "fr" | "fre" | "fra" => "French",
        "de" | "ger" | "deu" => "German",
        "es" | "spa" => "Spanish",
        "it" | "ita" => "Italian",
        "pt" | "por" => "Portuguese",
        "nl" | "dut" | "nld" => "Dutch",
        "sv" | "swe" => "Swedish",
        "no" | "nor" | "nob" => "Norwegian",
        "da" | "dan" => "Danish",
        "fi" | "fin" => "Finnish",
        "is" | "ice" | "isl" => "Icelandic",
        "pl" | "pol" => "Polish",
        "cs" | "cze" | "ces" => "Czech",
        "sk" | "slo" | "slk" => "Slovak",
        "hu" | "hun" => "Hungarian",
        "ro" | "rum" | "ron" => "Romanian",
        "bg" | "bul" => "Bulgarian",
        "hr" | "hrv" => "Croatian",
        "sr" | "srp" => "Serbian",
        "sl" | "slv" => "Slovenian",
        "el" | "gre" | "ell" => "Greek",
        "ru" | "rus" => "Russian",
        "uk" | "ukr" => "Ukrainian",
        "tr" | "tur" => "Turkish",
        "ar" | "ara" => "Arabic",
        "he" | "heb" => "Hebrew",
        "fa" | "per" | "fas" => "Persian",
        "hi" | "hin" => "Hindi",
        "ta" | "tam" => "Tamil",
        "th" | "tha" => "Thai",
        "vi" | "vie" => "Vietnamese",
        "id" | "ind" => "Indonesian",
        "ms" | "may" | "msa" => "Malay",
        "zh" | "chi" | "zho" | "cmn" => "Chinese",
        "yue" => "Cantonese",
        "ja" | "jpn" => "Japanese",
        "ko" | "kor" => "Korean",
        "la" | "lat" => "Latin",
        "et" | "est" => "Estonian",
        "lv" | "lav" => "Latvian",
        "lt" | "lit" => "Lithuanian",
        "ca" | "cat" => "Catalan",
        _ => return None,
    })
}

/// Distinct language names across one kind of stream, in stream order.
fn stream_languages(entry: &Value, key: &str) -> Vec<String> {
    let mut names: Vec<String> = Vec::new();
    for stream in entry
        .get(key)
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        if let Some(name) = string_field(stream, "language")
            .as_deref()
            .and_then(language_name)
            && !names.iter().any(|existing| existing == name)
        {
            names.push(name.to_string());
        }
    }
    names
}

/// Describes the main video stream the way people ask for it: "1080p HD",
/// "4K UHD HDR".
fn resolution(entry: &Value) -> Option<String> {
    let stream = entry.get("videoStreams")?.as_array()?.first()?;
    let width = number_field(stream, "width").unwrap_or(0);
    let height = number_field(stream, "height").unwrap_or(0);
    let mut label = if width >= 3800 || height >= 2000 {
        "4K 2160p UHD".to_string()
    } else if width >= 1900 || height >= 1000 {
        "1080p HD".to_string()
    } else if width >= 1260 || height >= 700 {
        "720p HD".to_string()
    } else if height > 0 {
        format!("{height}p SD")
    } else {
        return None;
    };
    if string_field(stream, "videoRange").is_some_and(|range| !range.eq_ignore_ascii_case("SDR")) {
        label.push_str(" HDR");
    }
    Some(label)
}

/// External catalogue ids: the exporter's provider ids plus ids embedded in
/// the folder name (`[tvdbid-72995]`), keyed by lowercase provider.
fn provider_ids(entry: &Value) -> Vec<(String, String)> {
    let mut ids: Vec<(String, String)> = Vec::new();
    let add = |provider: &str, id: &str, ids: &mut Vec<(String, String)>| {
        let provider = provider.trim().to_ascii_lowercase();
        let id = id.trim();
        // Free-form links and empty placeholders are not identifiers.
        if !provider.is_empty()
            && !id.is_empty()
            && id.len() <= 40
            && !id.contains(char::is_whitespace)
            && !id.contains("://")
            && !ids.iter().any(|(existing, _)| existing == &provider)
        {
            ids.push((provider, id.to_string()));
        }
    };
    if let Some(map) = entry.get("providerIds").and_then(Value::as_object) {
        for (provider, id) in map {
            match id {
                Value::String(text) => add(provider, text, &mut ids),
                Value::Number(number) => add(provider, &number.to_string(), &mut ids),
                _ => {}
            }
        }
    }
    if let Some(isbn) = string_field(entry, "isbn") {
        add("isbn", &isbn, &mut ids);
    }
    let path = string_field(entry, "relativePath").unwrap_or_default();
    for provider in ["imdb", "tmdb", "tvdb"] {
        let marker = format!("[{provider}id-");
        if let Some(start) = path.to_ascii_lowercase().find(&marker) {
            let rest = &path[start + marker.len()..];
            if let Some(end) = rest.find(']') {
                add(provider, &rest[..end], &mut ids);
            }
        }
    }
    ids
}

fn provider_label(provider: &str) -> String {
    match provider {
        "imdb" => "IMDb".to_string(),
        "tmdb" => "TMDb".to_string(),
        "tvdb" => "TVDB".to_string(),
        "isbn" => "ISBN".to_string(),
        "asin" => "ASIN".to_string(),
        other => other.to_string(),
    }
}

/// Kavita reports publication status as a number.
fn publication_status(entry: &Value) -> Option<String> {
    if let Some(text) = string_field(entry, "publicationStatus") {
        return Some(text);
    }
    Some(
        match number_field(entry, "publicationStatus")? {
            0 => "Ongoing",
            1 => "On hiatus",
            2 => "Completed",
            3 => "Cancelled",
            4 => "Ended",
            _ => return None,
        }
        .to_string(),
    )
}

/// Creators for the entry. Audiobook libraries are filed as
/// `Author/Title` or `Author/Series/Title`; when the item carries no author
/// metadata the top folder is the best available evidence of one.
fn authors(entry: &Value) -> Vec<String> {
    let listed = string_list(entry, "authors");
    if !listed.is_empty() || string_field(entry, "mediaType").as_deref() != Some("audiobook") {
        return listed;
    }
    let path = string_field(entry, "relativePath").unwrap_or_default();
    let mut parts = path.split('/').filter(|part| !part.is_empty());
    match (parts.next(), parts.next()) {
        // Underscore folders are this library's own groupings, not people.
        (Some(folder), Some(_)) if !folder.starts_with('_') => vec![folder.trim().to_string()],
        _ => Vec::new(),
    }
}

/// `S07E04` for an episode with both coordinates.
fn episode_code(entry: &Value) -> Option<String> {
    match (
        number_field(entry, "season"),
        number_field(entry, "episode"),
    ) {
        (Some(season), Some(episode)) => Some(format!("S{season:02}E{episode:02}")),
        _ => None,
    }
}

/// An episode title that only repeats its series and number ("Sherlock Holmes
/// S03E34 -") says nothing; return what remains once those are removed.
fn distinct_episode_title(title: &str, series: Option<&str>, code: Option<&str>) -> Option<String> {
    let mut rest = title.trim();
    if let Some(series) = series
        && rest.len() >= series.len()
        && rest.is_char_boundary(series.len())
        && rest[..series.len()].eq_ignore_ascii_case(series)
    {
        rest = &rest[series.len()..];
    }
    let separators = |ch: char| ch.is_whitespace() || matches!(ch, '-' | '–' | '—' | ':' | '.');
    rest = rest.trim_matches(separators);
    if let Some(code) = code
        && rest.len() >= code.len()
        && rest.is_char_boundary(code.len())
        && rest[..code.len()].eq_ignore_ascii_case(code)
    {
        rest = &rest[code.len()..];
    }
    rest = rest.trim_matches(separators);
    (!rest.is_empty()).then(|| rest.to_string())
}

fn scalar_metadata(map: &mut Map<String, Value>, key: &str, value: Option<String>) {
    if let Some(value) = value {
        map.insert(key.to_string(), Value::String(value));
    }
}

fn list_metadata(map: &mut Map<String, Value>, key: &str, values: Vec<String>) {
    if !values.is_empty() {
        map.insert(key.to_string(), Value::from(values));
    }
}

fn series_name(entry: &Value) -> Option<String> {
    string_field(entry, "series")
        .or_else(|| string_field(entry, "seriesName"))
        .or_else(|| string_list(entry, "series").into_iter().next())
}

/// Composes the human-readable title, folding Jellyfin episode coordinates
/// into the title so search results read "Series S01E02 — Episode".
fn display_title(entry: &Value) -> String {
    let media_type = string_field(entry, "mediaType");
    let title = string_field(entry, "title")
        .or_else(|| string_field(entry, "episodeTitle"))
        .or_else(|| series_name(entry))
        .or_else(|| string_field(entry, "name"))
        .or_else(|| {
            string_field(entry, "relativePath").and_then(|path| {
                Path::new(&path)
                    .file_stem()
                    .map(|name| name.to_string_lossy().replace('_', " "))
            })
        })
        .unwrap_or_else(|| "(untitled)".to_string());
    let series = series_name(entry);
    if media_type.as_deref() == Some("episode") {
        let code = episode_code(entry);
        let episode = distinct_episode_title(&title, series.as_deref(), code.as_deref());
        return match (series, code, episode) {
            (Some(series), Some(code), Some(episode)) => format!("{series} {code} — {episode}"),
            (Some(series), Some(code), None) => format!("{series} {code}"),
            (Some(series), None, Some(episode)) => format!("{series} — {episode}"),
            (Some(series), None, None) => series,
            (None, _, _) => title,
        };
    }
    title
}

/// Builds the searchable body from every descriptive field in the snapshot, so
/// a query for an author, narrator, series, genre, language, rating or
/// catalogue id matches even when the description does not mention it. Each
/// line is labelled in plain words: the label is what people type ("english
/// subtitles", "season 7"), and it makes the excerpt readable.
fn build_body(entry: &Value) -> String {
    let mut parts: Vec<String> = Vec::new();
    let list = |label: &str, values: Vec<String>| {
        (!values.is_empty()).then(|| format!("{label}: {}", values.join(", ")))
    };
    if let Some(series) = series_name(entry) {
        let mut line = match string_field(entry, "volumeNumber") {
            Some(volume) => format!("Series: {series}, volume {volume}"),
            None => format!("Series: {series}"),
        };
        match (
            number_field(entry, "season"),
            number_field(entry, "episode"),
        ) {
            (Some(season), Some(episode)) => line.push_str(&format!(
                " — Season {season}, Episode {episode} (S{season:02}E{episode:02})"
            )),
            (Some(season), None) => line.push_str(&format!(" — Season {season}")),
            _ => {}
        }
        parts.push(line);
    }
    let creators = authors(entry);
    let writers: Vec<String> = string_list(entry, "writers")
        .into_iter()
        .filter(|writer| !creators.contains(writer))
        .collect();
    parts.extend(list("By", creators));
    parts.extend(list("Written by", writers));
    parts.extend(list("Narrated by", string_list(entry, "narrators")));
    parts.extend(list("Genres", string_list(entry, "genres")));
    parts.extend(list("Tags", string_list(entry, "tags")));
    if let Some(publisher) = string_field(entry, "publisher") {
        parts.push(format!("Publisher: {publisher}"));
    }
    if let Some(year) = publication_year(entry) {
        parts.push(format!("Released: {year}"));
    }
    if let Some(language) = string_field(entry, "language") {
        parts.push(match language_name(&language) {
            Some(name) => format!("Language: {name}"),
            None => format!("Language: {language}"),
        });
    }
    if let Some(rating) = string_field(entry, "officialRating") {
        parts.push(format!("Rated: {rating}"));
    }
    if let Some(status) = publication_status(entry) {
        parts.push(format!("Status: {status}"));
    }
    if let Some(minutes) = number_field(entry, "runtimeMinutes").filter(|minutes| *minutes > 0) {
        parts.push(format!("Runtime: {minutes} minutes"));
    }
    parts.extend(list("Audio", stream_languages(entry, "audioStreams")));
    parts.extend(list(
        "Subtitles",
        stream_languages(entry, "subtitleStreams"),
    ));
    if let Some(resolution) = resolution(entry) {
        parts.push(format!("Video: {resolution}"));
    }
    let ids: Vec<String> = provider_ids(entry)
        .into_iter()
        .map(|(provider, id)| format!("{} {id}", provider_label(&provider)))
        .collect();
    if !ids.is_empty() {
        parts.push(ids.join(" · "));
    }
    let chapters: Vec<String> = string_list_by(entry, "chapters", "title")
        .into_iter()
        .take(200)
        .collect();
    parts.extend(list("Chapters", chapters));
    parts.push(string_field(entry, "subtitle").unwrap_or_default());
    parts.push(string_field(entry, "description").unwrap_or_default());
    let mut body: String = parts
        .into_iter()
        .filter(|part| !part.trim().is_empty())
        .collect::<Vec<_>>()
        .join("\n");
    if body.len() > BODY_LIMIT {
        let mut boundary = BODY_LIMIT;
        while boundary > 0 && !body.is_char_boundary(boundary) {
            boundary -= 1;
        }
        body.truncate(boundary);
    }
    body
}

/// Derives the record timestamp: an explicit publication/premiere date wins,
/// otherwise the publication year is treated as January 1 of that year.
fn created_at(entry: &Value) -> Option<i64> {
    for key in ["publishedDate", "premiereDate", "releaseDate"] {
        if let Some(raw) = string_field(entry, key)
            && let Some(timestamp) = parse_date(&raw)
        {
            return Some(timestamp);
        }
    }
    // A full date written into the year field keeps its month and day.
    if let Some(raw) = number_field(entry, "year").filter(|raw| *raw > 9999) {
        let date = format!(
            "{:04}-{:02}-{:02}",
            raw / 10_000,
            raw / 100 % 100,
            raw % 100
        );
        if let Some(timestamp) = parse_date(&date) {
            return Some(timestamp);
        }
    }
    publication_year(entry).and_then(|year| parse_date(&format!("{year:04}-01-01")))
}

/// Owner facet value: the per-user root owner, or the shared sentinel when the
/// snapshot marks the entry as shared (`ownerUsername` is null).
fn owner_of(entry: &Value) -> String {
    string_field(entry, "ownerUsername").unwrap_or_else(|| "shared".to_string())
}

/// Stable external id for the entry, preferring the origin application's item
/// id and falling back to the root-relative path.
fn external_id(entry: &Value, title: &str) -> String {
    if let Some(item_id) = string_field(entry, "itemId") {
        return item_id;
    }
    let root = string_field(entry, "rootId").unwrap_or_default();
    let relative = string_field(entry, "relativePath").unwrap_or_default();
    sha256_hex(&[&root, &relative, title])
}

impl MediaSnapshotExtractor {
    fn snapshot_path(source: &SourceConfig) -> Result<PathBuf, String> {
        source
            .setting_str("snapshotPath")
            .map(PathBuf::from)
            .ok_or_else(|| {
                "media-snapshot source is missing required setting 'snapshotPath'".to_string()
            })
    }

    fn load_entries(path: &PathBuf) -> Result<Vec<Value>, String> {
        // A missing or unreadable snapshot is an error, not an empty result:
        // returning an empty set would make the indexer prune every document
        // from this source whenever an export is briefly unavailable.
        let raw = std::fs::read_to_string(path)
            .map_err(|err| format!("failed to read media snapshot {}: {err}", path.display()))?;
        let parsed: Value = serde_json::from_str(&raw)
            .map_err(|err| format!("invalid media snapshot {}: {err}", path.display()))?;
        let entries = parsed
            .get("entries")
            .and_then(Value::as_array)
            .or_else(|| parsed.as_array())
            .ok_or_else(|| {
                format!(
                    "media snapshot {} must contain an entries array",
                    path.display()
                )
            })?;
        Ok(entries.clone())
    }
}

/// Fingerprints the snapshot and referenced book files (path, size, mtime)
/// plus the source settings. Book changes count even when the application has
/// not refreshed its metadata snapshot. Missing or unreadable inputs return
/// `None`, so extraction runs and reports the error rather than skipping it.
pub(crate) fn source_fingerprint(source: &SourceConfig) -> Option<String> {
    let path = source.setting_str("snapshotPath").map(PathBuf::from)?;
    if !path.is_file() {
        return None;
    }
    let mut files = std::collections::HashSet::from([path.clone()]);
    let books = super::book_files::BookFiles::new(source, None);
    if books.enabled() {
        for entry in MediaSnapshotExtractor::load_entries(&path).ok()? {
            files.extend(books.paths(&entry).ok()?);
        }
    }
    super::file_inventory_fingerprint(source, files)
}

impl super::Extractor for MediaSnapshotExtractor {
    fn extract(
        &self,
        source: &SourceConfig,
        emit: &mut dyn FnMut(ExtractedDocument),
    ) -> Result<(), String> {
        let path = Self::snapshot_path(source)?;
        let entries = Self::load_entries(&path)?;
        let app_base = source.app_base.trim_end_matches('/').to_string();
        let fallback_type = source
            .setting_str("contentType")
            .unwrap_or("application/octet-stream")
            .to_string();
        let mut books = super::book_files::BookFiles::new(source, self.pdftotext.as_deref());
        let mut book_failure = None;

        for entry in &entries {
            let title = display_title(entry);
            let media_type = string_field(entry, "mediaType");
            let owner = owner_of(entry);
            let relative_path = string_field(entry, "relativePath").unwrap_or_default();

            let mut metadata = Map::new();
            metadata.insert("owner".to_string(), Value::String(owner));
            scalar_metadata(&mut metadata, "series", series_name(entry));
            let creators = authors(entry);
            let writers: Vec<String> = string_list(entry, "writers")
                .into_iter()
                .filter(|writer| !creators.contains(writer))
                .collect();
            list_metadata(&mut metadata, "authors", creators);
            list_metadata(&mut metadata, "writers", writers);
            list_metadata(&mut metadata, "narrators", string_list(entry, "narrators"));
            list_metadata(&mut metadata, "genres", string_list(entry, "genres"));
            list_metadata(&mut metadata, "tags", string_list(entry, "tags"));
            scalar_metadata(
                &mut metadata,
                "year",
                publication_year(entry).map(|y| y.to_string()),
            );
            scalar_metadata(&mut metadata, "publisher", string_field(entry, "publisher"));
            scalar_metadata(&mut metadata, "language", string_field(entry, "language"));
            for key in ["season", "episode"] {
                if let Some(number) = number_field(entry, key) {
                    metadata.insert(key.to_string(), Value::from(number));
                }
            }
            scalar_metadata(
                &mut metadata,
                "runtime",
                number_field(entry, "runtimeMinutes")
                    .filter(|minutes| *minutes > 0)
                    .map(|minutes| format!("{minutes} min")),
            );
            scalar_metadata(
                &mut metadata,
                "rated",
                string_field(entry, "officialRating"),
            );
            if let Some(rating) = entry.get("communityRating").and_then(Value::as_f64) {
                metadata.insert(
                    "community_rating".to_string(),
                    Value::from((rating * 10.0).round() / 10.0),
                );
            }
            list_metadata(
                &mut metadata,
                "audio_languages",
                stream_languages(entry, "audioStreams"),
            );
            list_metadata(
                &mut metadata,
                "subtitle_languages",
                stream_languages(entry, "subtitleStreams"),
            );
            scalar_metadata(&mut metadata, "resolution", resolution(entry));
            scalar_metadata(&mut metadata, "status", publication_status(entry));
            // Exact catalogue ids make a pasted IMDb id or ISBN a top match.
            let ids: Map<String, Value> = provider_ids(entry)
                .into_iter()
                .filter(|(provider, _)| matches!(provider.as_str(), "imdb" | "isbn" | "asin"))
                .map(|(provider, id)| (provider, Value::String(id)))
                .collect();
            if !ids.is_empty() {
                metadata.insert("identifiers".to_string(), Value::Object(ids));
            }
            if let Err(err) = books.extract(entry, &title, &metadata, emit) {
                eprintln!("search: book file extraction failed: {err}");
                book_failure = Some(err);
            }

            emit(ExtractedDocument {
                external_id: external_id(entry, &title),
                kind: media_type.clone().unwrap_or_else(|| {
                    if fallback_type == "book" {
                        "book"
                    } else {
                        "media"
                    }
                    .to_string()
                }),
                title,
                body_text: build_body(entry),
                content_type: media_type.unwrap_or_else(|| fallback_type.clone()),
                origin_url: String::new(),
                app_url: app_base.clone(),
                file_path: relative_path,
                size_bytes: 0,
                content_created_at: created_at(entry),
                content_modified_at: None,
                metadata: Value::Object(metadata),
            });
        }
        match book_failure {
            Some(err) => Err(format!("book extraction incomplete: {err}")),
            None => Ok(()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::parse_sources;
    use crate::extract::Extractor;

    fn source(settings: &str) -> SourceConfig {
        parse_sources(&format!(
            r#"[{{"id":"media","source_type":"media-snapshot","app_base":"https://media.example.org","settings":{settings}}}]"#
        ))
        .expect("sources parse")
        .remove(0)
    }

    fn run_with(source: &SourceConfig) -> Result<Vec<ExtractedDocument>, String> {
        let mut docs = Vec::new();
        MediaSnapshotExtractor { pdftotext: None }.extract(source, &mut |doc| docs.push(doc))?;
        Ok(docs)
    }

    fn write_snapshot(entries: &str) -> (tempfile::TempDir, SourceConfig) {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("metadata.json");
        std::fs::write(
            &path,
            format!(r#"{{"schemaVersion":1,"observedAt":1700000000,"entries":{entries}}}"#),
        )
        .expect("write snapshot");
        let source = source(&format!(r#"{{"snapshotPath":"{}"}}"#, path.display()));
        (dir, source)
    }

    #[test]
    fn indexes_audiobook_metadata_into_a_searchable_body() {
        let (_dir, source) = write_snapshot(
            r#"[{
                "rootId":"shared-audiobooks","ownerUsername":null,"relativePath":"Sanderson/Mistborn/book1",
                "itemId":"abs-1","mediaType":"audiobook","title":"The Final Empire",
                "authors":[{"name":"Brandon Sanderson"}],"narrators":[{"name":"Michael Kramer"}],
                "series":[{"name":"Mistborn","sequence":"1"}],"seriesName":"Mistborn",
                "genres":[{"name":"Fantasy"}],"tags":["epic"],
                "publisher":"Macmillan","language":"en","year":2006,
                "description":"A thief crew plans an impossible heist."
            }]"#,
        );
        let docs = run_with(&source).expect("extract");
        assert_eq!(docs.len(), 1);
        let doc = &docs[0];
        assert_eq!(doc.external_id, "abs-1");
        assert_eq!(doc.title, "The Final Empire");
        assert_eq!(doc.content_type, "audiobook");
        assert_eq!(doc.file_path, "Sanderson/Mistborn/book1");
        assert_eq!(doc.metadata["owner"], Value::String("shared".to_string()));
        assert_eq!(
            doc.metadata["authors"],
            Value::from(vec!["Brandon Sanderson"])
        );
        assert!(doc.body_text.contains("Brandon Sanderson"));
        assert!(doc.body_text.contains("Fantasy"));
        assert!(doc.body_text.contains("impossible heist"));
        assert_eq!(doc.content_created_at, Some(1_136_073_600));
    }

    #[test]
    fn composes_episode_titles_and_personal_owners() {
        let (_dir, source) = write_snapshot(
            r#"[{
                "rootId":"personal-videos","ownerUsername":"dsaw","relativePath":"_Shows/Dune/S01E02.mkv",
                "itemId":"jf-2","mediaType":"episode","title":"The Gathering Storm",
                "series":"Dune","season":1,"episode":2,"premiereDate":"2024-02-01",
                "description":"Paul learns the truth."
            }]"#,
        );
        let docs = run_with(&source).expect("extract");
        assert_eq!(docs[0].title, "Dune S01E02 — The Gathering Storm");
        assert_eq!(docs[0].metadata["owner"], Value::String("dsaw".to_string()));
        assert_eq!(docs[0].content_created_at, Some(1_706_745_600));
    }

    #[test]
    fn applies_fallback_content_type_and_item_id() {
        let (_dir, source) = {
            let dir = tempfile::tempdir().expect("tempdir");
            let path = dir.path().join("metadata.json");
            std::fs::write(
                &path,
                r#"{"entries":[{"rootId":"shared-books","ownerUsername":null,"relativePath":"Manga/One Piece/vol1","title":"One Piece","description":"Pirates."}]}"#,
            )
            .expect("write");
            let source = source(&format!(
                r#"{{"snapshotPath":"{}","contentType":"book"}}"#,
                path.display()
            ));
            (dir, source)
        };
        let docs = run_with(&source).expect("extract");
        assert_eq!(docs[0].content_type, "book");
        assert!(!docs[0].external_id.is_empty());
        assert_eq!(docs[0].kind, "book");
    }

    #[test]
    fn rejects_missing_malformed_or_unconfigured_snapshots() {
        let missing = source(r#"{"snapshotPath":"/nonexistent/media/metadata.json"}"#);
        assert!(
            run_with(&missing).is_err(),
            "missing snapshot must not prune documents"
        );

        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("metadata.json");
        std::fs::write(&path, r#"{"schemaVersion":1}"#).expect("write");
        let malformed = source(&format!(r#"{{"snapshotPath":"{}"}}"#, path.display()));
        assert!(
            run_with(&malformed).is_err(),
            "snapshot without entries must be rejected"
        );

        let unconfigured = source("{}");
        assert!(
            run_with(&unconfigured).is_err(),
            "snapshotPath setting is required"
        );
    }

    #[test]
    fn empty_snapshot_emits_nothing() {
        let (_dir, source) = write_snapshot("[]");
        assert!(run_with(&source).expect("extract").is_empty());
    }
}
