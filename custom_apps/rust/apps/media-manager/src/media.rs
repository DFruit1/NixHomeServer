//! Core media-type model: strongly typed kinds and library categories.
//!
//! Every media kind and library category used by the catalog, scanner, and
//! HTTP surface is expressed as an enum here. The string values produced by
//! [`MediaKind::as_str`] and [`LibraryCategory::as_str`] are the same strings
//! that were previously stored in the SQLite `media_kind` column and emitted
//! by the JSON API, so the database and frontend contracts are unchanged.

use serde::{Deserialize, Serialize};
use std::fmt;

/// The kind of a catalogued file. Serialized as the historical snake_case
/// strings (`"video"`, `"music"`, `"audiobook"`, `"podcast"`, `"book"`,
/// `"artwork"`, `"subtitle"`, `"iso"`).
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MediaKind {
    Video,
    Music,
    Audiobook,
    Podcast,
    Book,
    Artwork,
    Subtitle,
    Iso,
}

impl MediaKind {
    pub const ALL: [MediaKind; 8] = [
        MediaKind::Video,
        MediaKind::Music,
        MediaKind::Audiobook,
        MediaKind::Podcast,
        MediaKind::Book,
        MediaKind::Artwork,
        MediaKind::Subtitle,
        MediaKind::Iso,
    ];

    /// Kinds that represent user-facing media rather than companions of
    /// other items (artwork, subtitles) or containers (ISO).
    pub const PRIMARY: [MediaKind; 5] = [
        MediaKind::Video,
        MediaKind::Music,
        MediaKind::Audiobook,
        MediaKind::Podcast,
        MediaKind::Book,
    ];

    /// Kinds a user can browse and edit core info for; companion kinds are
    /// only surfaced attached to their parent item.
    pub const fn is_primary(self) -> bool {
        matches!(
            self,
            MediaKind::Video
                | MediaKind::Music
                | MediaKind::Audiobook
                | MediaKind::Podcast
                | MediaKind::Book
        )
    }

    /// Companion kinds: files that belong to another item (artwork next to a
    /// movie, subtitles next to a video) rather than being items themselves.
    pub const fn is_companion(self) -> bool {
        matches!(self, MediaKind::Artwork | MediaKind::Subtitle)
    }

    pub const fn as_str(self) -> &'static str {
        match self {
            MediaKind::Video => "video",
            MediaKind::Music => "music",
            MediaKind::Audiobook => "audiobook",
            MediaKind::Podcast => "podcast",
            MediaKind::Book => "book",
            MediaKind::Artwork => "artwork",
            MediaKind::Subtitle => "subtitle",
            MediaKind::Iso => "iso",
        }
    }

    /// Parses the canonical snake_case form. Comparison against raw strings
    /// from the database or API must go through this so unknown values are
    /// rejected instead of silently mismatching.
    pub fn parse(value: &str) -> Option<MediaKind> {
        MediaKind::ALL
            .into_iter()
            .find(|kind| kind.as_str() == value)
    }

    /// File extensions that classify to this kind. The scanner lowercases
    /// extensions before classification, so these are lowercase.
    pub const fn extensions(self) -> &'static [&'static str] {
        match self {
            MediaKind::Video => &["mkv", "mp4", "m4v", "avi"],
            MediaKind::Music => &["mp3", "flac", "m4a", "ogg", "opus"],
            MediaKind::Audiobook => &["mp3", "flac", "m4a", "m4b", "ogg", "opus"],
            MediaKind::Podcast => &["mp3", "m4a", "m4b", "ogg", "opus"],
            MediaKind::Book => &["epub", "cbz", "cbr", "pdf"],
            MediaKind::Iso => &["iso"],
            MediaKind::Artwork => &[
                "jpg", "jpeg", "png", "webp", "gif", "bmp", "tif", "tiff", "avif", "svg", "heic",
                "heif", "jxl",
            ],
            MediaKind::Subtitle => &["srt", "vtt", "ass", "ssa", "sub", "idx"],
        }
    }

    /// The library category this kind belongs to, if it is tied to one.
    /// Companion kinds and ISO containers can appear in several categories.
    pub const fn category(self) -> Option<LibraryCategory> {
        match self {
            MediaKind::Video => Some(LibraryCategory::Videos),
            MediaKind::Music => Some(LibraryCategory::Music),
            MediaKind::Audiobook => Some(LibraryCategory::Audiobooks),
            MediaKind::Podcast => Some(LibraryCategory::Podcasts),
            MediaKind::Book => Some(LibraryCategory::Books),
            MediaKind::Artwork | MediaKind::Subtitle | MediaKind::Iso => None,
        }
    }
}

