use std::{
    ffi::OsString,
    process::{Command, Stdio},
    thread::sleep,
    time::{Duration, Instant},
};

use serde::de::DeserializeOwned;
use serde::Serialize;
use serde_json::{json, Value};
use time::{
    format_description::{well_known::Rfc3339, FormatItem},
    macros::format_description,
    OffsetDateTime,
};

use crate::{context::ResolvedContext, AppError};

const COMMAND_TIMEOUT: Duration = Duration::from_secs(20);
const COMMAND_POLL_INTERVAL: Duration = Duration::from_millis(50);
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
    Authenticated {
        stdout: String,
        session: ParsedSession,
    },
    Expired {
        diagnostic: String,
    },
    Missing {
        diagnostic: String,
    },
    ReauthRequired {
        diagnostic: String,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BaseSessionState {
    Present,
    Expired,
    Missing,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PrivilegedWriteState {
    Ready,
    ReauthRequired,
    Unavailable,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ParseConfidence {
    High,
    Heuristic,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionSnapshot {
    pub admin_name: String,
    pub server_url: String,
    pub matched_principal: Option<String>,
    pub base_session_state: BaseSessionState,
    pub privileged_write_state: PrivilegedWriteState,
    pub base_expiry: ParsedExpiry,
    pub privileged_expiry: ParsedExpiry,
    pub diagnostic_raw: String,
    pub parse_confidence: ParseConfidence,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedSession {
    pub principal: String,
    pub session_expiry: ParsedExpiry,
    pub purpose: ParsedSessionPurpose,
    pub raw: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParsedExpiry {
    Never,
    At(OffsetDateTime),
    Unknown(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParsedSessionPurpose {
    ReadOnly,
    ReadWrite { expiry: ParsedExpiry },
    Unknown(String),
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VerificationPolicy {
    SessionRecovery,
    ReadAfterWrite,
    MembershipConvergence,
    PolicyConvergence,
    ClientConvergence,
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
        Ok(self.session_snapshot()?.to_session_state())
    }

    pub fn session_snapshot(&self) -> Result<SessionSnapshot, AppError> {
        let context = "failed to inspect the current Kanidm session";
        let args = self.base_args(["session", "list"]);
        match self.run_raw(args, context)? {
            Ok(output) => Ok(classify_session_snapshot(
                output.stdout.trim(),
                &self.admin_name,
                &self.server_url,
                OffsetDateTime::now_utc(),
            )),
            Err(failure) => {
                let diagnostic = preferred_diagnostic(&failure);
                classify_heuristic_session_snapshot(&diagnostic, &self.admin_name, &self.server_url)
                    .ok_or_else(|| AppError::Backend {
                        message: context.to_string(),
                        failure: Box::new(failure),
                    })
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
        self.run_named_create_unit(
            self.base_args(["person", "create", account_id, display_name]),
            &format!("failed to create Kanidm user '{account_id}'"),
            "user",
            account_id,
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

    fn run_named_create_unit(
        &self,
        args: Vec<String>,
        context: &str,
        resource: &str,
        name: &str,
    ) -> Result<(), AppError> {
        match self.run_raw(args, context)? {
            Ok(_) => Ok(()),
            Err(failure) => {
                Err(self.classify_named_create_failure(resource, name, context, failure))
            }
        }
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
        let normalized_diagnostic = normalized(&classification_diagnostic(&failure));
        if is_session_expired(&normalized_diagnostic) || is_session_missing(&normalized_diagnostic)
        {
            return AppError::SessionRequired {
                message: format!("{context}. Run `kanidm-admin session login` first.",),
                details: session_or_reauth_details(&diagnostic, &failure),
            };
        }
        if is_reauth_required(&normalized_diagnostic) {
            return AppError::ReauthRequired {
                message: format!(
                    "{context}. Run `kanidm-admin session reauth` first. The base session may still appear active, but privileged write access has expired.",
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
        let normalized_diagnostic = normalized(&classification_diagnostic(&failure));
        if is_not_found(&normalized_diagnostic) {
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

    fn classify_named_create_failure(
        &self,
        resource: &str,
        name: &str,
        context: &str,
        failure: BackendFailure,
    ) -> AppError {
        let normalized_diagnostic = normalized(&classification_diagnostic(&failure));
        if is_already_exists(&normalized_diagnostic) {
            return AppError::AlreadyExists {
                message: format!("{resource} '{name}' already exists"),
                resource: resource.to_string(),
                name: name.to_string(),
                details: json!({
                    "resource": resource,
                    "name": name,
                    "backend": backend_failure_payload(&failure),
                }),
            };
        }
        self.classify_named_failure(resource, name, context, failure)
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

impl SessionSnapshot {
    pub fn to_session_state(&self) -> SessionState {
        match self.base_session_state {
            BaseSessionState::Expired => SessionState::Expired {
                diagnostic: self.diagnostic_raw.clone(),
            },
            BaseSessionState::Missing | BaseSessionState::Unknown => SessionState::Missing {
                diagnostic: self.diagnostic_raw.clone(),
            },
            BaseSessionState::Present => match self.privileged_write_state {
                PrivilegedWriteState::Ready => SessionState::Authenticated {
                    stdout: self.diagnostic_raw.clone(),
                    session: self.to_parsed_session(),
                },
                PrivilegedWriteState::ReauthRequired
                | PrivilegedWriteState::Unavailable
                | PrivilegedWriteState::Unknown => SessionState::ReauthRequired {
                    diagnostic: self.diagnostic_raw.clone(),
                },
            },
        }
    }

    pub fn base_session_present(&self) -> bool {
        matches!(self.base_session_state, BaseSessionState::Present)
    }

    pub fn privileged_write_ready(&self) -> bool {
        matches!(self.privileged_write_state, PrivilegedWriteState::Ready)
    }

    fn to_parsed_session(&self) -> ParsedSession {
        let principal = self
            .matched_principal
            .clone()
            .unwrap_or_else(|| self.admin_name.clone());
        let purpose = match self.privileged_write_state {
            PrivilegedWriteState::Ready => ParsedSessionPurpose::ReadWrite {
                expiry: self.privileged_expiry.clone(),
            },
            PrivilegedWriteState::ReauthRequired => ParsedSessionPurpose::ReadWrite {
                expiry: self.privileged_expiry.clone(),
            },
            PrivilegedWriteState::Unavailable | PrivilegedWriteState::Unknown => {
                ParsedSessionPurpose::Unknown("privileged write state unavailable".to_string())
            }
        };

        ParsedSession {
            principal,
            session_expiry: self.base_expiry.clone(),
            purpose,
            raw: self.diagnostic_raw.clone(),
        }
    }
}

impl VerificationPolicy {
    fn name(self) -> &'static str {
        match self {
            Self::SessionRecovery => "session_recovery",
            Self::ReadAfterWrite => "read_after_write",
            Self::MembershipConvergence => "membership_convergence",
            Self::PolicyConvergence => "policy_convergence",
            Self::ClientConvergence => "client_convergence",
        }
    }

    fn delays_ms(self) -> &'static [u64] {
        match self {
            Self::SessionRecovery => &[250, 500, 1_000, 1_500],
            Self::ReadAfterWrite => &[250, 500, 1_000, 2_000, 2_000, 3_000],
            Self::MembershipConvergence => &[250, 500, 1_000, 2_000, 2_000, 2_000, 3_000],
            Self::PolicyConvergence => &[250, 500, 1_000, 1_500, 2_000, 2_000],
            Self::ClientConvergence => &[250, 500, 1_000, 1_500, 2_000, 2_000],
        }
    }

    fn total_time_budget_ms(self) -> u64 {
        match self {
            Self::SessionRecovery => 5_000,
            Self::ReadAfterWrite => 12_000,
            Self::MembershipConvergence => 14_000,
            Self::PolicyConvergence => 10_000,
            Self::ClientConvergence => 10_000,
        }
    }

    fn allow_partial_success_warning(self) -> bool {
        !matches!(self, Self::SessionRecovery)
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
    policy: VerificationPolicy,
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
    let total_time_budget_ms = policy.total_time_budget_ms();

    for (attempt_index, delay_ms) in std::iter::once(0)
        .chain(policy.delays_ms().iter().copied())
        .enumerate()
    {
        if attempt_index > 0
            && start.elapsed().as_millis() + u128::from(delay_ms) > u128::from(total_time_budget_ms)
        {
            break;
        }
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
                        "verification_policy": {
                            "name": policy.name(),
                            "total_time_budget_ms": total_time_budget_ms,
                            "allow_partial_success_warning": policy.allow_partial_success_warning(),
                        },
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
                        "verification_policy": {
                            "name": policy.name(),
                            "total_time_budget_ms": total_time_budget_ms,
                            "allow_partial_success_warning": policy.allow_partial_success_warning(),
                        },
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
            "verification_policy": {
                "name": policy.name(),
                "total_time_budget_ms": total_time_budget_ms,
                "allow_partial_success_warning": policy.allow_partial_success_warning(),
            },
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

fn classification_diagnostic(failure: &BackendFailure) -> String {
    [failure.stderr.as_str(), failure.stdout.as_str()]
        .into_iter()
        .map(strip_control_sequences)
        .map(|text| text.trim().to_string())
        .filter(|text| !text.is_empty())
        .collect::<Vec<_>>()
        .join("\n")
}

fn normalized(text: &str) -> String {
    text.trim().to_lowercase()
}

const DISPLAY_TS_WITH_SUBSECOND_AND_OFFSET_SECONDS: &[FormatItem<'static>] = format_description!(
    "[year]-[month]-[day] [hour]:[minute]:[second].[subsecond digits:1+] [offset_hour sign:mandatory]:[offset_minute]:[offset_second]"
);
const DISPLAY_TS_WITH_OFFSET_SECONDS: &[FormatItem<'static>] = format_description!(
    "[year]-[month]-[day] [hour]:[minute]:[second] [offset_hour sign:mandatory]:[offset_minute]:[offset_second]"
);
const DISPLAY_TS_WITH_SUBSECOND: &[FormatItem<'static>] = format_description!(
    "[year]-[month]-[day] [hour]:[minute]:[second].[subsecond digits:1+] [offset_hour sign:mandatory]:[offset_minute]"
);
const DISPLAY_TS: &[FormatItem<'static>] = format_description!(
    "[year]-[month]-[day] [hour]:[minute]:[second] [offset_hour sign:mandatory]:[offset_minute]"
);

fn strip_control_sequences(text: &str) -> String {
    let mut result = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();

    while let Some(ch) = chars.next() {
        if ch == '\u{1b}' {
            if matches!(chars.peek(), Some('[')) {
                let _ = chars.next();
                for next in chars.by_ref() {
                    if ('@'..='~').contains(&next) {
                        break;
                    }
                }
                continue;
            }
            continue;
        }

        if ch.is_control() && ch != '\n' && ch != '\r' && ch != '\t' {
            continue;
        }

        result.push(ch);
    }

    result
}

fn classify_session_snapshot(
    output: &str,
    admin_name: &str,
    server_url: &str,
    now: OffsetDateTime,
) -> SessionSnapshot {
    let cleaned = strip_control_sequences(output);
    let trimmed = cleaned.trim();
    if trimmed.is_empty() {
        return SessionSnapshot {
            admin_name: admin_name.to_string(),
            server_url: server_url.to_string(),
            matched_principal: None,
            base_session_state: BaseSessionState::Missing,
            privileged_write_state: PrivilegedWriteState::Unavailable,
            base_expiry: ParsedExpiry::Unknown("no matching session was found".to_string()),
            privileged_expiry: ParsedExpiry::Unknown("no matching session was found".to_string()),
            diagnostic_raw: format!("No Kanidm session entries were listed for '{admin_name}'."),
            parse_confidence: ParseConfidence::High,
        };
    }

    let entries = parse_session_entries(trimmed);
    if !entries.is_empty() {
        if let Some(session) = entries
            .into_iter()
            .find(|session| session_matches_admin(&session.principal, admin_name))
        {
            return session.snapshot(admin_name, server_url, now, ParseConfidence::High);
        }

        return SessionSnapshot {
            admin_name: admin_name.to_string(),
            server_url: server_url.to_string(),
            matched_principal: None,
            base_session_state: BaseSessionState::Missing,
            privileged_write_state: PrivilegedWriteState::Unavailable,
            base_expiry: ParsedExpiry::Unknown("no matching session was found".to_string()),
            privileged_expiry: ParsedExpiry::Unknown("no matching session was found".to_string()),
            diagnostic_raw: format!(
                "No Kanidm session entry matched '{admin_name}'.\n\nObserved sessions:\n{trimmed}"
            ),
            parse_confidence: ParseConfidence::High,
        };
    }

    classify_heuristic_session_snapshot(trimmed, admin_name, server_url).unwrap_or_else(|| {
        SessionSnapshot {
            admin_name: admin_name.to_string(),
            server_url: server_url.to_string(),
            matched_principal: None,
            base_session_state: BaseSessionState::Unknown,
            privileged_write_state: PrivilegedWriteState::Unknown,
            base_expiry: ParsedExpiry::Unknown(
                "session list output could not be parsed".to_string(),
            ),
            privileged_expiry: ParsedExpiry::Unknown(
                "session list output could not be parsed".to_string(),
            ),
            diagnostic_raw: trimmed.to_string(),
            parse_confidence: ParseConfidence::Heuristic,
        }
    })
}

fn classify_heuristic_session_snapshot(
    diagnostic: &str,
    admin_name: &str,
    server_url: &str,
) -> Option<SessionSnapshot> {
    let trimmed = diagnostic.trim();
    let normalized_diagnostic = normalized(trimmed);
    if is_reauth_required(&normalized_diagnostic) {
        return Some(SessionSnapshot {
            admin_name: admin_name.to_string(),
            server_url: server_url.to_string(),
            matched_principal: session_mentions_admin(trimmed, admin_name)
                .then(|| admin_name.to_string()),
            base_session_state: BaseSessionState::Present,
            privileged_write_state: PrivilegedWriteState::ReauthRequired,
            base_expiry: ParsedExpiry::Unknown("heuristic classification".to_string()),
            privileged_expiry: ParsedExpiry::Unknown("heuristic classification".to_string()),
            diagnostic_raw: trimmed.to_string(),
            parse_confidence: ParseConfidence::Heuristic,
        });
    }
    if is_session_expired(&normalized_diagnostic) {
        return Some(SessionSnapshot {
            admin_name: admin_name.to_string(),
            server_url: server_url.to_string(),
            matched_principal: session_mentions_admin(trimmed, admin_name)
                .then(|| admin_name.to_string()),
            base_session_state: BaseSessionState::Expired,
            privileged_write_state: PrivilegedWriteState::Unavailable,
            base_expiry: ParsedExpiry::Unknown("heuristic classification".to_string()),
            privileged_expiry: ParsedExpiry::Unknown("heuristic classification".to_string()),
            diagnostic_raw: trimmed.to_string(),
            parse_confidence: ParseConfidence::Heuristic,
        });
    }
    if is_session_missing(&normalized_diagnostic) {
        return Some(SessionSnapshot {
            admin_name: admin_name.to_string(),
            server_url: server_url.to_string(),
            matched_principal: None,
            base_session_state: BaseSessionState::Missing,
            privileged_write_state: PrivilegedWriteState::Unavailable,
            base_expiry: ParsedExpiry::Unknown("heuristic classification".to_string()),
            privileged_expiry: ParsedExpiry::Unknown("heuristic classification".to_string()),
            diagnostic_raw: trimmed.to_string(),
            parse_confidence: ParseConfidence::Heuristic,
        });
    }
    session_mentions_admin(trimmed, admin_name).then(|| SessionSnapshot {
        admin_name: admin_name.to_string(),
        server_url: server_url.to_string(),
        matched_principal: Some(admin_name.to_string()),
        base_session_state: BaseSessionState::Present,
        privileged_write_state: PrivilegedWriteState::Unknown,
        base_expiry: ParsedExpiry::Unknown("heuristic classification".to_string()),
        privileged_expiry: ParsedExpiry::Unknown("heuristic classification".to_string()),
        diagnostic_raw: trimmed.to_string(),
        parse_confidence: ParseConfidence::Heuristic,
    })
}

fn parse_session_entries(output: &str) -> Vec<ParsedSession> {
    let mut entries = Vec::new();
    let mut current = Vec::new();
    let mut saw_separator = false;

    for line in output.lines() {
        if line.trim() == "---" {
            saw_separator = true;
            if let Some(session) = parse_session_block(&current) {
                entries.push(session);
            }
            current.clear();
            continue;
        }

        if !line.trim().is_empty() || !current.is_empty() {
            current.push(line.trim_end().to_string());
        }
    }

    if let Some(session) = parse_session_block(&current) {
        entries.push(session);
    }

    if saw_separator {
        entries
    } else {
        Vec::new()
    }
}

fn parse_session_block(lines: &[String]) -> Option<ParsedSession> {
    if lines.is_empty() {
        return None;
    }

    let mut principal = None;
    let mut session_expiry = None;
    let mut purpose = None;

    for line in lines {
        let (key, value) = match line.split_once(':') {
            Some((key, value)) => (normalized(key), value.trim()),
            None => continue,
        };

        match key.as_str() {
            "spn" | "account" | "name" if !value.is_empty() => {
                principal = Some(value.to_string());
            }
            "expiry" => session_expiry = Some(parse_session_expiry(value)),
            "purpose" => purpose = Some(parse_session_purpose(value)),
            _ => {}
        }
    }

    Some(ParsedSession {
        principal: principal?,
        session_expiry: session_expiry.unwrap_or_else(|| {
            ParsedExpiry::Unknown("session expiry line was not present".to_string())
        }),
        purpose: purpose.unwrap_or_else(|| {
            ParsedSessionPurpose::Unknown("session purpose line was not present".to_string())
        }),
        raw: lines.join("\n"),
    })
}

fn parse_session_expiry(value: &str) -> ParsedExpiry {
    match normalized(value).as_str() {
        "-" | "none" | "never" => ParsedExpiry::Never,
        _ => parse_session_timestamp(value)
            .map(ParsedExpiry::At)
            .unwrap_or_else(|| ParsedExpiry::Unknown(value.trim().to_string())),
    }
}

fn parse_session_purpose(value: &str) -> ParsedSessionPurpose {
    let normalized_value = normalized(value);
    if normalized_value == "read only" {
        return ParsedSessionPurpose::ReadOnly;
    }

    if normalized_value.starts_with("read write") {
        let expiry = value
            .split("(expiry:")
            .nth(1)
            .and_then(|segment| segment.strip_suffix(')'))
            .map(str::trim)
            .map(parse_session_expiry)
            .unwrap_or_else(|| {
                ParsedExpiry::Unknown(
                    "read write purpose did not include a parseable expiry".to_string(),
                )
            });
        return ParsedSessionPurpose::ReadWrite { expiry };
    }

    ParsedSessionPurpose::Unknown(value.trim().to_string())
}

fn parse_session_timestamp(value: &str) -> Option<OffsetDateTime> {
    let trimmed = value.trim();
    OffsetDateTime::parse(trimmed, &Rfc3339)
        .ok()
        .or_else(|| {
            OffsetDateTime::parse(trimmed, DISPLAY_TS_WITH_SUBSECOND_AND_OFFSET_SECONDS).ok()
        })
        .or_else(|| OffsetDateTime::parse(trimmed, DISPLAY_TS_WITH_OFFSET_SECONDS).ok())
        .or_else(|| OffsetDateTime::parse(trimmed, DISPLAY_TS_WITH_SUBSECOND).ok())
        .or_else(|| OffsetDateTime::parse(trimmed, DISPLAY_TS).ok())
}

fn session_matches_admin(principal: &str, admin_name: &str) -> bool {
    principal == admin_name
        || principal
            .split_once('@')
            .map(|(local_part, _)| local_part == admin_name)
            .unwrap_or(false)
}

fn session_mentions_admin(diagnostic: &str, admin_name: &str) -> bool {
    if admin_name.is_empty() {
        return false;
    }

    diagnostic
        .lines()
        .filter_map(|line| line.split_once(':'))
        .any(|(key, value)| {
            let normalized_key = normalized(key);
            matches!(normalized_key.as_str(), "spn" | "account" | "name")
                && session_matches_admin(value.trim(), admin_name)
        })
        || diagnostic.contains(admin_name)
}

impl ParsedSession {
    fn snapshot(
        &self,
        admin_name: &str,
        server_url: &str,
        now: OffsetDateTime,
        parse_confidence: ParseConfidence,
    ) -> SessionSnapshot {
        let privileged_expiry = self.privileged_expiry();
        let base_session_state = if self.base_session_expired(now) {
            BaseSessionState::Expired
        } else {
            BaseSessionState::Present
        };
        let privileged_write_state = match base_session_state {
            BaseSessionState::Expired => PrivilegedWriteState::Unavailable,
            BaseSessionState::Present => self.privileged_write_state(now),
            BaseSessionState::Missing | BaseSessionState::Unknown => PrivilegedWriteState::Unknown,
        };

        SessionSnapshot {
            admin_name: admin_name.to_string(),
            server_url: server_url.to_string(),
            matched_principal: Some(self.principal.clone()),
            base_session_state,
            privileged_write_state,
            base_expiry: self.session_expiry.clone(),
            privileged_expiry,
            diagnostic_raw: self.raw.clone(),
            parse_confidence,
        }
    }

    fn base_session_expired(&self, now: OffsetDateTime) -> bool {
        matches!(&self.session_expiry, ParsedExpiry::At(expiry) if now >= *expiry)
    }

    fn privileged_expiry(&self) -> ParsedExpiry {
        match &self.purpose {
            ParsedSessionPurpose::ReadOnly => ParsedExpiry::Unknown(
                "read only sessions do not expose privileged expiry".to_string(),
            ),
            ParsedSessionPurpose::ReadWrite { expiry } => expiry.clone(),
            ParsedSessionPurpose::Unknown(_) => {
                ParsedExpiry::Unknown("session purpose was not parseable".to_string())
            }
        }
    }

    fn privileged_write_state(&self, now: OffsetDateTime) -> PrivilegedWriteState {
        match &self.purpose {
            ParsedSessionPurpose::ReadOnly => PrivilegedWriteState::ReauthRequired,
            ParsedSessionPurpose::ReadWrite { expiry } => match expiry {
                ParsedExpiry::At(expiry) if now < *expiry => PrivilegedWriteState::Ready,
                ParsedExpiry::At(_) | ParsedExpiry::Never | ParsedExpiry::Unknown(_) => {
                    PrivilegedWriteState::ReauthRequired
                }
            },
            ParsedSessionPurpose::Unknown(_) => PrivilegedWriteState::Unknown,
        }
    }
}

#[cfg(test)]
fn classify_session_state(diagnostic: &str) -> SessionState {
    classify_heuristic_session_snapshot(diagnostic, "", "")
        .map(|snapshot| snapshot.to_session_state())
        .unwrap_or_else(|| SessionState::Missing {
            diagnostic: diagnostic.trim().to_string(),
        })
}

fn is_session_expired(text: &str) -> bool {
    text.contains("session has expired")
        || text.contains("expired auth token")
        || text.contains("token has expired")
        || text.contains("login again")
}

fn is_session_missing(text: &str) -> bool {
    text.contains("no valid auth tokens found")
        || text.contains("not authenticated")
        || text.contains("authentication required")
        || text.contains("no session")
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

fn is_already_exists(text: &str) -> bool {
    text.contains("already exists")
        || text.contains("duplicate")
        || text.contains("already present")
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
        let error = verify_with_retry::<(), _>(
            VerificationPolicy::ReadAfterWrite,
            "verification failed",
            json!({"ok": true}),
            true,
            || {
                Err(AppError::Json {
                    message: "bad json".to_string(),
                    details: json!({"stdout": "oops"}),
                })
            },
        )
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
    fn classifies_expired_session_diagnostics() {
        assert!(matches!(
            classify_session_state("Session has expired; login again"),
            SessionState::Expired { .. }
        ));
    }

    #[test]
    fn classifies_missing_session_diagnostics() {
        assert!(matches!(
            classify_session_state("No valid auth tokens found"),
            SessionState::Missing { .. }
        ));
    }

    #[test]
    fn classifies_reauth_required_diagnostics() {
        assert!(matches!(
            classify_session_state("Privileges have expired"),
            SessionState::ReauthRequired { .. }
        ));
    }

    #[test]
    fn session_listing_without_entries_is_missing() {
        let snapshot = classify_session_snapshot(
            "",
            "admindsaw",
            "https://id.example.test",
            OffsetDateTime::UNIX_EPOCH,
        );
        assert_eq!(snapshot.base_session_state, BaseSessionState::Missing);
        assert_eq!(
            snapshot.privileged_write_state,
            PrivilegedWriteState::Unavailable
        );
        assert_eq!(snapshot.parse_confidence, ParseConfidence::High);
    }

    #[test]
    fn session_listing_with_other_user_is_missing() {
        let listing = session_listing_block(
            "someone@example.test",
            "2030-01-01T00:00:00Z",
            "2030-01-01T00:30:00Z",
        );
        let snapshot = classify_session_snapshot(
            &listing,
            "admindsaw",
            "https://id.example.test",
            OffsetDateTime::UNIX_EPOCH,
        );
        assert_eq!(snapshot.base_session_state, BaseSessionState::Missing);
        assert_eq!(snapshot.matched_principal, None);
    }

    #[test]
    fn session_listing_selects_matching_admin_block() {
        let listing = format!(
            "{}\n{}",
            session_listing_block(
                "someone@example.test",
                "2030-01-01T00:00:00Z",
                "2030-01-01T00:30:00Z"
            ),
            session_listing_block(
                "admindsaw@example.test",
                "2030-01-02T00:00:00Z",
                "2030-01-02T00:30:00Z"
            )
        );

        let snapshot = classify_session_snapshot(
            &listing,
            "admindsaw",
            "https://id.example.test",
            OffsetDateTime::UNIX_EPOCH,
        );
        assert_eq!(
            snapshot.matched_principal.as_deref(),
            Some("admindsaw@example.test")
        );
        assert_eq!(snapshot.base_session_state, BaseSessionState::Present);
        assert_eq!(snapshot.privileged_write_state, PrivilegedWriteState::Ready);
    }

    #[test]
    fn session_listing_marks_expired_admin_session_as_expired() {
        let listing = session_listing_block(
            "admindsaw@example.test",
            "2000-01-01T00:00:00Z",
            "2000-01-01T00:30:00Z",
        );
        let snapshot = classify_session_snapshot(
            &listing,
            "admindsaw",
            "https://id.example.test",
            OffsetDateTime::parse("2030-01-01T00:00:00Z", &Rfc3339).expect("now"),
        );
        assert_eq!(snapshot.base_session_state, BaseSessionState::Expired);
        assert_eq!(
            snapshot.privileged_write_state,
            PrivilegedWriteState::Unavailable
        );
    }

    #[test]
    fn session_listing_with_no_expiry_authenticates_base_session() {
        let listing = r#"---
spn: admindsaw@example.test
uuid: 00000000-0000-0000-0000-000000000001
display: Dan
expiry: -
purpose: read write (expiry: 2030-01-01T00:30:00Z)
"#;
        let snapshot = classify_session_snapshot(
            listing,
            "admindsaw",
            "https://id.example.test",
            OffsetDateTime::UNIX_EPOCH,
        );
        assert_eq!(snapshot.base_session_state, BaseSessionState::Present);
        assert_eq!(snapshot.privileged_write_state, PrivilegedWriteState::Ready);
    }

    #[test]
    fn session_listing_with_expired_privileges_requires_reauth() {
        let listing = session_listing_block(
            "admindsaw@example.test",
            "2030-01-01T01:00:00Z",
            "2000-01-01T00:30:00Z",
        );
        let snapshot = classify_session_snapshot(
            &listing,
            "admindsaw",
            "https://id.example.test",
            OffsetDateTime::parse("2030-01-01T00:00:00Z", &Rfc3339).expect("now"),
        );
        assert_eq!(snapshot.base_session_state, BaseSessionState::Present);
        assert_eq!(
            snapshot.privileged_write_state,
            PrivilegedWriteState::ReauthRequired
        );
    }

    #[test]
    fn heuristic_snapshot_keeps_base_session_but_requires_reauth() {
        let snapshot = classify_session_snapshot(
            "active token for admindsaw",
            "admindsaw",
            "https://id.example.test",
            OffsetDateTime::UNIX_EPOCH,
        );
        assert_eq!(snapshot.base_session_state, BaseSessionState::Present);
        assert_eq!(
            snapshot.privileged_write_state,
            PrivilegedWriteState::Unknown
        );
        assert_eq!(snapshot.parse_confidence, ParseConfidence::Heuristic);
        assert!(matches!(
            snapshot.to_session_state(),
            SessionState::ReauthRequired { .. }
        ));
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

    #[test]
    fn strips_ansi_control_sequences_before_classification() {
        assert!(matches!(
            classify_session_state("\u{1b}[31mSession has expired; login again\u{1b}[0m"),
            SessionState::Expired { .. }
        ));
    }

    #[test]
    fn named_create_classifies_duplicates_as_already_exists() {
        let dir = tempfile::tempdir().expect("tempdir");
        let script = dir.path().join("kanidm-stub.sh");
        write_script(
            &script,
            r#"#!/usr/bin/env bash
printf '\033[31muser already exists\033[0m\n' >&2
exit 1
"#,
        );
        let cli = KanidmCli::new(&ResolvedContext {
            repo_root: None,
            server_url: "https://id.example.test".to_string(),
            admin_name: "admindsaw".to_string(),
            kanidm_bin: script.into_os_string(),
        });

        let error = cli
            .person_create("dsaw", "Dan")
            .expect_err("already exists");
        assert!(matches!(error, AppError::AlreadyExists { .. }));
    }

    fn session_listing_block(spn: &str, expiry: &str, privileged_expiry: &str) -> String {
        format!(
            r#"---
spn: {spn}
uuid: 00000000-0000-0000-0000-000000000001
display: Dan
expiry: {expiry}
purpose: read write (expiry: {privileged_expiry})
"#
        )
    }
}
