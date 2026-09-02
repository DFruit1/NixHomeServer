use media_manager::{
    provider_account_http::{provider_account_router, ProviderBrokerState},
    provider_accounts::ProviderAccountStore,
};
use serde_json::json;
use std::{net::IpAddr, path::PathBuf, sync::Arc};

#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        eprintln!(
            "{}",
            json!({
                "level": "error",
                "service": "media-manager-provider-broker",
                "event": "startup_failed",
                "error": error,
            })
        );
        std::process::exit(1);
    }
}

async fn run() -> Result<(), String> {
    let address = env_string("MEDIA_MANAGER_PROVIDER_ADDRESS", "127.0.0.1")
        .parse::<IpAddr>()
        .map_err(|error| format!("invalid MEDIA_MANAGER_PROVIDER_ADDRESS: {error}"))?;
    if !address.is_loopback() {
        return Err("MEDIA_MANAGER_PROVIDER_ADDRESS must be loopback".to_string());
    }
    let port = env_string("MEDIA_MANAGER_PROVIDER_PORT", "8088")
        .parse::<u16>()
        .map_err(|error| format!("invalid MEDIA_MANAGER_PROVIDER_PORT: {error}"))?;
    let state_dir = PathBuf::from(env_string(
        "MEDIA_MANAGER_PROVIDER_STATE_DIR",
        "/var/lib/media-manager-provider",
    ));
    std::fs::create_dir_all(&state_dir)
        .map_err(|error| format!("create provider state directory: {error}"))?;
    let store = ProviderAccountStore::open(
        &state_dir.join("provider-accounts.sqlite3"),
        &state_dir.join("master.key"),
    )
    .map_err(|error| format!("initialize provider accounts: {error}"))?;
    let app = provider_account_router(ProviderBrokerState {
        store: Arc::new(store),
    });
    let socket = std::net::SocketAddr::new(address, port);
    let listener = tokio::net::TcpListener::bind(socket)
        .await
        .map_err(|error| format!("bind {socket}: {error}"))?;
    eprintln!(
        "{}",
        json!({
            "level": "info",
            "service": "media-manager-provider-broker",
            "event": "listening",
            "address": socket.to_string(),
        })
    );
    // Axum 0.8's documented Tokio listener pattern:
    // https://docs.rs/axum/0.8.6/axum/fn.serve.html
    axum::serve(listener, app)
        .await
        .map_err(|error| format!("serve provider account API: {error}"))
}

fn env_string(name: &str, default: &str) -> String {
    std::env::var(name).unwrap_or_else(|_| default.to_string())
}
