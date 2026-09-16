mod api;
mod auth;
mod queue;

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
            queue::queue_list,
            queue::queue_add,
            queue::queue_remove,
            queue::queue_flush,
            queue::set_server_base_url,
        ])
        .run(tauri::generate_context!())
        .expect("error while running the YouTube Downloader shell");
}
