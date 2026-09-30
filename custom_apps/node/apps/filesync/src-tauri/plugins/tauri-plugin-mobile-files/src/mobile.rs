use serde::de::DeserializeOwned;
use tauri::{
    plugin::{PluginApi, PluginHandle},
    AppHandle, Runtime,
};

use crate::models::*;

pub fn init<R: Runtime, C: DeserializeOwned>(
    _app: &AppHandle<R>,
    api: PluginApi<R, C>,
) -> crate::Result<MobileFiles<R>> {
    #[cfg(target_os = "android")]
    let handle = api.register_android_plugin(
        "org.nixhomeserver.filesync.mobilefiles",
        "MobileFilesPlugin",
    )?;
    Ok(MobileFiles(handle))
}

pub struct MobileFiles<R: Runtime>(PluginHandle<R>);

impl<R: Runtime> MobileFiles<R> {
    pub fn acquire_sync_lock(&self) -> crate::Result<()> {
        self.0
            .run_mobile_plugin("acquireSyncLock", serde_json::json!({}))
            .map_err(Into::into)
    }

    pub fn release_sync_lock(&self) -> crate::Result<()> {
        self.0
            .run_mobile_plugin("releaseSyncLock", serde_json::json!({}))
            .map_err(Into::into)
    }

    pub fn release_local_folder(&self, folder_uri: String) -> crate::Result<()> {
        self.0
            .run_mobile_plugin(
                "releaseLocalFolder",
                serde_json::json!({ "folderUri": folder_uri }),
            )
            .map_err(Into::into)
    }

    pub fn create_temp_file(&self) -> crate::Result<String> {
        let response: StringResponse = self.0
            .run_mobile_plugin("createTempFile", ())
            .map_err(crate::Error::from)?;
        response.value.ok_or_else(|| crate::Error::Operation("Android returned no temporary file".into()))
    }

    pub fn pick_local_folder(&self) -> crate::Result<Option<PickedFolder>> {
        let response: PickedFolderResponse = self.0
            .run_mobile_plugin("pickLocalFolder", ())
            .map_err(crate::Error::from)?;
        Ok(response.value)
    }

    pub fn ensure_all_files_access(&self) -> crate::Result<bool> {
        let response: BooleanResponse = self.0
            .run_mobile_plugin("ensureAllFilesAccess", ())
            .map_err(crate::Error::from)?;
        Ok(response.value)
    }

    pub fn request_all_files_access(&self) -> crate::Result<bool> {
        let response: BooleanResponse = self.0
            .run_mobile_plugin("requestAllFilesAccess", ())
            .map_err(crate::Error::from)?;
        Ok(response.value)
    }

    pub fn create_local_folder(&self, subpath: String) -> crate::Result<PickedFolder> {
        let response: PickedFolderResponse = self.0
            .run_mobile_plugin("createLocalFolder", serde_json::json!({ "subpath": subpath }))
            .map_err(crate::Error::from)?;
        response.value.ok_or_else(|| crate::Error::Operation("Android returned no folder".into()))
    }

    pub fn store_session(&self, session: String) -> crate::Result<()> {
        self.store_secret("oidc-session".into(), session)
    }

    pub fn load_session(&self) -> crate::Result<Option<String>> {
        self.load_secret("oidc-session".into())
    }

    pub fn clear_session(&self) -> crate::Result<()> {
        self.clear_secret("oidc-session".into())
    }

    pub fn store_secret(&self, slot: String, secret: String) -> crate::Result<()> {
        self.0
            .run_mobile_plugin(
                "storeSecret",
                serde_json::json!({ "slot": slot, "secret": secret }),
            )
            .map_err(Into::into)
    }

    pub fn load_secret(&self, slot: String) -> crate::Result<Option<String>> {
        let response: StringResponse = self.0
            .run_mobile_plugin("loadSecret", serde_json::json!({ "slot": slot }))
            .map_err(crate::Error::from)?;
        Ok(response.value)
    }

    pub fn clear_secret(&self, slot: String) -> crate::Result<()> {
        self.0
            .run_mobile_plugin("clearSecret", serde_json::json!({ "slot": slot }))
            .map_err(Into::into)
    }