impl fmt::Display for MediaKind {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

impl std::str::FromStr for MediaKind {
    type Err = UnknownMediaKind;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        MediaKind::parse(value).ok_or_else(|| UnknownMediaKind {
            value: value.to_string(),
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct UnknownMediaKind {
    pub value: String,
}

impl fmt::Display for UnknownMediaKind {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "unknown media kind: {}", self.value)
    }
}

impl std::error::Error for UnknownMediaKind {}

/// The library category of a media root (`shared-videos`, `personal-books`,
/// ...). Serialized as the historical lowercase strings.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LibraryCategory {
    Videos,
    Music,
    Audiobooks,
    Podcasts,
    Books,
}

impl LibraryCategory {
    pub const ALL: [LibraryCategory; 5] = [
        LibraryCategory::Videos,
        LibraryCategory::Music,
        LibraryCategory::Audiobooks,
        LibraryCategory::Podcasts,
        LibraryCategory::Books,
    ];

    pub const fn as_str(self) -> &'static str {
        match self {
            LibraryCategory::Videos => "videos",
            LibraryCategory::Music => "music",
            LibraryCategory::Audiobooks => "audiobooks",
            LibraryCategory::Podcasts => "podcasts",
            LibraryCategory::Books => "books",
        }
    }

    /// On-disk folder under the shared or per-user root.
    pub const fn folder_name(self) -> &'static str {
        match self {
            LibraryCategory::Videos => "_Videos",
            LibraryCategory::Music => "_Music",
            LibraryCategory::Audiobooks => "_Audiobooks",
            LibraryCategory::Podcasts => "_Podcasts",
            LibraryCategory::Books => "_Books",
        }
    }

    pub const fn shared_label(self) -> &'static str {
        match self {
            LibraryCategory::Videos => "Shared videos",
            LibraryCategory::Music => "Shared music",
            LibraryCategory::Audiobooks => "Shared audiobooks",
            LibraryCategory::Podcasts => "Shared podcasts",
            LibraryCategory::Books => "Shared books",
        }
    }

    pub const fn personal_label(self) -> &'static str {
        match self {
            LibraryCategory::Videos => "My videos",
            LibraryCategory::Music => "My music",
            LibraryCategory::Audiobooks => "My audiobooks",
            LibraryCategory::Podcasts => "My podcasts",
            LibraryCategory::Books => "My books",
        }
    }

    /// The primary kind stored directly in this category.
    pub const fn primary_kind(self) -> MediaKind {
        match self {
            LibraryCategory::Videos => MediaKind::Video,
            LibraryCategory::Music => MediaKind::Music,
            LibraryCategory::Audiobooks => MediaKind::Audiobook,
            LibraryCategory::Podcasts => MediaKind::Podcast,
            LibraryCategory::Books => MediaKind::Book,
        }
    }

    /// Media kinds that may live in this category. Companion kinds
    /// (artwork, subtitles) are accepted in every category because they
    /// travel with their parent item. ISO containers have no category yet;
    /// the DVD inbox is listed directly rather than catalogued.
    pub const fn media_kinds(self) -> &'static [MediaKind] {
        match self {
            LibraryCategory::Videos => &[MediaKind::Video],
            LibraryCategory::Music => &[MediaKind::Music],
            LibraryCategory::Audiobooks => &[MediaKind::Audiobook],
            LibraryCategory::Podcasts => &[MediaKind::Podcast],
            LibraryCategory::Books => &[MediaKind::Book],
        }
    }

    pub fn parse(value: &str) -> Option<LibraryCategory> {
        LibraryCategory::ALL
            .into_iter()
            .find(|category| category.as_str() == value)
    }
}

