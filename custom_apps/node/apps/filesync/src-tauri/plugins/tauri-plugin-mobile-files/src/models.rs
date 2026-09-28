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

#[cfg(test)]
mod tests {
    use super::{PickedFolderResponse, StringResponse};

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
        ).unwrap();
        assert!(cancelled.value.is_none());
        assert_eq!(selected.value.unwrap().display_name, "Files");
    }
}
