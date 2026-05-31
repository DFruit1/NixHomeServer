use std::{
    ffi::OsString,
    io::Write,
    process::{Command, Stdio},
    thread::sleep,
    time::{Duration, Instant},
};

use serde::Serialize;
use serde_json::json;
use zeroize::Zeroize;

use crate::AppError;

const COMMAND_POLL_INTERVAL: Duration = Duration::from_millis(50);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CommandMode {
    InteractiveAuth,
    NonInteractiveRead,
    NonInteractiveWrite,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RawCommandRequest {
    pub args: Vec<String>,
    pub mode: CommandMode,
    pub timeout: Duration,
    pub stdin: Option<String>,
}

impl Drop for RawCommandRequest {
    fn drop(&mut self) {
        if let Some(stdin) = &mut self.stdin {
            stdin.zeroize();
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct ExitStatusSummary {
    pub success: bool,
    pub code: Option<i32>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RawCommandResult {
    pub status: ExitStatusSummary,
    pub stdout: String,
    pub stderr: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum BackendCrashKind {
    InteractivePanic,
    Timeout,
    SpawnIo,
    UnexpectedFailure,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct BackendFailure {
    pub program: String,
    pub args: Vec<String>,
    pub status: Option<i32>,
    pub stdout: String,
    pub stderr: String,
    pub crash_kind: Option<BackendCrashKind>,
}

impl BackendFailure {
    pub fn from_raw(program: &OsString, args: Vec<String>, result: RawCommandResult) -> Self {
        let crash_kind = classify_crash_kind(&result.stdout, &result.stderr, result.status.success);
        Self {
            program: program.to_string_lossy().to_string(),
            args,
            status: result.status.code,
            stdout: result.stdout,
            stderr: result.stderr,
            crash_kind,
        }
    }

    pub fn payload(&self) -> serde_json::Value {
        json!({
            "program": self.program,
            "args": self.args,
            "status": self.status,
            "stdout": self.stdout,
            "stderr": self.stderr,
            "crash_kind": self.crash_kind.map(BackendCrashKind::as_str),
        })
    }
}

impl BackendCrashKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::InteractivePanic => "interactive_panic",
            Self::Timeout => "timeout",
            Self::SpawnIo => "spawn_io",
            Self::UnexpectedFailure => "unexpected_failure",
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum BackendExecError {
    #[error("required dependency is missing: {binary}")]
    MissingDependency { binary: String },

    #[error("{message}")]
    Io {
        message: String,
        crash_kind: Option<BackendCrashKind>,
    },

    #[error("{message}")]
    Timeout {
        message: String,
        details: serde_json::Value,
    },
}

impl BackendExecError {
    pub fn into_app_error(self) -> AppError {
        match self {
            Self::MissingDependency { binary } => AppError::MissingDependency { binary },
            Self::Io { message, .. } => AppError::Io { message },
            Self::Timeout { message, details } => AppError::BackendTimeout { message, details },
        }
    }
}

pub trait KanidmBackend: Send + Sync {
    fn exec(&self, request: RawCommandRequest) -> Result<RawCommandResult, BackendExecError>;
}

#[derive(Debug, Clone)]
pub struct ProcessKanidmBackend {
    program: OsString,
}

impl ProcessKanidmBackend {
    pub fn new(program: OsString) -> Self {
        Self { program }
    }

    pub fn program(&self) -> &OsString {
        &self.program
    }
}

impl KanidmBackend for ProcessKanidmBackend {
    fn exec(&self, request: RawCommandRequest) -> Result<RawCommandResult, BackendExecError> {
        match request.mode {
            CommandMode::InteractiveAuth => run_interactive_command(&self.program, &request.args),
            CommandMode::NonInteractiveRead | CommandMode::NonInteractiveWrite => {
                run_captured_command(&self.program, &request)
            }
        }
    }
}

fn run_interactive_command(
    program: &OsString,
    args: &[String],
) -> Result<RawCommandResult, BackendExecError> {
    let status = Command::new(program)
        .args(args)
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status()
        .map_err(|error| map_spawn_error(program, error))?;

    Ok(RawCommandResult {
        status: ExitStatusSummary {
            success: status.success(),
            code: status.code(),
        },
        stdout: String::new(),
        stderr: String::new(),
    })
}

fn run_captured_command(
    program: &OsString,
    request: &RawCommandRequest,
) -> Result<RawCommandResult, BackendExecError> {
    let mut child = Command::new(program)
        .args(&request.args)
        .stdin(if request.stdin.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| map_spawn_error(program, error))?;

    if let Some(stdin_payload) = &request.stdin {
        let mut stdin = child.stdin.take().ok_or_else(|| BackendExecError::Io {
            message: format!("failed to open stdin for {}", program.to_string_lossy()),
            crash_kind: Some(BackendCrashKind::UnexpectedFailure),
        })?;
        stdin
            .write_all(stdin_payload.as_bytes())
            .map_err(|error| BackendExecError::Io {
                message: format!(
                    "failed to write stdin for {}: {error}",
                    program.to_string_lossy()
                ),
                crash_kind: Some(BackendCrashKind::UnexpectedFailure),
            })?;
    }

    let start = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => {
                let output = child
                    .wait_with_output()
                    .map_err(|error| BackendExecError::Io {
                        message: format!(
                            "failed to collect output from {}: {error}",
                            program.to_string_lossy()
                        ),
                        crash_kind: Some(BackendCrashKind::UnexpectedFailure),
                    })?;
                return Ok(RawCommandResult {
                    status: ExitStatusSummary {
                        success: output.status.success(),
                        code: output.status.code(),
                    },
                    stdout: String::from_utf8_lossy(&output.stdout).to_string(),
                    stderr: String::from_utf8_lossy(&output.stderr).to_string(),
                });
            }
            Ok(None) if start.elapsed() >= request.timeout => {
                let _ = child.kill();
                let output = child
                    .wait_with_output()
                    .map_err(|error| BackendExecError::Io {
                        message: format!(
                            "failed to collect timed-out output from {}: {error}",
                            program.to_string_lossy()
                        ),
                        crash_kind: Some(BackendCrashKind::UnexpectedFailure),
                    })?;
                return Err(BackendExecError::Timeout {
                    message: format!(
                        "kanidm backend command timed out after {} second(s)",
                        request.timeout.as_secs()
                    ),
                    details: json!({
                        "program": program.to_string_lossy(),
                        "args": request.args,
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
                return Err(BackendExecError::Io {
                    message: format!(
                        "failed while waiting on {}: {error}",
                        program.to_string_lossy()
                    ),
                    crash_kind: Some(BackendCrashKind::UnexpectedFailure),
                });
            }
        }
    }
}

fn map_spawn_error(program: &OsString, error: std::io::Error) -> BackendExecError {
    if error.kind() == std::io::ErrorKind::NotFound {
        BackendExecError::MissingDependency {
            binary: program.to_string_lossy().to_string(),
        }
    } else {
        BackendExecError::Io {
            message: format!("failed to execute {}: {error}", program.to_string_lossy()),
            crash_kind: Some(BackendCrashKind::SpawnIo),
        }
    }
}

fn classify_crash_kind(stdout: &str, stderr: &str, success: bool) -> Option<BackendCrashKind> {
    if success {
        return None;
    }

    let combined = format!("{stderr}\n{stdout}").to_lowercase();
    if combined.contains("thread 'main'")
        || combined.contains("panicked at")
        || combined.contains("not a terminal")
        || combined.contains("failed to interact with interactive session")
    {
        return Some(BackendCrashKind::InteractivePanic);
    }

    Some(BackendCrashKind::UnexpectedFailure)
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
        let backend = ProcessKanidmBackend::new(script.into_os_string());

        let error = backend
            .exec(RawCommandRequest {
                args: Vec::new(),
                mode: CommandMode::NonInteractiveRead,
                timeout: Duration::from_millis(10),
                stdin: None,
            })
            .expect_err("timeout");

        assert!(matches!(error, BackendExecError::Timeout { .. }));
    }

    #[test]
    fn classifies_upstream_terminal_panics() {
        let failure = BackendFailure::from_raw(
            &OsString::from("kanidm"),
            vec!["person".to_string(), "list".to_string()],
            RawCommandResult {
                status: ExitStatusSummary {
                    success: false,
                    code: Some(101),
                },
                stdout: String::new(),
                stderr: "thread 'main' panicked at foo\nFailed to interact with interactive session: Io(Custom { kind: NotConnected, error: \"not a terminal\" })".to_string(),
            },
        );

        assert_eq!(failure.crash_kind, Some(BackendCrashKind::InteractivePanic));
    }
}
