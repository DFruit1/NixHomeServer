use std::{
    ffi::OsString,
    process::{Command, Stdio},
    thread::sleep,
    time::{Duration, Instant},
};

use serde::de::DeserializeOwned;
use serde::Serialize;
use serde_json::{json, Value};

use crate::{context::ResolvedContext, AppError};

const COMMAND_TIMEOUT: Duration = Duration::from_secs(20);
const COMMAND_POLL_INTERVAL: Duration = Duration::from_millis(50);
const VERIFICATION_BACKOFF_MS: [u64; 7] = [250, 500, 1_000, 2_000, 2_000, 2_000, 2_000];

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

#[derive(Debug)]
pub enum VerificationCheck<T> {
    Matched { observed: Value, value: T },
    Mismatch { observed: Value },
    Fatal { observed: Value, error: AppError },
}

impl KanidmCli {
    pub fn new(context: &ResolvedContext) -> Self {
        Self {
            program: context.kanidm_bin.clone(),
            server_url: context.server_url.clone(),
            admin_name: context.admin_name.clone(),
        }
    }

    pub fn server_url(&self) -> &str {
        &self.server_url
    }

    pub fn admin_name(&self) -> &str {
        &self.admin_name
    }

    pub fn session_status(&self) -> Result<SessionState, AppError> {
        let context = "failed to inspect the current Kanidm session";
        let args = self.base_args(["session", "list"]);
        match self.run_raw(args, context)? {
            Ok(output) => Ok(SessionState::Authenticated {
                stdout: output.stdout,
            }),
            Err(failure) => {
                let diagnostic = preferred_diagnostic(&failure);
                if is_session_missing(&normalized(&diagnostic)) {
                    Ok(SessionState::Missing { diagnostic })
                } else {
                    Err(AppError::Backend {
                        message: context.to_string(),
                        failure: Box::new(failure),
                    })
                }
            }
        }
    }

    pub fn person_list<T: DeserializeOwned>(&self) -> Result<T, AppError> {
        self.run_json(
            self.json_args(["person", "list"]),
            "failed to list Kanidm users",
        )
    }

    pub fn person_get<T: DeserializeOwned>(&self, account_id: &str) -> Result<T, AppError> {
        self.run_named_json(
            self.json_args(["person", "get", account_id]),
            &format!("failed to load Kanidm user '{account_id}'"),
            "user",
            account_id,
        )
    }

    pub fn group_list<T: DeserializeOwned>(&self) -> Result<T, AppError> {
        self.run_json(
            self.json_args(["group", "list"]),
            "failed to list Kanidm groups",
        )
    }

    pub fn group_get<T: DeserializeOwned>(&self, group: &str) -> Result<T, AppError> {
        self.run_named_json(
            self.json_args(["group", "get", group]),
            &format!("failed to load Kanidm group '{group}'"),
            "group",
            group,
        )
    }

    pub fn group_list_members<T: DeserializeOwned>(&self, group: &str) -> Result<T, AppError> {
        self.run_json(
            self.json_args(["group", "list-members", group]),
            &format!("failed to list members of Kanidm group '{group}'"),
        )
    }

    pub fn oauth2_list<T: DeserializeOwned>(&self) -> Result<T, AppError> {
        self.run_json(
            self.json_args(["system", "oauth2", "list"]),
            "failed to list Kanidm oauth2 clients",
        )
    }

    pub fn oauth2_get<T: DeserializeOwned>(&self, client: &str) -> Result<T, AppError> {
        self.run_named_json(
            self.json_args(["system", "oauth2", "get", client]),
            &format!("failed to load Kanidm oauth2 client '{client}'"),
            "oauth2_client",
            client,
        )
    }

    pub fn person_create(&self, account_id: &str, display_name: &str) -> Result<(), AppError> {
        self.run_unit(
            self.base_args(["person", "create", account_id, display_name]),
            &format!("failed to create Kanidm user '{account_id}'"),
        )
    }

    pub fn person_disable(&self, account_id: &str) -> Result<(), AppError> {
        self.run_unit(
            self.base_args(["person", "validity", "expire-at", account_id, "now"]),
            &format!("failed to disable Kanidm user '{account_id}'"),
        )
    }

