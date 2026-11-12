//! A separate, socket-activated root process for bounded administration. Caddy
//! alone owns its socket; the general AI service cannot connect or mint its
//! trusted request extensions. No shell, raw journal, config, or secret reads.

use axum::{
    extract::{Request, State},
    http::{header, StatusCode},
    middleware,
    response::{IntoResponse, Response},
    routing::post,
    Json, Router,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{collections::BTreeSet, path::PathBuf, sync::Arc, time::Duration};
use tokio::{io::AsyncReadExt, sync::Semaphore};

const PROPERTIES: &[&str] = &[
    "Id",
    "LoadState",
    "ActiveState",
    "SubState",
    "Result",
    "MainPID",
    "ExecMainStatus",
    "MemoryCurrent",
    "CPUUsageNSec",
    "ActiveEnterTimestamp",
];

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct Config {
    username: String,
    host: String,
    systemctl: PathBuf,
    diagnostic_services: BTreeSet<String>,
    restartable_services: BTreeSet<String>,
}

impl Config {
    fn validate(&self) -> Result<(), &'static str> {
        if !crate::admin_tools::valid_admin(&self.username)
            || crate::parse_public_host(Some(self.host.clone()))
                .ok()
                .flatten()
                .as_deref()
                != Some(self.host.as_str())
            || !self.systemctl.is_absolute()
            || !self.diagnostic_services.iter().all(|s| valid_unit(s))
            || !self
                .restartable_services
                .is_subset(&self.diagnostic_services)
        {
            return Err("Invalid administrator backend configuration");
        }
        Ok(())
    }
}

#[derive(Clone)]
struct Backend {
    config: Arc<Config>,
    gate: Arc<Semaphore>,
}

pub(super) async fn serve() -> Result<(), Box<dyn std::error::Error>> {
    let listener = crate::gateway_socket::inherited()?
        .ok_or("Admin backend requires its Caddy-owned activated socket")?;
    let config: Config = serde_json::from_str(&std::env::var("AI_TOOLS_ADMIN_CONFIG")?)?;
    config.validate()?;
    axum::serve(listener, router(config)).await?;
    Ok(())
}

fn router(config: Config) -> Router {
    Router::new()
        .route("/admin", post(handle))
        .with_state(Backend {
            config: Arc::new(config),
            gate: Arc::new(Semaphore::new(1)),
        })
        .layer(middleware::from_fn(crate::gateway::authenticate))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Operation {
    name: String,
    arguments: Value,
}

async fn handle(State(backend): State<Backend>, request: Request) -> Response {
    let Some(caller) = request
        .extensions()
        .get::<crate::gateway::AuthenticatedCaller>()
    else {
        return fail(StatusCode::UNAUTHORIZED, "Authenticated caller required");
    };
    // Exact canonical login only: no case folding, email/group fallback, tool
    // arguments, header lists, or an identity cached by the ordinary AI process.
    if caller.username() != backend.config.username {
        return fail(StatusCode::FORBIDDEN, "Server-admin login required");
    }
    let config = &backend.config;
    let expected_host = format!("{}:443", config.host);
    let host = request
        .headers()
        .get(header::HOST)
        .and_then(|v| v.to_str().ok());
    let origin = request
        .headers()
        .get(header::ORIGIN)
        .and_then(|v| v.to_str().ok());
    if !matches!(host, Some(h) if h==config.host || h==expected_host)
        || !matches!(origin, Some(o) if o==format!("https://{}",config.host) || o==format!("https://{}:443",config.host))
    {
        return fail(
            StatusCode::FORBIDDEN,
            "Unexpected administration host or origin",
        );
    }
    if request
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.split(';').next())
        != Some("application/json")
    {
        return fail(StatusCode::UNSUPPORTED_MEDIA_TYPE, "JSON required");
    }
    let actor = caller.subject().to_owned();
    let bytes = match axum::body::to_bytes(request.into_body(), 4096).await {
        Ok(b) => b,
        Err(_) => return fail(StatusCode::BAD_REQUEST, "Invalid administration request"),
    };
    let op: Operation = match serde_json::from_slice(&bytes) {
        Ok(op) => op,
        Err(_) => return fail(StatusCode::BAD_REQUEST, "Invalid administration request"),
    };
    let Ok(_permit) = backend.gate.try_acquire() else {
        return fail(
            StatusCode::SERVICE_UNAVAILABLE,
            "Another administration operation is running",
        );
    };
    let result = execute(config, &op).await;
    // Canonical subject and fixed operation/unit are safe; never record the
    // request body, cookies, command output, or arbitrary error text.
    let operation = if crate::admin_tools::is_tool(&op.name) {
        op.name.as_str()
    } else {
        "invalid"
    };
    let unit = op
        .arguments
        .get("service")
        .and_then(Value::as_str)
        .filter(|s| valid_unit(s))
        .unwrap_or("none");
    eprintln!(
        "admin-tools subject={actor} operation={operation} service={unit} outcome={}",
        if result.is_ok() { "accepted" } else { "failed" }
    );
    match result {
        Ok(value) => Json(value).into_response(),
        Err((status, message)) => fail(status, message),
    }
}

