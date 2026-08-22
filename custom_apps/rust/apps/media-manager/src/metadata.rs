use crate::{
    broker::open_regular_file_beneath,
    catalog::CatalogItem,
    config::{AppConfig, IntegrationCapability},
};
use lofty::{
    config::ParseOptions,
    file::{FileType, TaggedFileExt},
    probe::Probe,
    tag::{Accessor, ItemKey},
};
use roxmltree::{Document, Node};
use serde::Serialize;
use serde_json::{json, Map, Value};
use std::{
    collections::{BTreeMap, BTreeSet},
    io::{Read, Seek, SeekFrom},
    path::Path,
    time::UNIX_EPOCH,
};
use zip::ZipArchive;
use zip::{write::SimpleFileOptions, CompressionMethod, ZipWriter};

const MAX_SIDECAR_BYTES: u64 = 1024 * 1024;
const MAX_RAW_PREVIEW_BYTES: usize = 64 * 1024;
const MAX_CONTAINER_BYTES: u64 = 512 * 1024 * 1024;
const MAX_ARCHIVE_ENTRIES: usize = 10_000;
const MAX_EMBEDDED_METADATA_BYTES: u64 = 2 * 1024 * 1024;
const MAX_PDF_XMP_SCAN_BYTES: u64 = 8 * 1024 * 1024;

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MetadataObservation {
    pub source: String,
    pub label: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub observed_at: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub relative_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub format: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub app_item_id: Option<String>,
    pub storage: String,
    pub consumed_by: Vec<String>,
    pub survives_rescan: bool,
    pub writable: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub locked: Option<bool>,
    pub fields: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub raw_preview: Option<String>,
}