    pub fn person_enable(&self, account_id: &str) -> Result<(), AppError> {
        self.run_unit(
            self.base_args(["person", "validity", "expire-at", account_id, "clear"]),
            &format!(
                "failed to clear expiry for Kanidm user '{account_id}' while enabling the account"
            ),
        )?;
        self.run_unit(
            self.base_args(["person", "validity", "begin-from", account_id, "clear"]),
            &format!(
                "failed to clear valid-from restriction for Kanidm user '{account_id}' while enabling the account"
            ),
        )
    }

    pub fn person_delete(&self, account_id: &str) -> Result<(), AppError> {
        self.run_unit(
            self.base_args(["person", "delete", account_id]),
            &format!("failed to delete Kanidm user '{account_id}'"),
        )
    }

    pub fn clear_expiry(&self, account_id: &str) -> Result<(), AppError> {
        self.run_unit(
            self.base_args(["person", "validity", "expire-at", account_id, "clear"]),
            &format!("failed to clear expiry for Kanidm user '{account_id}'"),
        )
    }

    pub fn clear_valid_from(&self, account_id: &str) -> Result<(), AppError> {
        self.run_unit(
            self.base_args(["person", "validity", "begin-from", account_id, "clear"]),
            &format!("failed to clear valid-from restriction for Kanidm user '{account_id}'"),
        )
    }

    pub fn update_mail(&self, account_id: &str, email: &str) -> Result<(), AppError> {
        self.run_unit(
            self.base_args(["person", "update", account_id, "--mail", email]),
            &format!("failed to set primary email for Kanidm user '{account_id}'"),
        )
    }

    pub fn person_create_reset_token(
        &self,
        account_id: &str,
        ttl_seconds: u64,
    ) -> Result<String, AppError> {
        self.run_stdout(
            self.base_args([
                "person",
                "credential",
                "create-reset-token",
                account_id,
                &ttl_seconds.to_string(),
            ]),
            &format!("failed to create a password reset token for Kanidm user '{account_id}'"),
        )
    }

    pub fn group_add_members(&self, group: &str, account_id: &str) -> Result<(), AppError> {
        self.run_unit(
            self.base_args(["group", "add-members", group, account_id]),
            &format!("failed to add '{account_id}' to group '{group}'"),
        )
    }

    pub fn group_remove_members(&self, group: &str, account_id: &str) -> Result<(), AppError> {
        self.run_unit(
            self.base_args(["group", "remove-members", group, account_id]),
            &format!("failed to remove '{account_id}' from group '{group}'"),
        )
    }

    pub fn oauth2_show_basic_secret(&self, client: &str) -> Result<String, AppError> {
        self.run_stdout(
            self.base_args(["system", "oauth2", "show-basic-secret", client]),
            &format!("failed to show the basic secret for oauth2 client '{client}'"),
        )
    }

    pub fn oauth2_reset_basic_secret(&self, client: &str) -> Result<String, AppError> {
        self.run_stdout(
            self.base_args(["system", "oauth2", "reset-basic-secret", client]),
            &format!("failed to reset the basic secret for oauth2 client '{client}'"),
        )
    }

    pub fn oauth2_add_redirect_url(&self, client: &str, url: &str) -> Result<(), AppError> {
        self.run_unit(
            self.base_args(["system", "oauth2", "add-redirect-url", client, url]),
            &format!("failed to add redirect URL '{url}' to oauth2 client '{client}'"),
        )
    }

    pub fn oauth2_remove_redirect_url(&self, client: &str, url: &str) -> Result<(), AppError> {
        self.run_unit(
            self.base_args(["system", "oauth2", "remove-redirect-url", client, url]),
            &format!("failed to remove redirect URL '{url}' from oauth2 client '{client}'"),
        )
    }

    pub fn oauth2_enable_pkce(&self, client: &str) -> Result<(), AppError> {
        self.run_unit(
            self.base_args(["system", "oauth2", "enable-pkce", client]),
            &format!("failed to enable PKCE for oauth2 client '{client}'"),
        )
    }

