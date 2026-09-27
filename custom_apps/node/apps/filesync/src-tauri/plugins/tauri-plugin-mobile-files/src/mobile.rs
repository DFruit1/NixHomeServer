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

    pub fn background_sync_status(&self) -> crate::Result<Option<String>> {
        let response: StringResponse = self.0
            .run_mobile_plugin("backgroundSyncStatus", serde_json::json!({}))
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
}
