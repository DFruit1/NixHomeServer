//! Media needs and actions: one capability table that maps every media kind to
//! the curation unit it forms and the user-facing actions it supports.
//!
//! Media kinds are consumed and stored differently. A movie is a single file, an
//! album is a folder whose files are tracks, a podcast is owned by its
//! application, and artwork or subtitles only exist beside another item. The
//! catalog, the HTTP handlers and the library UI all need to know those
//! differences, so they are named once here instead of being re-derived with
//! scattered `match media_kind` checks.
//!
//! This table answers only what is structurally true of a kind. Whether the
//! application that serves a kind is actually deployed is runtime state and
//! stays in the application registry; whether a specific file can be rewritten
//! stays in the metadata carrier and inspection layers.

use crate::media::{LibraryCategory, MediaKind};
use serde::{Deserialize, Serialize};

/// What the library treats as one curated item for a media kind.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CurationUnit {
    /// One file is one item; sibling files are independent items.
    File,
    /// A folder is one item and its files are parts (album tracks, chapters).
    FolderBundle,
    /// A file that only carries data for another item (cover artwork, subtitles).
    Companion,
    /// A container handled outside the catalog (the DVD ISO inbox).
    Container,
}

impl CurationUnit {
    /// Whether this unit is curated as a browsable, editable library item.
    pub const fn is_library_item(self) -> bool {
        matches!(self, CurationUnit::File | CurationUnit::FolderBundle)
    }
}

/// A user-facing action or intrinsic need the library can offer for a kind.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum MediaAction {
    /// Stream the file in the built-in player.
    PlayInline,
    /// Open the item in the application that owns it.
    PlayExternal,
    /// Install, replace, or upload cover artwork.
    EditArtwork,
    /// Write portable metadata (a sidecar or embedded tags).
    EditPortableMetadata,
    /// Metadata can only be edited in the owning application.
    EditNativeMetadata,
    /// Match metadata against external providers.
    LookupMetadata,
    /// Manage external and embedded subtitles.
    ManageSubtitles,
    /// Guided filename and folder organization.
    GuidedRename,
    /// Inspect and align track order inside a folder.
    TrackOrder,
}

impl MediaAction {
    pub const ALL: [MediaAction; 9] = [
        MediaAction::PlayInline,
        MediaAction::PlayExternal,
        MediaAction::EditArtwork,
        MediaAction::EditPortableMetadata,
        MediaAction::EditNativeMetadata,
        MediaAction::LookupMetadata,
        MediaAction::ManageSubtitles,
        MediaAction::GuidedRename,
        MediaAction::TrackOrder,
    ];
}

/// The intrinsic capabilities of one media kind.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaKindProfile {
    pub kind: MediaKind,
    pub curation_unit: CurationUnit,
    pub actions: &'static [MediaAction],
}

impl MediaKindProfile {
    pub fn supports(&self, action: MediaAction) -> bool {
        self.actions.contains(&action)
    }

    /// Whether the kind is curated as a browsable, editable library item.
    pub const fn is_library_item(&self) -> bool {
        self.curation_unit.is_library_item()
    }
}

const VIDEO_ACTIONS: &[MediaAction] = &[
    MediaAction::PlayExternal,
    MediaAction::EditArtwork,
    MediaAction::EditPortableMetadata,
    MediaAction::LookupMetadata,
    MediaAction::ManageSubtitles,
    MediaAction::GuidedRename,
];

const MUSIC_ACTIONS: &[MediaAction] = &[
    MediaAction::PlayInline,
    MediaAction::PlayExternal,
    MediaAction::EditArtwork,
    MediaAction::EditPortableMetadata,
    MediaAction::LookupMetadata,
    MediaAction::GuidedRename,
    MediaAction::TrackOrder,
];

const AUDIOBOOK_ACTIONS: &[MediaAction] = &[
    MediaAction::PlayInline,
    MediaAction::PlayExternal,
    MediaAction::EditArtwork,
    MediaAction::EditPortableMetadata,
    MediaAction::LookupMetadata,
    MediaAction::GuidedRename,
    MediaAction::TrackOrder,
];

const PODCAST_ACTIONS: &[MediaAction] = &[
    MediaAction::PlayExternal,
    MediaAction::EditArtwork,
    MediaAction::EditNativeMetadata,
    MediaAction::GuidedRename,
    MediaAction::TrackOrder,
];