    pub fn oauth2_disable_pkce(&self, client: &str) -> Result<(), AppError> {
        self.run_unit(
            self.base_args([
                "system",
                "oauth2",
                "warning-insecure-client-disable-pkce",
                client,
            ]),
            &format!("failed to disable PKCE for oauth2 client '{client}'"),
        )
    }

    pub fn oauth2_enable_consent(&self, client: &str) -> Result<(), AppError> {
        self.run_unit(
            self.base_args(["system", "oauth2", "enable-consent-prompt", client]),
            &format!("failed to enable the consent prompt for oauth2 client '{client}'"),
        )
    }

    pub fn oauth2_disable_consent(&self, client: &str) -> Result<(), AppError> {
        self.run_unit(
            self.base_args(["system", "oauth2", "disable-consent-prompt", client]),
            &format!("failed to disable the consent prompt for oauth2 client '{client}'"),
        )
    }

    pub fn group_policy_auth_expiry_set(&self, group: &str, seconds: u64) -> Result<(), AppError> {
        self.run_unit(
            self.base_args([
                "group",
                "account-policy",
                "auth-expiry",
                group,
                &seconds.to_string(),
            ]),
            &format!("failed to set auth-expiry for group '{group}'"),
        )
    }

    pub fn group_policy_auth_expiry_reset(&self, group: &str) -> Result<(), AppError> {
        self.run_unit(
            self.base_args(["group", "account-policy", "reset-auth-expiry", group]),
            &format!("failed to reset auth-expiry for group '{group}'"),
        )
    }

    pub fn group_policy_privilege_expiry_set(
        &self,
        group: &str,
        seconds: u64,
    ) -> Result<(), AppError> {
        self.run_unit(
            self.base_args([
                "group",
                "account-policy",
                "privilege-expiry",
                group,
                &seconds.to_string(),
            ]),
            &format!("failed to set privilege-expiry for group '{group}'"),
        )
    }

    pub fn group_policy_privilege_expiry_reset(&self, group: &str) -> Result<(), AppError> {
        self.run_unit(
            self.base_args(["group", "account-policy", "reset-privilege-expiry", group]),
            &format!("failed to reset privilege-expiry for group '{group}'"),
        )
    }

    pub fn login(&self) -> Result<(), AppError> {
        self.run_inherited([
            "login",
            "--url",
            &self.server_url,
            "--name",
            &self.admin_name,
        ])
    }

    pub fn reauth(&self) -> Result<(), AppError> {
        self.run_inherited([
            "reauth",
            "--url",
            &self.server_url,
            "--name",
            &self.admin_name,
        ])
    }

    pub fn logout(&self) -> Result<(), AppError> {
        self.run_unit(
            self.base_args(["logout"]),
            "failed to log out of the current Kanidm session",
        )
    }

    fn run_named_json<T: DeserializeOwned>(
        &self,
        args: Vec<String>,
        context: &str,
        resource: &str,
        name: &str,
    ) -> Result<T, AppError> {
        let output = match self.run_raw(args, context)? {
            Ok(output) => output,
            Err(failure) => {
                return Err(self.classify_named_failure(resource, name, context, failure))
            }
        };
        serde_json::from_str(&output.stdout).map_err(|error| AppError::Json {
            message: format!("{context}: invalid JSON from kanidm backend"),
            details: json!({
                "error": error.to_string(),
                "stdout": output.stdout,
            }),
        })
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

    fn run_stdout(&self, args: Vec<String>, context: &str) -> Result<String, AppError> {
        self.run_success(args, context).map(|output| output.stdout)
    }

    fn run_inherited<'a>(&self, args: impl IntoIterator<Item = &'a str>) -> Result<(), AppError> {
        let rendered_args = args.into_iter().map(ToOwned::to_owned).collect::<Vec<_>>();
        let status = Command::new(&self.program)
            .args(&rendered_args)
            .stdin(Stdio::inherit())
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit())
            .status()
            .map_err(|error| {
                if error.kind() == std::io::ErrorKind::NotFound {
                    AppError::MissingDependency {
                        binary: self.program.to_string_lossy().to_string(),
                    }
                } else {
                    AppError::Io {
                        message: format!(
                            "failed to execute {} interactively: {error}",
                            self.program.to_string_lossy()
                        ),
                    }
                }
            })?;

