//! Services that run on this server rather than online providers. Online
//! services lists them under "On this server" with only their status; Jellyfin
//! also names the metadata sources NixOS configures inside it.
use super::*;
use std::time::Duration;

const PROBE_TIMEOUT: Duration = Duration::from_secs(4);
const MAX_METADATA_SOURCES: usize = 8;

pub(super) struct Jellyfin {
    base: reqwest::Url,
    metadata_sources: Vec<String>,
}

impl Jellyfin {
    pub(super) fn new(base: &str, metadata_sources: &str) -> Result<Self, String> {
        let mut base = trusted_provider_base(base)?;
        if !base.path().ends_with('/') {
            base.set_path(&format!("{}/", base.path()));
        }
        let metadata_sources = metadata_sources
            .split(',')
            .map(str::trim)
            .filter(|source| !source.is_empty() && source.len() <= 64)
            .take(MAX_METADATA_SOURCES)
            .map(str::to_string)
            .collect();
        Ok(Self {
            base,
            metadata_sources,
        })
    }
}

/// Jellyfin needs no personal account in Media Manager, so a reachable server
/// is "running" rather than connected.
async fn jellyfin_status(state: &ProviderBrokerState) -> Value {
    let status = |status: &str, message: &str, sources: &[String]| {
        json!({
            "id": "jellyfin",
            "name": "Jellyfin",
            "logoUrl": "/assets/logos/jellyfin.svg",
            "status": status,
            "message": message,
            "metadataSources": sources,
        })
    };
    let Some(jellyfin) = state.jellyfin.as_ref() else {
        return status("notEnabled", "Jellyfin is not enabled on this server.", &[]);
    };
    let ping = match jellyfin.base.join("System/Ping") {
        Ok(url) => state.client.get(url).timeout(PROBE_TIMEOUT).send().await,
        Err(_) => {
            return status(
                "notReachable",
                "Jellyfin's address on this server is invalid.",
                &jellyfin.metadata_sources,
            )
        }
    };
    if ping.is_ok_and(|response| response.status().is_success()) {
        status("running", "", &jellyfin.metadata_sources)
    } else {
        status(
            "notReachable",
            "Jellyfin is enabled but is not responding. Check the Videos service.",
            &jellyfin.metadata_sources,
        )
    }
}

pub(super) async fn list(State(state): State<ProviderBrokerState>, headers: HeaderMap) -> Response {
    let request_id = request_id();
    let identity = match identity_from_headers(&headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    let (immich, jellyfin) = tokio::join!(
        immich::server_status(&state, &identity),
        jellyfin_status(&state)
    );
    Json(json!({
        "schemaVersion": 1,
        "services": [immich, jellyfin],
        "requestId": request_id,
    }))
    .into_response()
}