    pub fn schedule_background_sync(&self, enabled: bool) -> crate::Result<()> {
        self.0
            .run_mobile_plugin(
                "updateBackgroundSchedule",
                serde_json::json!({ "enabled": enabled.to_string() }),
            )
            .map_err(Into::into)
    }

    pub fn update_background_syncs(&self, pairs_json: String, enabled: bool) -> crate::Result<()> {
        self.0
            .run_mobile_plugin(
                "updateBackgroundSyncs",
                serde_json::json!({
                    "pairsJson": pairs_json,
                    "enabled": enabled.to_string(),
                }),
            )
            .map_err(Into::into)
    }

    pub fn run_sync_pair(&self, pair_json: String) -> crate::Result<serde_json::Value> {
        self.0
            .run_mobile_plugin("runSyncPair", serde_json::json!({ "pairJson": pair_json }))
            .map_err(Into::into)
    }

    pub fn estimate_sync_pair(&self, pair_json: String) -> crate::Result<serde_json::Value> {
        self.0
            .run_mobile_plugin("estimateSyncPair", serde_json::json!({ "pairJson": pair_json }))
            .map_err(Into::into)
    }

    pub fn storage_info(&self, folder_uri: String) -> crate::Result<StorageInfo> {
        self.0
            .run_mobile_plugin(
                "storageInfo",
                serde_json::json!({ "folderUri": folder_uri }),
            )
            .map_err(crate::Error::from)
    }

    pub fn background_sync_status(&self) -> crate::Result<Option<String>> {
        let response: StringResponse = self.0
            .run_mobile_plugin("backgroundSyncStatus", serde_json::json!({}))
            .map_err(crate::Error::from)?;
        Ok(response.value)
    }

    pub fn sync_progress(&self) -> crate::Result<Option<String>> {
        let response: StringResponse = self.0
            .run_mobile_plugin("syncProgress", serde_json::json!({}))
            .map_err(crate::Error::from)?;
        Ok(response.value)
    }

    pub fn ensure_notifications(&self) -> crate::Result<bool> {
        let response: BooleanResponse = self.0
            .run_mobile_plugin("ensureNotifications", serde_json::json!({}))
            .map_err(crate::Error::from)?;
        Ok(response.value)
    }

    pub fn list_local_files(&self, folder_uri: String) -> crate::Result<Vec<LocalEntry>> {
        let result: LocalListing = self
            .0
            .run_mobile_plugin(
                "listLocalFiles",
                serde_json::json!({ "folderUri": folder_uri }),
            )
            .map_err(crate::Error::from)?;
        Ok(result.entries)
    }

    pub fn stage_local_file(
        &self,
        folder_uri: String,
        relative_path: String,
    ) -> crate::Result<String> {
        let response: StringResponse = self.0
            .run_mobile_plugin(
                "stageLocalFile",
                serde_json::json!({ "folderUri": folder_uri, "relativePath": relative_path }),
            )
            .map_err(crate::Error::from)?;
        response.value.ok_or_else(|| crate::Error::Operation("Android returned no staged file".into()))
    }

    pub fn install_local_file(
        &self,
        folder_uri: String,
        relative_path: String,
        staged_path: String,
    ) -> crate::Result<()> {
        self.0.run_mobile_plugin("installLocalFile", serde_json::json!({ "folderUri": folder_uri, "relativePath": relative_path, "stagedPath": staged_path })).map_err(Into::into)
    }

    pub fn save_to_downloads(
        &self,
        staged_path: String,
        file_name: String,
        size: u64,
    ) -> crate::Result<SharedFile> {
        let response: SharedFileResponse = self
            .0
            .run_mobile_plugin(
                "saveToDownloads",
                serde_json::json!({
                    "stagedPath": staged_path,
                    "fileName": file_name,
                    "size": size,
                }),
            )
            .map_err(crate::Error::from)?;
        response
            .value
            .ok_or_else(|| crate::Error::Operation("Android saved no file".into()))
    }

    pub fn share_file(&self, staged_path: String, file_name: String) -> crate::Result<SharedFile> {
        let response: SharedFileResponse = self
            .0
            .run_mobile_plugin(
                "shareFile",
                serde_json::json!({ "stagedPath": staged_path, "fileName": file_name }),
            )
            .map_err(crate::Error::from)?;
        response
            .value
            .ok_or_else(|| crate::Error::Operation("Android shared no file".into()))
    }
}
