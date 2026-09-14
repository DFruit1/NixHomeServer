//! Application registry: the built-in media applications that manage library
//! media and whose exported metadata the catalog can import.
//!
//! Consumer effects and modification targets are derived from this registry
//! rather than hardcoded per media kind, so a kind can be served by more than
//! one application and a new application is added by implementing
//! [`MediaApplication`] and [`MetadataSource`] and registering it in
//! [`applications`] and [`metadata_sources`].

use crate::artwork_edit::{sidecar_artwork_plan, ArtworkEditRequest, ArtworkPlanAction};
use crate::config::AppConfig;
use crate::media::MediaKind;
use std::path::Path;

/// How an application consumes portable metadata for a kind it serves.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ConsumerProfile {
    pub effect: &'static str,
    pub portable: bool,
    pub message: &'static str,
    /// Ordered description of the sources the application reads for this kind
    /// and the priority it applies. Declared here so the UI can show users
    /// exactly where each program reads metadata from.
    pub source_priority: &'static str,
}

/// The application-local metadata edit target (the app's native editor).
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct NativeEditTarget {
    pub id: &'static str,
    pub label: &'static str,
}

/// A media application that owns (or could own) library media. The library UI
/// uses this to describe which application a kind belongs to and how metadata
/// edits propagate to it.
pub trait MediaApplication: Send + Sync {
    /// Required for every application: produce its concrete, recoverable image
    /// edit plan. No default implementation may silently choose another app's policy.
    fn plan_artwork_edit(&self, request: ArtworkEditRequest<'_>) -> ArtworkPlanAction;
    fn id(&self) -> &'static str;
    fn label(&self) -> &'static str;
    /// Kinds this application natively manages.
    fn serves(&self) -> &'static [MediaKind];
    fn public_url(&self, config: &AppConfig) -> Option<String>;
    fn consumer_profile(&self, kind: MediaKind) -> Option<ConsumerProfile>;
    fn native_edit_target(&self, kind: MediaKind) -> Option<NativeEditTarget>;
    /// The refresh capability this application advertises, if it can be
    /// re-indexed through the library (e.g. `"library-refresh"`). The safe
    /// default is `None`, meaning no refresh adapter.
    fn refresh_capability(&self) -> Option<&'static str> {
        None
    }
}

/// An application whose metadata export can be imported by the catalog. This
/// is separate from [`MediaApplication`] because an application may import
/// metadata for kinds it does not fully manage (Jellyfin exports movies and
/// episodes for the video library but only "manages" the video/music kinds).
pub trait MetadataSource: Send + Sync {
    fn app_id(&self) -> &'static str;
    fn app_label(&self) -> &'static str;
    /// Kinds whose items should be matched against this source's export.
    fn imports(&self) -> &'static [MediaKind];
    fn cache_file<'a>(&self, config: &'a AppConfig) -> Option<&'a Path>;
    fn allow_folder_prefix(&self) -> bool;
}

pub struct Jellyfin;

impl MediaApplication for Jellyfin {
    fn plan_artwork_edit(&self, request: ArtworkEditRequest<'_>) -> ArtworkPlanAction {
        sidecar_artwork_plan(request)
    }
    fn id(&self) -> &'static str {
        "jellyfin"
    }
    fn label(&self) -> &'static str {
        "Jellyfin"
    }
    fn serves(&self) -> &'static [MediaKind] {
        &[MediaKind::Video, MediaKind::Music]
    }
    fn public_url(&self, config: &AppConfig) -> Option<String> {
        config.jellyfin_public_url.clone()
    }
    fn consumer_profile(&self, _kind: MediaKind) -> Option<ConsumerProfile> {
        Some(ConsumerProfile {
            effect: "read-after-refresh",
            portable: true,
            message: "Jellyfin reads correctly named local NFO files after a library refresh.",
            source_priority: "NFO sidecar → embedded file tags → Jellyfin library database",
        })
    }
    fn native_edit_target(&self, _kind: MediaKind) -> Option<NativeEditTarget> {
        Some(NativeEditTarget {
            id: "jellyfin-application",
            label: "Jellyfin app metadata",
        })
    }
    fn refresh_capability(&self) -> Option<&'static str> {
        Some("library-refresh")
    }
}

impl MetadataSource for Jellyfin {
    fn app_id(&self) -> &'static str {
        "jellyfin"
    }
    fn app_label(&self) -> &'static str {
        "Jellyfin"
    }
    fn imports(&self) -> &'static [MediaKind] {
        &MediaKind::PRIMARY
    }
    fn cache_file<'a>(&self, config: &'a AppConfig) -> Option<&'a Path> {
        config.jellyfin_metadata_cache_file.as_deref()
    }
    fn allow_folder_prefix(&self) -> bool {
        false
    }
}

