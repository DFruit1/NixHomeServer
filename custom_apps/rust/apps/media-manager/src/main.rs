use homelab_common::{log_server_started, log_startup_failed, shutdown_signal};
use media_manager::{
    catalog::{Catalog, CatalogHandle},
    config::AppConfig,
    http::{router, AppState, ArtworkCandidateCache, JellyfinImageCache},
};
use std::sync::Arc;

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
    Catalog::initialize(&config.database_path())
        .map_err(|error| format!("initialize catalog: {error}"))?;
    let address = std::net::SocketAddr::new(config.address, config.port);
    let state = AppState {
        catalog: CatalogHandle::new(config.database_path()),
        config,
        jellyfin_image_cache: Arc::new(JellyfinImageCache::new()),
        artwork_candidate_cache: Arc::new(ArtworkCandidateCache::new()),
        provider_accounts_cache: Arc::default(),
        metadata_memo: Arc::default(),
        frontend_index: Arc::new(tokio::sync::OnceCell::new()),
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
