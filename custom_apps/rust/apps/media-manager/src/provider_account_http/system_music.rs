//! Music identification for host system jobs (system socket only).
//!
//! The audio CD importer fingerprints the tracks of a disc that MusicBrainz
//! does not know by its Disc ID. `acoustid/release-groups` resolves one
//! fingerprint to the release groups it appears on, with the AcoustID
//! account of the named user (for a disc, its uploader); without one the
//! answer is `no_account`. `musicbrainz/release-group` then lists that
//! group's releases with their track titles and lengths, so the importer
//! can confirm a release against the disc's own track count and timings.
//! Both answers are public data, so a cached answer serves every caller.

use super::{
    bounded_provider_json, provider_test_url, valid_mbid, zeroize_credentials,
    AcoustidLookupResponse, ProviderBrokerState,
};
use axum::{
    extract::{rejection::JsonRejection, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use homelab_common::{request_id, sha256_hex};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    collections::BTreeSet,
    time::{Duration, Instant},
};
use tokio::sync::Mutex;

const FINGERPRINT_CACHE_SCOPE: &str = "system-acoustid-release-groups";
const RELEASE_CACHE_SCOPE: &str = "system-musicbrainz-release-group";
/// A browse page of releases with their recordings stays within the
/// broker's 2 MiB provider response limit at this size.
const MAX_RELEASES: usize = 50;

/// AcoustID allows three requests a second; MusicBrainz one.
static NEXT_ACOUSTID: Mutex<Option<Instant>> = Mutex::const_new(None);
static NEXT_MUSICBRAINZ: Mutex<Option<Instant>> = Mutex::const_new(None);

async fn wait_for_turn(gate: &Mutex<Option<Instant>>, gap: Duration) {
    let wait = {
        let mut next = gate.lock().await;
        let now = Instant::now();
        let scheduled = next.map_or(now, |at| at.max(now));
        *next = Some(scheduled + gap);
        scheduled.saturating_duration_since(now)
    };
    tokio::time::sleep(wait).await;
}

fn outcome(event: &str, request_id: &str, status: StatusCode, error: &'static str) -> Response {
    log(event, request_id, error);
    (status, Json(json!({ "error": error }))).into_response()
}

fn log(event: &str, request_id: &str, outcome: &str) {
    eprintln!(
        "{}",
        json!({
            "level": "info",
            "service": "media-manager-provider-broker",
            "event": event,
            "requestId": request_id,
            "outcome": outcome,
        })
    );
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct ReleaseGroupsRequest {
    owner: String,
    fingerprint: String,
    duration: u32,
}

/// Usernames as the account store records them.
fn valid_owner(owner: &str) -> bool {
    (1..=64).contains(&owner.len())
        && owner.bytes().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'.' | b'_' | b'-')
        })
}

