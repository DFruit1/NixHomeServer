pub mod backend;
pub mod backend_log;
pub mod context;
pub mod interactive;
pub mod inventory;
pub mod kanidm_cli;
pub mod models;
pub mod ops;
pub mod output;
pub mod sensitivity;
pub mod session_state;
pub mod validation;
pub mod verification;

#[cfg(test)]
pub(crate) static TEST_ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

use crate::backend::BackendFailure;
use serde_json::{json, Value};
use thiserror::Error;

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
                let mut body = message.clone();
                if sensitivity::invocation_args_are_sensitive(&failure.args)
                    && (!stdout.is_empty() || !stderr.is_empty())
                {
                    body.push_str(
                        "\n\nBackend output was redacted because this command can emit secrets.",
                    );
                } else if !stdout.is_empty() {
                    body.push_str("\n\nBackend stdout:\n");
                    body.push_str(stdout);
                    if !stderr.is_empty() {
                        body.push_str("\n\nBackend stderr:\n");
                        body.push_str(stderr);
                    }
                } else if !stderr.is_empty() {
                    body.push_str("\n\nBackend stderr:\n");
                    body.push_str(stderr);
                }
                body
            }
            Self::AlreadyExists {
                message, details, ..
            }
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
            Self::Verification { message, details } => render_verification(message, details),
            Self::Json { message, details } => render_json_error(message, details),
            Self::BackendTimeout { message, details } => render_backend_timeout(message, details),
            Self::InventoryIncomplete { message, details } => {
                render_inventory_incomplete(message, details)
            }
            Self::Unsupported { message, details } => {
                let rendered =
                    serde_json::to_string_pretty(details).unwrap_or_else(|_| details.to_string());
                format!("{message}\n\nDetails:\n{rendered}")
            }
            Self::PartialSuccess { message, details } => render_partial_success(message, details),
            Self::SessionRequired {
                message,
                details: _,
            }
            | Self::ReauthRequired {
                message,
                details: _,
            } => message.clone(),
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
            Self::Backend { failure, .. } => {
                let payload = json!({
                    "kind": "backend",
                    "program": failure.program,
                    "args": failure.args,
                    "status": failure.status,
                    "stdout": failure.stdout,
                    "stderr": failure.stderr,
                    "crash_kind": failure.crash_kind.map(|kind| kind.as_str()),
                });
                if sensitivity::invocation_args_are_sensitive(&failure.args) {
                    sensitivity::sanitize_sensitive_value(payload)
                } else {
                    payload
                }
            }
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
    let mut body = Vec::new();

    if let Some(completed_steps) = render_step_list(details.get("completed_steps")) {
        body.push(format!("Completed:\n{completed_steps}"));
    } else {
        body.push(
            "Completed:\n- At least one earlier step completed before the failure was detected."
                .to_string(),
        );
    }

    if let Some(failed_step) = details.get("failed_step").and_then(Value::as_str) {
        body.push(format!(
            "Not yet confirmed:\n- {message}\n- Failed step: {failed_step}"
        ));
    } else {
        body.push(format!("Not yet confirmed:\n- {message}"));
    }

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

fn render_verification(message: &str, details: &Value) -> String {
    let lead = match details.get("failure_kind").and_then(Value::as_str) {
        Some("unixd_auth_failed") => {
            "The password update completed, but the UnixD password verification failed."
        }
        Some("posix_password_update_rejected") => {
            "Kanidm rejected the POSIX password update, so no local verification was attempted."
        }
        Some("sftp_runtime_not_ready") => {
            "The command completed, but the SFTP runtime checks did not all pass."
        }
        Some("membership_convergence_timeout") => {
            "The membership write may have completed, but Kanidm did not report the expected group state before the timeout."
        }
        Some("local_runtime_not_ready") => {
            "The remote change completed, but a local runtime prerequisite is still not ready."
        }
        Some("session_recovery_unstable") => {
            "Kanidm accepted the session command, but the expected session state was not confirmed."
        }
        Some("context_eval_failed") => {
            "The installed context was unavailable, and deriving context from the repo failed."
        }
        _ => "The command may have started, but the final state did not confirm in time.",
    };
    let mut body = vec![lead.to_string(), format!("What happened:\n{message}")];

    if let Some(expected) = details.get("expected_state") {
        body.push(format!("Expected state:\n{}", render_json_block(expected)));
    }

    if let Some(observed) = last_observed_state(details) {
        body.push(format!(
            "Last observed state:\n{}",
            render_json_block(&observed)
        ));
    }

    if let Some(failed_checks) = render_failed_checks(details) {
        body.push(format!("Not yet confirmed:\n{failed_checks}"));
    }

    if let Some(next_actions) = render_actions(details) {
        body.push(format!("Next action:\n{next_actions}"));
    } else if let Some(next_actions) =
        default_next_actions_for_failure_kind(details.get("failure_kind").and_then(Value::as_str))
    {
        body.push(format!("Next action:\n{next_actions}"));
    } else {
        body.push(
            "Next action:\n- Inspect the live state before retrying the command.".to_string(),
        );
    }

    if let Some(diagnostic) = extract_diagnostic(details) {
        body.push(format!("Backend diagnostic:\n{diagnostic}"));
    }

    body.join("\n\n")
}