        if status.success() {
            Ok(())
        } else {
            Err(AppError::Backend {
                message: format!(
                    "{} exited unsuccessfully; inspect the terminal output above",
                    self.program.to_string_lossy()
                ),
                failure: Box::new(BackendFailure {
                    program: self.program.to_string_lossy().to_string(),
                    args: rendered_args,
                    status: status.code(),
                    stdout: String::new(),
                    stderr: String::new(),
                }),
            })
        }
    }

    fn run_success(&self, args: Vec<String>, context: &str) -> Result<BackendSuccess, AppError> {
        match self.run_raw(args, context)? {
            Ok(output) => Ok(output),
            Err(failure) => Err(self.classify_failure(context, failure)),
        }
    }

    fn run_raw(
        &self,
        args: Vec<String>,
        context: &str,
    ) -> Result<Result<BackendSuccess, BackendFailure>, AppError> {
        let output = run_captured_command(&self.program, &args, context, COMMAND_TIMEOUT)?;
        if output.status.success() {
            Ok(Ok(BackendSuccess {
                stdout: output.stdout,
            }))
        } else {
            Ok(Err(BackendFailure {
                program: self.program.to_string_lossy().to_string(),
                args,
                status: output.status.code(),
                stdout: output.stdout,
                stderr: output.stderr,
            }))
        }
    }

    fn classify_failure(&self, context: &str, failure: BackendFailure) -> AppError {
        let diagnostic = preferred_diagnostic(&failure);
        let normalized_diagnostic = normalized(&diagnostic);
        if is_session_missing(&normalized_diagnostic) {
            return AppError::SessionRequired {
                message: format!(
                    "{context}. Run `kanidm login --url {} --name {}` first.",
                    self.server_url, self.admin_name
                ),
                details: session_or_reauth_details(&diagnostic, &failure),
            };
        }
        if is_reauth_required(&normalized_diagnostic) {
            return AppError::ReauthRequired {
                message: format!(
                    "{context}. Run `kanidm reauth --url {} --name {}` first.",
                    self.server_url, self.admin_name
                ),
                details: session_or_reauth_details(&diagnostic, &failure),
            };
        }
        AppError::Backend {
            message: context.to_string(),
            failure: Box::new(failure),
        }
    }

    fn classify_named_failure(
        &self,
        resource: &str,
        name: &str,
        context: &str,
        failure: BackendFailure,
    ) -> AppError {
        let diagnostic = preferred_diagnostic(&failure);
        if is_not_found(&normalized(&diagnostic)) {
            return AppError::NotFound {
                message: format!("{resource} '{name}' was not found"),
                resource: resource.to_string(),
                name: name.to_string(),
                details: json!({
                    "diagnostic": diagnostic,
                    "backend": backend_failure_payload(&failure),
                }),
            };
        }
        self.classify_failure(context, failure)
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

    fn json_args<'a>(&self, prefix: impl IntoIterator<Item = &'a str>) -> Vec<String> {
        let mut args = self.base_args(prefix);
        args.extend(["-o".to_string(), "json".to_string()]);
        args
    }
}

#[derive(Debug, Clone)]
struct BackendSuccess {
    stdout: String,
}

#[derive(Debug)]
struct CapturedCommandOutput {
    status: std::process::ExitStatus,
    stdout: String,
    stderr: String,
}

