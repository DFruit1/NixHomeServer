use super::*;

pub(super) fn frontend_mode() -> FrontendMode {
    match env::var("MAIL_ARCHIVE_UI_FRONTEND_MODE")
        .unwrap_or_else(|_| "production".to_string())
        .trim()
    {
        "vite" => FrontendMode::Vite,
        _ => FrontendMode::Production,
    }
}

pub(super) fn frontend_dist_dir_from_env() -> String {
    env::var("MAIL_ARCHIVE_UI_FRONTEND_DIST_DIR")
        .unwrap_or_else(|_| DEFAULT_FRONTEND_DIST_DIR.to_string())
}

pub(super) fn vite_origin_from_env() -> String {
    env::var("MAIL_ARCHIVE_UI_VITE_ORIGIN").unwrap_or_else(|_| DEFAULT_VITE_ORIGIN.to_string())
}

pub(super) fn render_frontend_tags() -> String {
    match frontend_mode() {
        FrontendMode::Production => {
            match production_asset_tags(&frontend_dist_dir_from_env(), FRONTEND_ENTRYPOINT) {
                Ok(tags) => tags,
                Err(error) => format!(
                    "<!-- mail-archive-ui frontend assets unavailable: {} -->",
                    escape_html(&error)
                ),
            }
        }
        FrontendMode::Vite => vite_asset_tags(&vite_origin_from_env()),
    }
}

pub(super) fn production_asset_tags(dist_dir: &str, entrypoint: &str) -> Result<String, String> {
    let manifest_path = PathBuf::from(dist_dir).join(".vite").join("manifest.json");
    let manifest_text = fs::read_to_string(&manifest_path).map_err(|error| {
        format!(
            "failed to read Vite manifest at {}: {error}",
            manifest_path.display()
        )
    })?;
    let manifest: serde_json::Value = serde_json::from_str(&manifest_text)
        .map_err(|error| format!("invalid manifest: {error}"))?;
    let entry = manifest
        .get(entrypoint)
        .and_then(|value| value.as_object())
        .ok_or_else(|| format!("manifest is missing entrypoint {entrypoint}"))?;
    let file = entry
        .get("file")
        .and_then(|value| value.as_str())
        .ok_or_else(|| format!("manifest entrypoint {entrypoint} is missing file"))?;

    let mut tags = String::new();
    if let Some(css_files) = entry.get("css").and_then(|value| value.as_array()) {
        for css_file in css_files.iter().filter_map(|value| value.as_str()) {
            writeln!(
                &mut tags,
                r#"<link rel="stylesheet" href="/static/frontend/{}">"#,
                escape_html(css_file)
            )
            .ok();
        }
    }
    writeln!(
        &mut tags,
        r#"<script type="module" src="/static/frontend/{}"></script>"#,
        escape_html(file)
    )
    .ok();
    Ok(tags)
}

pub(super) fn vite_asset_tags(origin: &str) -> String {
    let origin = origin.trim_end_matches('/');
    format!(
        r#"<script type="module" src="{}/@vite/client"></script>
<script type="module" src="{}/src/entry.dev.tsx"></script>"#,
        escape_html(origin),
        escape_html(origin),
    )
}

pub(super) fn layout(
    title: &str,
    identity: Option<&Identity>,
    active_nav: &str,
    body: &str,
) -> String {
    let frontend_tags = render_frontend_tags();
    let top_nav = if active_nav == "dashboard" {
        String::new()
    } else {
        format!(
            r#"<nav class="top-nav" aria-label="Main navigation">
          <a class="{}" href="/search">Mail</a>
          <a class="{}" href="/attachments">Attachments</a>
        </nav>"#,
            nav_active_class(active_nav == "search"),
            nav_active_class(active_nav == "attachments"),
        )
    };
    format!(
        r#"<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>{}</title>
    {}
  </head>
  <body>
    <main class="page">
      <header class="app-header">
        <a class="brand-link" href="/" aria-label="Mail Archive dashboard">
          <span class="brand-icon" aria-hidden="true"><span class="brand-envelope"></span></span>
          <span>Mail Archive</span>
        </a>
        {}
      </header>
      {}
      <footer class="page-footer">
        <p class="meta footer-meta">{}</p>
      </footer>
    </main>
    <div id="mail-archive-ui-islands"></div>
  </body>
</html>"#,
        escape_html(title),
        frontend_tags,
        top_nav,
        body,
        escape_html(&identity_summary(identity)),
    )
}

pub(super) fn identity_summary(identity: Option<&Identity>) -> String {
    identity
        .map(|identity| format!("Signed in as {}", identity.username))
        .unwrap_or_else(|| "Authentication required".to_string())
}

pub(super) fn nav_active_class(active: bool) -> &'static str {
    if active {
        "active"
    } else {
        ""
    }
}

pub(super) fn auth_error(status: StatusCode, message: &str) -> Response {
    let html = layout(
        "Access denied",
        None,
        "",
        &format!(
            "<section class=\"panel stack\"><p class=\"eyebrow\">Access denied</p><h1>Request blocked</h1><div class=\"error\">{}</div></section>",
            escape_html(message)
        ),
    );
    html_response_with_status(status, html)
}

