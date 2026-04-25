use std::{ffi::OsString, process::Command};

use serde::de::DeserializeOwned;
use serde::Serialize;
use serde_json::json;

use crate::{config::ResolvedConfig, AppError};

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct BackendFailure {
    pub program: String,
    pub args: Vec<String>,
    pub status: Option<i32>,
    pub stdout: String,
    pub stderr: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionState {
    Authenticated { stdout: String },
    Missing { diagnostic: String },
}

#[derive(Debug, Clone)]
pub struct KanidmCli {
    program: OsString,
    server_url: String,
    admin_name: String,
}

impl KanidmCli {
    pub fn new(config: &ResolvedConfig) -> Self {
        Self {
            program: config.kanidm_bin.clone(),
            server_url: config.server_url.clone(),
            admin_name: config.admin_name.clone(),
        }
    }

    pub fn server_url(&self) -> &str {
        &self.server_url
    }

    pub fn admin_name(&self) -> &str {
        &self.admin_name
    }

    pub fn session_status(&self) -> Result<SessionState, AppError> {
        let args = self.base_args(["session", "list"]);
        match self.run_raw(args)? {
            Ok(output) => Ok(SessionState::Authenticated {
                stdout: output.stdout,
            }),
            Err(failure) => {
                let diagnostic = failure_message(&failure);
                if is_session_missing(&diagnostic) {
                    Ok(SessionState::Missing { diagnostic })
                } else {
                    Err(AppError::Backend {
                        message: "failed to inspect the current Kanidm session".to_string(),
                        failure: Box::new(failure),
                    })
                }
            }
        }
    }

    pub fn person_list<T: DeserializeOwned>(&self) -> Result<T, AppError> {
        let args = self.base_args(["person", "list", "-o", "json"]);
        self.run_json(args, "failed to list Kanidm users")
    }

    pub fn person_get<T: DeserializeOwned>(&self, account_id: &str) -> Result<T, AppError> {
        let args = self.base_args(["person", "get", account_id, "-o", "json"]);
        self.run_json(args, &format!("failed to load Kanidm user '{account_id}'"))
    }

    pub fn person_create(&self, account_id: &str, display_name: &str) -> Result<(), AppError> {
        let args = self.base_args(["person", "create", account_id, display_name]);
        self.run_unit(
            args,
            &format!("failed to create Kanidm user '{account_id}'"),
        )
    }

    pub fn clear_expiry(&self, account_id: &str) -> Result<(), AppError> {
        let args = self.base_args(["person", "validity", "expire-at", account_id, "clear"]);
        self.run_unit(
            args,
            &format!("failed to clear expiry for Kanidm user '{account_id}'"),
        )
    }

    pub fn clear_valid_from(&self, account_id: &str) -> Result<(), AppError> {
        let args = self.base_args(["person", "validity", "begin-from", account_id, "clear"]);
        self.run_unit(
            args,
            &format!("failed to clear valid-from restriction for Kanidm user '{account_id}'"),
        )
    }

    pub fn update_mail(&self, account_id: &str, email: &str) -> Result<(), AppError> {
        let args = self.base_args(["person", "update", account_id, "--mail", email]);
        self.run_unit(
            args,
            &format!("failed to set primary email for Kanidm user '{account_id}'"),
        )
    }

    pub fn group_add_members(&self, group: &str, account_id: &str) -> Result<(), AppError> {
        let args = self.base_args(["group", "add-members", group, account_id]);
        self.run_unit(
            args,
            &format!("failed to add '{account_id}' to group '{group}'"),
        )
    }

    pub fn group_remove_members(&self, group: &str, account_id: &str) -> Result<(), AppError> {
        let args = self.base_args(["group", "remove-members", group, account_id]);
        self.run_unit(
            args,
            &format!("failed to remove '{account_id}' from group '{group}'"),
        )
    }

    fn run_json<T: DeserializeOwned>(
        &self,
        args: Vec<String>,
        context: &str,
    ) -> Result<T, AppError> {
        let output = self.run_success(args, context)?;
        serde_json::from_str(&output.stdout).map_err(|error| AppError::Json {
            message: format!("{context}: invalid JSON from kanidm backend"),
            details: json!({
                "error": error.to_string(),
                "stdout": output.stdout,
            }),
        })
    }

    fn run_unit(&self, args: Vec<String>, context: &str) -> Result<(), AppError> {
        self.run_success(args, context).map(|_| ())
    }

    fn run_success(&self, args: Vec<String>, context: &str) -> Result<BackendSuccess, AppError> {
        match self.run_raw(args)? {
            Ok(output) => Ok(output),
            Err(failure) => Err(self.classify_failure(context, failure)),
        }
    }

    fn run_raw(
        &self,
        args: Vec<String>,
    ) -> Result<Result<BackendSuccess, BackendFailure>, AppError> {
        let output = Command::new(&self.program)
            .args(&args)
            .output()
            .map_err(|error| {
                if error.kind() == std::io::ErrorKind::NotFound {
                    AppError::MissingDependency {
                        binary: self.program.to_string_lossy().to_string(),
                    }
                } else {
                    AppError::Io {
                        message: format!(
                            "failed to execute {}: {error}",
                            self.program.to_string_lossy()
                        ),
                    }
                }
            })?;

        let stdout = String::from_utf8_lossy(&output.stdout).to_string();
        let stderr = String::from_utf8_lossy(&output.stderr).to_string();

        if output.status.success() {
            Ok(Ok(BackendSuccess { stdout }))
        } else {
            Ok(Err(BackendFailure {
                program: self.program.to_string_lossy().to_string(),
                args,
                status: output.status.code(),
                stdout,
                stderr,
            }))
        }
    }

    fn classify_failure(&self, context: &str, failure: BackendFailure) -> AppError {
        let diagnostic = failure_message(&failure);
        if is_session_missing(&diagnostic) {
            return AppError::SessionRequired {
                message: format!(
                    "{context}. Run `kanidm login --url {} --name {}` first.",
                    self.server_url, self.admin_name
                ),
            };
        }
        if is_reauth_required(&diagnostic) {
            return AppError::ReauthRequired {
                message: format!(
                    "{context}. Run `kanidm reauth --url {} --name {}` first.",
                    self.server_url, self.admin_name
                ),
            };
        }
        AppError::Backend {
            message: context.to_string(),
            failure: Box::new(failure),
        }
    }

    fn base_args<'a>(&self, prefix: impl IntoIterator<Item = &'a str>) -> Vec<String> {
        let mut args = prefix
            .into_iter()
            .map(ToOwned::to_owned)
            .collect::<Vec<_>>();
        args.extend([
            "--url".to_string(),
            self.server_url.clone(),
            "--name".to_string(),
            self.admin_name.clone(),
        ]);
        args
    }
}

#[derive(Debug, Clone)]
struct BackendSuccess {
    stdout: String,
}

fn failure_message(failure: &BackendFailure) -> String {
    let stderr = failure.stderr.trim();
    if !stderr.is_empty() {
        stderr.to_lowercase()
    } else {
        failure.stdout.trim().to_lowercase()
    }
}

fn is_session_missing(text: &str) -> bool {
    text.contains("no valid auth tokens found")
        || text.contains("session has expired")
        || text.contains("login again")
        || text.contains("not authenticated")
}

fn is_reauth_required(text: &str) -> bool {
    text.contains("privileges have expired")
        || text.contains("privileges have not been re-authenticated")
        || text.contains("need to re-authenticate again")
        || text.contains("reauth")
}
