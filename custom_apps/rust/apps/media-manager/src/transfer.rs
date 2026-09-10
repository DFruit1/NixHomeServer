//! Media transfer contract: how media files can be moved between
//! applications through the library.
//!
//! An application opts into transfer by implementing [`MediaTransfer`] and
//! returning [`TransferCapability::ImportExport`]. Applications that own their
//! file layout (for example Immich) stay [`TransferCapability::ReadOnly`] and
//! are never offered as a move source or destination.
//!
//! The contract mirrors the rule that a file may be moved only when the
//! receiving application can re-index it after a refresh. Sidecars that the
//! receiving application cannot consume are preserved at the source rather
//! than deleted, unless the application opts into conversion by overriding
//! [`MediaTransfer::import_item`].

use crate::applications::{Audiobookshelf, Jellyfin, Kavita, MediaApplication};
use crate::catalog::CatalogItem;
use crate::media::{LibraryCategory, MediaKind, MetadataCarrier, SidecarFormat};
use serde::{Deserialize, Serialize};

/// Whether an application allows its media to be moved into and out of its
/// storage through the library UI.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TransferCapability {
    /// Files can be moved with ordinary filesystem moves and the application
    /// re-indexes them on the next refresh.
    ImportExport,
    /// The application owns its library layout and cannot be moved safely
    /// (for example Immich); it is read-only in the transfer UI.
    ReadOnly,
}

/// The role a file plays during a transfer: the media itself or a companion
/// that travels with it.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ArtifactRole {
    Primary,
    Sidecar,
    Subtitle,
    Artwork,
}

/// A single file that travels with an item during a transfer.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportedArtifact {
    pub relative_path: String,
    pub role: ArtifactRole,
    /// Present when the artifact is a portable metadata sidecar.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sidecar_format: Option<SidecarFormat>,
}

/// The set of files an application hands over for one item.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportedMedia {
    pub media_kind: MediaKind,
    pub artifacts: Vec<ExportedArtifact>,
}

/// A sidecar the receiving application rewrote into a format it can consume.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConvertedArtifact {
    pub artifact: ExportedArtifact,
    pub to_format: SidecarFormat,
}

/// How a receiving application takes an exported item: which artifacts it
/// accepts, which it converts, and which it leaves preserved at the source.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportPlan {
    pub accepted: Vec<ExportedArtifact>,
    pub converted: Vec<ConvertedArtifact>,
    pub preserved: Vec<ExportedArtifact>,
}

/// The transfer contract every transferable application implements.
pub trait MediaTransfer: MediaApplication {
    /// Whether media can be moved into and out of this application. The safe
    /// default is [`TransferCapability::ReadOnly`]; an application opts in to
    /// moves by returning [`TransferCapability::ImportExport`].
    fn transfer_capability(&self) -> TransferCapability {
        TransferCapability::ReadOnly
    }

    /// Describe the files that move out of this application with `item`. The
    /// default collects the primary file plus its portable sidecar (if any);
    /// applications override to include additional companions such as extra
    /// subtitle or artwork files.
    fn export_item(&self, item: &CatalogItem) -> ExportedMedia {
        let mut artifacts = vec![ExportedArtifact {
            relative_path: item.relative_path.clone(),
            role: ArtifactRole::Primary,
            sidecar_format: None,
        }];
        if let Some(MetadataCarrier::Sidecar(_)) = item.media_kind.carrier() {
            if let Some((path, format)) = crate::metadata::item_sidecar_path(item) {
                artifacts.push(ExportedArtifact {
                    relative_path: path,
                    role: ArtifactRole::Sidecar,
                    sidecar_format: Some(format),
                });
            }
        }
        ExportedMedia {
            media_kind: item.media_kind,
            artifacts,
        }
    }

    /// Whether this application reads the given sidecar format. The safe
    /// default is `false`, which makes every sidecar a preserved (kept) file.
    fn consumes_sidecar(&self, _format: SidecarFormat) -> bool {
        false
    }

    /// The library category this application publishes `kind` into. This is
    /// where an item lands when it is imported into this application. A
    /// second application for the same kind would point this at its own
    /// storage location.
    fn storage_category(&self, kind: MediaKind) -> Option<LibraryCategory> {
        kind.category()
    }

    /// Default preserve rule: sidecars this application cannot consume are
    /// kept at the source rather than deleted. Applications that can convert
    /// a sidecar override [`MediaTransfer::import_item`] instead.
    fn preserve_unimported(&self, exported: &ExportedMedia) -> Vec<ExportedArtifact> {
        exported
            .artifacts
            .iter()
            .filter(|artifact| {
                artifact
                    .sidecar_format
                    .is_some_and(|format| !self.consumes_sidecar(format))
            })
            .cloned()
            .collect()
    }

    /// Plan how this application ingests an exported item. The default accepts
    /// every artifact except sidecars it cannot consume, which it preserves;
    /// applications that convert sidecars override this to fill `converted`.
    fn import_item(&self, _item: &CatalogItem, exported: &ExportedMedia) -> ImportPlan {
        let preserved = self.preserve_unimported(exported);
        let accepted = exported
            .artifacts
            .iter()
            .filter(|artifact| !preserved.contains(artifact))
            .cloned()
            .collect();
        ImportPlan {
            accepted,
            converted: Vec::new(),
            preserved,
        }
    }
}

impl MediaTransfer for Jellyfin {
    fn transfer_capability(&self) -> TransferCapability {
        TransferCapability::ImportExport
    }