fn render_inventory_incomplete(message: &str, details: &Value) -> String {
    let mut body = vec![
        "This action was blocked because live discovery was incomplete, so the tool could not safely confirm the current state.".to_string(),
        format!("What happened:\n{message}"),
    ];

    if let Some(warnings) = render_step_list(details.get("warnings")) {
        body.push(format!("Warnings:\n{warnings}"));
    }

    if let Some(next_actions) = render_actions(details) {
        body.push(format!("Next action:\n{next_actions}"));
    } else {
        body.push(
            "Next action:\n- Re-run `kanidm-admin doctor` and fix discovery or session issues before retrying.".to_string(),
        );
    }

    body.join("\n\n")
}

fn render_backend_timeout(message: &str, details: &Value) -> String {
    let elapsed_ms = details.get("elapsed_ms").and_then(Value::as_u64);
    let mut body = vec![
        format!(
            "The Kanidm command did not finish within {} second(s).",
            elapsed_ms.map(|value| value.div_ceil(1000)).unwrap_or(20)
        ),
        format!("What happened:\n{message}"),
    ];

    if let Some(command) = render_command_summary(details) {
        body.push(format!("Command:\n{command}"));
    }

    body.push(
        "Next action:\n- Retry once if the server was temporarily busy.\n- If it times out again, run `kanidm-admin doctor` and inspect server responsiveness.".to_string(),
    );

    if let Some(diagnostic) = extract_diagnostic(details) {
        body.push(format!("Backend diagnostic:\n{diagnostic}"));
    }

    body.join("\n\n")
}

fn render_json_error(message: &str, details: &Value) -> String {
    let mut body = vec![
        "The Kanidm backend responded, but the output format did not match what this tool expected.".to_string(),
        format!("What happened:\n{message}"),
    ];

    if let Some(error) = details.get("error").and_then(Value::as_str) {
        body.push(format!("Parser error:\n- {error}"));
    }

    body.push(
        "Next action:\n- Confirm the `kanidm` CLI version is compatible.\n- If the issue persists, inspect the raw backend output below.".to_string(),
    );

    if let Some(diagnostic) = extract_diagnostic(details) {
        body.push(format!("Raw output:\n{diagnostic}"));
    }

    body.join("\n\n")
}