pub fn verify_with_retry<T, F>(
    context: &str,
    expected: Value,
    write_completed: bool,
    mut probe: F,
) -> Result<T, AppError>
where
    F: FnMut() -> Result<VerificationCheck<T>, AppError>,
{
    let start = Instant::now();
    let mut attempts = Vec::new();

    for (attempt_index, delay_ms) in std::iter::once(0)
        .chain(VERIFICATION_BACKOFF_MS)
        .enumerate()
    {
        if delay_ms > 0 {
            sleep(Duration::from_millis(delay_ms));
        }

        let attempt_number = attempt_index + 1;
        match probe() {
            Ok(VerificationCheck::Matched { observed, value }) => {
                attempts.push(json!({
                    "attempt": attempt_number,
                    "delay_ms": delay_ms,
                    "outcome": "matched",
                    "observed": observed,
                }));
                return Ok(value);
            }
            Ok(VerificationCheck::Mismatch { observed }) => {
                attempts.push(json!({
                    "attempt": attempt_number,
                    "delay_ms": delay_ms,
                    "outcome": "mismatch",
                    "observed": observed,
                }));
            }
            Ok(VerificationCheck::Fatal { observed, error }) => {
                attempts.push(json!({
                    "attempt": attempt_number,
                    "delay_ms": delay_ms,
                    "outcome": "fatal",
                    "observed": observed,
                    "error": error.json_payload(),
                }));
                return Err(AppError::Verification {
                    message: context.to_string(),
                    details: json!({
                        "elapsed_ms": start.elapsed().as_millis(),
                        "expected_state": expected,
                        "attempts": attempts,
                        "write_completed": write_completed,
                        "fatal_error": error.json_payload(),
                    }),
                });
            }
            Err(error) => {
                attempts.push(json!({
                    "attempt": attempt_number,
                    "delay_ms": delay_ms,
                    "outcome": "fatal",
                    "observed": error.json_payload(),
                    "error": error.json_payload(),
                }));
                return Err(AppError::Verification {
                    message: context.to_string(),
                    details: json!({
                        "elapsed_ms": start.elapsed().as_millis(),
                        "expected_state": expected,
                        "attempts": attempts,
                        "write_completed": write_completed,
                        "fatal_error": error.json_payload(),
                    }),
                });
            }
        }
    }

    Err(AppError::Verification {
        message: context.to_string(),
        details: json!({
            "elapsed_ms": start.elapsed().as_millis(),
            "expected_state": expected,
            "attempts": attempts,
            "write_completed": write_completed,
        }),
    })
}

fn run_captured_command(
    program: &OsString,
    args: &[String],
    context: &str,
    timeout: Duration,
) -> Result<CapturedCommandOutput, AppError> {
    let mut child = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| {
            if error.kind() == std::io::ErrorKind::NotFound {
                AppError::MissingDependency {
                    binary: program.to_string_lossy().to_string(),
                }
            } else {
                AppError::Io {
                    message: format!("failed to execute {}: {error}", program.to_string_lossy()),
                }
            }
        })?;

    let start = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => {
                let output = child.wait_with_output().map_err(|error| AppError::Io {
                    message: format!(
                        "failed to collect output from {}: {error}",
                        program.to_string_lossy()
                    ),
                })?;
                return Ok(CapturedCommandOutput {
                    status: output.status,
                    stdout: String::from_utf8_lossy(&output.stdout).to_string(),
                    stderr: String::from_utf8_lossy(&output.stderr).to_string(),
                });
            }
            Ok(None) if start.elapsed() >= timeout => {
                let _ = child.kill();
                let output = child.wait_with_output().map_err(|error| AppError::Io {
                    message: format!(
                        "failed to collect timed-out output from {}: {error}",
                        program.to_string_lossy()
                    ),
                })?;
                return Err(AppError::BackendTimeout {
                    message: format!(
                        "{context}: command timed out after {} second(s)",
                        timeout.as_secs()
                    ),
                    details: json!({
                        "program": program.to_string_lossy(),
                        "args": args,
                        "elapsed_ms": start.elapsed().as_millis(),
                        "stdout": String::from_utf8_lossy(&output.stdout),
                        "stderr": String::from_utf8_lossy(&output.stderr),
                    }),
                });
            }
            Ok(None) => sleep(COMMAND_POLL_INTERVAL),
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(AppError::Io {
                    message: format!(
                        "failed while waiting on {}: {error}",
                        program.to_string_lossy()
                    ),
                });
            }
        }
    }
}

fn backend_failure_payload(failure: &BackendFailure) -> Value {
    json!({
        "program": failure.program,
        "args": failure.args,
        "status": failure.status,
        "stdout": failure.stdout,
        "stderr": failure.stderr,
    })
}

