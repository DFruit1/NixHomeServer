use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PickedFolder {
    pub uri: String,
    pub display_name: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalEntry {
    pub path: String,
    pub kind: String,
    pub size: u64,
    pub modified_unix_ms: u64,
    pub sha256: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct LocalListing {
    pub entries: Vec<LocalEntry>,
}
