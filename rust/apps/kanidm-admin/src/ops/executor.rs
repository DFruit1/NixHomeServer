use serde_json::json;

use crate::{
    kanidm_cli::KanidmCli,
    output::CommandOutput,
    session_state::{BaseSessionState, PrivilegedWriteState, SessionSnapshot},
    verification::{verify_with_retry, VerificationCheck, VerificationPolicy},
    AppError,
};

const MAX_RECOVERY_CYCLES: usize = 2;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OperationKind {
    Read,
    Write,
    PrivilegedWrite,
    InteractiveSessionRecovery,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OperationPreconditions {
    None,
    BaseSessionPresent,
    PrivilegedWriteReady,
}

#[derive(Debug)]
pub enum OperationOutcome<T> {
    Success(T),
    Cancelled,
    RecoverableFailure(AppError),
    Fatal(AppError),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecoveryTarget {
    BaseSession,
    PrivilegedWrites,
}

#[derive(Debug, Clone)]
struct RecoveryRequirement {
    target: RecoveryTarget,
    snapshot: SessionSnapshot,
}

#[derive(Debug, Clone)]
pub struct RecoveryVerification {
    pub snapshot: SessionSnapshot,
    pub state: &'static str,
    pub privileged_write_access: &'static str,
    pub warnings: Vec<String>,
}

pub fn verify_session_recovery<F>(
    cli: &KanidmCli,
    expectation: RecoveryTarget,
    execute: F,
) -> Result<RecoveryVerification, AppError>
where
    F: FnOnce() -> Result<(), AppError>,
{
    execute()?;

    let (context, expected) = match expectation {
        RecoveryTarget::BaseSession => (
            format!(
                "kanidm login exited successfully but no active base session was detected for '{}'",
                cli.admin_name()
            ),
            json!({
                "base_session_present": true,
                "admin_name": cli.admin_name(),
                "server_url": cli.server_url(),
            }),
        ),
        RecoveryTarget::PrivilegedWrites => (
            format!(
                "kanidm reauth exited successfully but privileged write access was not confirmed for '{}'",
                cli.admin_name()
            ),
            json!({
                "base_session_present": true,
                "privileged_write_access": "ready",
                "admin_name": cli.admin_name(),
                "server_url": cli.server_url(),
            }),
        ),
    };

    verify_with_retry(
        VerificationPolicy::SessionRecovery,
        &context,
        expected,
        true,
        || {
            let snapshot = cli.session_snapshot()?;
            match expectation {
                RecoveryTarget::BaseSession if snapshot.base_session_present() => {
                    let (state, privileged_write_access, warnings) = if snapshot
                        .privileged_write_ready()
                    {
                        ("authenticated", "ready", Vec::new())
                    } else {
                        (
                                "reauth_required",
                                "reauth_required",
                                vec![
                                    "Privileged write access still requires `kanidm-admin session reauth`."
                                        .to_string(),
                                ],
                            )
                    };
                    Ok(VerificationCheck::Matched {
                        observed: session_recovery_observed(&snapshot),
                        value: RecoveryVerification {
                            snapshot,
                            state,
                            privileged_write_access,
                            warnings,
                        },
                    })
                }
                RecoveryTarget::PrivilegedWrites
                    if snapshot.base_session_present() && snapshot.privileged_write_ready() =>
                {
                    Ok(VerificationCheck::Matched {
                        observed: session_recovery_observed(&snapshot),
                        value: RecoveryVerification {
                            snapshot,
                            state: "authenticated",
                            privileged_write_access: "ready",
                            warnings: Vec::new(),
                        },
                    })
                }
                _ => Ok(VerificationCheck::Mismatch {
                    observed: session_recovery_observed(&snapshot),
                }),
            }
        },
    )
}

pub fn execute_interactive_operation<T, A, R>(
    cli: &KanidmCli,
    _kind: OperationKind,
    preconditions: OperationPreconditions,
    mut action: A,
    mut recover: R,
) -> Result<OperationOutcome<T>, AppError>
where
    A: FnMut() -> Result<T, AppError>,
    R: FnMut(RecoveryTarget, Option<&AppError>, Option<&SessionSnapshot>) -> Result<bool, AppError>,
{
    let mut recovery_cycles = 0usize;
    let mut skip_next_precheck = false;

    loop {
        if !std::mem::take(&mut skip_next_precheck) {
            if let Some(requirement) = check_preconditions_with_snapshot(cli, preconditions)? {
                if recovery_cycles >= MAX_RECOVERY_CYCLES {
                    return Ok(OperationOutcome::RecoverableFailure(
                        repeated_recovery_error(requirement.target),
                    ));
                }
                if !recover(requirement.target, None, Some(&requirement.snapshot))? {
                    return Ok(OperationOutcome::Cancelled);
                }
                recovery_cycles += 1;
                skip_next_precheck = true;
                continue;
            }
        }

        match action() {
            Ok(value) => return Ok(OperationOutcome::Success(value)),
            Err(error) => {
                let Some(target) = recovery_target_from_error(&error) else {
                    return Ok(OperationOutcome::RecoverableFailure(error));
                };
                if recovery_cycles >= MAX_RECOVERY_CYCLES {
                    return Ok(OperationOutcome::RecoverableFailure(
                        repeated_recovery_error(target),
                    ));
                }
                if !recover(target, Some(&error), None)? {
                    return Ok(OperationOutcome::Cancelled);
                }
                recovery_cycles += 1;
                skip_next_precheck = true;
                continue;
            }
        }
    }
}

pub fn check_preconditions(
    cli: &KanidmCli,
    preconditions: OperationPreconditions,
) -> Result<Option<RecoveryTarget>, AppError> {
    Ok(
        check_preconditions_with_snapshot(cli, preconditions)?
            .map(|requirement| requirement.target),
    )
}

fn check_preconditions_with_snapshot(
    cli: &KanidmCli,
    preconditions: OperationPreconditions,
) -> Result<Option<RecoveryRequirement>, AppError> {
    let snapshot = cli.session_snapshot()?;
    Ok(recovery_target_for_snapshot(&snapshot, preconditions)
        .map(|target| RecoveryRequirement { target, snapshot }))
}

pub fn recovery_target_for_snapshot(
    snapshot: &SessionSnapshot,
    preconditions: OperationPreconditions,
) -> Option<RecoveryTarget> {
    match preconditions {
        OperationPreconditions::None => None,
        OperationPreconditions::BaseSessionPresent => match snapshot.base_session_state {
            BaseSessionState::Present => None,
            BaseSessionState::Expired | BaseSessionState::Missing | BaseSessionState::Unknown => {
                Some(RecoveryTarget::BaseSession)
            }
        },
        OperationPreconditions::PrivilegedWriteReady => {
            match (snapshot.base_session_state, snapshot.privileged_write_state) {
                (BaseSessionState::Present, PrivilegedWriteState::Ready) => None,
                (BaseSessionState::Present, _) => Some(RecoveryTarget::PrivilegedWrites),
                (
                    BaseSessionState::Expired
                    | BaseSessionState::Missing
                    | BaseSessionState::Unknown,
                    _,
                ) => Some(RecoveryTarget::BaseSession),
            }
        }
    }
}

pub fn recovery_target_from_error(error: &AppError) -> Option<RecoveryTarget> {
    match error {
        AppError::SessionRequired { .. } => Some(RecoveryTarget::BaseSession),
        AppError::ReauthRequired { .. } => Some(RecoveryTarget::PrivilegedWrites),
        _ => None,
    }
}

fn repeated_recovery_error(target: RecoveryTarget) -> AppError {
    AppError::Verification {
        message: "session recovery did not stabilize after multiple attempts".to_string(),
        details: json!({
            "max_recovery_attempts": MAX_RECOVERY_CYCLES,
            "target": match target {
                RecoveryTarget::BaseSession => "base_session",
                RecoveryTarget::PrivilegedWrites => "privileged_writes",
            },
        }),
    }
}

fn session_recovery_observed(snapshot: &SessionSnapshot) -> serde_json::Value {
    json!({
        "base_session_present": snapshot.base_session_present(),
        "state": match (snapshot.base_session_state, snapshot.privileged_write_state) {
            (BaseSessionState::Present, PrivilegedWriteState::Ready) => "authenticated",
            (BaseSessionState::Present, _) => "reauth_required",
            (BaseSessionState::Expired, _) => "expired",
            (BaseSessionState::Missing | BaseSessionState::Unknown, _) => "missing",
        },
        "privileged_write_access": match snapshot.privileged_write_state {
            PrivilegedWriteState::Ready => "ready",
            PrivilegedWriteState::ReauthRequired => "reauth_required",
            PrivilegedWriteState::Unavailable => "unavailable",
            PrivilegedWriteState::Unknown => "unknown",
        },
        "diagnostic": snapshot.diagnostic_raw.trim(),
    })
}

pub fn recovery_command_output(
    cli: &KanidmCli,
    title: &str,
    verification: RecoveryVerification,
) -> CommandOutput {
    let human = match verification.state {
        "authenticated" => format!(
            "{title} succeeded for '{}'.\n\n{}",
            cli.admin_name(),
            verification.snapshot.diagnostic_raw.trim()
        ),
        "reauth_required" if title == "Login" => format!(
            "Base login successful for '{}'.\nSome actions require reauthentication for added security. If needed, you will be prompted to log in again automatically before those actions continue.\n\n{}",
            cli.admin_name(),
            verification.snapshot.diagnostic_raw.trim()
        ),
        "reauth_required" => format!(
            "{title} succeeded for '{}'. The base session is active, but privileged write access still requires `kanidm-admin session reauth`.\n\n{}",
            cli.admin_name(),
            verification.snapshot.diagnostic_raw.trim()
        ),
        _ => format!(
            "{title} completed for '{}'.\n\n{}",
            cli.admin_name(),
            verification.snapshot.diagnostic_raw.trim()
        ),
    };

    CommandOutput {
        message: match title {
            "Login" => "authenticated with Kanidm".to_string(),
            "Reauthenticate" => "Kanidm privileged reauthentication succeeded".to_string(),
            _ => format!("{title} succeeded"),
        },
        human,
        details: json!({
            "authenticated": verification.snapshot.base_session_present(),
            "base_session_present": verification.snapshot.base_session_present(),
            "state": verification.state,
            "privileged_write_access": verification.privileged_write_access,
        }),
        warnings: verification.warnings,
    }
}

#[cfg(test)]
mod tests {
    use std::{
        ffi::OsString,
        sync::{
            atomic::{AtomicUsize, Ordering},
            Arc,
        },
    };

    use super::*;
    use crate::{
        backend::{
            BackendExecError, ExitStatusSummary, KanidmBackend, ProcessKanidmBackend,
            RawCommandRequest, RawCommandResult,
        },
        kanidm_cli::{KanidmCli, ParseConfidence, ParsedExpiry},
    };

    fn snapshot(
        base_session_state: BaseSessionState,
        privileged_write_state: PrivilegedWriteState,
    ) -> SessionSnapshot {
        SessionSnapshot {
            admin_name: "admindsaw".to_string(),
            server_url: "https://id.example.test".to_string(),
            matched_principal: Some("admindsaw@example.test".to_string()),
            base_session_state,
            privileged_write_state,
            base_expiry: ParsedExpiry::Never,
            privileged_expiry: ParsedExpiry::Unknown("unknown".to_string()),
            diagnostic_raw: "diagnostic".to_string(),
            parse_confidence: ParseConfidence::High,
        }
    }

    fn test_cli() -> KanidmCli {
        KanidmCli::with_backend(
            OsString::from("kanidm"),
            "https://id.example.test".to_string(),
            "admindsaw".to_string(),
            Arc::new(ProcessKanidmBackend::new(OsString::from("kanidm"))),
        )
    }

    #[derive(Debug)]
    struct SessionListOnlyBackend {
        session_lists: Arc<AtomicUsize>,
    }

    impl KanidmBackend for SessionListOnlyBackend {
        fn exec(&self, request: RawCommandRequest) -> Result<RawCommandResult, BackendExecError> {
            if request.args.first().map(String::as_str) == Some("session")
                && request.args.get(1).map(String::as_str) == Some("list")
            {
                self.session_lists.fetch_add(1, Ordering::SeqCst);
                return Ok(RawCommandResult {
                    status: ExitStatusSummary {
                        success: true,
                        code: Some(0),
                    },
                    stdout: r#"---
spn: admindsaw@example.test
uuid: 00000000-0000-0000-0000-000000000001
display: Dan
expiry: 2030-01-01T01:00:00Z
purpose: read write (expiry: 2000-01-01T00:30:00Z)
"#
                    .to_string(),
                    stderr: String::new(),
                });
            }

            panic!("unexpected backend request: {:?}", request.args);
        }
    }

    #[test]
    fn privileged_preconditions_require_login_when_base_session_missing() {
        assert_eq!(
            recovery_target_for_snapshot(
                &snapshot(BaseSessionState::Missing, PrivilegedWriteState::Unavailable),
                OperationPreconditions::PrivilegedWriteReady,
            ),
            Some(RecoveryTarget::BaseSession)
        );
    }

    #[test]
    fn privileged_preconditions_require_reauth_when_base_session_is_active() {
        assert_eq!(
            recovery_target_for_snapshot(
                &snapshot(
                    BaseSessionState::Present,
                    PrivilegedWriteState::ReauthRequired
                ),
                OperationPreconditions::PrivilegedWriteReady,
            ),
            Some(RecoveryTarget::PrivilegedWrites)
        );
    }

    #[test]
    fn precondition_recovery_reuses_snapshot_and_runs_action_without_immediate_reprobe() {
        let session_lists = Arc::new(AtomicUsize::new(0));
        let cli = KanidmCli::with_backend(
            OsString::from("kanidm"),
            "https://id.example.test".to_string(),
            "admindsaw".to_string(),
            Arc::new(SessionListOnlyBackend {
                session_lists: Arc::clone(&session_lists),
            }),
        );
        let mut action_count = 0usize;
        let mut recovered_with_snapshot = false;

        let outcome = execute_interactive_operation(
            &cli,
            OperationKind::PrivilegedWrite,
            OperationPreconditions::PrivilegedWriteReady,
            || {
                action_count += 1;
                Ok("applied")
            },
            |target, error, snapshot| {
                assert_eq!(target, RecoveryTarget::PrivilegedWrites);
                assert!(error.is_none());
                let snapshot = snapshot.expect("precondition snapshot is reused");
                assert_eq!(snapshot.base_session_state, BaseSessionState::Present);
                assert_eq!(
                    snapshot.privileged_write_state,
                    PrivilegedWriteState::ReauthRequired
                );
                recovered_with_snapshot = true;
                Ok(true)
            },
        )
        .expect("operation executes");

        assert!(matches!(outcome, OperationOutcome::Success("applied")));
        assert!(recovered_with_snapshot);
        assert_eq!(action_count, 1);
        assert_eq!(session_lists.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn session_errors_map_to_recovery_targets() {
        assert_eq!(
            recovery_target_from_error(&AppError::SessionRequired {
                message: "login".to_string(),
                details: json!({}),
            }),
            Some(RecoveryTarget::BaseSession)
        );
        assert_eq!(
            recovery_target_from_error(&AppError::ReauthRequired {
                message: "reauth".to_string(),
                details: json!({}),
            }),
            Some(RecoveryTarget::PrivilegedWrites)
        );
    }

    #[test]
    fn login_recovery_output_explains_future_reauthentication() {
        let output = recovery_command_output(
            &test_cli(),
            "Login",
            RecoveryVerification {
                snapshot: snapshot(
                    BaseSessionState::Present,
                    PrivilegedWriteState::ReauthRequired,
                ),
                state: "reauth_required",
                privileged_write_access: "reauth_required",
                warnings: vec![
                    "Privileged write access still requires `kanidm-admin session reauth`."
                        .to_string(),
                ],
            },
        );

        assert!(output
            .human
            .contains("Base login successful for 'admindsaw'."));
        assert!(output
            .human
            .contains("Some actions require reauthentication for added security."));
        assert!(output
            .human
            .contains("you will be prompted to log in again automatically"));
        assert_eq!(output.details["state"], "reauth_required");
    }
}
