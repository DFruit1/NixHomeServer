use tauri::AppHandle;

/// Which flavour of the Tauri shell is running. The UI only offers the
/// in-app updater on Android; desktop builds are managed through Nix.
#[tauri::command]
pub fn app_platform() -> &'static str {
    if cfg!(target_os = "android") {
        "android"
    } else {
        "desktop"
    }
}

/// Download the server's APK into the app cache and hand it to the system
/// package installer through UpdateInstallActivity, reached via the app's
/// custom scheme — the same mechanism leave_app uses for ReturnActivity.
#[tauri::command]
pub async fn install_app_update(app: AppHandle) -> Result<(), String> {
    #[cfg(target_os = "android")]
    {
        android::install(&app).await
    }
    #[cfg(not(target_os = "android"))]
    {
        let _ = app;
        Err("In-app updates are only available in the Android app.".into())
    }
}

#[cfg(target_os = "android")]
mod android {
    use std::time::Duration;

    use tauri::{AppHandle, Manager};
    use tauri_plugin_opener::OpenerExt;

    use crate::auth;
    use crate::queue;

    const UPDATE_APK_NAME: &str = "youtube-downloader-update.apk";
    const INSTALL_SCHEME: &str = "org.sydneybasiniot.youtubedownloader://install";

    pub(super) async fn install(app: &AppHandle) -> Result<(), String> {
        let base_url = queue::server_base_url(app)
            .ok_or_else(|| "No server is configured yet.".to_string())?;
        let token = auth::authorization_token(app)
            .await?
            .ok_or_else(|| "Sign in to install updates.".to_string())?;

        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(300))
            .build()
            .map_err(|error| error.to_string())?;
        let response = client
            .get(format!("{base_url}/api/app/download"))
            .bearer_auth(&token)
            .send()
            .await
            .map_err(|error| error.to_string())?;
        let status = response.status();
        if status == reqwest::StatusCode::UNAUTHORIZED || status == reqwest::StatusCode::FORBIDDEN {
            return Err("Sign in to install updates.".into());
        }
        if !status.is_success() {
            return Err(format!("the server returned {status} for the update package"));
        }
        let bytes = response.bytes().await.map_err(|error| error.to_string())?;

        let cache_dir = app.path().cache_dir().map_err(|error| error.to_string())?;
        std::fs::create_dir_all(&cache_dir).map_err(|error| error.to_string())?;
        let target = cache_dir.join(UPDATE_APK_NAME);
        std::fs::write(&target, &bytes).map_err(|error| error.to_string())?;

        // Pass the absolute path so the Kotlin side does not have to guess
        // which directory Tauri's cache_dir resolved to on this device.
        let mut install_url = url::Url::parse(INSTALL_SCHEME).map_err(|error| error.to_string())?;
        let target_path = target.to_str().ok_or_else(|| "cache path is not valid UTF-8".to_string())?;
        install_url
            .query_pairs_mut()
            .append_pair("path", target_path);
        app.opener()
            .open_url(install_url.as_str(), None::<&str>)
            .map_err(|error| error.to_string())
    }
}