pub(super) fn server_error_page(
    title: &str,
    message: &str,
    identity: Option<&Identity>,
) -> Response {
    let html = layout(
        title,
        identity,
        "",
        &format!(
            "<section class=\"panel stack\"><p class=\"eyebrow\">Service error</p><h1>{}</h1><div class=\"error\">{}</div></section>",
            escape_html(title),
            escape_html(message)
        ),
    );
    html_response_with_status(StatusCode::INTERNAL_SERVER_ERROR, html)
}

pub(super) fn escape_html(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

pub(super) fn local_datetime(timestamp: i64) -> Option<DateTime<Local>> {
    DateTime::<Utc>::from_timestamp(timestamp, 0).map(|value| value.with_timezone(&Local))
}

pub(super) fn format_timestamp_date_label(timestamp: i64) -> String {
    local_datetime(timestamp)
        .map(|value| value.format("%d %b %Y").to_string())
        .unwrap_or_else(|| "Unknown date".to_string())
}

pub(super) fn format_timestamp_tooltip_label(timestamp: i64) -> String {
    local_datetime(timestamp)
        .map(|value| {
            let hour = value.hour();
            let display_hour = match hour % 12 {
                0 => 12,
                value => value,
            };
            let suffix = if hour < 12 { "am" } else { "pm" };
            format!(
                "{}, {}:{:02}{}",
                value.format("%d %b %Y"),
                display_hour,
                value.minute(),
                suffix
            )
        })
        .unwrap_or_else(|| "Unknown date".to_string())
}

pub(super) fn random_hex(bytes: usize) -> String {
    let mut buffer = vec![0_u8; bytes];
    OsRng.fill_bytes(&mut buffer);
    buffer
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>()
}

pub(super) fn parse_optional_query_i64(raw: Option<&str>) -> Result<Option<i64>, String> {
    match raw.map(str::trim).filter(|value| !value.is_empty()) {
        Some(value) => value
            .parse::<i64>()
            .map(Some)
            .map_err(|error| format!("invalid integer '{value}': {error}")),
        None => Ok(None),
    }
}

pub(super) fn deserialize_optional_query_i64<'de, D>(
    deserializer: D,
) -> Result<Option<i64>, D::Error>
where
    D: Deserializer<'de>,
{
    let raw = Option::<String>::deserialize(deserializer)?;
    parse_optional_query_i64(raw.as_deref()).map_err(de::Error::custom)
}

pub(super) fn normalize_selected_account_id(
    accounts: &[AccountRecord],
    selected_account_id: Option<i64>,
) -> Option<i64> {
    selected_account_id.filter(|selected| accounts.iter().any(|account| account.id == *selected))
}

pub(super) fn has_explicit_query_param(raw_query: &str) -> bool {
    raw_query
        .split('&')
        .any(|part| part == "q" || part.starts_with("q="))
}

pub(super) fn has_explicit_search_param(raw_query: &str) -> bool {
    const SEARCH_KEYS: &[&str] = &[
        "q",
        "sender_address",
        "sender_name",
        "sender_domain",
        "subject",
        "body_text",
        "date_from",
        "date_to",
        "has_attachments",
        "priority",
    ];
    raw_query.split('&').any(|part| {
        let key = part.split_once('=').map(|(key, _)| key).unwrap_or(part);
        SEARCH_KEYS.contains(&key)
    })
}

pub(super) fn url_encode_component(value: &str) -> String {
    value
        .bytes()
        .flat_map(|byte| match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                vec![byte as char]
            }
            b' ' => vec!['+'],
            _ => format!("%{byte:02X}").chars().collect::<Vec<_>>(),
        })
        .collect()
}

pub(super) fn attachments_redirect_location(
    return_to: Option<&str>,
    flash: Option<&str>,
    error: Option<&str>,
) -> String {
    let mut location = return_to
        .filter(|value| value.starts_with("/attachments"))
        .unwrap_or("/attachments")
        .to_string();
    let separator = if location.contains('?') { '&' } else { '?' };
    let mut first_extra = true;
    for (key, value) in [("flash", flash), ("error", error)] {
        if let Some(value) = value.filter(|value| !value.is_empty()) {
            location.push(if first_extra { separator } else { '&' });
            first_extra = false;
            location.push_str(key);
            location.push('=');
            location.push_str(&url_encode_component(value));
        }
    }
    location
}

pub(super) fn message_redirect_location(
    return_to: Option<&str>,
    flash: Option<&str>,
    error: Option<&str>,
) -> String {
    let mut location = return_to
        .filter(|value| value.starts_with("/search") || value.starts_with("/attachments"))
        .unwrap_or("/search")
        .to_string();
    let separator = if location.contains('?') { '&' } else { '?' };
    let mut first_extra = true;
    for (key, value) in [("flash", flash), ("error", error)] {
        if let Some(value) = value.filter(|value| !value.is_empty()) {
            location.push(if first_extra { separator } else { '&' });
            first_extra = false;
            location.push_str(key);
            location.push('=');
            location.push_str(&url_encode_component(value));
        }
    }
    location
}

