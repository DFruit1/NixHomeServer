//! Application-dispatched artwork edits produce recoverable broker plans.
//! Image decoding, authorization, staging and confirmation remain in the HTTP layer.
use crate::{
    broker::{
        ArchiveEmbeddedArtworkAction, BrokerAction, InstallArtworkAction, ReplaceArtworkAction,
    },
    catalog::CatalogItem,
};

/// Embedded artwork already extracted from a media container and staged in the
/// provider staging directory, ready to be archived before a sidecar cover is
/// installed. The media container itself is never rewritten.
pub struct EmbeddedArtworkStaging<'a> {
    pub staging_filename: &'a str,
    pub expected: &'a str,
    pub extension: &'a str,
}

pub struct ArtworkEditRequest<'a> {
    pub item: &'a CatalogItem,
    pub existing_artwork: Option<&'a CatalogItem>,
    pub embedded_artwork: Option<EmbeddedArtworkStaging<'a>>,
    pub extension: &'a str,
    pub staging_filename: &'a str,
    pub expected: &'a str,
    pub request_id: &'a str,
}

pub struct ArtworkPlanAction {
    pub broker_action: BrokerAction,
    /// Optional first action that archives the extracted embedded cover into the
    /// media's superseded subfolder before the new cover is installed.
    pub archive_action: Option<BrokerAction>,
    pub archived_relative_path: Option<String>,
    pub destination_relative_path: String,
}

/// Shared portable image-file implementation. Each application explicitly opts
/// into this behavior through its required `plan_artwork_edit` implementation.
/// This writes a sidecar; it does not imply a native app or embedded-image edit.
pub fn sidecar_artwork_plan(request: ArtworkEditRequest<'_>) -> ArtworkPlanAction {
    let item = request.item;
    let extension = request.extension;
    let request_id = request.request_id;
    if let Some(artwork) = request.existing_artwork {
        let (parent, filename) = artwork
            .relative_path
            .rsplit_once('/')
            .unwrap_or(("", &artwork.relative_path));
        let (stem, original_extension) = filename.rsplit_once('.').unwrap_or((filename, "jpg"));
        let destination_relative_path = join_relative(parent, &format!("{stem}.{extension}"));
        let archived_relative_path = join_relative(
            parent,
            &format!("superseded/{stem}-{request_id}.{original_extension}"),
        );
        ArtworkPlanAction {
            broker_action: BrokerAction::ReplaceArtwork(ReplaceArtworkAction {
                staging_filename: request.staging_filename.to_string(),
                root_id: artwork.root_id.clone(),
                source_relative_path: artwork.relative_path.clone(),
                archived_relative_path: archived_relative_path.clone(),
                replacement_relative_path: destination_relative_path.clone(),
                expected_source: artwork.fingerprint.clone(),
                expected_replacement: request.expected.to_string(),
            }),
            archive_action: None,
            archived_relative_path: Some(archived_relative_path),
            destination_relative_path,
        }
    } else {
        let parent = item
            .relative_path
            .rsplit_once('/')
            .map(|(parent, _)| parent)
            .unwrap_or("");
        let (archive_action, archived_relative_path) =
            embedded_archive_action(item, parent, request_id, request.embedded_artwork);
        let destination_relative_path = join_relative(parent, &format!("cover.{extension}"));
        ArtworkPlanAction {
            broker_action: BrokerAction::InstallArtwork(InstallArtworkAction {
                staging_filename: request.staging_filename.to_string(),
                destination_root_id: item.root_id.clone(),
                destination_relative_path: destination_relative_path.clone(),
                expected: request.expected.to_string(),
            }),
            archive_action,
            archived_relative_path,
            destination_relative_path,
        }
    }
}

/// Build the broker action that preserves an extracted embedded cover in the
/// media folder's superseded subfolder. The archive lives beside the media so
/// the write never has to cross a filesystem boundary.
fn embedded_archive_action(
    item: &CatalogItem,
    parent: &str,
    request_id: &str,
    embedded: Option<EmbeddedArtworkStaging<'_>>,
) -> (Option<BrokerAction>, Option<String>) {
    let Some(embedded) = embedded else {
        return (None, None);
    };
    let filename = item
        .relative_path
        .rsplit('/')
        .next()
        .unwrap_or(&item.relative_path);
    let stem = filename
        .rsplit_once('.')
        .map(|(stem, _)| stem)
        .unwrap_or(filename);
    let archived_relative_path = join_relative(
        parent,
        &format!(
            "superseded/{stem}-{request_id}.{}",
            embedded.extension.trim_start_matches('.')
        ),
    );
    (
        Some(BrokerAction::ArchiveEmbeddedArtwork(
            ArchiveEmbeddedArtworkAction {
                staging_filename: embedded.staging_filename.to_string(),
                root_id: item.root_id.clone(),
                archived_relative_path: archived_relative_path.clone(),
                expected: embedded.expected.to_string(),
            },
        )),
        Some(archived_relative_path),
    )
}

fn join_relative(parent: &str, filename: &str) -> String {
    if parent.is_empty() {
        filename.to_string()
    } else {
        format!("{parent}/{filename}")
    }
}
