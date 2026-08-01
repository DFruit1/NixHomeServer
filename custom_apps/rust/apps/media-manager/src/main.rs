use media_manager::{
    catalog::{Catalog, CatalogHandle},
    config::AppConfig,
    http::{router, AppState},
};
use serde_json::json;

#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        eprintln!(
            "{}",
            json!({
                "level": "error",
                "service": "media-manager",
                "event": "startup_failed",
                "error": error,
            })
        );
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
    let state = AppState {
        catalog: CatalogHandle::new(config.database_path()),
        config,
    };
    let listener = tokio::net::TcpListener::bind(address)
        .await
        .map_err(|error| format!("bind {address}: {error}"))?;
    eprintln!(
        "{}",
        json!({
            "level": "info",
            "service": "media-manager",
            "event": "server_started",
            "address": address.to_string(),
        })
    );
    axum::serve(listener, router(state).into_make_service())
        .with_graceful_shutdown(shutdown_signal())
        .await
        .map_err(|error| format!("serve requests: {error}"))
}

async fn shutdown_signal() {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };
    #[cfg(unix)]
    let terminate = async {
        if let Ok(mut signal) =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        {
            signal.recv().await;
        }
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();
    tokio::select! {
        () = ctrl_c => {},
        () = terminate => {},
    }
}