impl MetadataObservation {
    #[cfg(test)]
    fn for_test(source: &str, fields: Value) -> Self {
        Self {
            source: source.to_string(),
            label: source.to_string(),
            observed_at: None,
            relative_path: None,
            format: None,
            app_item_id: None,
            storage: if source == "filename" {
                "filename"
            } else {
                "application-database"
            }
            .to_string(),
            consumed_by: Vec::new(),
            survives_rescan: source == "filename",
            writable: false,
            locked: None,
            fields,
            raw_preview: None,
        }
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MetadataHealthIssue {
    pub code: String,
    pub severity: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub field: Option<String>,
    pub title: String,
    pub message: String,
    pub sources: Vec<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MetadataModificationTarget {
    pub id: String,
    pub label: String,
    pub kind: String,
    pub available: bool,
    pub recommended: bool,
    pub requires_refresh: bool,
    pub message: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SidecarInspection {
    pub relative_path: String,
    pub format: String,
    pub exists: bool,
    pub can_replace: bool,
    pub consumer_effective: bool,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ConsumerEffect {
    pub id: String,
    pub label: String,
    pub available: bool,
    pub effect: String,
    pub can_manage_natively: bool,
    pub portable_write_supported: bool,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub native_url: Option<String>,
}

pub fn filename_observation(fields: &Value) -> MetadataObservation {
    MetadataObservation {
        source: "filename".to_string(),
        label: "Filename".to_string(),
        observed_at: None,
        relative_path: None,
        format: None,
        app_item_id: None,
        storage: "filename".to_string(),
        consumed_by: Vec::new(),
        survives_rescan: true,
        writable: false,
        locked: None,
        fields: metadata_fields(fields),
        raw_preview: None,
    }
}

pub fn application_observation(source: &str, label: &str, fields: &Value) -> MetadataObservation {
    MetadataObservation {
        source: source.to_string(),
        label: label.to_string(),
        observed_at: fields.get("observedAt").and_then(Value::as_u64),
        relative_path: None,
        format: None,
        app_item_id: fields
            .get("itemId")
            .and_then(Value::as_str)
            .map(str::to_string),
        storage: "application-database".to_string(),
        consumed_by: vec![source.to_string()],
        survives_rescan: fields
            .get("isLocked")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        writable: true,
        locked: fields.get("isLocked").and_then(Value::as_bool),
        fields: metadata_fields(fields),
        raw_preview: None,
    }
}

pub fn item_sidecar_path(item: &CatalogItem, media_type: &str) -> (String, &'static str) {
    let stem = item
        .relative_path
        .rsplit_once('.')
        .map(|(stem, _)| stem)
        .unwrap_or(&item.relative_path);
    match item.media_kind.as_str() {
        "video" => (format!("{stem}.nfo"), "nfo"),
        "music" => (
            item.relative_path
                .rsplit_once('/')
                .map(|(parent, _)| format!("{parent}/album.nfo"))
                .unwrap_or_else(|| "album.nfo".to_string()),
            "nfo",
        ),
        "audiobook" | "podcast" => (
            item.relative_path
                .rsplit_once('/')
                .map(|(parent, _)| format!("{parent}/metadata.opf"))
                .unwrap_or_else(|| "metadata.opf".to_string()),
            "opf",
        ),
        "book" => (format!("{stem}.opf"), "opf"),
        _ if media_type == "music" => (format!("{stem}.nfo"), "nfo"),
        _ => (format!("{stem}.nfo"), "nfo"),
    }
}

pub fn folder_sidecar_path(relative_path: &str, media_type: &str) -> (String, &'static str) {
    match media_type {
        "series" => (format!("{relative_path}/tvshow.nfo"), "nfo"),
        "season" => (format!("{relative_path}/season.nfo"), "nfo"),
        "music" => (format!("{relative_path}/album.nfo"), "nfo"),
        "audiobook" | "podcast" | "book" => (format!("{relative_path}/metadata.opf"), "opf"),
        _ => (format!("{relative_path}/movie.nfo"), "nfo"),
    }
}

pub fn inspect_sidecar(
    root: &Path,
    relative_path: String,
    format: &str,
    consumer_effective: bool,
) -> (SidecarInspection, Option<MetadataObservation>) {
    let mut inspection = SidecarInspection {
        relative_path: relative_path.clone(),
        format: format.to_string(),
        exists: false,
        can_replace: false,
        consumer_effective,
    };
    let Ok(mut file) = open_regular_file_beneath(root, &relative_path) else {
        return (inspection, None);
    };
    let Ok(metadata) = file.metadata() else {
        return (inspection, None);
    };
    if metadata.len() > MAX_SIDECAR_BYTES {
        return (inspection, None);
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    if file
        .by_ref()
        .take(MAX_SIDECAR_BYTES + 1)
        .read_to_end(&mut bytes)
        .is_err()
        || bytes.len() as u64 > MAX_SIDECAR_BYTES
    {
        return (inspection, None);
    }
    let Ok(text) = String::from_utf8(bytes) else {
        return (inspection, None);
    };
    let Ok(fields) = parse_sidecar_fields(&text) else {
        return (inspection, None);
    };
    inspection.exists = true;
    inspection.can_replace = consumer_effective;
    let observed_at = metadata
        .modified()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map(|duration| duration.as_secs());
    let raw_preview = if text.len() <= MAX_RAW_PREVIEW_BYTES {
        text
    } else {
        let mut boundary = MAX_RAW_PREVIEW_BYTES;
        while !text.is_char_boundary(boundary) {
            boundary -= 1;
        }
        format!("{}\n…", &text[..boundary])
    };
    (
        inspection,
        Some(MetadataObservation {
            source: "sidecar".to_string(),
            label: format!("{} sidecar", format.to_ascii_uppercase()),
            observed_at,
            relative_path: Some(relative_path),
            format: Some(format.to_string()),
            app_item_id: None,
            storage: "sidecar-file".to_string(),
            consumed_by: if consumer_effective {
                vec![if format == "opf" {
                    "audiobookshelf"
                } else {
                    "jellyfin"
                }
                .to_string()]
            } else {
                Vec::new()
            },
            survives_rescan: true,
            writable: consumer_effective,
            locked: None,
            fields,
            raw_preview: Some(raw_preview),
        }),
    )
}

pub fn inspect_embedded_metadata(
    root: &Path,
    item: &CatalogItem,
) -> Result<Option<MetadataObservation>, String> {
    let extension = item
        .relative_path
        .rsplit_once('.')
        .map(|(_, extension)| extension.to_ascii_lowercase())
        .unwrap_or_default();
    if matches!(item.media_kind.as_str(), "music" | "audiobook" | "podcast") {
        return inspect_audio_tags(root, item);
    }
    if extension == "pdf" {
        return inspect_pdf_xmp(root, item);
    }
    if !matches!(extension.as_str(), "epub" | "cbz") {
        return Ok(None);
    }
    let file = open_regular_file_beneath(root, &item.relative_path)
        .map_err(|error| format!("open container: {error}"))?;
    let metadata = file
        .metadata()
        .map_err(|error| format!("stat container: {error}"))?;
    if metadata.len() > MAX_CONTAINER_BYTES {
        return Err("container exceeds the bounded metadata inspection limit".to_string());
    }
    let observed_at = metadata
        .modified()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map(|duration| duration.as_secs());
    let mut archive =
        ZipArchive::new(file).map_err(|error| format!("open ZIP container: {error}"))?;
    if archive.len() > MAX_ARCHIVE_ENTRIES {
        return Err("container has too many entries to inspect safely".to_string());
    }
    if archive
        .has_overlapping_files()
        .map_err(|error| format!("inspect ZIP layout: {error}"))?
    {
        return Err("container has overlapping ZIP entries".to_string());
    }
    let (source, label, entry_name, format) = if extension == "epub" {
        let container = read_zip_entry(&mut archive, "META-INF/container.xml")?;
        let document = Document::parse(&container)
            .map_err(|error| format!("parse EPUB container.xml: {error}"))?;
        let package = document
            .descendants()
            .find(|node| {
                node.is_element() && node.tag_name().name().eq_ignore_ascii_case("rootfile")
            })
            .and_then(|node| node.attribute("full-path"))
            .filter(|path| valid_archive_metadata_path(path))
            .ok_or_else(|| "EPUB container.xml has no safe package-document path".to_string())?
            .to_string();
        ("embedded-epub", "Embedded EPUB package", package, "opf")
    } else {
        let comic_info = (0..archive.len())
            .filter_map(|index| archive.name_for_index(index).map(str::to_string))
            .find(|name| !name.contains('/') && name.eq_ignore_ascii_case("ComicInfo.xml"))
            .ok_or_else(|| "CBZ has no root ComicInfo.xml".to_string())?;
        (
            "embedded-comicinfo",
            "Embedded ComicInfo.xml",
            comic_info,
            "comicinfo",
        )
    };
    let raw = read_zip_entry(&mut archive, &entry_name)?;
    let fields = if format == "comicinfo" {
        parse_comicinfo_fields(&raw)?
    } else {
        parse_sidecar_fields(&raw)?
    };
    Ok(Some(MetadataObservation {
        source: source.to_string(),
        label: label.to_string(),
        observed_at,
        relative_path: Some(format!("{}!/{}", item.relative_path, entry_name)),
        format: Some(format.to_string()),
        app_item_id: None,
        storage: "embedded-file".to_string(),
        consumed_by: vec!["kavita".to_string()],
        survives_rescan: true,
        writable: matches!(extension.as_str(), "epub" | "cbz"),
        locked: None,
        fields,
        raw_preview: Some(bounded_preview(raw)),
    }))
}

pub fn rewrite_embedded_metadata(
    input: std::fs::File,
    output: std::fs::File,
    extension: &str,
    generated: &str,
) -> Result<String, String> {
    if !matches!(extension, "epub" | "cbz") {
        return Err("only EPUB and CBZ containers can be rewritten safely".to_string());
    }
    if generated.len() > MAX_EMBEDDED_METADATA_BYTES as usize {
        return Err("generated embedded metadata exceeds the safe edit limit".to_string());
    }
    let mut archive =
        ZipArchive::new(input).map_err(|error| format!("open ZIP container: {error}"))?;
    if archive.len() > MAX_ARCHIVE_ENTRIES {
        return Err("container has too many entries to rewrite safely".to_string());
    }
    if archive
        .has_overlapping_files()
        .map_err(|error| format!("inspect ZIP layout: {error}"))?
    {
        return Err("container has overlapping ZIP entries".to_string());
    }
    validate_archive_entry_names(&archive)?;
    let target = if extension == "epub" {
        let container = read_zip_entry(&mut archive, "META-INF/container.xml")?;
        let document = Document::parse(&container)
            .map_err(|error| format!("parse EPUB container.xml: {error}"))?;
        document
            .descendants()
            .find(|node| {
                node.is_element() && node.tag_name().name().eq_ignore_ascii_case("rootfile")
            })
            .and_then(|node| node.attribute("full-path"))
            .filter(|path| valid_archive_metadata_path(path))
            .ok_or_else(|| "EPUB container.xml has no safe package-document path".to_string())?
            .to_string()
    } else {
        (0..archive.len())
            .filter_map(|index| archive.name_for_index(index).map(str::to_string))
            .find(|name| !name.contains('/') && name.eq_ignore_ascii_case("ComicInfo.xml"))
            .unwrap_or_else(|| "ComicInfo.xml".to_string())
    };
    let matching_entries = (0..archive.len())
        .filter(|index| {
            archive
                .name_for_index(*index)
                .is_some_and(|name| name == target)
        })
        .count();
    if matching_entries > 1 {
        return Err("container has duplicate embedded metadata entries".to_string());
    }
    if extension == "epub" && matching_entries != 1 {
        return Err("EPUB package document is missing".to_string());
    }
    let comment = archive.comment().to_vec();
    let mut writer = ZipWriter::new(output);
    if !comment.is_empty() {
        writer
            .set_raw_comment(comment.into_boxed_slice())
            .map_err(|error| format!("copy ZIP comment: {error}"))?;
    }
    let mut replaced = false;
    for index in 0..archive.len() {
        let name = archive
            .name_for_index(index)
            .unwrap_or_default()
            .to_string();
        if name == target {
            let mut entry = archive
                .by_index(index)
                .map_err(|error| format!("open metadata entry: {error}"))?;
            if entry.size() > MAX_EMBEDDED_METADATA_BYTES {
                return Err("embedded metadata exceeds the safe edit limit".to_string());
            }
            let options = entry.options();
            let mut existing = String::new();
            entry
                .by_ref()
                .take(MAX_EMBEDDED_METADATA_BYTES + 1)
                .read_to_string(&mut existing)
                .map_err(|error| format!("read embedded metadata: {error}"))?;
            let merged = merge_managed_sidecar(&existing, generated)?;
            writer
                .start_file(&target, options)
                .map_err(|error| format!("start metadata entry: {error}"))?;
            std::io::Write::write_all(&mut writer, merged.as_bytes())
                .map_err(|error| format!("write metadata entry: {error}"))?;
            replaced = true;
        } else {
            let entry = archive
                .by_index(index)
                .map_err(|error| format!("open ZIP entry: {error}"))?;
            writer
                .raw_copy_file(entry)
                .map_err(|error| format!("copy ZIP entry: {error}"))?;
        }
    }
    if !replaced {
        writer
            .start_file(
                &target,
                SimpleFileOptions::default().compression_method(CompressionMethod::Deflated),
            )
            .map_err(|error| format!("start ComicInfo.xml: {error}"))?;
        std::io::Write::write_all(&mut writer, generated.as_bytes())
            .map_err(|error| format!("write ComicInfo.xml: {error}"))?;
    }
    let output = writer
        .finish()
        .map_err(|error| format!("finish ZIP container: {error}"))?;
    output
        .sync_all()
        .map_err(|error| format!("sync ZIP container: {error}"))?;
    Ok(target)
}

fn inspect_audio_tags(
    root: &Path,
    item: &CatalogItem,
) -> Result<Option<MetadataObservation>, String> {
    let Some(file_type) = FileType::from_path(&item.relative_path) else {
        return Ok(None);
    };
    let file = open_regular_file_beneath(root, &item.relative_path)
        .map_err(|error| format!("open tagged audio: {error}"))?;
    let metadata = file
        .metadata()
        .map_err(|error| format!("stat tagged audio: {error}"))?;
    let tagged = match Probe::with_file_type(std::io::BufReader::new(file), file_type)
        .options(ParseOptions::new().read_properties(false))
        .read()
    {
        Ok(tagged) => tagged,
        Err(_) => return Ok(None),
    };
    let Some(tag) = tagged.primary_tag().or_else(|| tagged.first_tag()) else {
        return Ok(None);
    };
    let strings = |key: ItemKey| {
        unique_values(
            tag.get_strings(key)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(str::to_string),
        )
    };
    let first = |key: ItemKey| {
        tag.get_string(key)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string)
    };
    let is_podcast = item.media_kind == "podcast";
    let title = if is_podcast {
        tag.title().map(|value| value.into_owned())
    } else {
        tag.album()
            .or_else(|| tag.title())
            .map(|value| value.into_owned())
    };
    let authors = {
        let album = strings(ItemKey::AlbumArtists);
        if album.is_empty() {
            tag.artist()
                .map(|value| vec![value.into_owned()])
                .unwrap_or_default()
        } else {
            album
        }
    };
    let narrators = strings(ItemKey::Performer);
    let description = first(ItemKey::PodcastDescription)
        .or_else(|| first(ItemKey::Description))
        .or_else(|| tag.comment().map(|value| value.into_owned()));
    let genres = tag
        .genre()
        .map(|value| {
            value
                .split([',', ';'])
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(str::to_string)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    let series = if is_podcast {
        first(ItemKey::ShowName)
    } else {
        None
    };
    let mut provider_ids = Map::new();
    if let Some(url) = first(ItemKey::PodcastUrl) {
        provider_ids.insert("podcastUrl".to_string(), Value::String(url));
    }
    if let Some(guid) = first(ItemKey::PodcastGlobalUniqueId) {
        provider_ids.insert("podcastGuid".to_string(), Value::String(guid));
    }
    let fields = metadata_fields(&json!({
        "mediaType": item.media_kind, "title": title, "authors": authors, "narrators": narrators,
        "series": series, "volumeNumber": tag.track().map(|value| value.to_string()),
        "publisher": first(ItemKey::Publisher), "language": first(ItemKey::Language),
        "genres": genres, "description": description, "providerIds": provider_ids,
        "trackNumber": tag.track(), "trackTotal": tag.track_total(), "discNumber": tag.disk(), "discTotal": tag.disk_total(),
    }));
    let observed_at = metadata
        .modified()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map(|duration| duration.as_secs());
    let raw_preview = serde_json::to_string_pretty(&json!({
        "tagType": format!("{:?}", tag.tag_type()), "itemCount": tag.item_count(), "pictureCount": tag.picture_count(),
        "track": tag.track(), "trackTotal": tag.track_total(), "disc": tag.disk(), "discTotal": tag.disk_total(),
    })).ok();
    Ok(Some(MetadataObservation {
        source: "embedded-audio-tags".to_string(),
        label: "Embedded audio tags".to_string(),
        observed_at,
        relative_path: Some(item.relative_path.clone()),
        format: Some(format!("{:?}", tag.tag_type()).to_ascii_lowercase()),
        app_item_id: None,
        storage: "embedded-file".to_string(),
        consumed_by: vec![if is_podcast || item.media_kind == "audiobook" {
            "audiobookshelf"
        } else {
            "jellyfin"
        }
        .to_string()],
        survives_rescan: true,
        writable: false,
        locked: None,
        fields,
        raw_preview,
    }))
}

fn inspect_pdf_xmp(root: &Path, item: &CatalogItem) -> Result<Option<MetadataObservation>, String> {
    let mut file = open_regular_file_beneath(root, &item.relative_path)
        .map_err(|error| format!("open PDF: {error}"))?;
    let metadata = file
        .metadata()
        .map_err(|error| format!("stat PDF: {error}"))?;
    let bytes = if metadata.len() <= MAX_PDF_XMP_SCAN_BYTES {
        let mut bytes = Vec::with_capacity(metadata.len() as usize);
        file.read_to_end(&mut bytes)
            .map_err(|error| format!("read PDF metadata: {error}"))?;
        bytes
    } else {
        let chunk_size = (MAX_PDF_XMP_SCAN_BYTES / 2) as usize;
        let mut bytes = vec![0; chunk_size];
        file.read_exact(&mut bytes)
            .map_err(|error| format!("read PDF header: {error}"))?;
        file.seek(SeekFrom::End(-(chunk_size as i64)))
            .map_err(|error| format!("seek PDF trailer: {error}"))?;
        let mut trailer = vec![0; chunk_size];
        file.read_exact(&mut trailer)
            .map_err(|error| format!("read PDF trailer: {error}"))?;
        bytes.extend_from_slice(&trailer);
        bytes
    };
    let Some(start) = find_bytes(&bytes, b"<x:xmpmeta") else {
        return Ok(None);
    };
    let Some(relative_end) = find_bytes(&bytes[start..], b"</x:xmpmeta>") else {
        return Ok(None);
    };
    let end = start + relative_end + b"</x:xmpmeta>".len();
    let raw = std::str::from_utf8(&bytes[start..end])
        .map_err(|_| "PDF XMP packet is not UTF-8".to_string())?
        .to_string();
    let fields = parse_pdf_xmp_fields(&raw)?;
    let observed_at = metadata
        .modified()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map(|duration| duration.as_secs());
    Ok(Some(MetadataObservation {
        source: "embedded-pdf-xmp".to_string(),
        label: "Embedded PDF XMP".to_string(),
        observed_at,
        relative_path: Some(format!("{}!/XMP", item.relative_path)),
        format: Some("xmp".to_string()),
        app_item_id: None,
        storage: "embedded-file".to_string(),
        consumed_by: vec!["kavita".to_string()],
        survives_rescan: true,
        writable: false,
        locked: None,
        fields,
        raw_preview: Some(bounded_preview(raw)),
    }))
}

fn find_bytes(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

fn parse_pdf_xmp_fields(text: &str) -> Result<Value, String> {
    let document = Document::parse(text).map_err(|error| error.to_string())?;
    let root = document.root_element();
    let values = |name: &str| -> Vec<String> {
        let mut seen = BTreeSet::new();
        root.descendants()
            .filter(|node| node.is_element() && node.tag_name().name().eq_ignore_ascii_case(name))
            .flat_map(|node| node.descendants().filter_map(|child| child.text()))
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .filter(|value| seen.insert(value.to_ascii_lowercase()))
            .map(str::to_string)
            .collect()
    };
    let first = |name: &str| values(name).into_iter().next();
    let date = first("date");
    Ok(metadata_fields(&json!({
        "mediaType": "book", "title": first("title"), "authors": values("creator"),
        "publisher": first("publisher"), "language": first("language"), "genres": values("subject"),
        "description": first("description"), "year": date.as_deref().and_then(|value| value.get(0..4)).and_then(|value| value.parse::<u16>().ok()),
        "isbn": values("identifier").into_iter().find(|value| value.to_ascii_lowercase().contains("isbn")),
    })))
}

fn read_zip_entry<R: Read + Seek>(
    archive: &mut ZipArchive<R>,
    name: &str,
) -> Result<String, String> {
    let mut entry = archive
        .by_name(name)
        .map_err(|_| format!("container entry {name} is missing"))?;
    if !entry.is_file() || entry.size() > MAX_EMBEDDED_METADATA_BYTES {
        return Err(format!(
            "container entry {name} is not a bounded regular file"
        ));
    }
    let mut bytes = Vec::with_capacity(entry.size() as usize);
    entry
        .by_ref()
        .take(MAX_EMBEDDED_METADATA_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| format!("read container entry {name}: {error}"))?;
    if bytes.len() as u64 > MAX_EMBEDDED_METADATA_BYTES {
        return Err(format!(
            "container entry {name} exceeds the inspection limit"
        ));
    }
    String::from_utf8(bytes).map_err(|_| format!("container entry {name} is not UTF-8"))
}

fn valid_archive_metadata_path(path: &str) -> bool {
    !path.is_empty()
        && !path.starts_with('/')
        && !path.contains('\\')
        && path.len() <= 4096
        && path
            .split('/')
            .all(|part| !part.is_empty() && part != "." && part != "..")
}

fn validate_archive_entry_names<R: Read + Seek>(archive: &ZipArchive<R>) -> Result<(), String> {
    for index in 0..archive.len() {
        let name = archive
            .name_for_index(index)
            .ok_or_else(|| "container has an unreadable ZIP entry name".to_string())?;
        let path = name.strip_suffix('/').unwrap_or(name);
        if !valid_archive_metadata_path(path) {
            return Err(format!("container has an unsafe ZIP entry path: {name}"));
        }
    }
    Ok(())
}

fn bounded_preview(text: String) -> String {
    if text.len() <= MAX_RAW_PREVIEW_BYTES {
        return text;
    }
    let mut boundary = MAX_RAW_PREVIEW_BYTES;
    while !text.is_char_boundary(boundary) {
        boundary -= 1;
    }
    format!("{}\n…", &text[..boundary])
}

fn parse_comicinfo_fields(text: &str) -> Result<Value, String> {
    let document = Document::parse(text).map_err(|error| error.to_string())?;
    let root = document.root_element();
    if !root.tag_name().name().eq_ignore_ascii_case("ComicInfo") {
        return Err("ComicInfo.xml has an unexpected root element".to_string());
    }
    let split_values = |name: &str| {
        first_text(root, &[name])
            .into_iter()
            .flat_map(|value| {
                value
                    .split(',')
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .map(str::to_string)
                    .collect::<Vec<_>>()
            })
            .collect::<Vec<_>>()
    };
    let mut provider_ids = Map::new();
    if let Some(web) = first_text(root, &["Web"]) {
        provider_ids.insert("web".to_string(), Value::String(web));
    }
    let year = first_text(root, &["Year"]).and_then(|value| value.parse::<u16>().ok());
    Ok(metadata_fields(&json!({
        "mediaType": "book",
        "title": first_text(root, &["Title"]),
        "year": year,
        "authors": split_values("Writer"),
        "writers": split_values("Writer"),
        "series": first_text(root, &["Series"]),
        "volumeNumber": first_text(root, &["Number"]),
        "publisher": first_text(root, &["Publisher"]),
        "language": first_text(root, &["LanguageISO"]),
        "genres": split_values("Genre"),
        "description": first_text(root, &["Summary"]),
        "providerIds": provider_ids,
    })))
}

pub fn health_issues(
    media_kind: &str,
    effective: &Value,
    observations: &[MetadataObservation],
) -> Vec<MetadataHealthIssue> {
    let mut issues = Vec::new();
    let missing = |field: &str| {
        effective.get(field).is_none_or(|value| {
            value.is_null()
                || value.as_str().is_some_and(|value| value.trim().is_empty())
                || value.as_array().is_some_and(Vec::is_empty)
        })
    };
    if missing("title") {
        issues.push(health_issue(
            "missing-title",
            "error",
            Some("title"),
            "Title is missing",
            "Media applications need a stable title for matching and display.",
            Vec::new(),
        ));
    }
    if matches!(media_kind, "audiobook" | "book" | "podcast") && missing("authors") {
        issues.push(health_issue(
            "missing-authors",
            "warning",
            Some("authors"),
            "Author or creator is missing",
            "Add a portable creator so the item remains identifiable outside one app.",
            Vec::new(),
        ));
    }
    if media_kind == "audiobook" && missing("narrators") {
        issues.push(health_issue(
            "missing-narrators",
            "warning",
            Some("narrators"),
            "Narrator is missing",
            "Audiobookshelf can display and filter narrators when this field is present.",
            Vec::new(),
        ));
    }
    if !missing("volumeNumber") && missing("series") {
        issues.push(health_issue(
            "sequence-without-series",
            "warning",
            Some("series"),
            "Sequence has no series",
            "A volume or sequence number is ambiguous without its series name.",
            Vec::new(),
        ));
    }
    if matches!(media_kind, "audiobook" | "podcast") {
        for observation in observations {
            let audio_files = observation
                .fields
                .get("audioFiles")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            if audio_files.iter().any(|file| {
                file.get("error")
                    .and_then(Value::as_str)
                    .is_some_and(|error| !error.trim().is_empty())
            }) {
                issues.push(health_issue(
                    "audio-file-errors",
                    "error",
                    None,
                    "One or more audio files could not be parsed",
                    "Inspect the file-level error before changing ordering or embedding metadata.",
                    vec![observation.source.clone()],
                ));
            }
            let mut track_numbers = BTreeSet::new();
            let mut duplicate_track = false;
            let mut missing_track = false;
            for file in &audio_files {
                let disc = file.get("discNumber").and_then(value_as_u64).unwrap_or(1);
                if let Some(track) = file.get("trackNumber").and_then(value_as_u64) {
                    if !track_numbers.insert((disc, track)) {
                        duplicate_track = true;
                    }
                } else if audio_files.len() > 1 {
                    missing_track = true;
                }
            }
            if duplicate_track {
                issues.push(health_issue(
                    "duplicate-track-numbers",
                    "warning",
                    Some("trackNumber"),
                    "Track numbers are duplicated",
                    "Duplicate disc and track numbers can make chapter and playback order unstable.",
                    vec![observation.source.clone()],
                ));
            }
            if missing_track {
                issues.push(health_issue(
                    "missing-track-numbers",
                    "info",
                    Some("trackNumber"),
                    "Some files have no track number",
                    "Confirm that filename ordering matches the intended playback order.",
                    vec![observation.source.clone()],
                ));
            }
            let mut chapters = observation
                .fields
                .get("chapters")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|chapter| {
                    Some((
                        chapter.get("start")?.as_f64()?,
                        chapter.get("end")?.as_f64()?,
                    ))
                })
                .collect::<Vec<_>>();
            chapters.sort_by(|left, right| left.0.total_cmp(&right.0));
            let invalid_chapter = chapters.iter().enumerate().any(|(index, (start, end))| {
                !start.is_finite()
                    || !end.is_finite()
                    || *start < 0.0
                    || end <= start
                    || index
                        .checked_sub(1)
                        .is_some_and(|previous| chapters[previous].1 > *start)
            });
            if invalid_chapter {
                issues.push(health_issue(
                    "invalid-chapters",
                    "warning",
                    Some("chapters"),
                    "Chapter times overlap or run backwards",
                    "Use Audiobookshelf's chapter editor to correct chapter boundaries before embedding them.",
                    vec![observation.source.clone()],
                ));
            }
        }
    }
    for field in [
        "title",
        "subtitle",
        "year",
        "series",
        "volumeNumber",
        "authors",
        "narrators",
        "language",
    ] {
        let mut values = BTreeMap::<String, Vec<String>>::new();
        for observation in observations {
            if let Some(value) = observation
                .fields
                .get(field)
                .filter(|value| !value.is_null())
            {
                let normalized = normalized_metadata_value(value);
                if !normalized.is_empty() {
                    values
                        .entry(normalized)
                        .or_default()
                        .push(observation.source.clone());
                }
            }
        }
        if values.len() > 1 {
            issues.push(health_issue(
                &format!("conflicting-{field}"),
                if field == "title" { "warning" } else { "info" },
                Some(field),
                &format!("{} differs between sources", field_label(field)),
                "Compare the source values and choose which layer should be authoritative.",
                values.into_values().flatten().collect(),
            ));
        }
    }
    issues
}

fn value_as_u64(value: &Value) -> Option<u64> {
    value
        .as_u64()
        .or_else(|| value.as_str().and_then(|value| value.parse::<u64>().ok()))
}

fn health_issue(
    code: &str,
    severity: &str,
    field: Option<&str>,
    title: &str,
    message: &str,
    sources: Vec<String>,
) -> MetadataHealthIssue {
    MetadataHealthIssue {
        code: code.to_string(),
        severity: severity.to_string(),
        field: field.map(str::to_string),
        title: title.to_string(),
        message: message.to_string(),
        sources,
    }
}

fn normalized_metadata_value(value: &Value) -> String {
    match value {
        Value::String(value) => value.trim().to_ascii_lowercase(),
        Value::Array(values) => values
            .iter()
            .map(normalized_metadata_value)
            .filter(|value| !value.is_empty())
            .collect::<Vec<_>>()
            .join("\u{0}"),
        Value::Number(value) => value.to_string(),
        _ => String::new(),
    }
}

fn field_label(field: &str) -> String {
    let mut output = String::new();
    for (index, character) in field.chars().enumerate() {
        if index > 0 && character.is_ascii_uppercase() {
            output.push(' ');
        }
        output.push(if index == 0 {
            character.to_ascii_uppercase()
        } else {
            character
        });
    }
    output
}

pub fn modification_targets(
    media_kind: &str,
    extension: &str,
    application_available: bool,
) -> Vec<MetadataModificationTarget> {
    let application = match media_kind {
        "video" | "music" => Some(("jellyfin-application", "Jellyfin app metadata")),
        "audiobook" | "podcast" => {
            Some(("audiobookshelf-application", "Audiobookshelf app metadata"))
        }
        "book" => Some(("kavita-application", "Kavita app metadata")),
        _ => None,
    };
    let portable = if media_kind == "book" {
        let safe = matches!(extension, "epub" | "cbz");
        MetadataModificationTarget {
            id: "portable-embedded".to_string(), label: "Portable embedded metadata".to_string(),
            kind: "portable-file".to_string(), available: safe, recommended: safe, requires_refresh: true,
            message: if safe { "Rebuild and validate the EPUB or CBZ while preserving all other entries." } else { "PDF and CBR metadata writes are inspection-only because a safe lossless rewrite is not available." }.to_string(),
        }
    } else {
        MetadataModificationTarget {
            id: "portable-sidecar".to_string(), label: "Portable file metadata".to_string(),
            kind: "portable-file".to_string(), available: true, recommended: true, requires_refresh: true,
            message: "Write metadata beside or into the media so it remains portable across application databases.".to_string(),
        }
    };
    let mut targets = vec![portable];
    if let Some((id, label)) = application {
        targets.push(MetadataModificationTarget {
            id: id.to_string(), label: label.to_string(), kind: "application-local".to_string(),
            available: application_available, recommended: false, requires_refresh: false,
            message: "Use the application's native editor for fields that should remain local to that application.".to_string(),
        });
    }
    targets
}

pub fn consumer_effects(config: &AppConfig, media_kind: &str) -> Vec<ConsumerEffect> {
    let (id, label, effect, portable, message, native_url) = match media_kind {
        "video" | "music" => (
            "jellyfin",
            "Jellyfin",
            "read-after-refresh",
            true,
            "Jellyfin reads correctly named local NFO files after a library refresh.",
            config.jellyfin_public_url.clone(),
        ),
        "audiobook" => (
            "audiobookshelf",
            "Audiobookshelf",
            "read-after-refresh",
            true,
            "Audiobookshelf reads OPF/NFO files according to the library metadata priority.",
            config.audiobookshelf_public_url.clone(),
        ),
        "podcast" => (
            "audiobookshelf",
            "Audiobookshelf",
            "native-podcast-metadata",
            false,
            "Audiobookshelf keeps podcasts as a distinct media type; embedded episode tags remain portable, while feed and episode metadata can be managed in its native editor.",
            config.audiobookshelf_public_url.clone(),
        ),
        "book" => (
            "kavita",
            "Kavita",
            "embedded-metadata-required",
            false,
            "Kavita requires OPF inside EPUB, ComicInfo.xml inside comic archives, or PDF XMP metadata; an external OPF is ignored.",
            config.kavita_public_url.clone(),
        ),
        _ => return Vec::new(),
    };
    vec![ConsumerEffect {
        id: id.to_string(),
        label: label.to_string(),
        available: integration(config, id).is_some_and(|entry| entry.available),
        effect: effect.to_string(),
        can_manage_natively: true,
        portable_write_supported: portable,
        message: message.to_string(),
        native_url,
    }]
}

fn integration<'a>(config: &'a AppConfig, id: &str) -> Option<&'a IntegrationCapability> {
    config.integrations.iter().find(|entry| entry.id == id)
}

pub fn metadata_fields(value: &Value) -> Value {
    const FIELDS: &[&str] = &[
        "mediaType",
        "title",
        "year",
        "authors",
        "narrators",
        "series",
        "volumeNumber",
        "publisher",
        "isbn",
        "language",
        "genres",
        "description",
        "season",
        "episode",
        "episodeTitle",
        "premiereDate",
        "runtimeMinutes",
        "officialRating",
        "communityRating",
        "writers",
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
    let mut fields = Map::new();
    if let Some(object) = value.as_object() {
        for field in FIELDS {
            if let Some(value) = object.get(*field).filter(|value| !value.is_null()) {
                fields.insert((*field).to_string(), value.clone());
            }
        }
    }
    Value::Object(fields)
}

fn parse_sidecar_fields(text: &str) -> Result<Value, String> {
    let document = Document::parse(text).map_err(|error| error.to_string())?;
    let root = document.root_element();
    let root_name = root.tag_name().name().to_ascii_lowercase();
    let media_type = match root_name.as_str() {
        "episodedetails" => "episode",
        "tvshow" => "series",
        "season" => "season",
        "album" => "music",
        "package" => "book",
        _ => "movie",
    };
    let title = first_text(root, &["title", "localtitle"]);
    let year = first_text(root, &["year", "date"])
        .and_then(|value| value.get(0..4).map(str::to_string))
        .and_then(|value| value.parse::<u16>().ok());
    let genres = all_text(root, &["genre", "subject"]);
    let writers = all_text(root, &["writer"]);
    let authors = unique_values(
        all_text(root, &["artist", "creator"])
            .into_iter()
            .chain(writers.iter().cloned()),
    );
    let narrators = root
        .descendants()
        .filter(|node| node.is_element() && node.tag_name().name().eq_ignore_ascii_case("meta"))
        .filter(|node| {
            node.attribute("name")
                .is_some_and(|name| name.eq_ignore_ascii_case("narrator"))
        })
        .filter_map(|node| node.attribute("content"))
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .collect::<Vec<_>>();
    let series = first_text(root, &["showtitle"]).or_else(|| meta_content(root, "calibre:series"));
    let volume_number = meta_content(root, "calibre:series_index");
    let provider_ids = root
        .descendants()
        .filter(|node| node.is_element() && node.tag_name().name().eq_ignore_ascii_case("uniqueid"))
        .filter_map(|node| Some((node.attribute("type")?.trim(), node.text()?.trim())))
        .filter(|(provider, id)| !provider.is_empty() && !id.is_empty())
        .take(32)
        .map(|(provider, id)| (provider.to_ascii_lowercase(), Value::String(id.to_string())))
        .collect::<Map<_, _>>();
    let isbn = root
        .descendants()
        .find(|node| {
            node.is_element()
                && node.tag_name().name().eq_ignore_ascii_case("identifier")
                && node.attributes().any(|attribute| {
                    (attribute.name().eq_ignore_ascii_case("id")
                        || attribute.name().eq_ignore_ascii_case("scheme"))
                        && attribute.value().to_ascii_lowercase().contains("isbn")
                })
        })
        .and_then(|node| node.text())
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string);
    let mut fields = json!({
        "mediaType": media_type,
        "title": title.clone(),
        "year": year,
        "authors": authors,
        "narrators": narrators,
        "series": series,
        "volumeNumber": volume_number,
        "publisher": first_text(root, &["studio", "publisher"]),
        "isbn": isbn,
        "language": first_text(root, &["language"]),
        "genres": genres,
        "description": first_text(root, &["plot", "review", "description", "summary"]),
        "season": first_u32(root, "season"),
        "episode": first_u32(root, "episode"),
        "episodeTitle": if media_type == "episode" { title.clone() } else { None },
        "premiereDate": first_text(root, &["premiered", "releasedate", "aired"]),
        "runtimeMinutes": first_u32(root, "runtime"),
        "officialRating": first_text(root, &["mpaa", "customrating"]),
        "communityRating": first_text(root, &["rating"]).and_then(|value| value.parse::<f32>().ok()),
        "writers": writers,
        "providerIds": provider_ids,
    });
    if let Some(object) = fields.as_object_mut() {
        object.retain(|_, value| !value.is_null());
    }
    Ok(fields)
}

pub fn merge_managed_sidecar(existing: &str, generated: &str) -> Result<String, String> {
    if existing.len() > MAX_SIDECAR_BYTES as usize || generated.len() > MAX_SIDECAR_BYTES as usize {
        return Err("metadata sidecar exceeds the safe edit limit".to_string());
    }
    let existing_document = Document::parse(existing).map_err(|error| error.to_string())?;
    let generated_document = Document::parse(generated).map_err(|error| error.to_string())?;
    let existing_root = existing_document.root_element();
    let generated_root = generated_document.root_element();
    if !existing_root
        .tag_name()
        .name()
        .eq_ignore_ascii_case(generated_root.tag_name().name())
    {
        return Err("the existing sidecar has a different metadata type".to_string());
    }
    let existing_target = managed_container(existing_root)?;
    let generated_target = managed_container(generated_root)?;
    let target_range = existing_target.range();
    let opening_end = existing[target_range.start..target_range.end]
        .find('>')
        .map(|offset| target_range.start + offset)
        .ok_or_else(|| "metadata container has no opening tag".to_string())?;
    let closing_start = existing[target_range.start..target_range.end]
        .rfind("</")
        .map(|offset| target_range.start + offset)
        .ok_or_else(|| "metadata container has no closing tag".to_string())?;
    let mut preserved = existing[opening_end + 1..closing_start].to_string();
    let mut managed_ranges = existing_target
        .children()
        .filter(|node| node.is_element() && is_managed_element(*node, existing_root))
        .map(|node| {
            let range = node.range();
            (range.start - opening_end - 1)..(range.end - opening_end - 1)
        })
        .collect::<Vec<_>>();
    managed_ranges.sort_by_key(|range| range.start);
    for range in managed_ranges.into_iter().rev() {
        preserved.replace_range(range, "");
    }
    let generated_children = generated_target
        .children()
        .filter(|node| node.is_element() && is_managed_element(*node, generated_root))
        .map(|node| generated[node.range()].trim().to_string())
        .collect::<Vec<_>>()
        .join("\n  ");
    let mut opening = existing[..=opening_end].to_string();
    if generated_children.contains("dc:") && !existing.contains("xmlns:dc=") {
        opening.insert_str(
            opening.len() - 1,
            " xmlns:dc=\"http://purl.org/dc/elements/1.1/\"",
        );
    }
    let merged = format!(
        "{opening}\n  {generated_children}{preserved}{}",
        &existing[closing_start..]
    );
    Document::parse(&merged).map_err(|error| format!("merged sidecar is invalid XML: {error}"))?;
    Ok(merged)
}

fn managed_container<'a, 'input>(root: Node<'a, 'input>) -> Result<Node<'a, 'input>, String> {
    if root.tag_name().name().eq_ignore_ascii_case("package") {
        root.children()
            .find(|node| {
                node.is_element() && node.tag_name().name().eq_ignore_ascii_case("metadata")
            })
            .ok_or_else(|| "OPF package has no metadata element".to_string())
    } else {
        Ok(root)
    }
}

fn is_managed_element(node: Node<'_, '_>, root: Node<'_, '_>) -> bool {
    let name = node.tag_name().name().to_ascii_lowercase();
    if root.tag_name().name().eq_ignore_ascii_case("ComicInfo") {
        return matches!(
            name.as_str(),
            "title"
                | "series"
                | "number"
                | "summary"
                | "year"
                | "writer"
                | "publisher"
                | "genre"
                | "languageiso"
                | "web"
        );
    }
    if root.tag_name().name().eq_ignore_ascii_case("package") {
        if name == "meta" {
            return node.attribute("name").is_some_and(|value| {
                matches!(
                    value.to_ascii_lowercase().as_str(),
                    "calibre:series" | "calibre:series_index" | "narrator"
                )
            });
        }
        return matches!(
            name.as_str(),
            "title"
                | "creator"
                | "description"
                | "publisher"
                | "language"
                | "date"
                | "identifier"
                | "subject"
        );
    }
    matches!(
        name.as_str(),
        "title"
            | "localtitle"
            | "sorttitle"
            | "year"
            | "plot"
            | "review"
            | "studio"
            | "language"
            | "showtitle"
            | "season"
            | "episode"
            | "premiered"
            | "releasedate"
            | "aired"
            | "mpaa"
            | "customrating"
            | "runtime"
            | "rating"
            | "artist"
            | "genre"
            | "writer"
            | "uniqueid"
    )
}

fn first_text(root: Node<'_, '_>, names: &[&str]) -> Option<String> {
    root.descendants()
        .find(|node| {
            node.is_element()
                && names
                    .iter()
                    .any(|name| node.tag_name().name().eq_ignore_ascii_case(name))
        })
        .and_then(|node| node.text())
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

fn all_text(root: Node<'_, '_>, names: &[&str]) -> Vec<String> {
    unique_values(
        root.descendants()
            .filter(|node| {
                node.is_element()
                    && names
                        .iter()
                        .any(|name| node.tag_name().name().eq_ignore_ascii_case(name))
            })
            .filter_map(|node| node.text())
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string),
    )
}

fn unique_values(values: impl IntoIterator<Item = String>) -> Vec<String> {
    let mut seen = BTreeSet::new();
    values
        .into_iter()
        .filter(|value| seen.insert(value.to_ascii_lowercase()))
        .collect()
}

fn meta_content(root: Node<'_, '_>, name: &str) -> Option<String> {
    root.descendants()
        .find(|node| {
            node.is_element()
                && node.tag_name().name().eq_ignore_ascii_case("meta")
                && node
                    .attribute("name")
                    .is_some_and(|value| value.eq_ignore_ascii_case(name))
        })
        .and_then(|node| node.attribute("content"))
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

fn first_u32(root: Node<'_, '_>, name: &str) -> Option<u32> {
    first_text(root, &[name]).and_then(|value| value.parse::<u32>().ok())
}

pub fn initial_field_sources(fields: &Value, source: &str) -> BTreeMap<String, String> {
    fields
        .as_object()
        .into_iter()
        .flat_map(|object| object.iter())
        .filter(|(_, value)| !value.is_null())
        .map(|(field, _)| (field.clone(), source.to_string()))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::{
        health_issues, inspect_embedded_metadata, merge_managed_sidecar, modification_targets,
        parse_sidecar_fields, rewrite_embedded_metadata, MetadataObservation,
    };
    use crate::catalog::CatalogItem;
    use serde_json::json;
    use std::io::Write;
    use zip::{write::SimpleFileOptions, CompressionMethod, ZipWriter};

    #[test]
    fn parses_namespaced_opf_fields() {
        let fields = parse_sidecar_fields(
            r#"<package xmlns="http://www.idpf.org/2007/opf"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Book</dc:title><dc:creator>Author</dc:creator><dc:subject>History</dc:subject><meta name="calibre:series" content="Series"/></metadata></package>"#,
        )
        .expect("OPF");
        assert_eq!(fields["title"], "Book");
        assert_eq!(fields["authors"][0], "Author");
        assert_eq!(fields["series"], "Series");
    }

    #[test]
    fn replaces_managed_xml_while_preserving_unknown_elements() {
        let merged = merge_managed_sidecar(
            "<?xml version=\"1.0\"?><movie data-owner=\"user\"><title>Old</title><!-- keep --><custom rating=\"A\">untouched</custom><genre>Old genre</genre></movie>",
            "<?xml version=\"1.0\"?><movie><title>New</title><genre>New genre</genre></movie>",
        )
        .expect("merged NFO");
        assert!(merged.contains("<title>New</title>"));
        assert!(merged.contains("<genre>New genre</genre>"));
        assert!(!merged.contains("<title>Old</title>"));
        assert!(merged.contains("<!-- keep -->"));
        assert!(merged.contains("<custom rating=\"A\">untouched</custom>"));
        assert!(merged.contains("data-owner=\"user\""));
    }

    #[test]
    fn inspects_the_package_document_selected_by_epub_container_xml() {
        let temp = tempfile::tempdir().expect("temporary directory");
        let path = temp.path().join("Novel.epub");
        let mut archive = ZipWriter::new(std::fs::File::create(&path).expect("EPUB"));
        let options = SimpleFileOptions::default().compression_method(CompressionMethod::Deflated);
        archive
            .start_file("META-INF/container.xml", options)
            .expect("container entry");
        archive
            .write_all(br#"<container><rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#)
            .expect("container XML");
        archive
            .start_file("OPS/ignored.opf", options)
            .expect("ignored OPF");
        archive
            .write_all(br#"<package><metadata><title>Wrong book</title></metadata></package>"#)
            .expect("ignored metadata");
        archive
            .start_file("OPS/package.opf", options)
            .expect("package OPF");
        archive
            .write_all(br#"<package xmlns="http://www.idpf.org/2007/opf"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>The Portable Book</dc:title><dc:creator>Alex Author</dc:creator><dc:subject>History</dc:subject><meta name="calibre:series" content="Archive Series"/><meta name="calibre:series_index" content="2"/></metadata></package>"#)
            .expect("package metadata");
        archive.finish().expect("finish EPUB");

        let item = CatalogItem {
            id: "book-1".to_string(),
            root_id: "shared-books".to_string(),
            owner_username: None,
            relative_path: "Novel.epub".to_string(),
            media_kind: "book".to_string(),
            size_bytes: 0,
            modified_ns: 0,
            fingerprint: "fixture".to_string(),
        };
        let observation = inspect_embedded_metadata(temp.path(), &item)
            .expect("inspection result")
            .expect("embedded OPF observation");
        assert_eq!(observation.source, "embedded-epub");
        assert_eq!(
            observation.relative_path.as_deref(),
            Some("Novel.epub!/OPS/package.opf")
        );
        assert_eq!(observation.fields["title"], "The Portable Book");
        assert_eq!(observation.fields["authors"][0], "Alex Author");
        assert_eq!(observation.fields["volumeNumber"], "2");
        assert_eq!(observation.storage, "embedded-file");
        assert_eq!(observation.consumed_by, vec!["kavita"]);
        assert!(observation.survives_rescan);
    }

    #[test]
    fn inspects_only_root_comicinfo_xml_in_cbz_archives() {
        let temp = tempfile::tempdir().expect("temporary directory");
        let path = temp.path().join("Issue.cbz");
        let mut archive = ZipWriter::new(std::fs::File::create(&path).expect("CBZ"));
        let options = SimpleFileOptions::default().compression_method(CompressionMethod::Deflated);
        archive
            .start_file("nested/ComicInfo.xml", options)
            .expect("nested metadata");
        archive
            .write_all(b"<ComicInfo><Title>Wrong</Title></ComicInfo>")
            .expect("nested XML");
        archive
            .start_file("ComicInfo.xml", options)
            .expect("root metadata");
        archive.write_all(br#"<ComicInfo><Title>Issue One</Title><Series>Series Name</Series><Number>1</Number><Writer>Writer One, Writer Two</Writer><Genre>Adventure, History</Genre><Summary>A summary.</Summary><LanguageISO>en</LanguageISO><Web>https://example.invalid/issue</Web></ComicInfo>"#).expect("root XML");
        archive.finish().expect("finish CBZ");
        let item = CatalogItem {
            id: "book-2".to_string(),
            root_id: "shared-books".to_string(),
            owner_username: None,
            relative_path: "Issue.cbz".to_string(),
            media_kind: "book".to_string(),
            size_bytes: 0,
            modified_ns: 0,
            fingerprint: "fixture".to_string(),
        };
        let observation = inspect_embedded_metadata(temp.path(), &item)
            .expect("inspection result")
            .expect("ComicInfo observation");
        assert_eq!(observation.source, "embedded-comicinfo");
        assert_eq!(observation.fields["title"], "Issue One");
        assert_eq!(observation.fields["series"], "Series Name");
        assert_eq!(observation.fields["volumeNumber"], "1");
        assert_eq!(
            observation.fields["writers"]
                .as_array()
                .expect("writers")
                .len(),
            2
        );
    }

    #[test]
    fn embedded_rewrite_rejects_unsafe_archive_entry_paths() {
        let temp = tempfile::tempdir().expect("temporary directory");
        let input_path = temp.path().join("unsafe.cbz");
        let output_path = temp.path().join("rewritten.cbz");
        let mut archive = ZipWriter::new(std::fs::File::create(&input_path).expect("CBZ"));
        archive
            .start_file("../escape.txt", SimpleFileOptions::default())
            .expect("unsafe entry");
        archive.write_all(b"unsafe").expect("entry contents");
        archive.finish().expect("finish CBZ");

        let error = rewrite_embedded_metadata(
            std::fs::File::open(input_path).expect("input"),
            std::fs::File::create(output_path).expect("output"),
            "cbz",
            "<ComicInfo><Title>Safe title</Title></ComicInfo>",
        )
        .expect_err("unsafe archive must not be rewritten");
        assert!(error.contains("unsafe ZIP entry path"));
    }

    #[test]
    fn inspects_plain_pdf_xmp_without_loading_the_whole_document() {
        let temp = tempfile::tempdir().expect("temporary directory");
        std::fs::write(
            temp.path().join("Paper.pdf"),
            br#"%PDF-1.7
<x:xmpmeta xmlns:x="adobe:ns:meta/" xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:dc="http://purl.org/dc/elements/1.1/">
<rdf:RDF><rdf:Description><dc:title><rdf:Alt><rdf:li xml:lang="x-default">Groundwater Paper</rdf:li></rdf:Alt></dc:title><dc:creator><rdf:Seq><rdf:li>Researcher One</rdf:li></rdf:Seq></dc:creator><dc:subject><rdf:Bag><rdf:li>Geology</rdf:li></rdf:Bag></dc:subject><dc:language><rdf:Bag><rdf:li>en-AU</rdf:li></rdf:Bag></dc:language></rdf:Description></rdf:RDF></x:xmpmeta>
%%EOF"#,
        )
        .expect("PDF fixture");
        let item = CatalogItem {
            id: "book-3".to_string(),
            root_id: "shared-books".to_string(),
            owner_username: None,
            relative_path: "Paper.pdf".to_string(),
            media_kind: "book".to_string(),
            size_bytes: 0,
            modified_ns: 0,
            fingerprint: "fixture".to_string(),
        };
        let observation = inspect_embedded_metadata(temp.path(), &item)
            .expect("inspection result")
            .expect("PDF XMP observation");
        assert_eq!(observation.source, "embedded-pdf-xmp");
        assert_eq!(observation.fields["title"], "Groundwater Paper");
        assert_eq!(observation.fields["authors"][0], "Researcher One");
        assert_eq!(observation.fields["genres"][0], "Geology");
        assert_eq!(observation.fields["language"], "en-AU");
        assert!(!observation.writable);
    }

    #[test]
    fn metadata_health_reports_conflicts_and_missing_audiobook_people() {
        let observations = vec![
            MetadataObservation::for_test("filename", json!({"title":"One"})),
            MetadataObservation::for_test("audiobookshelf", json!({"title":"Two"})),
        ];
        let issues = health_issues("audiobook", &json!({"title":"Two"}), &observations);
        assert!(issues.iter().any(|issue| issue.code == "conflicting-title"));
        assert!(issues.iter().any(|issue| issue.code == "missing-authors"));
        assert!(issues.iter().any(|issue| issue.code == "missing-narrators"));
    }

    #[test]
    fn audiobook_health_reports_track_and_chapter_integrity_problems() {
        let observations = vec![MetadataObservation::for_test(
            "audiobookshelf",
            json!({
                "title":"Book", "authors":["Author"], "narrators":["Narrator"],
                "audioFiles":[
                    {"filename":"one.mp3","discNumber":1,"trackNumber":1},
                    {"filename":"two.mp3","discNumber":1,"trackNumber":1,"error":"unreadable"}
                ],
                "chapters":[
                    {"title":"Broken","start":20.0,"end":10.0},
                    {"title":"Overlap","start":5.0,"end":30.0}
                ]
            }),
        )];
        let issues = health_issues(
            "audiobook",
            &json!({"title":"Book","authors":["Author"],"narrators":["Narrator"]}),
            &observations,
        );
        assert!(issues.iter().any(|issue| issue.code == "audio-file-errors"));
        assert!(issues
            .iter()
            .any(|issue| issue.code == "duplicate-track-numbers"));
        assert!(issues.iter().any(|issue| issue.code == "invalid-chapters"));
    }

    #[test]
    fn modification_targets_distinguish_portable_and_application_local_changes() {
        let targets = modification_targets("book", "epub", true);
        assert!(targets
            .iter()
            .any(|target| target.id == "portable-embedded" && target.available));
        assert!(targets
            .iter()
            .any(|target| target.id == "kavita-application" && target.kind == "application-local"));
        let pdf = modification_targets("book", "pdf", true);
        assert!(pdf
            .iter()
            .any(|target| target.id == "portable-embedded" && !target.available));
    }
}
