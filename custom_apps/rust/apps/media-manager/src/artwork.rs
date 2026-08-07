use crate::{broker::open_regular_file_beneath, catalog::CatalogItem};
use lofty::{
    config::ParseOptions,
    file::{FileType, TaggedFileExt},
    picture::PictureType,
    probe::Probe,
};
use std::{
    io::{BufReader, Read},
    path::Path,
};

const MAX_ARTWORK_BYTES: u64 = 32 * 1024 * 1024;

pub(crate) struct ArtworkBody {
    pub(crate) bytes: Vec<u8>,
    pub(crate) content_type: String,
}

pub(crate) fn read_artwork_file(
    root_path: &Path,
    relative_path: &str,
) -> Result<ArtworkBody, String> {
    let file =
        open_regular_file_beneath(root_path, relative_path).map_err(|error| error.to_string())?;
    let mut bytes = Vec::new();
    file.take(MAX_ARTWORK_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| error.to_string())?;
    if bytes.len() as u64 > MAX_ARTWORK_BYTES {
        return Err("artwork exceeds the 32 MiB limit".to_string());
    }
    Ok(ArtworkBody {
        bytes,
        content_type: artwork_content_type(relative_path).to_string(),
    })
}

fn artwork_content_type(path: &str) -> &'static str {
    match path
        .rsplit_once('.')
        .map(|(_, extension)| extension.to_ascii_lowercase())
        .as_deref()
    {
        Some("jpg") | Some("jpeg") => "image/jpeg",
        Some("png") => "image/png",
        Some("webp") => "image/webp",
        Some("gif") => "image/gif",
        Some("bmp") => "image/bmp",
        Some("tif") | Some("tiff") => "image/tiff",
        Some("avif") => "image/avif",
        Some("svg") => "image/svg+xml",
        Some("heic") => "image/heic",
        Some("heif") => "image/heif",
        Some("jxl") => "image/jxl",
        _ => "application/octet-stream",
    }
}

pub(crate) fn read_embedded_artwork(
    root_path: &Path,
    relative_path: &str,
) -> Result<Option<ArtworkBody>, String> {
    let Some(file_type) = FileType::from_path(relative_path) else {
        return Ok(None);
    };
    let file =
        open_regular_file_beneath(root_path, relative_path).map_err(|error| error.to_string())?;
    let tagged_file = match Probe::with_file_type(BufReader::new(file), file_type)
        .options(ParseOptions::new().read_properties(false))
        .read()
    {
        Ok(tagged_file) => tagged_file,
        Err(_) => return Ok(None),
    };
    let picture = tagged_file
        .tags()
        .iter()
        .flat_map(|tag| tag.pictures())
        .filter(|picture| {
            !picture.data().is_empty() && picture.data().len() as u64 <= MAX_ARTWORK_BYTES
        })
        .min_by_key(|picture| match picture.pic_type() {
            PictureType::CoverFront => 0,
            PictureType::Other => 1,
            PictureType::Illustration => 2,
            _ => 3,
        });
    let Some(picture) = picture else {
        return Ok(None);
    };
    let Some(mime_type) = picture.mime_type() else {
        return Ok(None);
    };
    let content_type = mime_type.as_str();
    if !content_type.starts_with("image/") {
        return Ok(None);
    }
    Ok(Some(ArtworkBody {
        bytes: picture.data().to_vec(),
        content_type: content_type.to_string(),
    }))
}

pub(crate) fn preferred_artwork(items: &[CatalogItem], target_path: &str) -> Option<CatalogItem> {
    let (target_parent, target_name) = target_path.rsplit_once('/').unwrap_or(("", target_path));
    let target_stem = target_name
        .rsplit_once('.')
        .map(|(stem, _)| stem)
        .unwrap_or(target_name)
        .to_ascii_lowercase();
    let mut candidate_parents = vec![target_parent];
    let mut ancestor = target_parent;
    for _ in 0..3 {
        let Some((parent, _)) = ancestor.rsplit_once('/') else {
            break;
        };
        candidate_parents.push(parent);
        ancestor = parent;
    }

    items
        .iter()
        .filter_map(|candidate| {
            if candidate.media_kind != "artwork" {
                return None;
            }
            let (candidate_parent, candidate_name) = candidate
                .relative_path
                .rsplit_once('/')
                .unwrap_or(("", &candidate.relative_path));
            let distance = candidate_parents
                .iter()
                .position(|parent| *parent == candidate_parent)?;
            Some((candidate, distance, candidate_name))
        })
        .min_by_key(|(candidate, distance, candidate_name)| {
            let stem = candidate_name
                .rsplit_once('.')
                .map(|(stem, _)| stem)
                .unwrap_or_default()
                .to_ascii_lowercase();
            let target_priority = [
                "",
                "-poster",
                "-cover",
                "-folder",
                "-front",
                "-thumb",
                "-landscape",
                "-banner",
                "-fanart",
                "-backdrop",
                "-clearlogo",
                "-logo",
            ]
            .iter()
            .position(|suffix| stem == format!("{target_stem}{suffix}"));
            let generic_priority = [
                "cover",
                "folder",
                "poster",
                "artwork",
                "front",
                "thumb",
                "landscape",
                "banner",
                "fanart",
                "backdrop",
                "clearlogo",
                "logo",
            ]
            .iter()
            .position(|preferred| *preferred == stem);
            let name_priority = target_priority
                .or_else(|| generic_priority.map(|priority| 100 + priority))
                .unwrap_or(usize::MAX);
            (*distance, name_priority, candidate.relative_path.clone())
        })
        .map(|(candidate, _, _)| candidate.clone())
}