pub(super) async fn acoustid_release_groups(
    State(state): State<ProviderBrokerState>,
    payload: Result<Json<ReleaseGroupsRequest>, JsonRejection>,
) -> Response {
    const EVENT: &str = "system_acoustid_release_groups";
    let request_id = request_id();
    let request = payload.ok().map(|Json(request)| request).filter(|request| {
        valid_owner(&request.owner)
            && (1..=24 * 60 * 60).contains(&request.duration)
            && (4..=16 * 1024).contains(&request.fingerprint.len())
            && request
                .fingerprint
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
    });
    let Some(request) = request else {
        return outcome(
            EVENT,
            &request_id,
            StatusCode::BAD_REQUEST,
            "invalid_request",
        );
    };
    let cache_key = sha256_hex(
        format!(
            "{FINGERPRINT_CACHE_SCOPE}:v1\0{}\0{}",
            request.fingerprint, request.duration
        )
        .as_bytes(),
    );
    if let Some(mut cached) = state.lookup_cache.get(&cache_key).await
        && cached["releaseGroups"].is_array()
    {
        log(EVENT, &request_id, "cache_hit");
        cached["cached"] = json!(true);
        return Json(cached).into_response();
    }
    let no_account = || outcome(EVENT, &request_id, StatusCode::NOT_FOUND, "no_account");
    let failed = || {
        outcome(
            EVENT,
            &request_id,
            StatusCode::BAD_GATEWAY,
            "provider_error",
        )
    };
    let identity = match state
        .store
        .account_identity_for_username("acoustid", &request.owner)
    {
        Ok(Some(identity)) => identity,
        Ok(None) => return no_account(),
        Err(_) => {
            return outcome(
                EVENT,
                &request_id,
                StatusCode::INTERNAL_SERVER_ERROR,
                "storage_error",
            )
        }
    };
    let mut credentials = match state.store.load_credentials(&identity, "acoustid") {
        Ok(Some(credentials)) => credentials,
        _ => return no_account(),
    };
    let Some(api_key) = credentials.get("apiKey").cloned() else {
        zeroize_credentials(&mut credentials);
        return no_account();
    };
    zeroize_credentials(&mut credentials);
    let Ok(url) = provider_test_url(&state.endpoints.acoustid_api_base, "lookup") else {
        return failed();
    };
    wait_for_turn(&NEXT_ACOUSTID, Duration::from_millis(350)).await;
    let duration = request.duration.to_string();
    let response = state
        .client
        .get(url)
        .query(&[
            ("client", api_key.as_str()),
            ("fingerprint", request.fingerprint.as_str()),
            ("duration", duration.as_str()),
            ("meta", "recordingids+releasegroups"),
        ])
        .send()
        .await;
    let response = match response {
        Ok(response) if response.status() == StatusCode::TOO_MANY_REQUESTS => {
            return outcome(
                EVENT,
                &request_id,
                StatusCode::TOO_MANY_REQUESTS,
                "rate_limited",
            )
        }
        Ok(response) if response.status().is_success() => response,
        _ => return failed(),
    };
    let payload = match bounded_provider_json::<AcoustidLookupResponse>(response).await {
        Ok(payload) if payload.status == "ok" => payload,
        _ => return failed(),
    };
    let release_groups: BTreeSet<String> = payload
        .results
        .into_iter()
        .flat_map(|result| result.recordings)
        .flat_map(|recording| recording.releasegroups)
        .map(|group| group.id)
        .filter(|id| valid_mbid(id))
        .collect();
    let mut body = json!({ "releaseGroups": release_groups });
    state
        .lookup_cache
        .put(cache_key, FINGERPRINT_CACHE_SCOPE, "system", body.clone())
        .await;
    log(EVENT, &request_id, "fetched");
    body["cached"] = json!(false);
    Json(body).into_response()
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct ReleaseGroupRequest {
    release_group: String,
}

fn text(value: &Value, key: &str) -> String {
    value
        .get(key)
        .and_then(Value::as_str)
        .map(|text| text.split_whitespace().collect::<Vec<_>>().join(" "))
        .unwrap_or_default()
        .chars()
        .take(300)
        .collect()
}

/// A release reduced to what a disc is compared with and tagged from.
fn release(value: &Value) -> Option<Value> {
    let id = text(value, "id");
    let title = text(value, "title");
    if !valid_mbid(&id) || title.is_empty() {
        return None;
    }
    let artist: String = value
        .get("artist-credit")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .map(|credit| {
            format!(
                "{}{}",
                text(credit, "name"),
                credit
                    .get("joinphrase")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
            )
        })
        .collect();
    let media: Vec<Value> = value
        .get("media")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .take(40)
        .map(|medium| {
            let tracks: Vec<Value> = medium
                .get("tracks")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .take(200)
                .map(|track| {
                    json!({
                        "position": track.get("position").and_then(Value::as_u64),
                        "title": text(track, "title"),
                        "lengthMs": track.get("length").and_then(Value::as_u64),
                    })
                })
                .collect();
            json!({
                "position": medium.get("position").and_then(Value::as_u64),
                "tracks": tracks,
            })
        })
        .collect();
    Some(json!({
        "id": id,
        "title": title,
        "artist": artist.trim(),
        "date": text(value, "date"),
        "status": text(value, "status"),
        "media": media,
    }))
}

pub(super) async fn musicbrainz_release_group(
    State(state): State<ProviderBrokerState>,
    payload: Result<Json<ReleaseGroupRequest>, JsonRejection>,
) -> Response {
    const EVENT: &str = "system_musicbrainz_release_group";
    let request_id = request_id();
    let Some(release_group) = payload
        .ok()
        .map(|Json(request)| request.release_group)
        .filter(|id| valid_mbid(id))
    else {
        return outcome(
            EVENT,
            &request_id,
            StatusCode::BAD_REQUEST,
            "invalid_request",
        );
    };
    let cache_key = sha256_hex(format!("{RELEASE_CACHE_SCOPE}:v1\0{release_group}").as_bytes());
    if let Some(mut cached) = state.lookup_cache.get(&cache_key).await
        && cached["releases"].is_array()
    {
        log(EVENT, &request_id, "cache_hit");
        cached["cached"] = json!(true);
        return Json(cached).into_response();
    }
    let failed = || {
        outcome(
            EVENT,
            &request_id,
            StatusCode::BAD_GATEWAY,
            "provider_error",
        )
    };
    let Some(url) = state
        .endpoints
        .additional_api_bases
        .get("musicbrainz")
        .and_then(|base| provider_test_url(base, "release").ok())
    else {
        return failed();
    };
    wait_for_turn(&NEXT_MUSICBRAINZ, Duration::from_millis(1100)).await;
    let limit = MAX_RELEASES.to_string();
    let response = state
        .client
        .get(url)
        .query(&[
            ("release-group", release_group.as_str()),
            ("inc", "recordings+artist-credits+media"),
            ("fmt", "json"),
            ("limit", limit.as_str()),
        ])
        .send()
        .await;
    let response = match response {
        Ok(response) if response.status() == StatusCode::SERVICE_UNAVAILABLE => {
            // MusicBrainz answers 503 when a client asks too fast.
            return outcome(
                EVENT,
                &request_id,
                StatusCode::TOO_MANY_REQUESTS,
                "rate_limited",
            );
        }
        Ok(response) if response.status().is_success() => response,
        _ => return failed(),
    };
    let Ok(payload) = bounded_provider_json::<Value>(response).await else {
        return failed();
    };
    let Some(releases) = payload.get("releases").and_then(Value::as_array) else {
        return failed();
    };
    let releases: Vec<Value> = releases
        .iter()
        .filter_map(release)
        .take(MAX_RELEASES)
        .collect();
    let mut body = json!({ "releases": releases });
    state
        .lookup_cache
        .put(cache_key, RELEASE_CACHE_SCOPE, "system", body.clone())
        .await;
    log(EVENT, &request_id, "fetched");
    body["cached"] = json!(false);
    Json(body).into_response()
}
