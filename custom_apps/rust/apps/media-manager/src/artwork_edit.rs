//! Application-dispatched artwork edits produce recoverable broker plans.
//! Image decoding, authorization, staging and confirmation remain in the HTTP layer.
use crate::{
    broker::{BrokerAction, InstallArtworkAction, ReplaceArtworkAction},
    catalog::CatalogItem,
};

pub struct ArtworkEditRequest<'a> {
    pub item: &'a CatalogItem,
    pub existing_artwork: Option<&'a CatalogItem>,
    pub extension: &'a str,
    pub staging_filename: &'a str,
    pub expected: &'a str,
    pub request_id: &'a str,
}

pub struct ArtworkPlanAction {
    pub broker_action: BrokerAction,
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
            archived_relative_path: Some(archived_relative_path),
            destination_relative_path,
        }
    } else {
        let parent = item
            .relative_path
            .rsplit_once('/')
            .map(|(parent, _)| parent)
            .unwrap_or("");
        let destination_relative_path = join_relative(parent, &format!("cover.{extension}"));
        ArtworkPlanAction {
            broker_action: BrokerAction::InstallArtwork(InstallArtworkAction {
                staging_filename: request.staging_filename.to_string(),
                destination_root_id: item.root_id.clone(),
                destination_relative_path: destination_relative_path.clone(),
                expected: request.expected.to_string(),
            }),
            archived_relative_path: None,
            destination_relative_path,
        }
    }
}

fn join_relative(parent: &str, filename: &str) -> String {
    if parent.is_empty() {
        filename.to_string()
    } else {
        format!("{parent}/{filename}")
    }
}