pub(super) fn attachment_download_response(
    filename: &str,
    mime_type: &str,
    bytes: Vec<u8>,
) -> Response {
    let mut response = Response::new(Body::from(bytes));
    *response.status_mut() = StatusCode::OK;
    if let Ok(value) = HeaderValue::from_str(mime_type) {
        response.headers_mut().insert(CONTENT_TYPE, value);
    } else {
        response.headers_mut().insert(
            CONTENT_TYPE,
            HeaderValue::from_static("application/octet-stream"),
        );
    }
    if let Ok(value) = HeaderValue::from_str(&content_disposition_attachment(filename)) {
        response.headers_mut().insert(CONTENT_DISPOSITION, value);
    }
    harden_response(response)
}

pub(super) async fn zip_download_file_response(zip_file: TempZipFile) -> Response {
    let metadata = match tokio::fs::metadata(&zip_file.path).await {
        Ok(metadata) => metadata,
        Err(error) => {
            return server_error_page(
                "Download failed",
                &format!("ZIP file is unavailable: {error}"),
                None,
            )
        }
    };
    let file = match tokio::fs::File::open(&zip_file.path).await {
        Ok(file) => file,
        Err(error) => {
            return server_error_page(
                "Download failed",
                &format!("ZIP file could not be opened: {error}"),
                None,
            )
        }
    };
    let stream = ReaderStream::new(file);
    let mut response = Response::new(Body::from_stream(stream));
    *response.status_mut() = StatusCode::OK;
    response
        .headers_mut()
        .insert(CONTENT_TYPE, HeaderValue::from_static("application/zip"));
    if let Ok(value) = HeaderValue::from_str(&metadata.len().to_string()) {
        response.headers_mut().insert("Content-Length", value);
    }
    if let Ok(value) = HeaderValue::from_str(&content_disposition_attachment(&zip_file.filename)) {
        response.headers_mut().insert(CONTENT_DISPOSITION, value);
    }
    harden_response(response)
}

pub(super) fn html_response(html: String) -> Response {
    harden_response(Html(html).into_response())
}

pub(super) fn html_response_with_status(status: StatusCode, html: String) -> Response {
    harden_response((status, Html(html)).into_response())
}

pub(super) fn json_response<T: Serialize>(status: StatusCode, payload: T) -> Response {
    harden_response((status, Json(payload)).into_response())
}

pub(super) fn no_store_response(mut response: Response) -> Response {
    response
        .headers_mut()
        .insert("Cache-Control", HeaderValue::from_static("no-store"));
    response
}

pub(super) fn redirect_response(location: &str) -> Response {
    harden_response(Redirect::to(location).into_response())
}

pub(super) fn content_type_for_path(path: &FsPath) -> &'static str {
    match path.extension().and_then(|extension| extension.to_str()) {
        Some("css") => "text/css; charset=utf-8",
        Some("html") => "text/html; charset=utf-8",
        Some("js") => "text/javascript; charset=utf-8",
        Some("json") => "application/json; charset=utf-8",
        Some("svg") => "image/svg+xml",
        Some("wasm") => "application/wasm",
        _ => "application/octet-stream",
    }
}

pub(super) fn vite_ws_origin(origin: &str) -> String {
    if let Some(rest) = origin.strip_prefix("https://") {
        format!("wss://{rest}")
    } else if let Some(rest) = origin.strip_prefix("http://") {
        format!("ws://{rest}")
    } else {
        origin.to_string()
    }
}

pub(super) fn content_security_policy() -> String {
    match frontend_mode() {
        FrontendMode::Production => {
            "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; form-action 'self'; frame-ancestors 'none'; base-uri 'self'".to_string()
        }
        FrontendMode::Vite => {
            let origin = vite_origin_from_env();
            let origin = origin.trim_end_matches('/');
            let ws_origin = vite_ws_origin(origin);
            format!(
                "default-src 'self'; script-src 'self' {origin}; style-src 'self' 'unsafe-inline' {origin}; connect-src 'self' {origin} {ws_origin}; img-src 'self' data:; form-action 'self'; frame-ancestors 'none'; base-uri 'self'"
            )
        }
    }
}

pub(super) fn harden_response(mut response: Response) -> Response {
    let headers = response.headers_mut();
    headers.insert("X-Frame-Options", HeaderValue::from_static("DENY"));
    headers.insert(
        "X-Content-Type-Options",
        HeaderValue::from_static("nosniff"),
    );
    headers.insert("Referrer-Policy", HeaderValue::from_static("same-origin"));
    headers.insert(
        "Content-Security-Policy",
        HeaderValue::from_str(&content_security_policy()).unwrap_or_else(|_| {
            HeaderValue::from_static(
                "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; form-action 'self'; frame-ancestors 'none'; base-uri 'self'",
            )
        }),
    );
    response
}
