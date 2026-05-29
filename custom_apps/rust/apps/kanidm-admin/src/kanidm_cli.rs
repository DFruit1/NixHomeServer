use std::{
    ffi::{OsStr, OsString},
    path::Path,
    sync::{Arc, Mutex},
    time::Duration,
};

use serde::de::DeserializeOwned;
use serde_json::{json, Value};
use time::OffsetDateTime;

use crate::{
    backend::{CommandMode, KanidmBackend, ProcessKanidmBackend, RawCommandRequest},
    context::ResolvedContext,
    session_state::{
        classification_diagnostic, concise_session_diagnostic, concise_session_message,
        is_already_exists, is_not_found, preferred_diagnostic, SessionDiagnostic,
        SessionInterpreter,
    },
    AppError,
};

const COMMAND_TIMEOUT: Duration = Duration::from_secs(20);

pub use crate::session_state::{
    BaseSessionState, ParseConfidence, ParsedExpiry, ParsedSession, ParsedSessionPurpose,
    PrivilegedWriteState, SessionFailureKind, SessionObservation, SessionSnapshot, SessionState,
};
pub use crate::{
    backend::{BackendFailure, ExitStatusSummary},
    verification::{verify_with_retry, VerificationCheck, VerificationPolicy},
};

#[derive(Clone)]
pub struct KanidmCli {
    program: OsString,
    server_url: String,
    admin_name: String,
    backend: Arc<dyn KanidmBackend>,
    backend_steps: Arc<Mutex<Vec<Value>>>,
}

impl std::fmt::Debug for KanidmCli {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("KanidmCli")
            .field("program", &self.program)
            .field("server_url", &self.server_url)
            .field("admin_name", &self.admin_name)
            .finish()
    }
}

impl KanidmCli {
    pub fn new(context: &ResolvedContext) -> Self {
        Self {
            program: context.kanidm_bin.clone(),
            server_url: context.server_url.clone(),
            admin_name: context.admin_name.clone(),
            backend: Arc::new(ProcessKanidmBackend::new(context.kanidm_bin.clone())),
            backend_steps: Arc::new(Mutex::new(Vec::new())),
        }
    }

    #[cfg(test)]
    #[allow(dead_code)]
    pub(crate) fn with_backend(
        program: OsString,
        server_url: String,
        admin_name: String,
        backend: Arc<dyn KanidmBackend>,
    ) -> Self {
        Self {
            program,
            server_url,
            admin_name,
            backend,
            backend_steps: Arc::new(Mutex::new(Vec::new())),
        }
    }

    pub fn server_url(&self) -> &str {
        &self.server_url
    }

    pub fn admin_name(&self) -> &str {
        &self.admin_name
    }

    pub fn take_backend_steps(&self) -> Vec<Value> {
        self.backend_steps
            .lock()
            .map(|mut steps| std::mem::take(&mut *steps))
            .unwrap_or_default()
    }

    pub fn session_status(&self) -> Result<SessionState, AppError> {
        Ok(self.session_snapshot()?.to_session_state())
    }