const BOOK_ACTIONS: &[MediaAction] = &[
    MediaAction::PlayExternal,
    MediaAction::EditArtwork,
    MediaAction::EditPortableMetadata,
    MediaAction::LookupMetadata,
    MediaAction::GuidedRename,
];

/// An artwork file is the image itself, so it can always be replaced.
const ARTWORK_ACTIONS: &[MediaAction] = &[MediaAction::EditArtwork];
const SUBTITLE_ACTIONS: &[MediaAction] = &[];
const CONTAINER_ACTIONS: &[MediaAction] = &[];

impl MediaKind {
    /// The intrinsic capability profile for this kind.
    pub const fn profile(self) -> MediaKindProfile {
        match self {
            MediaKind::Video => MediaKindProfile {
                kind: self,
                curation_unit: CurationUnit::File,
                actions: VIDEO_ACTIONS,
            },
            MediaKind::Music => MediaKindProfile {
                kind: self,
                curation_unit: CurationUnit::FolderBundle,
                actions: MUSIC_ACTIONS,
            },
            MediaKind::Audiobook => MediaKindProfile {
                kind: self,
                curation_unit: CurationUnit::FolderBundle,
                actions: AUDIOBOOK_ACTIONS,
            },
            MediaKind::Podcast => MediaKindProfile {
                kind: self,
                curation_unit: CurationUnit::FolderBundle,
                actions: PODCAST_ACTIONS,
            },
            MediaKind::Book => MediaKindProfile {
                kind: self,
                curation_unit: CurationUnit::File,
                actions: BOOK_ACTIONS,
            },
            MediaKind::Artwork => MediaKindProfile {
                kind: self,
                curation_unit: CurationUnit::Companion,
                actions: ARTWORK_ACTIONS,
            },
            MediaKind::Subtitle => MediaKindProfile {
                kind: self,
                curation_unit: CurationUnit::Companion,
                actions: SUBTITLE_ACTIONS,
            },
            MediaKind::Iso => MediaKindProfile {
                kind: self,
                curation_unit: CurationUnit::Container,
                actions: CONTAINER_ACTIONS,
            },
        }
    }

    /// Whether this kind supports the given action.
    pub fn supports(self, action: MediaAction) -> bool {
        self.profile().supports(action)
    }
}

impl LibraryCategory {
    /// The capability profile of the kind stored directly in this category.
    pub const fn profile(self) -> MediaKindProfile {
        self.primary_kind().profile()
    }
}