    fn consumes_sidecar(&self, format: SidecarFormat) -> bool {
        format == SidecarFormat::Nfo
    }
}

impl MediaTransfer for Audiobookshelf {
    fn transfer_capability(&self) -> TransferCapability {
        TransferCapability::ImportExport
    }

    fn consumes_sidecar(&self, format: SidecarFormat) -> bool {
        matches!(format, SidecarFormat::Nfo | SidecarFormat::Opf)
    }
}

impl MediaTransfer for Kavita {
    fn transfer_capability(&self) -> TransferCapability {
        TransferCapability::ImportExport
    }
}

/// Every registered application, as a transfer participant.
pub fn transfer_apps() -> &'static [&'static dyn MediaTransfer] {
    &[&Jellyfin, &Audiobookshelf, &Kavita]
}

/// Applications that can receive `kind` through a transfer, i.e. those that
/// both manage the kind and allow filesystem moves.
pub fn transferable(kind: MediaKind) -> impl Iterator<Item = &'static dyn MediaTransfer> {
    transfer_apps().iter().copied().filter(move |app| {
        app.transfer_capability() == TransferCapability::ImportExport
            && app.serves().contains(&kind)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::applications::{Audiobookshelf, Jellyfin, Kavita};

    fn item(relative_path: &str, media_kind: MediaKind) -> CatalogItem {
        CatalogItem {
            id: "item-test".to_string(),
            root_id: "shared-videos".to_string(),
            owner_username: None,
            relative_path: relative_path.to_string(),
            media_kind,
            size_bytes: 1,
            modified_ns: 1,
            fingerprint: "f".to_string(),
        }
    }

    #[test]
    fn export_collects_the_primary_file_and_sidecar() {
        let video = item("Movies/Foo (2001)/Foo (2001).mkv", MediaKind::Video);
        let exported = Jellyfin.export_item(&video);
        assert_eq!(exported.media_kind, MediaKind::Video);
        assert_eq!(
            exported.artifacts[0],
            ExportedArtifact {
                relative_path: "Movies/Foo (2001)/Foo (2001).mkv".to_string(),
                role: ArtifactRole::Primary,
                sidecar_format: None,
            }
        );
        assert_eq!(
            exported.artifacts[1],
            ExportedArtifact {
                relative_path: "Movies/Foo (2001)/Foo (2001).nfo".to_string(),
                role: ArtifactRole::Sidecar,
                sidecar_format: Some(SidecarFormat::Nfo),
            }
        );
    }

    #[test]
    fn export_omits_a_sidecar_for_embedded_and_native_only_kinds() {
        let book = item("Books/Bar.epub", MediaKind::Book);
        let exported = Kavita.export_item(&book);
        assert_eq!(exported.artifacts.len(), 1);
        assert_eq!(exported.artifacts[0].role, ArtifactRole::Primary);

        let podcast = item("Podcasts/Ep.m4a", MediaKind::Podcast);
        let exported = Audiobookshelf.export_item(&podcast);
        assert_eq!(exported.artifacts.len(), 1);
        assert_eq!(exported.artifacts[0].role, ArtifactRole::Primary);
    }

    #[test]
    fn import_preserves_sidecars_the_receiver_cannot_consume() {
        let audiobook = item("Audiobooks/Book/Book.m4b", MediaKind::Audiobook);
        let exported = Audiobookshelf.export_item(&audiobook);
        assert!(exported
            .artifacts
            .iter()
            .any(|artifact| { artifact.sidecar_format == Some(SidecarFormat::Opf) }));

        // Jellyfin does not read OPF, so importing it preserves the sidecar.
        let plan = Jellyfin.import_item(&audiobook, &exported);
        assert!(plan
            .preserved
            .iter()
            .any(|artifact| { artifact.sidecar_format == Some(SidecarFormat::Opf) }));
        assert!(plan
            .accepted
            .iter()
            .any(|artifact| artifact.role == ArtifactRole::Primary));
        assert!(plan.converted.is_empty());
    }

    #[test]
    fn transferable_lists_import_export_apps_that_serve_the_kind() {
        assert_eq!(
            transferable(MediaKind::Video)
                .map(|app| app.id())
                .collect::<Vec<_>>(),
            ["jellyfin"]
        );
        assert_eq!(
            transferable(MediaKind::Book)
                .map(|app| app.id())
                .collect::<Vec<_>>(),
            ["kavita"]
        );
        assert_eq!(transferable(MediaKind::Artwork).count(), 0);
        assert_eq!(transferable(MediaKind::Subtitle).count(), 0);
    }

    #[test]
    fn every_registered_app_is_transferable_today() {
        for app in transfer_apps() {
            assert_eq!(
                app.transfer_capability(),
                TransferCapability::ImportExport,
                "{} should be transferable",
                app.id()
            );
        }
    }

    #[test]
    fn storage_category_maps_a_kind_to_its_publishing_category() {
        assert_eq!(
            Jellyfin.storage_category(MediaKind::Video),
            Some(LibraryCategory::Videos)
        );
        assert_eq!(
            Jellyfin.storage_category(MediaKind::Music),
            Some(LibraryCategory::Music)
        );
        assert_eq!(
            Audiobookshelf.storage_category(MediaKind::Audiobook),
            Some(LibraryCategory::Audiobooks)
        );
        assert_eq!(
            Kavita.storage_category(MediaKind::Book),
            Some(LibraryCategory::Books)
        );
        assert_eq!(Jellyfin.storage_category(MediaKind::Artwork), None);
        assert_eq!(Jellyfin.storage_category(MediaKind::Subtitle), None);
    }
}
