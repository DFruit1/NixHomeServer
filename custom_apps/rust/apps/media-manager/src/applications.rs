//! Application registry: the built-in media applications that manage library
//! media and whose exported metadata the catalog can import.
//!
//! Consumer effects and modification targets are derived from this registry
//! rather than hardcoded per media kind, so a kind can be served by more than
//! one application and a new application is added by implementing
//! [`MediaApplication`] and [`MetadataSource`] and registering it in
//! [`applications`] and [`metadata_sources`].

use crate::config::AppConfig;
use crate::media::MediaKind;
use std::path::Path;

/// How an application consumes portable metadata for a kind it serves.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ConsumerProfile {
    pub effect: &'static str,
    pub portable: bool,
    pub message: &'static str,
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
            }),
            MediaKind::Podcast => Some(ConsumerProfile {
                effect: "native-podcast-metadata",
                portable: false,
                message: "Audiobookshelf keeps podcasts as a distinct media type; embedded episode tags remain portable, while feed and episode metadata can be managed in its native editor.",
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