    pub fn session_snapshot(&self) -> Result<SessionSnapshot, AppError> {
        let context = "failed to inspect the current Kanidm session";
        let args = self.base_args(["session", "list"]);
        match self.run_raw(args, context)? {
            Ok(output) => Ok(SessionInterpreter::from_session_list(
                output.stdout.trim(),
                &self.admin_name,
                &self.server_url,
                OffsetDateTime::now_utc(),
            )),
            Err(failure) => match SessionInterpreter::from_backend_failure(
                &failure,
                &self.admin_name,
                &self.server_url,
            ) {
                SessionObservation::Snapshot(snapshot) => Ok(snapshot),
                SessionObservation::Failure(kind, diagnostic) => {
                    snapshot_from_failure(kind, diagnostic, &self.admin_name, &self.server_url)
                }
            },
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

    pub fn person_posix_set_password(
        &self,
        account_id: &str,
        password: &str,
    ) -> Result<BackendSuccess, AppError> {
        self.run_success_with_stdin(
            self.base_args(["person", "posix", "set-password", account_id]),
            format!("{password}\n{password}\n"),
            &format!("failed to set POSIX password for Kanidm user '{account_id}'"),
        )
    }

    pub fn unix_cache_invalidate(&self) -> Result<BackendSuccess, AppError> {
        self.run_kanidm_unix_success(
            vec!["cache-invalidate".to_string()],
            "failed to invalidate Kanidm UnixD cache",
        )
    }

    pub fn unix_status(&self) -> Result<BackendSuccess, AppError> {
        self.run_kanidm_unix_success(
            vec!["status".to_string()],
            "failed to inspect Kanidm UnixD status",
        )
    }

    pub fn unix_auth_test(&self, account_id: &str) -> Result<BackendSuccess, AppError> {
        self.run_kanidm_unix_inherited(vec![
            "auth-test".to_string(),
            "--name".to_string(),
            account_id.to_string(),
        ])
    }

    fn run_kanidm_unix_success(
        &self,
        args: Vec<String>,
        context: &str,
    ) -> Result<BackendSuccess, AppError> {
        let program = self.kanidm_unix_program();
        let backend = ProcessKanidmBackend::new(program.clone());
        let output = backend
            .exec(RawCommandRequest {
                args: args.clone(),
                mode: CommandMode::NonInteractiveWrite,
                timeout: COMMAND_TIMEOUT,
                stdin: None,
            })
            .map_err(|error| error.into_app_error())?;

        if output.status.success {
            let success = BackendSuccess::from_raw(&program, args, output);
            self.record_backend_success("kanidm-unix", &success);
            Ok(success)
        } else {
            Err(AppError::Backend {
                message: context.to_string(),
                failure: Box::new(BackendFailure::from_raw(&program, args, output)),
            })
        }
    }

    fn run_kanidm_unix_inherited(&self, args: Vec<String>) -> Result<BackendSuccess, AppError> {
        let program = self.kanidm_unix_program();
        let backend = ProcessKanidmBackend::new(program.clone());
        let result = backend
            .exec(RawCommandRequest {
                args: args.clone(),
                mode: CommandMode::InteractiveAuth,
                timeout: COMMAND_TIMEOUT,
                stdin: None,
            })
            .map_err(|error| error.into_app_error())?;
        if result.status.success {
            let success = BackendSuccess::from_raw(&program, args, result);
            self.record_backend_success("kanidm-unix", &success);
            Ok(success)
        } else {
            Err(AppError::Backend {
                message: format!(
                    "{} exited unsuccessfully; inspect the terminal output above",
                    program.to_string_lossy()
                ),
                failure: Box::new(BackendFailure::from_raw(&program, args, result)),
            })
        }
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
        self.run_inherited(self.base_args(["login"]))
    }

    pub fn reauth(&self) -> Result<(), AppError> {
        self.run_inherited(self.base_args(["reauth"]))
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
        match serde_json::from_str(&output.stdout) {
            Ok(value) => Ok(value),
            Err(error) => {
                let normalized_stdout = output.stdout.trim().to_lowercase();
                if is_not_found(&normalized_stdout) {
                    return Err(AppError::NotFound {
                        message: format!("{resource} '{name}' was not found"),
                        resource: resource.to_string(),
                        name: name.to_string(),
                        details: json!({
                            "diagnostic": output.stdout.trim(),
                            "stdout": output.stdout,
                        }),
                    });
                }
                Err(AppError::Json {
                    message: format!("{context}: invalid JSON from kanidm backend"),
                    details: json!({
                        "error": error.to_string(),
                        "stdout": output.stdout,
                    }),
                })
            }
        }
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

    fn run_inherited(&self, args: Vec<String>) -> Result<(), AppError> {
        let result = self
            .backend
            .exec(RawCommandRequest {
                args: args.clone(),
                mode: CommandMode::InteractiveAuth,
                timeout: COMMAND_TIMEOUT,
                stdin: None,
            })
            .map_err(|error| error.into_app_error())?;
        if result.status.success {
            Ok(())
        } else {
            Err(AppError::Backend {
                message: format!(
                    "{} exited unsuccessfully; inspect the terminal output above",
                    self.program.to_string_lossy()
                ),
                failure: Box::new(BackendFailure::from_raw(&self.program, args, result)),
            })
        }
    }

    fn run_success(&self, args: Vec<String>, context: &str) -> Result<BackendSuccess, AppError> {
        match self.run_raw(args, context)? {
            Ok(output) => Ok(output),
            Err(failure) => Err(self.classify_failure(context, failure)),
        }
    }

    fn run_success_with_stdin(
        &self,
        args: Vec<String>,
        stdin: String,
        context: &str,
    ) -> Result<BackendSuccess, AppError> {
        let output = self
            .backend
            .exec(RawCommandRequest {
                args: args.clone(),
                mode: CommandMode::NonInteractiveWrite,
                timeout: COMMAND_TIMEOUT,
                stdin: Some(stdin),
            })
            .map_err(|error| error.into_app_error())?;

        if output.status.success {
            let success = BackendSuccess::from_raw(&self.program, args, output);
            self.record_backend_success("kanidm", &success);
            Ok(success)
        } else {
            Err(self.classify_failure(
                context,
                BackendFailure::from_raw(&self.program, args, output),
            ))
        }
    }

    fn run_raw(
        &self,
        args: Vec<String>,
        _context: &str,
    ) -> Result<Result<BackendSuccess, BackendFailure>, AppError> {
        let mode = command_mode_for_args(&args);
        let output = self
            .backend
            .exec(RawCommandRequest {
                args: args.clone(),
                mode,
                timeout: COMMAND_TIMEOUT,
                stdin: None,
            })
            .map_err(|error| error.into_app_error())?;

        if output.status.success {
            let success = BackendSuccess::from_raw(&self.program, args, output);
            if mode == CommandMode::NonInteractiveWrite {
                self.record_backend_success("kanidm", &success);
            }
            Ok(Ok(success))
        } else {
            Ok(Err(BackendFailure::from_raw(&self.program, args, output)))
        }
    }

    fn classify_failure(&self, context: &str, failure: BackendFailure) -> AppError {
        match SessionInterpreter::from_backend_failure(&failure, &self.admin_name, &self.server_url)
        {
            SessionObservation::Failure(kind @ (SessionFailureKind::Missing | SessionFailureKind::Expired), diagnostic) => {
                let base_session_state = match kind {
                    SessionFailureKind::Missing => BaseSessionState::Missing,
                    SessionFailureKind::Expired => BaseSessionState::Expired,
                    SessionFailureKind::ReauthRequired
                    | SessionFailureKind::Unknown
                    | SessionFailureKind::BackendUnavailable => unreachable!(),
                };
                let snapshot = session_snapshot_for_common_failure(
                    base_session_state,
                    &self.admin_name,
                    &self.server_url,
                    diagnostic.primary.clone(),
                );
                AppError::SessionRequired {
                    message: concise_session_message(&self.admin_name, &snapshot).unwrap_or_else(|| {
                        format!("{context}. Run `kanidm-admin session login` first.")
                    }),
                    details: session_or_reauth_details(&failure, diagnostic),
                }
            }
            SessionObservation::Failure(SessionFailureKind::ReauthRequired, diagnostic) => {
                let snapshot = session_snapshot_for_common_failure(
                    BaseSessionState::Present,
                    &self.admin_name,
                    &self.server_url,
                    diagnostic.primary.clone(),
                );
                AppError::ReauthRequired {
                    message: concise_session_message(&self.admin_name, &snapshot).unwrap_or_else(|| {
                        format!(
                            "{context}. Run `kanidm-admin session reauth` first. The base session may still appear active, but privileged write access has expired."
                        )
                    }),
                    details: session_or_reauth_details(&failure, diagnostic),
                }
            }
            SessionObservation::Failure(SessionFailureKind::Unknown | SessionFailureKind::BackendUnavailable, _) => {
                AppError::Backend {
                    message: context.to_string(),
                    failure: Box::new(failure),
                }
            }
            SessionObservation::Snapshot(snapshot) => AppError::Backend {
                message: format!(
                    "{context}: backend returned an unexpected failure while session state looked like '{}'",
                    snapshot.diagnostic_raw.trim()
                ),
                failure: Box::new(failure),
            },
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
        let normalized_diagnostic = classification_diagnostic(&failure).trim().to_lowercase();
        if is_not_found(&normalized_diagnostic) {
            return AppError::NotFound {
                message: format!("{resource} '{name}' was not found"),
                resource: resource.to_string(),
                name: name.to_string(),
                details: json!({
                    "diagnostic": diagnostic,
                    "backend": failure.payload(),
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
        let normalized_diagnostic = classification_diagnostic(&failure).trim().to_lowercase();
        if is_already_exists(&normalized_diagnostic) {
            return AppError::AlreadyExists {
                message: format!("{resource} '{name}' already exists"),
                resource: resource.to_string(),
                name: name.to_string(),
                details: json!({
                    "resource": resource,
                    "name": name,
                    "backend": failure.payload(),
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

    fn kanidm_unix_program(&self) -> OsString {
        let path = Path::new(&self.program);
        if path.file_name() == Some(OsStr::new("kanidm")) {
            if let Some(parent) = path.parent() {
                return parent.join("kanidm-unix").into_os_string();
            }
        }
        OsString::from("kanidm-unix")
    }

    fn record_backend_success(&self, step: &str, success: &BackendSuccess) {
        if let Ok(mut steps) = self.backend_steps.lock() {
            steps.push(success.payload(step));
        }
    }
}

fn session_snapshot_for_common_failure(
    base_session_state: BaseSessionState,
    admin_name: &str,
    server_url: &str,
    diagnostic: String,
) -> SessionSnapshot {
    let privileged_write_state = match base_session_state {
        BaseSessionState::Present => PrivilegedWriteState::ReauthRequired,
        BaseSessionState::Expired | BaseSessionState::Missing | BaseSessionState::Unknown => {
            PrivilegedWriteState::Unavailable
        }
    };

    SessionSnapshot {
        admin_name: admin_name.to_string(),
        server_url: server_url.to_string(),
        matched_principal: None,
        base_session_state,
        privileged_write_state,
        base_expiry: ParsedExpiry::Unknown("heuristic classification".to_string()),
        privileged_expiry: ParsedExpiry::Unknown("heuristic classification".to_string()),
        diagnostic_raw: diagnostic,
        parse_confidence: ParseConfidence::Heuristic,
    }
}

#[derive(Debug, Clone)]
pub struct BackendSuccess {
    pub program: String,
    pub args: Vec<String>,
    pub status: ExitStatusSummary,
    pub stdout: String,
    pub stderr: String,
}

impl BackendSuccess {
    fn from_raw(
        program: &OsString,
        args: Vec<String>,
        result: crate::backend::RawCommandResult,
    ) -> Self {
        Self {
            program: program.to_string_lossy().to_string(),
            args,
            status: result.status,
            stdout: result.stdout,
            stderr: result.stderr,
        }
    }

    pub fn payload(&self, step: &str) -> Value {
        json!({
            "step": step,
            "program": self.program,
            "args": self.args,
            "status": self.status,
            "stdout": self.stdout,
            "stderr": self.stderr,
        })
    }
}

fn command_mode_for_args(args: &[String]) -> CommandMode {
    let first = args.first().map(String::as_str);
    let second = args.get(1).map(String::as_str);
    let third = args.get(2).map(String::as_str);

    match (first, second, third) {
        (Some("session"), Some("list"), _) => CommandMode::NonInteractiveRead,
        (Some("person"), Some("list" | "get"), _) => CommandMode::NonInteractiveRead,
        (Some("group"), Some("list" | "get" | "list-members"), _) => {
            CommandMode::NonInteractiveRead
        }
        (Some("system"), Some("oauth2"), Some("list" | "get")) => CommandMode::NonInteractiveRead,
        _ => CommandMode::NonInteractiveWrite,
    }
}

fn snapshot_from_failure(
    kind: SessionFailureKind,
    diagnostic: SessionDiagnostic,
    admin_name: &str,
    server_url: &str,
) -> Result<SessionSnapshot, AppError> {
    let (base_session_state, privileged_write_state) = match kind {
        SessionFailureKind::Missing => {
            (BaseSessionState::Missing, PrivilegedWriteState::Unavailable)
        }
        SessionFailureKind::Expired => {
            (BaseSessionState::Expired, PrivilegedWriteState::Unavailable)
        }
        SessionFailureKind::ReauthRequired => (
            BaseSessionState::Present,
            PrivilegedWriteState::ReauthRequired,
        ),
        SessionFailureKind::Unknown | SessionFailureKind::BackendUnavailable => {
            return Err(AppError::Io {
                message: diagnostic.primary,
            })
        }
    };

    Ok(SessionSnapshot {
        admin_name: admin_name.to_string(),
        server_url: server_url.to_string(),
        matched_principal: None,
        base_session_state,
        privileged_write_state,
        base_expiry: ParsedExpiry::Unknown("heuristic classification".to_string()),
        privileged_expiry: ParsedExpiry::Unknown("heuristic classification".to_string()),
        diagnostic_raw: diagnostic.primary,
        parse_confidence: ParseConfidence::Heuristic,
    })
}

fn session_or_reauth_details(failure: &BackendFailure, diagnostic: SessionDiagnostic) -> Value {
    json!({
        "diagnostic": diagnostic.primary,
        "raw_diagnostic": diagnostic.raw,
        "sanitized_diagnostic": concise_session_diagnostic(failure),
        "backend": failure.payload(),
    })
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
            vaultwarden_url: None,
            vaultwarden_admin_token_file: None,
        });

        let error = cli.person_get::<Value>("dsaw").expect_err("not found");
        assert!(matches!(error, AppError::NotFound { .. }));
    }

    #[test]
    fn named_json_normalizes_successful_plaintext_not_found_diagnostics() {
        let dir = tempfile::tempdir().expect("tempdir");
        let script = dir.path().join("kanidm-stub.sh");
        write_script(
            &script,
            r#"#!/usr/bin/env bash
printf 'No matching entries\n'
exit 0
"#,
        );
        let cli = KanidmCli::new(&ResolvedContext {
            repo_root: None,
            server_url: "https://id.example.test".to_string(),
            admin_name: "admindsaw".to_string(),
            kanidm_bin: script.into_os_string(),
            vaultwarden_url: None,
            vaultwarden_admin_token_file: None,
        });

        let error = cli.person_get::<Value>("dsaw").expect_err("not found");
        assert!(matches!(error, AppError::NotFound { .. }));
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
            vaultwarden_url: None,
            vaultwarden_admin_token_file: None,
        });

        let error = cli
            .person_create("dsaw", "Dan")
            .expect_err("already exists");
        assert!(matches!(error, AppError::AlreadyExists { .. }));
    }
}