impl fmt::Display for LibraryCategory {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

impl std::str::FromStr for LibraryCategory {
    type Err = UnknownLibraryCategory;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        LibraryCategory::parse(value).ok_or_else(|| UnknownLibraryCategory {
            value: value.to_string(),
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct UnknownLibraryCategory {
    pub value: String,
}

impl fmt::Display for UnknownLibraryCategory {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "unknown library category: {}", self.value)
    }
}

impl std::error::Error for UnknownLibraryCategory {}

impl rusqlite::types::ToSql for MediaKind {
    fn to_sql(&self) -> rusqlite::Result<rusqlite::types::ToSqlOutput<'_>> {
        Ok(rusqlite::types::ToSqlOutput::Borrowed(
            rusqlite::types::ValueRef::Text(self.as_str().as_bytes()),
        ))
    }
}

impl rusqlite::types::FromSql for MediaKind {
    fn column_result(value: rusqlite::types::ValueRef<'_>) -> rusqlite::types::FromSqlResult<Self> {
        let text = value.as_str()?;
        MediaKind::parse(text).ok_or(rusqlite::types::FromSqlError::InvalidType)
    }
}

/// Classifies a lowercased file extension within a library category into a
/// media kind. Companion kinds (artwork, subtitles) are recognized in every
/// category because they are filed beside the item they describe.
pub fn classify(category: LibraryCategory, extension: &str) -> Option<MediaKind> {
    for companion in [MediaKind::Artwork, MediaKind::Subtitle] {
        if companion.extensions().contains(&extension) {
            return Some(companion);
        }
    }
    let kinds = category.media_kinds();
    let kind = kinds
        .iter()
        .copied()
        .find(|kind| kind.extensions().contains(&extension))?;
    debug_assert!(category.media_kinds().contains(&kind));
    Some(kind)
}

/// The on-disk document format of a portable metadata sidecar. The two formats
/// the library writes today are NFO (video, music) and OPF (audiobook, book).
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SidecarFormat {
    Nfo,
    Opf,
}

impl SidecarFormat {
    pub const ALL: [SidecarFormat; 2] = [SidecarFormat::Nfo, SidecarFormat::Opf];

    pub const fn as_str(self) -> &'static str {
        match self {
            SidecarFormat::Nfo => "nfo",
            SidecarFormat::Opf => "opf",
        }
    }

    /// File extension used when writing this sidecar to disk.
    pub const fn extension(self) -> &'static str {
        self.as_str()
    }
}

impl fmt::Display for SidecarFormat {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

/// Where a media item's authoritative portable metadata lives. This is the
/// distinction the app-transfer contract needs: whether metadata can move with
/// the file (sidecar or embedded) or is locked to an application.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MetadataCarrier {
    /// Metadata is written to a sibling file (`.nfo` or `.opf`).
    Sidecar(SidecarFormat),
    /// Metadata is written inside the item itself (EPUB/CBZ package, PDF XMP).
    Embedded,
    /// The item has no portable metadata carrier; metadata lives only in an
    /// application database or embedded audio tags that cannot be rewritten.
    NativeOnly,
}

/// Describes where a media kind keeps its portable metadata. This is a single
/// source of truth used by the metadata modification UI and (later) the
/// application import/export contract, so a new kind or app can be added
/// without re-deriving carrier rules in several places.
pub trait MetadataCarrierStrategy {
    fn carrier(&self) -> Option<MetadataCarrier>;
}

impl MetadataCarrierStrategy for MediaKind {
    fn carrier(&self) -> Option<MetadataCarrier> {
        match self {
            MediaKind::Video => Some(MetadataCarrier::Sidecar(SidecarFormat::Nfo)),
            MediaKind::Music => Some(MetadataCarrier::Sidecar(SidecarFormat::Nfo)),
            MediaKind::Audiobook => Some(MetadataCarrier::Sidecar(SidecarFormat::Opf)),
            MediaKind::Book => Some(MetadataCarrier::Embedded),
            MediaKind::Podcast => Some(MetadataCarrier::NativeOnly),
            MediaKind::Artwork | MediaKind::Subtitle | MediaKind::Iso => None,
        }
    }
}