fn session_or_reauth_details(diagnostic: &str, failure: &BackendFailure) -> Value {
    json!({
        "diagnostic": diagnostic,
        "backend": backend_failure_payload(failure),
    })
}

fn preferred_diagnostic(failure: &BackendFailure) -> String {
    let stderr = failure.stderr.trim();
    if !stderr.is_empty() {
        stderr.to_string()
    } else {
        failure.stdout.trim().to_string()
    }
}

fn normalized(text: &str) -> String {
    text.trim().to_lowercase()
}

fn is_session_missing(text: &str) -> bool {
    text.contains("no valid auth tokens found")
        || text.contains("session has expired")
        || text.contains("login again")
        || text.contains("not authenticated")
        || text.contains("authentication required")
}

fn is_reauth_required(text: &str) -> bool {
    text.contains("privileges have expired")
        || text.contains("privileges have not been re-authenticated")
        || text.contains("need to re-authenticate again")
        || text.contains("must re-authenticate")
        || text.contains("privileged session has expired")
}

fn is_not_found(text: &str) -> bool {
    text.contains("not found")
        || text.contains("no matching entries")
        || text.contains("does not exist")
        || text.contains("no entries were returned")
        || text.contains("cannot find")
}

#[cfg(test)]
mod tests {
    use std::{fs, os::unix::fs::PermissionsExt, path::Path, process::Command as ProcessCommand};

    use super::*;

    fn write_script(path: &Path, body: &str) {
        let shell = ProcessCommand::new("bash")
            .args(["-lc", "command -v bash"])
            .output()
            .ok()
            .filter(|output| output.status.success())
            .and_then(|output| String::from_utf8(output.stdout).ok())
            .map(|stdout| stdout.trim().to_string())
            .filter(|stdout| !stdout.is_empty())
            .unwrap_or_else(|| "/bin/sh".to_string());
        let rewritten = body.replacen("#!/usr/bin/env bash", &format!("#!{shell}"), 1);
        fs::write(path, rewritten).expect("write script");
        let mut permissions = fs::metadata(path).expect("metadata").permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(path, permissions).expect("chmod");
    }

    #[test]
    fn captured_command_times_out() {
        let dir = tempfile::tempdir().expect("tempdir");
        let script = dir.path().join("sleep.sh");
        write_script(
            &script,
            r#"#!/usr/bin/env bash
sleep 1
"#,
        );

        let error = run_captured_command(
            &script.into_os_string(),
            &[],
            "timed command",
            Duration::from_millis(10),
        )
        .expect_err("timeout");

        assert!(matches!(error, AppError::BackendTimeout { .. }));
    }

    #[test]
    fn verification_stops_on_fatal_probe_error() {
        let error =
            verify_with_retry::<(), _>("verification failed", json!({"ok": true}), true, || {
                Err(AppError::Json {
                    message: "bad json".to_string(),
                    details: json!({"stdout": "oops"}),
                })
            })
            .expect_err("fatal error");

        match error {
            AppError::Verification { details, .. } => {
                assert_eq!(details["attempts"][0]["outcome"], "fatal");
            }
            other => panic!("unexpected error: {other:?}"),
        }
    }

    #[test]
    fn reauth_classifier_is_not_triggered_by_unrelated_text() {
        assert!(!is_reauth_required(
            "documentation mentions reauthentication flow"
        ));
        assert!(is_reauth_required("privileges have expired"));
    }

    #[test]
    fn named_json_normalizes_not_found_diagnostics() {
        let dir = tempfile::tempdir().expect("tempdir");
        let script = dir.path().join("kanidm-stub.sh");
        write_script(
            &script,
            r#"#!/usr/bin/env bash
printf 'No matching entries were found\n' >&2
exit 1
"#,
        );
        let cli = KanidmCli::new(&ResolvedContext {
            repo_root: None,
            server_url: "https://id.example.test".to_string(),
            admin_name: "admindsaw".to_string(),
            kanidm_bin: script.into_os_string(),
        });

        let error = cli.person_get::<Value>("dsaw").expect_err("not found");
        assert!(matches!(error, AppError::NotFound { .. }));
    }
}