/// Every media kind's profile, in canonical kind order. This is the wire form
/// the library UI uses instead of its own kind tables.
pub fn profiles() -> Vec<MediaKindProfile> {
    MediaKind::ALL.into_iter().map(MediaKind::profile).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media::MetadataCarrier;

    #[test]
    fn every_kind_has_exactly_one_profile() {
        let profiles = profiles();
        assert_eq!(profiles.len(), MediaKind::ALL.len());
        for kind in MediaKind::ALL {
            assert_eq!(profiles.iter().filter(|p| p.kind == kind).count(), 1);
            assert_eq!(kind.profile().kind, kind);
        }
    }

    #[test]
    fn action_lists_have_no_duplicates() {
        for kind in MediaKind::ALL {
            let actions = kind.profile().actions;
            for (index, action) in actions.iter().enumerate() {
                assert!(
                    !actions[index + 1..].contains(action),
                    "{kind:?} repeats {action:?}"
                );
            }
        }
    }

    #[test]
    fn companions_and_containers_are_not_library_items() {
        for kind in [MediaKind::Artwork, MediaKind::Subtitle, MediaKind::Iso] {
            assert!(!kind.profile().is_library_item(), "{kind:?}");
        }
        // An artwork file is the image itself and can be replaced; subtitles
        // and ISO containers expose no item-level actions.
        assert!(MediaKind::Artwork.supports(MediaAction::EditArtwork));
        assert!(MediaKind::Subtitle.profile().actions.is_empty());
        assert!(MediaKind::Iso.profile().actions.is_empty());
        for kind in MediaKind::PRIMARY {
            assert!(kind.profile().is_library_item(), "{kind:?}");
        }
    }

    #[test]
    fn video_is_a_file_with_subtitles_and_no_inline_playback() {
        let profile = MediaKind::Video.profile();
        assert_eq!(profile.curation_unit, CurationUnit::File);
        assert!(profile.supports(MediaAction::ManageSubtitles));
        assert!(profile.supports(MediaAction::EditPortableMetadata));
        assert!(profile.supports(MediaAction::LookupMetadata));
        assert!(!profile.supports(MediaAction::PlayInline));
        assert!(!profile.supports(MediaAction::TrackOrder));
    }

    #[test]
    fn audio_is_a_folder_bundle_with_inline_playback_and_track_order() {
        for kind in [MediaKind::Music, MediaKind::Audiobook] {
            let profile = kind.profile();
            assert_eq!(
                profile.curation_unit,
                CurationUnit::FolderBundle,
                "{kind:?}"
            );
            assert!(profile.supports(MediaAction::PlayInline), "{kind:?}");
            assert!(profile.supports(MediaAction::TrackOrder), "{kind:?}");
            assert!(!profile.supports(MediaAction::ManageSubtitles), "{kind:?}");
        }
    }

    #[test]
    fn podcast_is_native_only_without_inline_playback() {
        let profile = MediaKind::Podcast.profile();
        assert_eq!(profile.curation_unit, CurationUnit::FolderBundle);
        assert!(profile.supports(MediaAction::EditNativeMetadata));
        assert!(profile.supports(MediaAction::TrackOrder));
        assert!(!profile.supports(MediaAction::EditPortableMetadata));
        assert!(!profile.supports(MediaAction::LookupMetadata));
        assert!(!profile.supports(MediaAction::PlayInline));
    }

    #[test]
    fn book_uses_embedded_portable_metadata_and_no_inline_playback() {
        let profile = MediaKind::Book.profile();
        assert_eq!(profile.curation_unit, CurationUnit::File);
        assert!(profile.supports(MediaAction::EditPortableMetadata));
        assert!(profile.supports(MediaAction::LookupMetadata));
        assert!(!profile.supports(MediaAction::PlayInline));
    }

    #[test]
    fn every_primary_kind_has_exactly_one_metadata_edit_action() {
        let metadata_actions = [
            MediaAction::EditPortableMetadata,
            MediaAction::EditNativeMetadata,
        ];
        for kind in MediaKind::PRIMARY {
            let profile = kind.profile();
            assert_eq!(
                metadata_actions
                    .iter()
                    .filter(|action| profile.supports(**action))
                    .count(),
                1,
                "{kind:?} must have exactly one metadata edit action"
            );
        }
    }

    #[test]
    fn every_action_is_used_by_at_least_one_kind() {
        for action in MediaAction::ALL {
            assert!(
                MediaKind::ALL.into_iter().any(|kind| kind.supports(action)),
                "{action:?} is not mapped to any kind"
            );
        }
    }

    #[test]
    fn library_items_match_the_primary_kinds() {
        for kind in MediaKind::ALL {
            assert_eq!(
                kind.profile().is_library_item(),
                kind.is_primary(),
                "{kind:?} capability and primary-kind flags disagree"
            );
        }
    }

    #[test]
    fn metadata_actions_match_the_carrier() {
        // The metadata-edit actions and the metadata carrier answer the same
        // structural question, so adding one without the other is a bug the
        // table should catch.
        for kind in MediaKind::ALL {
            let portable = matches!(
                kind.carrier(),
                Some(MetadataCarrier::Sidecar(_) | MetadataCarrier::Embedded)
            );
            let native_only = matches!(kind.carrier(), Some(MetadataCarrier::NativeOnly));
            assert_eq!(
                kind.supports(MediaAction::EditPortableMetadata),
                portable,
                "{kind:?} portable action and carrier disagree"
            );
            assert_eq!(
                kind.supports(MediaAction::EditNativeMetadata),
                native_only,
                "{kind:?} native action and carrier disagree"
            );
        }
    }

    #[test]
    fn profiles_serialize_with_kebab_case_actions() {
        let value = serde_json::to_value(MediaKind::Music.profile()).unwrap();
        assert_eq!(value["kind"], "music");
        assert_eq!(value["curationUnit"], "folder_bundle");
        assert!(value["actions"]
            .as_array()
            .unwrap()
            .contains(&serde_json::json!("play-inline")));
        assert!(value["actions"]
            .as_array()
            .unwrap()
            .contains(&serde_json::json!("track-order")));
    }
}