fn fail(status: StatusCode, message: &'static str) -> Response {
    (status, Json(json!({"error":message}))).into_response()
}
type Failure = (StatusCode, &'static str);
fn bad() -> Failure {
    (StatusCode::BAD_REQUEST, "Invalid administration arguments")
}

fn valid_unit(unit: &str) -> bool {
    unit.len() <= 200
        && unit.ends_with(".service")
        && unit
            .bytes()
            .next()
            .is_some_and(|b| b.is_ascii_alphanumeric())
        && unit
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-_.:@".contains(&b))
}

async fn execute(config: &Config, operation: &Operation) -> Result<Value, Failure> {
    if operation.name == "server_health" || operation.name == "server_services" {
        if operation
            .arguments
            .as_object()
            .is_none_or(|v| !v.is_empty())
        {
            return Err(bad());
        }
        if operation.name == "server_health" {
            return health().await;
        }
        let output = command(
            config,
            &[
                "list-units",
                "--type=service",
                "--state=failed",
                "--plain",
                "--legend=false",
                "--full",
                "--all",
            ],
        )
        .await?;
        // --output=json controls journal output, not list-units. These flags
        // remove bullets/headers; never consume or return unit descriptions.
        let text = std::str::from_utf8(&output)
            .map_err(|_| (StatusCode::BAD_GATEWAY, "Service inventory is unavailable"))?;
        let failed: Vec<_> = text
            .lines()
            .filter_map(|line| {
                let mut columns = line.split_whitespace();
                let unit = columns.next()?;
                let _load = columns.next()?;
                let active = columns.next()?;
                let sub = columns.next()?;
                config
                    .diagnostic_services
                    .contains(unit)
                    .then(|| json!({"service":unit,"active":active,"sub":sub}))
            })
            .collect();
        return Ok(
            json!({"diagnostic_services":config.diagnostic_services,"restartable_services":config.restartable_services,"failed_services":failed}),
        );
    }
    if !matches!(
        operation.name.as_str(),
        "server_service_status" | "server_restart_service"
    ) {
        return Err(bad());
    }
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Service {
        service: String,
    }
    let input: Service = serde_json::from_value(operation.arguments.clone()).map_err(|_| bad())?;
    if !valid_unit(&input.service) || !config.diagnostic_services.contains(&input.service) {
        return Err((
            StatusCode::FORBIDDEN,
            "Service is outside the diagnostic allowlist",
        ));
    }
    if operation.name == "server_restart_service" {
        if !config.restartable_services.contains(&input.service) {
            return Err((
                StatusCode::FORBIDDEN,
                "Service is outside the restart allowlist",
            ));
        }
        command(config, &["--no-block", "restart", "--", &input.service]).await?;
        return Ok(
            json!({"service":input.service,"status":"restart_requested","message":"Restart requested; inspect server_service_status before reporting recovery. Do not repeat an uncertain request automatically."}),
        );
    }
    let properties = format!("--property={}", PROPERTIES.join(","));
    let output = command(
        config,
        &["show", "--all", &properties, "--", &input.service],
    )
    .await?;
    let text = std::str::from_utf8(&output)
        .map_err(|_| (StatusCode::BAD_GATEWAY, "Service state is unavailable"))?;
    let mut state = serde_json::Map::new();
    for line in text.lines() {
        if let Some((key, value)) = line.split_once('=')
            && PROPERTIES.contains(&key)
        {
            state.insert(key.to_owned(), json!(value));
        }
    }
    Ok(
        json!({"service":input.service,"properties":state,"restartable":config.restartable_services.contains(&input.service)}),
    )
}

async fn command(config: &Config, arguments: &[&str]) -> Result<Vec<u8>, Failure> {
    let mut command = tokio::process::Command::new(&config.systemctl);
    command
        .env_clear()
        .env("LC_ALL", "C")
        .env("SYSTEMD_COLORS", "0")
        .current_dir("/")
        .args(["--no-pager", "--no-ask-password"])
        .args(arguments)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true);
    let mut child = command
        .spawn()
        .map_err(|_| (StatusCode::BAD_GATEWAY, "Service manager is unavailable"))?;
    let stdout = child
        .stdout
        .take()
        .ok_or((StatusCode::BAD_GATEWAY, "Service output is unavailable"))?;
    let work = async {
        let read = async {
            let mut bytes = Vec::new();
            stdout
                .take(262145)
                .read_to_end(&mut bytes)
                .await
                .map_err(|_| ())?;
            if bytes.len() > 262144 {
                return Err(());
            }
            Ok(bytes)
        };
        let wait = async {
            let status = child.wait().await.map_err(|_| ())?;
            if status.success() {
                Ok(())
            } else {
                Err(())
            }
        };
        let (bytes, ()) = tokio::try_join!(read, wait)?;
        Ok::<_, ()>(bytes)
    };
    tokio::time::timeout(Duration::from_secs(15), work)
        .await
        .map_err(|_| {
            (
                StatusCode::GATEWAY_TIMEOUT,
                "Service operation timed out; inspect status before retrying",
            )
        })?
        .map_err(|_| {
            (
                StatusCode::BAD_GATEWAY,
                "Service manager could not complete the operation",
            )
        })
}

