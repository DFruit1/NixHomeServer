mod api;
mod auth;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![
            auth::oauth_status,
            auth::oauth_logout,
            auth::oauth_login,
            api::api_request,
        ])
        .run(tauri::generate_context!())
        .expect("error while running the YouTube Downloader shell");
}