fn render_actions(details: &Value) -> Option<String> {
    render_step_list(details.get("next_actions")).or_else(|| {
        details
            .get("concurrency_hint")
            .and_then(|hint| render_step_list(hint.get("next_actions")))
    })
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

fn render_failed_checks(details: &Value) -> Option<String> {
    let direct = details.get("failed_required_checks");
    let runtime = details
        .get("runtime")
        .and_then(|runtime| runtime.get("failed_required_checks"));
    let items = direct
        .or(runtime)
        .and_then(Value::as_array)?
        .iter()
        .filter_map(Value::as_str)
        .map(|item| format!("- {item}"))
        .collect::<Vec<_>>();
    (!items.is_empty()).then(|| items.join("\n"))
}

fn default_next_actions_for_failure_kind(failure_kind: Option<&str>) -> Option<String> {
    let actions = match failure_kind? {
        "membership_convergence_timeout" => vec![
            "Inspect the current memberships with `kanidm-admin membership show <account_id>`.",
            "Retry only after confirming the target group list is still intended.",
        ],
        "local_runtime_not_ready" => vec![
            "Run the matching local diagnose command to inspect failed runtime checks.",
            "Check the failed systemd unit or mount listed under Not yet confirmed.",
        ],
        "session_recovery_unstable" => vec![
            "Run `kanidm-admin session diagnose`.",
            "Retry `kanidm-admin session login` or `kanidm-admin session reauth` after the session state is clear.",
        ],
        "context_eval_failed" => vec![
            "Run the guarded rebuild/deploy helper so `/etc/kanidm-admin/context.json` is installed.",
            "If running from a checkout, pass `--repo-root` or set `KANIDM_ADMIN_REPO_ROOT` to a directory containing `vars.nix`.",
            "Set `KANIDM_ADMIN_CONTEXT_FILE` to a valid installed context file when using this outside the repo.",
        ],
        "posix_password_update_rejected" => vec![
            "Choose a POSIX/SFTP password that satisfies Kanidm password policy and history requirements.",
            "Retry the password-set command and stop if Kanidm reports another policy or complexity rejection.",
        ],
        _ => return None,
    };
    Some(
        actions
            .into_iter()
            .map(|action| format!("- {action}"))
            .collect::<Vec<_>>()
            .join("\n"),
    )
}

fn last_observed_state(details: &Value) -> Option<Value> {
    details
        .get("attempts")
        .and_then(Value::as_array)?
        .iter()
        .rev()
        .find_map(|attempt| attempt.get("observed").cloned())
}

fn render_command_summary(details: &Value) -> Option<String> {
    let program = details.get("program").and_then(Value::as_str)?;
    let args = details
        .get("args")
        .and_then(Value::as_array)
        .map(|values| {
            values
                .iter()
                .filter_map(Value::as_str)
                .collect::<Vec<_>>()
                .join(" ")
        })
        .unwrap_or_default();
    Some(if args.is_empty() {
        program.to_string()
    } else {
        format!("{program} {args}")
    })
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

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn verification_errors_lead_with_plain_language_summary() {
        let error = AppError::Verification {
            message: "verification failed".to_string(),
            details: json!({
                "expected_state": { "enabled": true },
                "attempts": [
                    { "observed": { "enabled": false } }
                ]
            }),
        };

        let rendered = error.human_message();
        assert!(rendered.contains("final state did not confirm in time"));
        assert!(rendered.contains("Expected state"));
        assert!(rendered.contains("Last observed state"));
    }

    #[test]
    fn unixd_auth_verification_errors_use_specific_summary() {
        let error = AppError::Verification {
            message: "UnixD rejected the password".to_string(),
            details: json!({
                "failure_kind": "unixd_auth_failed",
                "next_actions": ["retry the auth test"],
            }),
        };

        let rendered = error.human_message();
        assert!(rendered.contains("UnixD password verification failed"));
        assert!(rendered.contains("UnixD rejected the password"));
        assert!(rendered.contains("retry the auth test"));
    }

    #[test]
    fn partial_success_splits_completed_and_unconfirmed_state() {
        let error = AppError::PartialSuccess {
            message: "user 'alice' was modified, but 'mail_update' did not finish cleanly"
                .to_string(),
            details: json!({
                "completed_steps": ["person_create"],
                "failed_step": "mail_update",
                "next_actions": ["inspect alice"],
            }),
        };

        let rendered = error.human_message();
        assert!(rendered.contains("Completed:\n- person_create"));
        assert!(rendered.contains("Not yet confirmed:"));
        assert!(rendered.contains("Failed step: mail_update"));
        assert!(rendered.contains("inspect alice"));
    }

    #[test]
    fn inventory_incomplete_errors_suggest_doctor() {
        let error = AppError::InventoryIncomplete {
            message: "inventory incomplete".to_string(),
            details: json!({
                "warnings": ["parse warning"],
            }),
        };

        let rendered = error.human_message();
        assert!(rendered.contains("live discovery was incomplete"));
        assert!(rendered.contains("kanidm-admin doctor"));
    }

    #[test]
    fn backend_timeout_errors_render_command_summary() {
        let error = AppError::BackendTimeout {
            message: "timed out".to_string(),
            details: json!({
                "program": "kanidm",
                "args": ["person", "list"],
                "elapsed_ms": 20000,
                "stderr": "slow backend",
            }),
        };

        let rendered = error.human_message();
        assert!(rendered.contains("did not finish within"));
        assert!(rendered.contains("kanidm person list"));
        assert!(rendered.contains("slow backend"));
    }
}
