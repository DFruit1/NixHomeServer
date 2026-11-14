//! Pre-sized thumbnails for photo tiles and cover artwork.
//!
//! Browsers alias visibly ("grain") when they shrink a large photo or cover
//! several-fold into a small tile. Tiles request a size close to their rendered
//! pixel size instead, and this module produces it with an area-averaging
//! reduction followed by a Lanczos pass. Sizes snap to a small fixed set so
//! browser and server caches stay effective.

use image::{
    codecs::{jpeg::JpegEncoder, png::PngEncoder},
    imageops::FilterType,
    DynamicImage, ImageDecoder, ImageReader, Limits,
};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, VecDeque},
    io::Cursor,
    sync::{Mutex, OnceLock},
};

/// Shortest-side pixel sizes a thumbnail request may ask for.
pub(crate) const THUMBNAIL_SIZES: [u32; 3] = [160, 320, 640];
const JPEG_QUALITY: u8 = 86;
/// Thumbnails of panoramas keep at most this aspect ratio of detail.
const MAX_ASPECT: u32 = 4;
const CACHE_BUDGET_BYTES: usize = 48 * 1024 * 1024;

/// Snap a requested shortest-side size up to the nearest supported size.
/// Requests above the largest size return `None`: the caller serves the
/// original image.
pub(crate) fn snap_size(requested: u32) -> Option<u32> {
    THUMBNAIL_SIZES
        .into_iter()
        .find(|size| *size >= requested.max(1))
}

/// `?size=` on image endpoints: the shortest side the client renders, in
/// device pixels. Omitted means the original image.
#[derive(Debug, Default, Deserialize)]
pub(crate) struct ThumbnailQuery {
    #[serde(default)]
    pub(crate) size: Option<u32>,
}

impl ThumbnailQuery {
    pub(crate) fn snapped(&self) -> Option<u32> {
        self.size.and_then(snap_size)
    }
}

/// Serve `bytes` at the requested size when that is smaller than the source,
/// otherwise unchanged. Decoding runs off the async runtime; `None` means the
/// resize task itself failed.
pub(crate) async fn sized(
    bytes: Vec<u8>,
    content_type: String,
    size: Option<u32>,
) -> Option<(Vec<u8>, String)> {
    let Some(size) = size else {
        return Some((bytes, content_type));
    };
    let (thumb, bytes, content_type) =
        tokio::task::spawn_blocking(move || (thumbnail(&bytes, size), bytes, content_type))
            .await
            .ok()?;
    Some(match thumb {
        Some(thumb) => (thumb.bytes, thumb.content_type),
        None => (bytes, content_type),
    })
}

pub(crate) struct Thumbnail {
    pub(crate) bytes: Vec<u8>,
    pub(crate) content_type: String,
}

/// Resize `bytes` so its shortest side is `size` pixels. Images already at or
/// below that size, and formats the decoder cannot read, return `None` so the
/// caller serves the original unchanged.
pub(crate) fn thumbnail(bytes: &[u8], size: u32) -> Option<Thumbnail> {
    let key = (Sha256::digest(bytes).into(), size);
    if let Some(hit) = cache().lock().ok()?.get(&key) {
        return hit.clone().map(|(bytes, content_type)| Thumbnail {
            bytes,
            content_type: content_type.to_string(),
        });
    }
    let rendered = render(bytes, size);
    if let Ok(mut cache) = cache().lock() {
        cache.insert(key, rendered.clone());
    }
    rendered.map(|(bytes, content_type)| Thumbnail {
        bytes,
        content_type: content_type.to_string(),
    })
}

fn render(bytes: &[u8], size: u32) -> Option<(Vec<u8>, &'static str)> {
    let mut reader = ImageReader::new(Cursor::new(bytes))
        .with_guessed_format()
        .ok()?;
    let mut limits = Limits::default();
    limits.max_image_width = Some(12_000);
    limits.max_image_height = Some(12_000);
    limits.max_alloc = Some(512 * 1024 * 1024);
    reader.limits(limits);
    let mut decoder = reader.into_decoder().ok()?;
    let orientation = decoder.orientation().ok();
    let mut image = DynamicImage::from_decoder(decoder).ok()?;
    if let Some(orientation) = orientation {
        image.apply_orientation(orientation);
    }
    let (width, height) = (image.width(), image.height());
    let short = width.min(height);
    if short <= size {
        return None;
    }
    // Scale so the short side matches; cap the long side for extreme panoramas.
    let long_cap = f64::from(size.saturating_mul(MAX_ASPECT));
    let scale = (f64::from(size) / f64::from(short)).min(long_cap / f64::from(width.max(height)));
    let target_w = ((f64::from(width) * scale).round() as u32).max(1);
    let target_h = ((f64::from(height) * scale).round() as u32).max(1);
    // Area-average large sources to twice the target first: it removes the
    // high frequencies that alias, and keeps the Lanczos pass cheap.
    if width > target_w.saturating_mul(4) {
        image = image.thumbnail_exact(target_w * 2, target_h * 2);
    }
    let image = image.resize_exact(target_w, target_h, FilterType::Lanczos3);
    let mut out = Vec::new();
    if image.color().has_alpha() && has_transparency(&image) {
        image
            .to_rgba8()
            .write_with_encoder(PngEncoder::new(&mut out))
            .ok()?;
        Some((out, "image/png"))
    } else {
        image
            .to_rgb8()
            .write_with_encoder(JpegEncoder::new_with_quality(&mut out, JPEG_QUALITY))
            .ok()?;
        Some((out, "image/jpeg"))
    }
}

fn has_transparency(image: &DynamicImage) -> bool {
    image.to_rgba8().pixels().any(|pixel| pixel.0[3] < 255)
}

type CacheKey = ([u8; 32], u32);
type CacheValue = Option<(Vec<u8>, &'static str)>;

/// Content-addressed, byte-bounded FIFO cache. Track lists ask for the same
/// album cover once per row; keying by source content serves them from one
/// render and never returns a stale thumbnail after a cover changes.
#[derive(Default)]
struct ThumbnailCache {
    entries: HashMap<CacheKey, CacheValue>,
    order: VecDeque<CacheKey>,
    bytes: usize,
}

impl ThumbnailCache {
    fn get(&self, key: &CacheKey) -> Option<&CacheValue> {
        self.entries.get(key)
    }

    fn insert(&mut self, key: CacheKey, value: CacheValue) {
        let cost = value.as_ref().map_or(0, |(bytes, _)| bytes.len()) + 64;
        if cost > CACHE_BUDGET_BYTES || self.entries.contains_key(&key) {
            return;
        }
        while self.bytes + cost > CACHE_BUDGET_BYTES {
            let Some(oldest) = self.order.pop_front() else {
                break;
            };
            if let Some(evicted) = self.entries.remove(&oldest) {
                self.bytes -= evicted.as_ref().map_or(0, |(bytes, _)| bytes.len()) + 64;
            }
        }
        self.entries.insert(key, value);
        self.order.push_back(key);
        self.bytes += cost;
    }
}

fn cache() -> &'static Mutex<ThumbnailCache> {
    static CACHE: OnceLock<Mutex<ThumbnailCache>> = OnceLock::new();
    CACHE.get_or_init(Default::default)
}
