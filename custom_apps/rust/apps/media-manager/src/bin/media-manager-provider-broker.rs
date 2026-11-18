use media_manager::{
    provider_account_http::{provider_account_router, provider_system_router, ProviderBrokerState},
    provider_accounts::ProviderAccountStore,
    tmdb::TmdbCredentials,
};
use serde_json::json;
use std::{
    net::IpAddr,
    os::unix::fs::{FileTypeExt, PermissionsExt},
    path::{Path, PathBuf},
    sync::Arc,
};

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
    let mut state = ProviderBrokerState::new(Arc::new(store))
        .map_err(|error| format!("initialize provider client: {error}"))?
        .with_lookup_cache(&state_dir.join("lookup-cache.sqlite3"))
        .map_err(|error| format!("initialize provider lookup cache: {error}"))?;
    // The host's TMDB key serves system jobs (DVD episode numbering) only;
    // a missing or unreadable key leaves TMDB answers `tmdb_unconfigured`.
    if let Some(path) = std::env::var_os("MEDIA_MANAGER_TMDB_API_KEY_FILE") {
        match TmdbCredentials::from_file(Path::new(&path)) {
            Ok(credentials) => state = state.with_system_tmdb_key(credentials.api_key.clone())?,
            Err(error) => eprintln!(
                "{}",
                json!({
                    "level": "warn",
                    "service": "media-manager-provider-broker",
                    "event": "system_tmdb_key_unavailable",
                    "error": error.to_string(),
                })
            ),
        }
    }
    if let Ok(base) = std::env::var("MEDIA_MANAGER_JELLYFIN_BASE_URL") {
        state = state.with_jellyfin(
            &base,
            &env_string("MEDIA_MANAGER_JELLYFIN_METADATA_SOURCES", ""),
        )?;
    }
    if let Ok(base) = std::env::var("MEDIA_MANAGER_IMMICH_API_BASE") {
        let socket = PathBuf::from(env_string(
            "MEDIA_MANAGER_EYE_SOCKET",
            "/run/media-manager-eye/eye.sock",
        ));
        state = state.with_images(&base, &socket)?;
        if let Ok(socket) = std::env::var("MEDIA_MANAGER_DECISION_SOCKET") {
            state = state.with_decision_socket(std::path::Path::new(&socket))?;
        }
        if let Ok(url) = std::env::var("MEDIA_MANAGER_BONSAI_URL") {
            state = state.with_bonsai(
                &url,
                &env_string("MEDIA_MANAGER_BONSAI_MODEL", "bonsai-ternary-27b"),
            )?;
        }
        if env_string("MEDIA_MANAGER_IMMICH_MANAGED", "false") == "true" {
            state = state.with_managed_immich();
        }
    }
    tokio::spawn(state.clone().run_image_indexer());
    tokio::spawn(state.clone().run_photo_tag_review());
    // Host system jobs reach a separate router over a Unix socket whose
    // directory group grants access; they never use forwarded identities.
    let system = match std::env::var("MEDIA_MANAGER_PROVIDER_SYSTEM_SOCKET") {
        Ok(path) if !path.is_empty() => {
            let path = PathBuf::from(path);
            let listener = bind_system_socket(&path)?;
            let router = provider_system_router(state.clone());
            eprintln!(
                "{}",
                json!({
                    "level": "info",
                    "service": "media-manager-provider-broker",
                    "event": "system_listening",
                    "socket": path.display().to_string(),
                })
            );
            Some(tokio::spawn(async move {
                axum::serve(listener, router)
                    .await
                    .map_err(|error| format!("serve provider system API: {error}"))
            }))
        }
        _ => None,
    };
    let app = provider_account_router(state);
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
    let public = axum::serve(listener, app);
    match system {
        Some(system) => tokio::select! {
            result = public => result.map_err(|error| format!("serve provider account API: {error}")),
            result = system => result
                .map_err(|error| format!("provider system API task failed: {error}"))
                .and_then(|result| result)
                .and_then(|()| Err("provider system API stopped".to_string())),
        },
        None => public
            .await
            .map_err(|error| format!("serve provider account API: {error}")),
    }
}

/// Bind the system socket with mode 0660; its directory (set up by the unit)
/// decides which group may connect. Only a stale socket is ever replaced.
fn bind_system_socket(path: &Path) -> Result<tokio::net::UnixListener, String> {
    match std::fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_socket() => std::fs::remove_file(path)
            .map_err(|error| format!("remove stale system socket: {error}"))?,
        Ok(_) => return Err(format!("{} exists and is not a socket", path.display())),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(format!("inspect system socket: {error}")),
    }
    let listener = tokio::net::UnixListener::bind(path)
        .map_err(|error| format!("bind {}: {error}", path.display()))?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o660))
        .map_err(|error| format!("set system socket mode: {error}"))?;
    Ok(listener)
}

fn env_string(name: &str, default: &str) -> String {
    std::env::var(name).unwrap_or_else(|_| default.to_string())
}
