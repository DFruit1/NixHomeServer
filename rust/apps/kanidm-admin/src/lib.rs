pub mod context;
pub mod interactive;
pub mod inventory;
pub mod kanidm_cli;
pub mod models;
pub mod ops;
pub mod output;
pub mod validation;

use serde_json::{json, Value};
use thiserror::Error;

use crate::kanidm_cli::BackendFailure;

#[derive(Debug, Error)]
pub enum AppError {
    #[error("{message}")]
    Config { message: String },

    #[error("required dependency is missing: {binary}")]
    MissingDependency { binary: String },

    #[error("{message}")]
    Backend {
        message: String,
        failure: Box<BackendFailure>,
    },

    #[error("{message}")]
    NotFound {
        message: String,
        resource: String,
        name: String,
        details: Value,
    },

    #[error("{message}")]
    AlreadyExists {
        message: String,
        resource: String,
        name: String,
        details: Value,
    },

    #[error("{message}")]
    Verification { message: String, details: Value },

    #[error("{message}")]
    PartialSuccess { message: String, details: Value },

    #[error("{message}")]
    SessionRequired { message: String, details: Value },

    #[error("{message}")]
    ReauthRequired { message: String, details: Value },

    #[error("{message}")]
    Json { message: String, details: Value },

    #[error("{message}")]
    BackendTimeout { message: String, details: Value },

    #[error("{message}")]
    InventoryIncomplete { message: String, details: Value },

    #[error("{message}")]
    Unsupported { message: String, details: Value },

    #[error("{message}")]
    Io { message: String },
}

impl AppError {
    pub fn exit_code(&self) -> i32 {
        match self {
            Self::Config { .. } => 2,
            Self::MissingDependency { .. } => 3,
            Self::NotFound { .. } => 5,
            Self::SessionRequired { .. } => 6,
            Self::ReauthRequired { .. } => 7,
            Self::Verification { .. } => 8,
            Self::PartialSuccess { .. } => 8,
            Self::Json { .. } => 9,
            Self::Backend { .. } => 10,
            Self::Io { .. } => 11,
            Self::BackendTimeout { .. } => 12,
            Self::InventoryIncomplete { .. } => 13,
            Self::Unsupported { .. } => 14,
            Self::AlreadyExists { .. } => 15,
        }
    }

    pub fn human_message(&self) -> String {
        match self {
            Self::Backend { message, failure } => {
                let stderr = failure.stderr.trim();
                let stdout = failure.stdout.trim();
                if !stderr.is_empty() {
                    format!("{message}\n\nBackend stderr:\n{stderr}")
                } else if !stdout.is_empty() {
                    format!("{message}\n\nBackend stdout:\n{stdout}")
                } else {
                    message.clone()
                }
            }
            Self::Verification { message, details }
            | Self::AlreadyExists {
                message, details, ..
            }
            | Self::Json { message, details }
            | Self::BackendTimeout { message, details }
            | Self::InventoryIncomplete { message, details }
            | Self::Unsupported { message, details }
            | Self::NotFound {
                message, details, ..
            } => {
                if matches!(self, Self::AlreadyExists { .. }) {
                    return render_already_exists(message, details);
                }
                let rendered =
                    serde_json::to_string_pretty(details).unwrap_or_else(|_| details.to_string());
                format!("{message}\n\nDetails:\n{rendered}")
            }
            Self::PartialSuccess { message, details } => render_partial_success(message, details),
            Self::SessionRequired { message, details }
            | Self::ReauthRequired { message, details } => {
                let diagnostic = details
                    .get("diagnostic")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|value| !value.is_empty());
                match diagnostic {
                    Some(diagnostic) => format!("{message}\n\nDiagnostic:\n{diagnostic}"),
                    None => message.clone(),
                }
            }
            _ => self.to_string(),
        }
    }

    pub fn json_payload(&self) -> Value {
        json!({
            "status": "error",
            "message": self.to_string(),
            "details": self.details(),
        })
    }

    fn details(&self) -> Value {
        match self {
            Self::Config { message } => json!({ "kind": "config", "message": message }),
            Self::MissingDependency { binary } => {
                json!({ "kind": "missing_dependency", "binary": binary })
            }
            Self::Backend { failure, .. } => json!({
                "kind": "backend",
                "program": failure.program,
                "args": failure.args,
                "status": failure.status,
                "stdout": failure.stdout,
                "stderr": failure.stderr,
            }),
            Self::NotFound {
                resource,
                name,
                details,
                ..
            } => {
                json!({ "kind": "not_found", "resource": resource, "name": name, "details": details })
            }
            Self::AlreadyExists {
                resource,
                name,
                details,
                ..
            } => {
                json!({ "kind": "already_exists", "resource": resource, "name": name, "details": details })
            }
            Self::Verification { details, .. } => {
                json!({ "kind": "verification", "details": details })
            }
            Self::PartialSuccess { details, .. } => {
                json!({ "kind": "partial_success", "details": details })
            }
            Self::SessionRequired { message, details } => {
                json!({ "kind": "session_required", "message": message, "details": details })
            }
            Self::ReauthRequired { message, details } => {
                json!({ "kind": "reauth_required", "message": message, "details": details })
            }
            Self::Json { details, .. } => json!({ "kind": "json", "details": details }),
            Self::BackendTimeout { details, .. } => {
                json!({ "kind": "backend_timeout", "details": details })
            }
            Self::InventoryIncomplete { details, .. } => {
                json!({ "kind": "inventory_incomplete", "details": details })
            }
            Self::Unsupported { details, .. } => {
                json!({ "kind": "unsupported", "details": details })
            }
            Self::Io { message } => json!({ "kind": "io", "message": message }),
        }
    }
}