async fn health() -> Result<Value, Failure> {
    let unavailable = || {
        (
            StatusCode::BAD_GATEWAY,
            "Resource information is unavailable",
        )
    };
    let uptime = tokio::fs::read_to_string("/proc/uptime")
        .await
        .map_err(|_| unavailable())?;
    let load = tokio::fs::read_to_string("/proc/loadavg")
        .await
        .map_err(|_| unavailable())?;
    let memory = tokio::fs::read_to_string("/proc/meminfo")
        .await
        .map_err(|_| unavailable())?;
    let memory: serde_json::Map<String, Value> = memory
        .lines()
        .filter_map(|line| {
            let (key, value) = line.split_once(':')?;
            if !["MemTotal", "MemAvailable", "SwapTotal", "SwapFree"].contains(&key) {
                return None;
            }
            let number = value.split_whitespace().next()?.parse::<u64>().ok()?;
            Some((key.to_owned(), json!(number)))
        })
        .collect();
    Ok(
        json!({"uptime_seconds":uptime.split_whitespace().next().and_then(|v|v.parse::<f64>().ok()),"load_average":load.split_whitespace().take(3).filter_map(|v|v.parse::<f64>().ok()).collect::<Vec<_>>(),"memory_kib":memory}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{body::Body, http::Request};
    use std::os::unix::fs::PermissionsExt;
    use tower::ServiceExt;

    // Privileged operations and cross-login escalation are concrete catastrophic
    // risks; tests use an inert fixture executable, never real systemctl.
    fn config() -> Config {
        Config {
            username: "admindsaw".into(),
            host: "tools.example.test".into(),
            systemctl: "/nonexistent/systemctl".into(),
            diagnostic_services: ["jellyfin.service", "caddy.service"]
                .map(str::to_owned)
                .into(),
            restartable_services: ["jellyfin.service".to_owned()].into(),
        }
    }

    fn request(user: Option<&str>, body: Value) -> Request<Body> {
        let mut request = Request::builder()
            .method("POST")
            .uri("/admin")
            .header("host", "tools.example.test")
            .header("origin", "https://tools.example.test")
            .header("content-type", "application/json")
            .body(Body::from(body.to_string()))
            .unwrap();
        if let Some(user) = user {
            request.headers_mut().insert(
                "x-forwarded-user",
                format!("subject-{user}").parse().unwrap(),
            );
            request
                .headers_mut()
                .insert("x-forwarded-preferred-username", user.parse().unwrap());
        }
        request
    }

    #[tokio::test]
    async fn backend_authenticates_every_request_before_parsing_or_execution() {
        let app = router(config());
        let body = json!({"name":"server_restart_service","arguments":{"service":"jellyfin.service","username":"admindsaw"}});
        assert_eq!(
            app.clone()
                .oneshot(request(None, body.clone()))
                .await
                .unwrap()
                .status(),
            StatusCode::UNAUTHORIZED
        );
        for name in ["dsaw", "AdminDsaw", "admindsaw@example.test"] {
            assert_eq!(
                app.clone()
                    .oneshot(request(Some(name), body.clone()))
                    .await
                    .unwrap()
                    .status(),
                StatusCode::FORBIDDEN
            );
        }
        let health = json!({"name":"server_health","arguments":{}});
        for origin in [
            "https://evil.test",
            "https://tools.example.test:444",
            "null",
        ] {
            let mut req = request(Some("admindsaw"), health.clone());
            req.headers_mut().insert("origin", origin.parse().unwrap());
            assert_eq!(
                app.clone().oneshot(req).await.unwrap().status(),
                StatusCode::FORBIDDEN
            );
        }
        let mut req = request(Some("admindsaw"), health.clone());
        req.headers_mut()
            .append("x-forwarded-preferred-username", "dsaw".parse().unwrap());
        assert_eq!(
            app.clone().oneshot(req).await.unwrap().status(),
            StatusCode::UNAUTHORIZED
        );
        assert_eq!(
            app.clone()
                .oneshot(request(Some("admindsaw"), health.clone()))
                .await
                .unwrap()
                .status(),
            StatusCode::OK
        );
        // An administrator's preceding request never authorizes the next user.
        assert_eq!(
            app.oneshot(request(Some("dsaw"), health))
                .await
                .unwrap()
                .status(),
            StatusCode::FORBIDDEN
        );
    }

    #[tokio::test]
    async fn restart_allowlist_and_schema_block_privilege_expansion() {
        let cfg = config();
        cfg.validate().unwrap();
        for service in [
            "caddy.service",
            "kanidm.service",
            "jellyfin.service;reboot",
            "--system",
            "../jellyfin.service",
            "jellyfin.service/other",
        ] {
            let error = execute(
                &cfg,
                &Operation {
                    name: "server_restart_service".into(),
                    arguments: json!({"service":service}),
                },
            )
            .await
            .unwrap_err();
            assert_eq!(error.0, StatusCode::FORBIDDEN);
        }
        for (name, arguments) in [
            ("exec", json!({"command":"reboot"})),
            (
                "server_restart_service",
                json!({"service":"jellyfin.service","command":"reboot"}),
            ),
            ("server_health", json!({"username":"admindsaw"})),
        ] {
            assert_eq!(
                execute(
                    &cfg,
                    &Operation {
                        name: name.into(),
                        arguments
                    }
                )
                .await
                .unwrap_err()
                .0,
                StatusCode::BAD_REQUEST
            );
        }
    }

    #[tokio::test]
    async fn fixed_commands_and_safe_properties_are_preserved() {
        let dir = crate::tests::SyntheticSharedRoot::new("admin-systemctl");
        let executable = dir.join("systemctl");
        let record = dir.join("arguments");
        let script=format!("#!/bin/sh\nprintf '%s\\n' \"$@\" > '{}'\ncase \"$*\" in\n *list-units*) printf 'jellyfin.service loaded failed failed do-not-return\\nunknown.service loaded failed failed hidden\\n' ;;\n *) printf 'Id=jellyfin.service\\nActiveState=active\\nEnvironment=do-not-return\\n' ;;\nesac\n",record.display());
        std::fs::write(&executable, script).unwrap();
        std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o755)).unwrap();
        let mut cfg = config();
        cfg.systemctl = executable;
        let op = Operation {
            name: "server_service_status".into(),
            arguments: json!({"service":"jellyfin.service"}),
        };
        let result = execute(&cfg, &op).await.unwrap();
        assert_eq!(result["properties"]["ActiveState"], "active");
        assert!(!result.to_string().contains("do-not-return"));
        let inventory = execute(
            &cfg,
            &Operation {
                name: "server_services".into(),
                arguments: json!({}),
            },
        )
        .await
        .unwrap();
        assert_eq!(inventory["failed_services"].as_array().unwrap().len(), 1);
        assert_eq!(inventory["failed_services"][0]["active"], "failed");
        assert!(!inventory.to_string().contains("do-not-return"));
        let op = Operation {
            name: "server_restart_service".into(),
            arguments: json!({"service":"jellyfin.service"}),
        };
        assert_eq!(
            execute(&cfg, &op).await.unwrap()["status"],
            "restart_requested"
        );
        assert_eq!(
            std::fs::read_to_string(record).unwrap(),
            "--no-pager\n--no-ask-password\n--no-block\nrestart\n--\njellyfin.service\n"
        );
    }
}