pub struct Audiobookshelf;

impl MediaApplication for Audiobookshelf {
    fn plan_artwork_edit(&self, request: ArtworkEditRequest<'_>) -> ArtworkPlanAction {
        sidecar_artwork_plan(request)
    }
    fn id(&self) -> &'static str {
        "audiobookshelf"
    }
    fn label(&self) -> &'static str {
        "Audiobookshelf"
    }
    fn serves(&self) -> &'static [MediaKind] {
        &[MediaKind::Audiobook, MediaKind::Podcast]
    }
    fn public_url(&self, config: &AppConfig) -> Option<String> {
        config.audiobookshelf_public_url.clone()
    }
    fn consumer_profile(&self, kind: MediaKind) -> Option<ConsumerProfile> {
        match kind {
            MediaKind::Audiobook => Some(ConsumerProfile {
                effect: "read-after-refresh",
                portable: true,
                message: "Audiobookshelf reads OPF/NFO files according to the library metadata priority.",
                source_priority: "metadata.opf sidecar → embedded audio tags → Audiobookshelf library database",
            }),
            MediaKind::Podcast => Some(ConsumerProfile {
                effect: "native-podcast-metadata",
                portable: false,
                message: "Audiobookshelf keeps podcasts as a distinct media type; embedded episode tags remain portable, while feed and episode metadata can be managed in its native editor.",
                source_priority: "Embedded episode tags → Audiobookshelf podcast feed database",
            }),
            _ => None,
        }
    }
    fn native_edit_target(&self, _kind: MediaKind) -> Option<NativeEditTarget> {
        Some(NativeEditTarget {
            id: "audiobookshelf-application",
            label: "Audiobookshelf app metadata",
        })
    }
    fn refresh_capability(&self) -> Option<&'static str> {
        Some("library-refresh")
    }
}

impl MetadataSource for Audiobookshelf {
    fn app_id(&self) -> &'static str {
        "audiobookshelf"
    }
    fn app_label(&self) -> &'static str {
        "Audiobookshelf"
    }
    fn imports(&self) -> &'static [MediaKind] {
        &[MediaKind::Audiobook, MediaKind::Podcast]
    }
    fn cache_file<'a>(&self, config: &'a AppConfig) -> Option<&'a Path> {
        config.audiobookshelf_metadata_cache_file.as_deref()
    }
    fn allow_folder_prefix(&self) -> bool {
        true
    }
}

pub struct Kavita;

impl MediaApplication for Kavita {
    fn plan_artwork_edit(&self, request: ArtworkEditRequest<'_>) -> ArtworkPlanAction {
        sidecar_artwork_plan(request)
    }
    fn id(&self) -> &'static str {
        "kavita"
    }
    fn label(&self) -> &'static str {
        "Kavita"
    }
    fn serves(&self) -> &'static [MediaKind] {
        &[MediaKind::Book]
    }
    fn public_url(&self, config: &AppConfig) -> Option<String> {
        config.kavita_public_url.clone()
    }
    fn consumer_profile(&self, _kind: MediaKind) -> Option<ConsumerProfile> {
        Some(ConsumerProfile {
            effect: "embedded-metadata-required",
            portable: false,
            message: "Kavita requires OPF inside EPUB, ComicInfo.xml inside comic archives, or PDF XMP metadata; an external OPF is ignored.",
            source_priority: "Embedded container metadata only — EPUB OPF, CBZ ComicInfo, or PDF XMP; an external sidecar is ignored",
        })
    }
    fn native_edit_target(&self, _kind: MediaKind) -> Option<NativeEditTarget> {
        Some(NativeEditTarget {
            id: "kavita-application",
            label: "Kavita app metadata",
        })
    }
    fn refresh_capability(&self) -> Option<&'static str> {
        Some("library-refresh")
    }
}

impl MetadataSource for Kavita {
    fn app_id(&self) -> &'static str {
        "kavita"
    }
    fn app_label(&self) -> &'static str {
        "Kavita"
    }
    fn imports(&self) -> &'static [MediaKind] {
        &[MediaKind::Book]
    }
    fn cache_file<'a>(&self, config: &'a AppConfig) -> Option<&'a Path> {
        config.kavita_metadata_cache_file.as_deref()
    }
    fn allow_folder_prefix(&self) -> bool {
        true
    }
}

/// Every registered media application.
pub fn applications() -> &'static [&'static dyn MediaApplication] {
    &[&Jellyfin, &Audiobookshelf, &Kavita]
}

/// Applications that natively manage the given kind.
pub fn serving(kind: MediaKind) -> impl Iterator<Item = &'static dyn MediaApplication> {
    applications()
        .iter()
        .copied()
        .filter(move |app| app.serves().contains(&kind))
}

