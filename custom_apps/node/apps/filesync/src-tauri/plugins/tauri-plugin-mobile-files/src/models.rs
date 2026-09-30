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

#[derive(Debug, Deserialize)]
pub struct StringResponse {
    pub value: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct PickedFolderResponse {
    pub value: Option<PickedFolder>,
}

#[derive(Debug, Deserialize)]
pub struct BooleanResponse {
    pub value: bool,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StorageInfo {
    pub free_bytes: u64,
    pub total_bytes: u64,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SharedFile {
    pub uri: String,
    pub name: String,
}

#[derive(Debug, Deserialize)]
pub struct SharedFileResponse {
    pub value: Option<SharedFile>,
}

#[cfg(test)]
mod tests {
    use super::{PickedFolderResponse, SharedFileResponse, StorageInfo, StringResponse};

    #[test]
    fn storage_info_deserializes_camel_case_byte_counts() {
        let info: StorageInfo =
            serde_json::from_str(r#"{"freeBytes":1234,"totalBytes":8192}"#).unwrap();
        assert_eq!(info.free_bytes, 1234);
        assert_eq!(info.total_bytes, 8192);
    }

    #[test]
    fn mobile_string_response_preserves_missing_and_present_values() {
        let missing: StringResponse = serde_json::from_str(r#"{"value":null}"#).unwrap();
        let present: StringResponse = serde_json::from_str(r#"{"value":"saved"}"#).unwrap();
        assert_eq!(missing.value, None);
        assert_eq!(present.value.as_deref(), Some("saved"));
    }

    #[test]
    fn mobile_folder_response_preserves_cancel_and_selection() {
        let cancelled: PickedFolderResponse = serde_json::from_str(r#"{"value":null}"#).unwrap();
        let selected: PickedFolderResponse = serde_json::from_str(
            r#"{"value":{"uri":"content://tree","displayName":"Files"}}"#,
        )
        .unwrap();
        assert!(cancelled.value.is_none());
        assert_eq!(selected.value.unwrap().display_name, "Files");
    }

    #[test]
    fn mobile_shared_file_response_keeps_the_saved_name_and_uri() {
        let saved: SharedFileResponse = serde_json::from_str(
            r#"{"value":{"uri":"content://downloads/12","name":"song (1).flac"}}"#,
        )
        .unwrap();
        let value = saved.value.expect("a saved file");
        assert_eq!(value.name, "song (1).flac");
        assert_eq!(value.uri, "content://downloads/12");
    }
}
