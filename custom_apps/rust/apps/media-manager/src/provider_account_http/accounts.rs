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
    let identity = match authenticated_identity(&headers, &request_id) {
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
    let identity = match authenticated_identity(&headers, &request_id) {
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
    let identity = match authenticated_identity(&headers, &request_id) {
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
    let identity = match authenticated_identity(&headers, &request_id) {
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
    match response {
        Ok(response) if response.status().is_success() => ProviderTestOutcome {
            status: "ready",
            message: "The provider accepted this account.",
        },
        Ok(response)
            if matches!(
                response.status(),
                reqwest::StatusCode::UNAUTHORIZED | reqwest::StatusCode::FORBIDDEN
            ) =>
        {
            ProviderTestOutcome {
                status: "rejected",
                message: "The provider rejected the saved account.",
            }
        }
        Ok(response) if response.status() == reqwest::StatusCode::TOO_MANY_REQUESTS => {
            ProviderTestOutcome {
                status: "rateLimited",
                message: "The provider rate limit was reached; try again later.",
            }
        }
        Ok(_) | Err(_) => ProviderTestOutcome {
            status: "unavailable",
            message: "The provider could not be reached or did not accept the test request.",
        },
    }
}

fn invalid_saved_credentials() -> ProviderTestOutcome {
    ProviderTestOutcome {
        status: "rejected",
        message: "The saved credential document is incomplete.",
    }
}