/// Every registered metadata importer.
pub fn metadata_sources() -> &'static [&'static dyn MetadataSource] {
    &[&Jellyfin, &Audiobookshelf, &Kavita]
}

/// Whether the given application is present and enabled in the configuration.
pub fn integration_available(config: &AppConfig, id: &str) -> bool {
    config
        .integrations
        .iter()
        .any(|entry| entry.id == id && entry.available)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_application_plans_recoverable_artwork_edits() {
        use crate::{broker::BrokerAction, catalog::CatalogItem};
        for application in applications() {
            let item = CatalogItem {
                id: "item".into(),
                root_id: "library".into(),
                owner_username: None,
                relative_path: "Title/media.file".into(),
                media_kind: application.serves()[0],
                size_bytes: 10,
                modified_ns: 0,
                fingerprint: "media-fingerprint".into(),
            };
            let artwork = CatalogItem {
                relative_path: "Title/poster.jpg".into(),
                media_kind: MediaKind::Artwork,
                fingerprint: "old-image".into(),
                ..item.clone()
            };
            for existing in [None, Some(&artwork)] {
                let plan = application.plan_artwork_edit(ArtworkEditRequest {
                    item: &item,
                    existing_artwork: existing,
                    embedded_artwork: None,
                    extension: "png",
                    staging_filename: "upload.png",
                    expected: "new-image",
                    request_id: "request",
                });
                match plan.broker_action {
                    BrokerAction::InstallArtwork(action) => {
                        assert!(existing.is_none());
                        assert_eq!(action.destination_relative_path, "Title/cover.png");
                        assert_eq!(action.expected, "new-image");
                    }
                    BrokerAction::ReplaceArtwork(action) => {
                        assert!(existing.is_some());
                        assert_eq!(action.source_relative_path, "Title/poster.jpg");
                        assert_eq!(
                            action.archived_relative_path,
                            "Title/superseded/poster-request.jpg"
                        );
                        assert_eq!(action.replacement_relative_path, "Title/poster.png");
                        assert_eq!(action.expected_source, "old-image");
                        assert_eq!(action.expected_replacement, "new-image");
                    }
                    _ => panic!("unexpected artwork action for {}", application.id()),
                }
            }
        }
    }

    #[test]
    fn each_kind_is_served_by_the_expected_application() {
        assert_eq!(
            serving(MediaKind::Video)
                .map(|app| app.id())
                .collect::<Vec<_>>(),
            ["jellyfin"]
        );
        assert_eq!(
            serving(MediaKind::Music)
                .map(|app| app.id())
                .collect::<Vec<_>>(),
            ["jellyfin"]
        );
        assert_eq!(
            serving(MediaKind::Audiobook)
                .map(|app| app.id())
                .collect::<Vec<_>>(),
            ["audiobookshelf"]
        );
        assert_eq!(
            serving(MediaKind::Podcast)
                .map(|app| app.id())
                .collect::<Vec<_>>(),
            ["audiobookshelf"]
        );
        assert_eq!(
            serving(MediaKind::Book)
                .map(|app| app.id())
                .collect::<Vec<_>>(),
            ["kavita"]
        );
        assert_eq!(serving(MediaKind::Artwork).count(), 0);
        assert_eq!(serving(MediaKind::Subtitle).count(), 0);
        assert_eq!(serving(MediaKind::Iso).count(), 0);
    }

    #[test]
    fn every_primary_kind_has_exactly_one_serving_application_today() {
        // The registry must still resolve every primary kind to a consumer;
        // this becomes more than one only when a second app for a kind is added.
        for kind in MediaKind::PRIMARY {
            let apps = serving(kind).collect::<Vec<_>>();
            assert_eq!(
                apps.len(),
                1,
                "{kind:?} should be served by exactly one app"
            );
            assert!(apps[0].consumer_profile(kind).is_some());
            assert!(apps[0].native_edit_target(kind).is_some());
        }
    }

    #[test]
    fn metadata_sources_map_kinds_to_importers() {
        let sources = metadata_sources();
        let jellyfin = sources
            .iter()
            .find(|source| source.app_id() == "jellyfin")
            .unwrap();
        assert!(jellyfin.imports().contains(&MediaKind::Video));
        assert!(jellyfin.imports().contains(&MediaKind::Book));
        assert!(!jellyfin.allow_folder_prefix());

        let audiobookshelf = sources
            .iter()
            .find(|source| source.app_id() == "audiobookshelf")
            .unwrap();
        assert!(audiobookshelf.imports().contains(&MediaKind::Audiobook));
        assert!(audiobookshelf.allow_folder_prefix());

        let kavita = sources
            .iter()
            .find(|source| source.app_id() == "kavita")
            .unwrap();
        assert!(kavita.imports().contains(&MediaKind::Book));
        assert!(kavita.allow_folder_prefix());
    }
}
