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

const EMBEDDED_ARTWORK_KINDS: &[&str] = &[
    "music",
    "audiobook",
    "book",
    "video",
    "movie",
    "tv",
    "episode",
];

pub(crate) fn is_embedded_artwork_capable(media_kind: &str) -> bool {
    EMBEDDED_ARTWORK_KINDS.contains(&media_kind)
}

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
    let mut content_type = artwork_content_type(relative_path).to_string();
    if content_type == "application/octet-stream" {
        if let Some(sniffed) = sniff_image_content_type(&bytes) {
            content_type = sniffed;
        }
    }
    Ok(ArtworkBody {
        bytes,
        content_type,
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
    let content_type = picture
        .mime_type()
        .map(|mime| mime.as_str().to_string())
        .filter(|mime| mime.starts_with("image/"))
        .or_else(|| sniff_image_content_type(picture.data()));
    let Some(content_type) = content_type else {
        return Ok(None);
    };
    if !content_type.starts_with("image/") {
        return Ok(None);
    }
    Ok(Some(ArtworkBody {
        bytes: picture.data().to_vec(),
        content_type,
    }))
}

pub(crate) fn sniff_image_content_type(bytes: &[u8]) -> Option<String> {
    const SIGNATURES: &[(&str, &[u8])] = &[
        ("image/jpeg", &[0xFF, 0xD8, 0xFF]),
        (
            "image/png",
            &[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
        ),
        ("image/gif", b"GIF8"),
        ("image/bmp", b"BM"),
        ("image/webp", b"RIFF"),
    ];
    for (mime, signature) in SIGNATURES {
        if bytes.starts_with(signature) {
            if *mime == "image/webp" && bytes.len() >= 12 && &bytes[8..12] != b"WEBP" {
                continue;
            }
            return Some((*mime).to_string());
        }
    }
    if bytes.len() >= 12 && &bytes[4..8] == b"ftyp" {
        let brand = &bytes[8..12];
        let mosaic = &[
            (b"heic", "image/heic"),
            (b"heix", "image/heic"),
            (b"mif1", "image/heif"),
            (b"avif", "image/avif"),
            (b"jxl ", "image/jxl"),
        ];
        for (brand_bytes, mime) in mosaic {
            if brand == brand_bytes.as_slice() {
                return Some((*mime).to_string());
            }
        }
    }
    None
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
    while let Some((parent, _)) = ancestor.rsplit_once('/') {
        if parent == ancestor {
            break;
        }
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
            Some((candidate, distance, candidate_name, candidate_parent))
        })
        .min_by_key(|(candidate, distance, candidate_name, candidate_parent)| {
            let stem = candidate_name
                .rsplit_once('.')
                .map(|(stem, _)| stem)
                .unwrap_or_default()
                .to_ascii_lowercase();
            let suffixes = [
                "",
                "-poster",
                "-cover",
                "-folder",
                "-default",
                "-movie",
                "-show",
                "-jacket",
                "-front",
                "-thumb",
                "-landscape",
                "-banner",
                "-fanart",
                "-backdrop",
                "-background",
                "-art",
                "-clearlogo",
                "-logo",
            ];
            let folder_stem = candidate_parent
                .rsplit('/')
                .next()
                .unwrap_or(candidate_parent)
                .to_ascii_lowercase();
            let target_priority = suffixes
                .iter()
                .position(|suffix| stem == format!("{target_stem}{suffix}"))
                .or_else(|| {
                    suffixes
                        .iter()
                        .position(|suffix| stem == format!("{folder_stem}{suffix}"))
                        .map(|priority| 50 + priority)
                });
            let generic_priority = [
                "cover",
                "folder",
                "poster",
                "default",
                "movie",
                "show",
                "jacket",
                "artwork",
                "front",
                "thumb",
                "landscape",
                "banner",
                "fanart",
                "backdrop",
                "background",
                "art",
                "clearlogo",
                "logo",
            ]
            .iter()
            .position(|preferred| *preferred == stem);
            let name_priority = target_priority
                .or_else(|| generic_priority.map(|priority| 100 + priority))
                .unwrap_or(usize::MAX);
            (
                usize::from(name_priority == usize::MAX),
                *distance,
                name_priority,
                candidate.relative_path.clone(),
            )
        })
        .map(|(candidate, _, _, _)| candidate.clone())
}
