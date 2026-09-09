use homelab_common::{log_server_started, log_startup_failed, shutdown_signal};
use media_manager::{
    catalog::{Catalog, CatalogHandle},
    config::AppConfig,
    http::{router, AppState, JellyfinImageCache},
    tmdb::{TmdbClient, TmdbClientConfig, TmdbCredentials, TMDB_API_BASE},
};
use std::sync::Arc;
use std::time::Duration;

#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        log_startup_failed("media-manager", &error);
        std::process::exit(1);
    }
}

async fn run() -> Result<(), String> {
    let config = AppConfig::from_env()?;
    std::fs::create_dir_all(&config.state_dir)
        .map_err(|error| format!("create state directory: {error}"))?;
    Catalog::open(&config.database_path())
        .map_err(|error| format!("initialize catalog: {error}"))?;
    let address = std::net::SocketAddr::new(config.address, config.port);
    let tmdb_client = config.tmdb_api_key_file.as_ref().and_then(|path| {
        TmdbCredentials::from_file(path)
            .ok()
            .map(|credentials| TmdbClientConfig {
                api_key: Some(credentials.api_key.clone()),
                tmdb_api_base: TMDB_API_BASE.to_string(),
                request_gap: Duration::from_millis(config.tmdb_request_gap_ms),
                user_agent: credentials
                    .user_agent
                    .clone()
                    .unwrap_or_else(|| "media-manager/0.1.0".to_string()),
            })
            .and_then(|config| TmdbClient::new(config).ok())
            .map(Arc::new)
    });

    let state = AppState {
        catalog: CatalogHandle::new(config.database_path()),
        config,
        jellyfin_image_cache: Arc::new(JellyfinImageCache::new()),
        tmdb_client,
    };
    let listener = tokio::net::TcpListener::bind(address)
        .await
        .map_err(|error| format!("bind {address}: {error}"))?;
    log_server_started("media-manager", &address.to_string());
    axum::serve(listener, router(state).into_make_service())
        .with_graceful_shutdown(shutdown_signal())
        .await
        .map_err(|error| format!("serve requests: {error}"))
}
