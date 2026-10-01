use axum::{
    extract::{OriginalUri, State},
    http::{header, StatusCode, Uri},
    response::{IntoResponse, Response},
    routing::get,
    Router,
};
use std::{env, path::PathBuf, sync::Arc};

#[derive(Clone)]
struct AppState {
    channels: PathBuf,
}

fn valid_channel(channel: &str) -> bool {
    !channel.is_empty()
        && channel.len() <= 64
        && channel
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
        && !channel.starts_with('-')
        && !channel.ends_with('-')
}

fn alias_path(uri: &Uri) -> Option<(&str, &str)> {
    let path = uri.path();
    if let Some(suffix) = path.strip_prefix("/fdroid/repo")
        && (suffix.is_empty() || suffix.starts_with('/'))
    {
        return Some(("fdroid", suffix));
    }
    let remaining = path.strip_prefix("/published/")?;
    let channel = remaining.split('/').next()?;
    let suffix = &remaining[channel.len()..];
    valid_channel(channel).then_some((channel, suffix))
}

fn valid_suffix(suffix: &str) -> bool {
    if suffix.len() > 4096 || suffix.contains('\\') {
        return false;
    }
    let lower = suffix.to_ascii_lowercase();
    if ["%2e", "%2f", "%5c", "%00", "%25"]
        .iter()
        .any(|part| lower.contains(part))
    {
        return false;
    }
    !suffix.split('/').any(|part| part == "." || part == "..")
}

fn valid_cid(cid: &str) -> bool {
    cid.len() >= 50
        && cid.len() <= 120
        && cid.starts_with('b')
        && cid
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || (b'2'..=b'7').contains(&byte))
}

async fn resolve_alias(
    State(state): State<Arc<AppState>>,
    OriginalUri(uri): OriginalUri,
) -> Response {
    let Some((channel, suffix)) = alias_path(&uri) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    if !valid_suffix(suffix) {
        return StatusCode::BAD_REQUEST.into_response();
    }
    let pointer = state.channels.join(format!("{channel}.cid"));
    let Ok(cid) = tokio::fs::read_to_string(pointer).await else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let cid = cid.trim();
    if !valid_cid(cid) {
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    }
    (
        StatusCode::TEMPORARY_REDIRECT,
        [
            (header::LOCATION, format!("/ipfs/{cid}{suffix}")),
            (header::CACHE_CONTROL, "no-store".to_string()),
        ],
    )
        .into_response()
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let listen = env::var("IPFS_ALIAS_LISTEN")?;
    let channels = PathBuf::from(env::var("IPFS_ALIAS_CHANNELS_DIR")?);
    let state = Arc::new(AppState { channels });
    let app = Router::new()
        .route("/healthz", get(|| async { StatusCode::OK }))
        .route("/fdroid/repo", get(resolve_alias))
        .route("/fdroid/repo/{*path}", get(resolve_alias))
        .route("/published/{channel}", get(resolve_alias))
        .route("/published/{channel}/{*path}", get(resolve_alias))
        .with_state(state);
    let listener = tokio::net::TcpListener::bind(listen).await?;
    axum::serve(listener, app).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{alias_path, valid_cid, valid_suffix};

    #[test]
    fn maps_repo_and_generic_aliases() {
        assert_eq!(
            alias_path(&"/fdroid/repo/index-v2.json".parse().unwrap()),
            Some(("fdroid", "/index-v2.json"))
        );
        assert_eq!(
            alias_path(&"/published/isos/linux.iso".parse().unwrap()),
            Some(("isos", "/linux.iso"))
        );
        assert!(alias_path(&"/published/../private".parse().unwrap()).is_none());
    }

    #[test]
    fn rejects_traversal_and_invalid_pointers() {
        assert!(!valid_suffix("/%2e%2e/private"));
        assert!(!valid_suffix("/../private"));
        assert!(!valid_cid("../../etc/passwd"));
        assert!(valid_cid(
            "bafybeigdyrzt5sfp7udm7hu76uhcx7odmshpf4c2si2qvxw32fxj7cwxji"
        ));
    }
}
