pub mod commands;
pub mod config;
pub mod groups;
pub mod kanidm_cli;
pub mod models;
pub mod output;

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

    #[error("invalid managed group: {group}")]
    InvalidManagedGroup { group: String },

    #[error("user not found: {account_id}")]
    UserNotFound { account_id: String },

    #[error("{message}")]
    Verification { message: String, details: Value },

    #[error("{message}")]
    SessionRequired { message: String },

    #[error("{message}")]
    ReauthRequired { message: String },

    #[error("{message}")]
    Json { message: String, details: Value },

    #[error("{message}")]
    Io { message: String },
}

impl AppError {
    pub fn exit_code(&self) -> i32 {
        match self {
            Self::Config { .. } => 2,
            Self::MissingDependency { .. } => 3,
            Self::InvalidManagedGroup { .. } => 4,
            Self::UserNotFound { .. } => 5,
            Self::SessionRequired { .. } => 6,
            Self::ReauthRequired { .. } => 7,
            Self::Verification { .. } => 8,
            Self::Json { .. } => 9,
            Self::Backend { .. } => 10,
            Self::Io { .. } => 11,
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
            Self::Verification { message, details } | Self::Json { message, details } => {
                let rendered =
                    serde_json::to_string_pretty(details).unwrap_or_else(|_| details.to_string());
                format!("{message}\n\nDetails:\n{rendered}")
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
            Self::InvalidManagedGroup { group } => {
                json!({ "kind": "invalid_managed_group", "group": group })
            }
            Self::UserNotFound { account_id } => {
                json!({ "kind": "user_not_found", "account_id": account_id })
            }
            Self::Verification { details, .. } => {
                json!({ "kind": "verification", "details": details })
            }
            Self::SessionRequired { message } => {
                json!({ "kind": "session_required", "message": message })
            }
            Self::ReauthRequired { message } => {
                json!({ "kind": "reauth_required", "message": message })
            }
            Self::Json { details, .. } => json!({ "kind": "json", "details": details }),
            Self::Io { message } => json!({ "kind": "io", "message": message }),
        }
    }
}