fn render_already_exists(message: &str, details: &Value) -> String {
    let mut body = vec![message.to_string()];

    if let Some(observed_state) = details.get("observed_state") {
        body.push(format!(
            "Current observed state:\n{}",
            render_json_block(observed_state)
        ));
    }

    if let Some(next_actions) = render_actions(details) {
        body.push(format!("Next action:\n{next_actions}"));
    }

    if let Some(diagnostic) = extract_diagnostic(details.get("backend").unwrap_or(details)) {
        body.push(format!("Backend diagnostic:\n{diagnostic}"));
    }

    body.join("\n\n")
}

fn render_partial_success(message: &str, details: &Value) -> String {
    let mut body = vec![format!("What happened:\n{message}")];

    if let Some(observed_state) = details.get("observed_state") {
        body.push(format!(
            "Current observed state:\n{}",
            render_json_block(observed_state)
        ));
    }

    if let Some(completed_steps) = render_step_list(details.get("completed_steps")) {
        body.push(format!("Completed steps:\n{completed_steps}"));
    }

    if let Some(failed_step) = details.get("failed_step").and_then(Value::as_str) {
        body.push(format!("Failed step:\n- {failed_step}"));
    }

    if let Some(next_actions) = render_actions(details) {
        body.push(format!("Next action:\n{next_actions}"));
    }

    if let Some(diagnostic) = extract_diagnostic(details.get("backend").unwrap_or(details)) {
        body.push(format!("Backend diagnostic:\n{diagnostic}"));
    }

    body.join("\n\n")
}

fn render_actions(details: &Value) -> Option<String> {
    render_step_list(details.get("next_actions"))
}

fn render_step_list(value: Option<&Value>) -> Option<String> {
    let items = value
        .and_then(Value::as_array)?
        .iter()
        .filter_map(Value::as_str)
        .map(|item| format!("- {item}"))
        .collect::<Vec<_>>();
    (!items.is_empty()).then(|| items.join("\n"))
}

fn render_json_block(value: &Value) -> String {
    serde_json::to_string_pretty(value).unwrap_or_else(|_| value.to_string())
}

fn extract_diagnostic(value: &Value) -> Option<String> {
    value.as_object()?;

    let direct = value
        .get("diagnostic")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned);
    if direct.is_some() {
        return direct;
    }

    let details = value.get("details");
    if let Some(details) = details {
        if let Some(diagnostic) = extract_diagnostic(details) {
            return Some(diagnostic);
        }
    }

    let stderr = value
        .get("stderr")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty());
    if let Some(stderr) = stderr {
        return Some(stderr.to_string());
    }

    value
        .get("stdout")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}
