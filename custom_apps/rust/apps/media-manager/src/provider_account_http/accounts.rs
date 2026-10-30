use super::*;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct SaveProviderAccountRequest {
    credentials: BTreeMap<String, String>,
}

pub(super) async fn list_provider_accounts(
    State(state): State<ProviderBrokerState>,
    headers: HeaderMap,
) -> Response {
    let request_id = request_id();
    let identity = match identity_from_headers(&headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    let summaries = match state.store.list(&identity) {
        Ok(summaries) => summaries,
        Err(error) => return storage_failure(error, &request_id).into_response(),
    };
    Json(json!({
        "schemaVersion": 1,
        "providers": provider_views(&summaries),
        "recoveryAdvice": "Saved credentials cannot be viewed again. Keep the recovery copy in Vaultwarden, KeePassXC, or another password manager.",
        "requestId": request_id,
    }))
    .into_response()
}

pub(super) async fn save_provider_account(
    State(state): State<ProviderBrokerState>,
    headers: HeaderMap,
    Path(provider_id): Path<String>,
    payload: Result<Json<SaveProviderAccountRequest>, JsonRejection>,
) -> Response {
    let request_id = request_id();
    let identity = match identity_from_headers(&headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    let mut request = match payload {
        Ok(Json(request)) => request,
        Err(_) => {
            return ApiError::new(
                StatusCode::BAD_REQUEST,
                "invalid_json",
                "Supply a valid provider credential document.",
                request_id,
            )
            .into_response()
        }
    };
    let Some(definition) = provider_definition(&provider_id) else {
        zeroize_credentials(&mut request.credentials);
        return ApiError::new(
            StatusCode::NOT_FOUND,
            "provider_not_found",
            "The requested metadata provider is not in the provider catalog.",
            request_id,
        )
        .into_response();
    };
    if definition.implementation_status != ImplementationStatus::Active {
        zeroize_credentials(&mut request.credentials);
        return ApiError::new(
            StatusCode::CONFLICT,
            "provider_adapter_unavailable",
            "Credentials cannot be saved until this provider's lookup adapter is available.",
            request_id,
        )
        .into_response();
    }
    if definition.credential_fields.is_empty() {
        zeroize_credentials(&mut request.credentials);
        return ApiError::new(
            StatusCode::CONFLICT,
            "provider_account_not_required",
            "This provider does not require a saved account.",
            request_id,
        )
        .into_response();
    }
    if let Err(message) = validate_credentials(definition, &request.credentials) {
        zeroize_credentials(&mut request.credentials);
        return ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "credential_validation_failed",
            message,
            request_id,
        )
        .into_response();
    }
    let result = state.store.save(
        &identity,
        definition.id,
        &request.credentials,
        unix_timestamp(),
    );
    zeroize_credentials(&mut request.credentials);
    if let Err(error) = result {
        return storage_failure(error, &request_id).into_response();
    }
    let summary = match state.store.list(&identity) {
        Ok(summaries) => summaries
            .into_iter()
            .find(|summary| summary.provider_id == definition.id),
        Err(error) => return storage_failure(error, &request_id).into_response(),
    };
    Json(json!({
        "provider": provider_view(definition, summary.as_ref()),
        "requestId": request_id,
    }))
    .into_response()
}

pub(super) async fn delete_provider_account(
    State(state): State<ProviderBrokerState>,
    headers: HeaderMap,
    Path(provider_id): Path<String>,
) -> Response {
    let request_id = request_id();
    let identity = match identity_from_headers(&headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    if provider_definition(&provider_id).is_none() {
        return ApiError::new(
            StatusCode::NOT_FOUND,
            "provider_not_found",
            "The requested metadata provider is not in the provider catalog.",
            request_id,
        )
        .into_response();
    }
    match state.store.delete(&identity, &provider_id) {
        Ok(_) => StatusCode::NO_CONTENT.into_response(),
        Err(error) => storage_failure(error, &request_id).into_response(),
    }
}

pub(super) async fn test_provider_account(
    State(state): State<ProviderBrokerState>,
    headers: HeaderMap,
    Path(provider_id): Path<String>,
) -> Response {
    let request_id = request_id();
    let identity = match identity_from_headers(&headers, &request_id) {
        Ok(identity) => identity,
        Err(error) => return error.into_response(),
    };
    let Some(definition) = provider_definition(&provider_id) else {
        return ApiError::new(
            StatusCode::NOT_FOUND,
            "provider_not_found",
            "The requested metadata provider is not in the provider catalog.",
            request_id,
        )
        .into_response();
    };
    if definition.credential_fields.is_empty() {
        return ApiError::new(
            StatusCode::CONFLICT,
            "provider_test_not_required",
            "This public provider does not have a saved account to test.",
            request_id,
        )
        .into_response();
    }
    let Some(connection_test) = definition.connection_test.filter(|_| definition.can_test()) else {
        return ApiError::new(
            StatusCode::CONFLICT,
            "provider_test_unavailable",
            "A live connection test will be enabled with this provider's lookup adapter.",
            request_id,
        )
        .into_response();
    };
    let mut credentials = match state.store.load_credentials(&identity, definition.id) {
        Ok(Some(credentials)) => credentials,
        Ok(None) => {
            return ApiError::new(
                StatusCode::NOT_FOUND,
                "provider_account_not_found",
                "No configured provider account exists for this identity.",
                request_id,
            )
            .into_response()
        }
        Err(error) => return storage_failure(error, &request_id).into_response(),
    };
    let outcome = test_live_provider(&state, connection_test, &credentials).await;
    zeroize_credentials(&mut credentials);
    if let Err(error) = state.store.record_test_result(
        &identity,
        definition.id,
        outcome.status,
        outcome.message,
        unix_timestamp(),
    ) {
        return storage_failure(error, &request_id).into_response();
    }
    Json(json!({
        "providerId": definition.id,
        "status": outcome.status,
        "message": outcome.message,
        "requestId": request_id,
    }))
    .into_response()
}

struct ProviderTestOutcome {
    status: &'static str,
    message: &'static str,
}

impl ProviderTestOutcome {
    const READY: Self = Self {
        status: "ready",
        message: "The provider accepted this account.",
    };
    const REJECTED: Self = Self {
        status: "rejected",
        message: "The provider rejected the saved account.",
    };
    const RATE_LIMITED: Self = Self {
        status: "rateLimited",
        message: "The provider rate limit was reached; try again later.",
    };
    const UNAVAILABLE: Self = Self {
        status: "unavailable",
        message: "The provider could not be reached or did not accept the test request.",
    };
}

async fn test_live_provider(
    state: &ProviderBrokerState,
    adapter: ConnectionTestAdapter,
    credentials: &BTreeMap<String, String>,
) -> ProviderTestOutcome {
    let response = match adapter {
        ConnectionTestAdapter::Tmdb => {
            let url = provider_test_url(&state.endpoints.tmdb_api_base, "authentication");
            match (url, credentials.get("apiKey")) {
                (Ok(url), Some(api_key)) => state.client.get(url).bearer_auth(api_key).send().await,
                _ => return invalid_saved_credentials(),
            }
        }
        ConnectionTestAdapter::Acoustid => {
            let Some(api_key) = credentials.get("apiKey") else {
                return invalid_saved_credentials();
            };
            let Ok(url) = provider_test_url(&state.endpoints.acoustid_api_base, "lookup") else {
                return ProviderTestOutcome::UNAVAILABLE;
            };
            // Valid Chromaprint data for three synthetic subfingerprints. A lookup
            // with no matches still validates the application key; no audio is read.
            state
                .client
                .get(url)
                .query(&[
                    ("client", api_key.as_str()),
                    ("duration", "3"),
                    ("fingerprint", "AQAAA1OiKEnCRJESAA"),
                ])
                .send()
                .await
        }
        ConnectionTestAdapter::GoogleBooks => {
            let Some(api_key) = credentials.get("apiKey") else {
                return invalid_saved_credentials();
            };
            let Ok(url) = provider_test_url(&state.endpoints.google_books_api_base, "volumes")
            else {
                return ProviderTestOutcome::UNAVAILABLE;
            };
            state
                .client
                .get(url)
                .query(&[
                    ("key", api_key.as_str()),
                    ("q", "isbn:9780140328721"),
                    ("maxResults", "1"),
                    ("fields", "kind,totalItems"),
                ])
                .send()
                .await
        }
        ConnectionTestAdapter::OpenSubtitles => {
            let url = provider_test_url(&state.endpoints.opensubtitles_api_base, "login");
            match (
                url,
                credentials.get("apiKey"),
                credentials.get("username"),
                credentials.get("password"),
            ) {
                (Ok(url), Some(api_key), Some(username), Some(password)) => {
                    let user_agent = credentials
                        .get("userAgent")
                        .map(String::as_str)
                        .filter(|value| !value.trim().is_empty())
                        .unwrap_or("NixHomeServer Media Manager");
                    state
                        .client
                        .post(url)
                        .header("api-key", api_key)
                        .header(reqwest::header::USER_AGENT, user_agent)
                        .json(&json!({ "username": username, "password": password }))
                        .send()
                        .await
                }
                _ => return invalid_saved_credentials(),
            }
        }
    };
    let Ok(response) = response else {
        return ProviderTestOutcome::UNAVAILABLE;
    };
    let status = response.status();
    if status == StatusCode::TOO_MANY_REQUESTS {
        return ProviderTestOutcome::RATE_LIMITED;
    }
    match adapter {
        ConnectionTestAdapter::Acoustid => acoustid_test_outcome(response).await,
        ConnectionTestAdapter::GoogleBooks => google_books_test_outcome(response).await,
        _ if status.is_success() => ProviderTestOutcome::READY,
        _ if matches!(status, StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN) => {
            ProviderTestOutcome::REJECTED
        }
        _ => ProviderTestOutcome::UNAVAILABLE,
    }
}

async fn acoustid_test_outcome(response: reqwest::Response) -> ProviderTestOutcome {
    let status = response.status();
    if matches!(status, StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN) {
        return ProviderTestOutcome::REJECTED;
    }
    if !status.is_success() && status != StatusCode::BAD_REQUEST {
        return ProviderTestOutcome::UNAVAILABLE;
    }
    let Ok(body) = bounded_provider_json::<serde_json::Value>(response).await else {
        return ProviderTestOutcome::UNAVAILABLE;
    };
    // AcoustID reports API errors in JSON, including invalid keys (4) and
    // throttling (14). Never infer key validity from an arbitrary HTTP 200.
    match body.get("status").and_then(|value| value.as_str()) {
        Some("ok")
            if status.is_success()
                && body.get("results").is_some_and(|value| value.is_array())
                && body.get("error").is_none() =>
        {
            ProviderTestOutcome::READY
        }
        Some("error") => match body.pointer("/error/code").and_then(|value| value.as_u64()) {
            Some(4) => ProviderTestOutcome::REJECTED,
            Some(14) => ProviderTestOutcome::RATE_LIMITED,
            _ => ProviderTestOutcome::UNAVAILABLE,
        },
        _ => ProviderTestOutcome::UNAVAILABLE,
    }
}

async fn google_books_test_outcome(response: reqwest::Response) -> ProviderTestOutcome {
    let status = response.status();
    if !status.is_success() && !status.is_client_error() {
        return ProviderTestOutcome::UNAVAILABLE;
    }
    let body = bounded_provider_json::<serde_json::Value>(response).await;
    if matches!(status, StatusCode::BAD_REQUEST | StatusCode::FORBIDDEN) {
        if let Ok(body) = &body {
            // Google uses both legacy errors[].reason and details[].reason,
            // and may return quota failures as HTTP 403 instead of HTTP 429.
            if body
                .pointer("/error/status")
                .and_then(|value| value.as_str())
                == Some("RESOURCE_EXHAUSTED")
                || google_books_error_reason(
                    body,
                    &[
                        "dailyLimitExceeded",
                        "rateLimitExceeded",
                        "userRateLimitExceeded",
                        "quotaExceeded",
                        "RATE_LIMIT_EXCEEDED",
                        "QUOTA_EXCEEDED",
                    ],
                )
            {
                return ProviderTestOutcome::RATE_LIMITED;
            }
            if google_books_error_reason(
                body,
                &[
                    "keyInvalid",
                    "keyExpired",
                    "API_KEY_INVALID",
                    "API_KEY_EXPIRED",
                ],
            ) {
                return ProviderTestOutcome::REJECTED;
            }
        }
    }
    if matches!(status, StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN) {
        return ProviderTestOutcome::REJECTED;
    }
    match body {
        Ok(body)
            if status.is_success()
                && body.get("kind").and_then(|value| value.as_str()) == Some("books#volumes")
                && body.get("totalItems").is_some_and(|value| value.is_u64())
                && body.get("error").is_none() =>
        {
            ProviderTestOutcome::READY
        }
        _ => ProviderTestOutcome::UNAVAILABLE,
    }
}

fn google_books_error_reason(body: &serde_json::Value, reasons: &[&str]) -> bool {
    ["/error/errors", "/error/details"]
        .into_iter()
        .filter_map(|path| body.pointer(path).and_then(|value| value.as_array()))
        .flatten()
        .filter_map(|error| error.get("reason").and_then(|value| value.as_str()))
        .any(|reason| reasons.contains(&reason))
}

fn invalid_saved_credentials() -> ProviderTestOutcome {
    ProviderTestOutcome {
        status: "rejected",
        message: "The saved credential document is incomplete.",
    }
}