impl MediaKind {
    /// The portable metadata carrier for this kind, if any.
    pub fn carrier(self) -> Option<MetadataCarrier> {
        MetadataCarrierStrategy::carrier(&self)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn media_kind_strings_round_trip() {
        for kind in MediaKind::ALL {
            assert_eq!(MediaKind::parse(kind.as_str()), Some(kind));
            assert_eq!(kind.as_str().parse::<MediaKind>().unwrap(), kind);
        }
        assert_eq!(MediaKind::parse("nonsense"), None);
    }

    #[test]
    fn library_category_strings_round_trip() {
        for category in LibraryCategory::ALL {
            assert_eq!(LibraryCategory::parse(category.as_str()), Some(category));
            assert_eq!(
                category.as_str().parse::<LibraryCategory>().unwrap(),
                category
            );
        }
        assert_eq!(LibraryCategory::parse("iso"), None);
    }

    #[test]
    fn serde_serializes_historical_strings() {
        assert_eq!(
            serde_json::to_value(MediaKind::Audiobook).unwrap(),
            "audiobook"
        );
        assert_eq!(
            serde_json::from_value::<MediaKind>(serde_json::Value::String("audiobook".into()))
                .unwrap(),
            MediaKind::Audiobook
        );
        assert_eq!(
            serde_json::to_value(LibraryCategory::Audiobooks).unwrap(),
            "audiobooks"
        );
    }

    #[test]
    fn every_category_kind_classifies_from_its_extensions() {
        for category in LibraryCategory::ALL {
            for kind in category.media_kinds() {
                for extension in kind.extensions() {
                    assert_eq!(
                        classify(category, extension),
                        Some(*kind),
                        "{extension} in {category:?}"
                    );
                }
            }
        }
    }

    #[test]
    fn companion_kinds_classify_in_every_category() {
        for category in LibraryCategory::ALL {
            assert_eq!(classify(category, "jpg"), Some(MediaKind::Artwork));
            assert_eq!(classify(category, "srt"), Some(MediaKind::Subtitle));
            assert_eq!(classify(category, "xyz123"), None);
        }
    }

    #[test]
    fn primary_kinds_map_to_their_category() {
        for category in LibraryCategory::ALL {
            assert_eq!(category.primary_kind().category(), Some(category));
            assert!(category.primary_kind().is_primary());
        }
        assert!(MediaKind::Artwork.is_companion());
        assert!(MediaKind::Subtitle.is_companion());
        assert!(!MediaKind::Iso.is_primary());
        assert!(!MediaKind::Iso.is_companion());
    }

    #[test]
    fn iso_is_not_classified_until_it_has_a_category() {
        // The DVD inbox is listed outside the catalog today; classification
        // of ISO files is intentionally reserved for a future category.
        for category in LibraryCategory::ALL {
            assert_eq!(classify(category, "iso"), None);
        }
    }

    #[test]
    fn sidecar_formats_serialize_to_historical_strings() {
        for format in SidecarFormat::ALL {
            assert_eq!(format.as_str(), format.extension());
        }
        assert_eq!(serde_json::to_value(SidecarFormat::Nfo).unwrap(), "nfo");
        assert_eq!(serde_json::to_value(SidecarFormat::Opf).unwrap(), "opf");
    }

    #[test]
    fn carriers_match_the_library_wire_contract() {
        use MetadataCarrier::{Embedded, NativeOnly, Sidecar};
        assert_eq!(
            MediaKind::Video.carrier(),
            Some(Sidecar(SidecarFormat::Nfo))
        );
        assert_eq!(
            MediaKind::Music.carrier(),
            Some(Sidecar(SidecarFormat::Nfo))
        );
        assert_eq!(
            MediaKind::Audiobook.carrier(),
            Some(Sidecar(SidecarFormat::Opf))
        );
        assert_eq!(MediaKind::Book.carrier(), Some(Embedded));
        assert_eq!(MediaKind::Podcast.carrier(), Some(NativeOnly));
        assert_eq!(MediaKind::Artwork.carrier(), None);
        assert_eq!(MediaKind::Subtitle.carrier(), None);
        assert_eq!(MediaKind::Iso.carrier(), None);
    }

    #[test]
    fn every_primary_kind_has_a_carrier() {
        for kind in MediaKind::PRIMARY {
            assert!(kind.carrier().is_some(), "{kind:?} has no carrier");
        }
    }
}
