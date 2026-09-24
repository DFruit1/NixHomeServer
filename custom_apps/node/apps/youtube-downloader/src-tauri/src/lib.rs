mod api;
mod auth;
mod queue;
mod update;

/// After a prompted share has been queued, send the app to the background so
/// the source app (usually YouTube) comes back. Android resolves the custom
/// scheme through ReturnActivity, which moves the task to the back.
#[tauri::command]
fn leave_app(app: tauri::AppHandle) -> Result<(), String> {
    #[cfg(target_os = "android")]
    {
        use tauri_plugin_opener::OpenerExt;
        app.opener()
            .open_url("org.sydneybasiniot.youtubedownloader://return", None::<&str>)
            .map_err(|error| error.to_string())?;
    }
    #[cfg(not(target_os = "android"))]
    {
        let _ = app;
    }
    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .setup(|app| {
            let handle = app.handle().clone();
            queue::sync_shared_files(&handle);
            tauri::async_runtime::spawn(async move {
                let _ = queue::queue_flush(handle).await;
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            auth::oauth_status,
            auth::oauth_logout,
            auth::oauth_login,
            api::api_request,
            queue::prompt_take,
            queue::queue_list,
            queue::queue_add,
            queue::queue_remove,
            queue::queue_flush,
            queue::set_server_base_url,
            update::app_platform,
            update::install_app_update,
            leave_app,
        ])
        .run(tauri::generate_context!())
        .expect("error while running the YouTube Downloader shell");
}
