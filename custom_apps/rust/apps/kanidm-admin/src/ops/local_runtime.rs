use std::{
    collections::BTreeSet,
    io::Write,
    path::PathBuf,
    process::{Command, Stdio},
    thread::sleep,
    time::{Duration, Instant},
};

use serde::Serialize;
use serde_json::{json, Value};
use zeroize::Zeroize;

use crate::{
    backend::ExitStatusSummary,
    kanidm_cli::{KanidmCli, LocalCommandRedactedRecord},
    output::shell_quote_arg,
    sensitivity,
    verification::{VerificationDomain, VerificationSummary},
};

const COMMAND_POLL_INTERVAL: Duration = Duration::from_millis(50);
const DEFAULT_ROOT_HELPER: &str = "kanidm-admin-root";
const ENV_ROOT_HELPER: &str = "KANIDM_ADMIN_ROOT_HELPER";
pub const DEFAULT_CONVERGENCE_TIMEOUT: Duration = Duration::from_secs(30);
pub const DEFAULT_CONVERGENCE_INTERVAL: Duration = Duration::from_millis(500);

#[derive(Debug, Clone)]
pub struct LocalCommandSpec {
    pub program: String,
    pub args: Vec<String>,
    pub stdin: CommandStdin,
    pub timeout: Duration,
    pub allowed_exit_codes: BTreeSet<i32>,
    pub redaction: RedactionPolicy,
}

impl LocalCommandSpec {
    pub fn new(
        program: impl Into<String>,
        args: impl IntoIterator<Item = impl Into<String>>,
    ) -> Self {
        Self {
            program: program.into(),
            args: args.into_iter().map(Into::into).collect(),
            stdin: CommandStdin::None,
            timeout: Duration::from_secs(20),
            allowed_exit_codes: BTreeSet::from([0]),
            redaction: RedactionPolicy::default(),
        }
    }

    pub fn with_timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    pub fn with_stdin(mut self, stdin: CommandStdin) -> Self {
        self.stdin = stdin;
        self
    }

    pub fn with_redaction(mut self, redaction: RedactionPolicy) -> Self {
        self.redaction = redaction;
        self
    }

    pub fn display_command(&self) -> DisplayCommand {
        DisplayCommand {
            program: self.program.clone(),
            args: self.args.clone(),
        }
    }

    fn sanitized_args(&self) -> Vec<String> {
        if self.redaction.redact_args {
            vec![sensitivity::REDACTED.to_string()]
        } else {
            self.args.clone()
        }
    }

    fn sanitized_stdout<'a>(&self, stdout: &'a str) -> &'a str {
        if self.redaction.redact_stdout {
            sensitivity::REDACTED
        } else {
            stdout
        }
    }

    fn sanitized_stderr<'a>(&self, stderr: &'a str) -> &'a str {
        if self.redaction.redact_stderr {
            sensitivity::REDACTED
        } else {
            stderr
        }
    }
}

#[derive(Debug, Clone)]
pub enum CommandStdin {
    None,
    Secret(String),
    Bytes(Vec<u8>),
}

impl Drop for CommandStdin {
    fn drop(&mut self) {
        match self {
            Self::Secret(value) => value.zeroize(),
            Self::Bytes(value) => value.zeroize(),
            Self::None => {}
        }
    }
}

impl CommandStdin {
    fn as_bytes(&self) -> Option<&[u8]> {
        match self {
            Self::None => None,
            Self::Secret(value) => Some(value.as_bytes()),
            Self::Bytes(value) => Some(value.as_slice()),
        }
    }

    fn is_secret(&self) -> bool {
        matches!(self, Self::Secret(_))
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalCommandResult {
    pub status: CommandStatus,
    pub stdout: String,
    pub stderr: String,
    pub elapsed: Duration,
}

impl LocalCommandResult {
    pub fn exit_code(&self) -> Option<i32> {
        match &self.status {
            CommandStatus::Exited(code) => Some(*code),
            CommandStatus::TimedOut | CommandStatus::SpawnFailed(_) => None,
        }
    }

    pub fn allowed_success(&self, allowed_exit_codes: &BTreeSet<i32>) -> bool {
        match self.status {
            CommandStatus::Exited(code) => allowed_exit_codes.contains(&code),
            CommandStatus::TimedOut | CommandStatus::SpawnFailed(_) => false,
        }
    }

    pub fn detail(&self) -> String {
        let stdout = self.stdout.trim();
        if !stdout.is_empty() {
            stdout.to_string()
        } else if !self.stderr.trim().is_empty() {
            self.stderr.trim().to_string()
        } else {
            match &self.status {
                CommandStatus::Exited(code) => format!("exited with status {code}"),
                CommandStatus::TimedOut => "timed out".to_string(),
                CommandStatus::SpawnFailed(error) => error.clone(),
            }
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CommandStatus {
    Exited(i32),
    TimedOut,
    SpawnFailed(String),
}

#[derive(Debug, Clone, Default)]
pub struct RedactionPolicy {
    pub redact_args: bool,
    pub redact_stdout: bool,
    pub redact_stderr: bool,
    pub secret_labels: Vec<String>,
}

impl RedactionPolicy {
    pub fn secret_stdin(label: impl Into<String>) -> Self {
        Self {
            redact_args: false,
            redact_stdout: false,
            redact_stderr: false,
            secret_labels: vec![label.into()],
        }
    }

    pub fn redact_stdout(label: impl Into<String>) -> Self {
        Self {
            redact_stdout: true,
            secret_labels: vec![label.into()],
            ..Self::default()
        }
    }

    fn payload(&self, stdin_secret: bool) -> Value {
        json!({
            "args": self.redact_args,
            "stdout": self.redact_stdout,
            "stderr": self.redact_stderr,
            "stdin_secret": stdin_secret,
            "secret_labels": self.secret_labels,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct DisplayCommand {
    pub program: String,
    pub args: Vec<String>,
}

impl DisplayCommand {
    pub fn display_string(&self) -> String {
        if self.args.is_empty() {
            shell_quote_arg(&self.program)
        } else {
            format!(
                "{} {}",
                shell_quote_arg(&self.program),
                self.args
                    .iter()
                    .map(|arg| shell_quote_arg(arg))
                    .collect::<Vec<_>>()
                    .join(" ")
            )
        }
    }
}

pub struct RuntimeCheck {
    pub id: &'static str,
    pub label: String,
    pub required: bool,
    pub command: Option<DisplayCommand>,
    pub run: Box<dyn FnOnce() -> RuntimeCheckResult>,
}

impl RuntimeCheck {
    pub fn run(self) -> RuntimeCheckReport {
        let result = (self.run)();
        RuntimeCheckReport {
            id: self.id.to_string(),
            label: self.label,
            required: self.required,
            status: result.status,
            command: self.command.map(|command| command.display_string()),
            summary: result.summary,
            detail: result.detail,
            probe: result.probe,
        }
    }
}

#[derive(Debug, Clone)]
pub struct RuntimeCheckResult {
    pub status: CheckStatus,
    pub summary: String,
    pub detail: Option<String>,
    pub probe: Option<Value>,
}

impl RuntimeCheckResult {
    pub fn passed(summary: impl Into<String>) -> Self {
        Self {
            status: CheckStatus::Passed,
            summary: summary.into(),
            detail: None,
            probe: None,
        }
    }

    pub fn failed(summary: impl Into<String>) -> Self {
        Self {
            status: CheckStatus::Failed,
            summary: summary.into(),
            detail: None,
            probe: None,
        }
    }

    pub fn skipped(summary: impl Into<String>) -> Self {
        Self {
            status: CheckStatus::Skipped,
            summary: summary.into(),
            detail: None,
            probe: None,
        }
    }

    pub fn unknown(summary: impl Into<String>) -> Self {
        Self {
            status: CheckStatus::Unknown,
            summary: summary.into(),
            detail: None,
            probe: None,
        }
    }

    pub fn with_detail(mut self, detail: impl Into<String>) -> Self {
        self.detail = Some(detail.into());
        self
    }

    pub fn with_probe(mut self, probe: Value) -> Self {
        self.probe = Some(probe);
        self
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CheckStatus {
    Passed,
    Failed,
    Skipped,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ConvergencePolicy {
    pub timeout: Duration,
    pub interval: Duration,
    pub stable_successes_required: usize,
}

impl Default for ConvergencePolicy {
    fn default() -> Self {
        Self {
            timeout: DEFAULT_CONVERGENCE_TIMEOUT,
            interval: DEFAULT_CONVERGENCE_INTERVAL,
            stable_successes_required: 1,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct RuntimeReport {
    pub target: String,
    pub subject: String,
    pub ready: bool,
    pub attempts: usize,
    pub elapsed_ms: u128,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub failed_required_checks: Vec<String>,
    #[serde(skip_serializing_if = "is_zero_usize")]
    pub suppressed_attempts: usize,
    pub checks: Vec<RuntimeCheckReport>,
}

#[derive(Debug, Clone, Serialize)]
pub struct RuntimeCheckReport {
    pub id: String,
    pub label: String,
    pub required: bool,
    pub status: CheckStatus,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    pub summary: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub probe: Option<Value>,
}

impl RuntimeReport {
    pub fn new(
        target: impl Into<String>,
        subject: impl Into<String>,
        ready: bool,
        attempts: usize,
        elapsed_ms: u128,
        checks: Vec<RuntimeCheckReport>,
    ) -> Self {
        let failed_required_checks = checks
            .iter()
            .filter(|check| check.required && check.status != CheckStatus::Passed)
            .map(|check| check.id.clone())
            .collect::<Vec<_>>();
        Self {
            target: target.into(),
            subject: subject.into(),
            ready,
            attempts,
            elapsed_ms,
            failed_required_checks,
            suppressed_attempts: attempts.saturating_sub(1),
            checks,
        }
    }

    pub fn required_checks_passed(&self) -> bool {
        self.checks
            .iter()
            .all(|check| !check.required || check.status == CheckStatus::Passed)
    }

    pub fn refresh_derived(&mut self) {
        self.failed_required_checks = self
            .checks
            .iter()
            .filter(|check| check.required && check.status != CheckStatus::Passed)
            .map(|check| check.id.clone())
            .collect();
        self.suppressed_attempts = self.attempts.saturating_sub(1);
    }

    pub fn verification_summary(&self) -> VerificationSummary {
        VerificationSummary {
            domain: VerificationDomain::LocalRuntime,
            target: self.target.clone(),
            ready: self.ready,
            attempts: self.attempts,
            elapsed_ms: self.elapsed_ms,
        }
    }
}

fn is_zero_usize(value: &usize) -> bool {
    *value == 0
}

#[derive(Debug, Clone)]
pub enum RootAction {
    StartSystemdUnit { unit: String },
    Chpasswd { username: String },
    ReadSecretFile { path: PathBuf },
}

#[derive(Debug, Clone)]
pub struct LocalCommandExecution {
    pub result: LocalCommandResult,
    pub backend_payload: Value,
}

pub fn run_local_command(
    cli: &KanidmCli,
    step: &str,
    spec: LocalCommandSpec,
) -> LocalCommandExecution {
    let result = execute_local_command(&spec);
    let success = result.allowed_success(&spec.allowed_exit_codes);
    let sanitized_args = spec.sanitized_args();
    let stdout = spec.sanitized_stdout(&result.stdout).to_string();
    let stderr = spec.sanitized_stderr(&result.stderr).to_string();
    let status = ExitStatusSummary {
        success,
        code: result.exit_code(),
    };
    let redaction = spec.redaction.payload(spec.stdin.is_secret());
    cli.record_local_command_redacted_result(LocalCommandRedactedRecord {
        step,
        program: &spec.program,
        args: &sanitized_args,
        status,
        stdout: &stdout,
        stderr: &stderr,
        redaction: redaction.clone(),
    });

    LocalCommandExecution {
        backend_payload: json!({
            "step": step,
            "mode": "non_interactive_read",
            "program": spec.program,
            "args": sanitized_args,
            "status": status,
            "stdout": stdout,
            "stderr": stderr,
            "error": null,
            "redaction": redaction,
        }),
        result,
    }
}

pub fn execute_local_command(spec: &LocalCommandSpec) -> LocalCommandResult {
    let start = Instant::now();
    let mut child = match Command::new(&spec.program)
        .args(&spec.args)
        .stdin(if spec.stdin.as_bytes().is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
    {
        Ok(child) => child,
        Err(error) => {
            return LocalCommandResult {
                status: CommandStatus::SpawnFailed(error.to_string()),
                stdout: String::new(),
                stderr: error.to_string(),
                elapsed: start.elapsed(),
            };
        }
    };

    if let Some(stdin_payload) = spec.stdin.as_bytes() {
        let write_result = child
            .stdin
            .take()
            .ok_or_else(|| "failed to open stdin".to_string())
            .and_then(|mut child_stdin| {
                child_stdin
                    .write_all(stdin_payload)
                    .map_err(|error| error.to_string())
            });
        if let Err(error) = write_result {
            let _ = child.kill();
            let _ = child.wait();
            return LocalCommandResult {
                status: CommandStatus::SpawnFailed(error.clone()),
                stdout: String::new(),
                stderr: error,
                elapsed: start.elapsed(),
            };
        }
    }

    loop {
        match child.try_wait() {
            Ok(Some(_)) => match child.wait_with_output() {
                Ok(output) => {
                    return LocalCommandResult {
                        status: CommandStatus::Exited(output.status.code().unwrap_or(-1)),
                        stdout: String::from_utf8_lossy(&output.stdout).to_string(),
                        stderr: String::from_utf8_lossy(&output.stderr).to_string(),
                        elapsed: start.elapsed(),
                    };
                }
                Err(error) => {
                    return LocalCommandResult {
                        status: CommandStatus::SpawnFailed(error.to_string()),
                        stdout: String::new(),
                        stderr: error.to_string(),
                        elapsed: start.elapsed(),
                    };
                }
            },
            Ok(None) if start.elapsed() >= spec.timeout => {
                let _ = child.kill();
                let output = child.wait_with_output();
                let (stdout, stderr) = match output {
                    Ok(output) => (
                        String::from_utf8_lossy(&output.stdout).to_string(),
                        String::from_utf8_lossy(&output.stderr).to_string(),
                    ),
                    Err(error) => (String::new(), error.to_string()),
                };
                return LocalCommandResult {
                    status: CommandStatus::TimedOut,
                    stdout,
                    stderr,
                    elapsed: start.elapsed(),
                };
            }
            Ok(None) => sleep(COMMAND_POLL_INTERVAL),
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                return LocalCommandResult {
                    status: CommandStatus::SpawnFailed(error.to_string()),
                    stdout: String::new(),
                    stderr: error.to_string(),
                    elapsed: start.elapsed(),
                };
            }
        }
    }
}

pub fn run_root_action(
    cli: &KanidmCli,
    step: &str,
    action: RootAction,
    secret_stdin: Option<String>,
    timeout: Duration,
) -> LocalCommandExecution {
    let spec = root_action_spec(action, secret_stdin, timeout);
    run_local_command(cli, step, spec)
}

pub fn root_action_spec(
    action: RootAction,
    secret_stdin: Option<String>,
    timeout: Duration,
) -> LocalCommandSpec {
    let helper = std::env::var(ENV_ROOT_HELPER).unwrap_or_else(|_| DEFAULT_ROOT_HELPER.to_string());
    match action {
        RootAction::StartSystemdUnit { unit } => LocalCommandSpec::new(
            "sudo",
            [
                "-n".to_string(),
                helper.clone(),
                "systemd-start".to_string(),
                unit,
            ],
        )
        .with_timeout(timeout),
        RootAction::Chpasswd { username } => {
            let stdin = secret_stdin.unwrap_or_default();
            LocalCommandSpec::new(
                "sudo",
                [
                    "-n".to_string(),
                    helper.clone(),
                    "chpasswd".to_string(),
                    username.clone(),
                ],
            )
            .with_timeout(timeout)
            .with_stdin(CommandStdin::Secret(stdin))
            .with_redaction(RedactionPolicy::secret_stdin(format!(
                "chpasswd:{username}"
            )))
        }
        RootAction::ReadSecretFile { path } => LocalCommandSpec::new(
            "sudo",
            [
                "-n".to_string(),
                helper,
                "read-secret".to_string(),
                path.display().to_string(),
            ],
        )
        .with_timeout(timeout)
        .with_redaction(RedactionPolicy::redact_stdout("secret_file")),
    }
}

pub fn local_command_check<F>(
    cli: KanidmCli,
    id: &'static str,
    label: impl Into<String>,
    required: bool,
    step: impl Into<String>,
    spec: LocalCommandSpec,
    summarize: F,
) -> RuntimeCheck
where
    F: FnOnce(&LocalCommandExecution) -> RuntimeCheckResult + 'static,
{
    let step = step.into();
    let command = spec.display_command();
    RuntimeCheck {
        id,
        label: label.into(),
        required,
        command: Some(command),
        run: Box::new(move || {
            let execution = run_local_command(&cli, &step, spec);
            summarize(&execution)
        }),
    }
}

pub fn verify_until<F>(
    target: impl Into<String>,
    subject: impl Into<String>,
    policy: ConvergencePolicy,
    mut build_checks: F,
) -> RuntimeReport
where
    F: FnMut() -> Vec<RuntimeCheck>,
{
    let started = Instant::now();
    let mut attempts = 0usize;
    let mut stable_successes = 0usize;
    let mut latest = RuntimeReport::new(target, subject, false, 0, 0, Vec::new());

    loop {
        attempts = attempts.saturating_add(1);
        let checks = build_checks()
            .into_iter()
            .map(RuntimeCheck::run)
            .collect::<Vec<_>>();
        let checks_ready = checks
            .iter()
            .all(|check| !check.required || check.status == CheckStatus::Passed);
        if checks_ready {
            stable_successes = stable_successes.saturating_add(1);
        } else {
            stable_successes = 0;
        }
        let converged = stable_successes >= policy.stable_successes_required.max(1);
        latest = RuntimeReport::new(
            latest.target,
            latest.subject,
            checks_ready && converged,
            attempts,
            started.elapsed().as_millis(),
            checks,
        );
        if latest.ready || started.elapsed() >= policy.timeout {
            return latest;
        }

        let remaining = policy
            .timeout
            .checked_sub(started.elapsed())
            .unwrap_or_default();
        sleep(policy.interval.min(remaining));
    }
}

pub fn command_probe_payload(execution: &LocalCommandExecution) -> Value {
    json!({
        "success": execution
            .backend_payload
            .get("status")
            .and_then(|status| status.get("success"))
            .and_then(Value::as_bool)
            .unwrap_or(false),
        "code": execution.result.exit_code(),
        "stdout": execution.backend_payload.get("stdout").cloned().unwrap_or_else(|| json!("")),
        "stderr": execution.backend_payload.get("stderr").cloned().unwrap_or_else(|| json!("")),
    })
}

pub fn status_from_success(success: bool) -> CheckStatus {
    if success {
        CheckStatus::Passed
    } else {
        CheckStatus::Failed
    }
}

#[cfg(test)]
mod tests {
    use std::{
        fs,
        os::unix::fs::PermissionsExt,
        path::Path,
        process::Command as ProcessCommand,
        sync::{
            atomic::{AtomicUsize, Ordering},
            Arc,
        },
    };

    use tempfile::tempdir;

    use crate::{
        context::{ResolvedContext, RuntimePolicy, SftpRuntimeConfig},
        TEST_ENV_LOCK,
    };

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

    fn cli_for(script: &Path) -> KanidmCli {
        KanidmCli::new(&ResolvedContext {
            repo_root: None,
            server_url: "https://id.example.test".to_string(),
            admin_name: "admindsaw".to_string(),
            kanidm_bin: script.as_os_str().to_os_string(),
            vaultwarden_url: None,
            vaultwarden_admin_token_file: None,
            sftp_runtime: SftpRuntimeConfig::default(),
            runtime_policy: RuntimePolicy::default(),
        })
    }

    #[test]
    fn successful_command_result_is_captured() {
        let dir = tempdir().expect("tempdir");
        let script = dir.path().join("ok.sh");
        write_script(
            &script,
            r#"#!/usr/bin/env bash
printf 'hello\n'
"#,
        );

        let result = execute_local_command(&LocalCommandSpec::new(
            script.display().to_string(),
            Vec::<String>::new(),
        ));

        assert_eq!(result.status, CommandStatus::Exited(0));
        assert_eq!(result.stdout, "hello\n");
    }

    #[test]
    fn non_zero_exit_code_maps_to_failed_check() {
        let dir = tempdir().expect("tempdir");
        let script = dir.path().join("fail.sh");
        write_script(
            &script,
            r#"#!/usr/bin/env bash
printf 'nope\n' >&2
exit 7
"#,
        );

        let spec = LocalCommandSpec::new(script.display().to_string(), Vec::<String>::new());
        let result = execute_local_command(&spec);

        assert_eq!(result.status, CommandStatus::Exited(7));
        assert!(!result.allowed_success(&spec.allowed_exit_codes));
    }

    #[test]
    fn timeout_maps_to_timed_out() {
        let dir = tempdir().expect("tempdir");
        let script = dir.path().join("slow.sh");
        write_script(
            &script,
            r#"#!/usr/bin/env bash
sleep 1
"#,
        );

        let result = execute_local_command(
            &LocalCommandSpec::new(script.display().to_string(), Vec::<String>::new())
                .with_timeout(Duration::from_millis(10)),
        );

        assert_eq!(result.status, CommandStatus::TimedOut);
    }

    #[test]
    fn secret_stdin_and_redacted_output_are_not_logged() {
        let dir = tempdir().expect("tempdir");
        let script = dir.path().join("secret.sh");
        write_script(
            &script,
            r#"#!/usr/bin/env bash
cat >/dev/null
printf 'secret stdout\n'
printf 'secret stderr\n' >&2
"#,
        );
        let cli = cli_for(&script);

        let spec = LocalCommandSpec::new(script.display().to_string(), Vec::<String>::new())
            .with_stdin(CommandStdin::Secret("super secret stdin".to_string()))
            .with_redaction(RedactionPolicy {
                redact_stdout: true,
                redact_stderr: true,
                secret_labels: vec!["test_secret".to_string()],
                ..RedactionPolicy::default()
            });
        let execution = run_local_command(&cli, "secret command", spec);

        assert_eq!(execution.result.stdout, "secret stdout\n");
        let rendered_logs = serde_json::to_string(&cli.recent_backend_logs()).expect("logs");
        assert!(!rendered_logs.contains("super secret stdin"));
        assert!(!rendered_logs.contains("secret stdout"));
        assert!(!rendered_logs.contains("secret stderr"));
        assert!(rendered_logs.contains("<redacted>"));
    }

    #[test]
    fn redacted_args_are_not_logged() {
        let dir = tempdir().expect("tempdir");
        let script = dir.path().join("ok.sh");
        write_script(&script, "#!/usr/bin/env bash\nexit 0\n");
        let cli = cli_for(&script);

        let spec = LocalCommandSpec::new(
            script.display().to_string(),
            ["--password", "argument-secret"],
        )
        .with_redaction(RedactionPolicy {
            redact_args: true,
            ..RedactionPolicy::default()
        });
        run_local_command(&cli, "redacted args", spec);

        let rendered_logs = serde_json::to_string(&cli.recent_backend_logs()).expect("logs");
        assert!(!rendered_logs.contains("argument-secret"));
        assert!(rendered_logs.contains("<redacted>"));
    }

    #[test]
    fn required_unknown_blocks_readiness_but_optional_skipped_does_not() {
        let report = verify_until(
            "test",
            "subject",
            ConvergencePolicy {
                timeout: Duration::from_millis(0),
                interval: Duration::from_millis(1),
                stable_successes_required: 1,
            },
            || {
                vec![
                    RuntimeCheck {
                        id: "required.unknown",
                        label: "required".to_string(),
                        required: true,
                        command: None,
                        run: Box::new(|| RuntimeCheckResult::unknown("unknown")),
                    },
                    RuntimeCheck {
                        id: "optional.skipped",
                        label: "optional".to_string(),
                        required: false,
                        command: None,
                        run: Box::new(|| RuntimeCheckResult::skipped("skipped")),
                    },
                ]
            },
        );

        assert!(!report.ready);
        assert_eq!(report.attempts, 1);
        assert_eq!(report.failed_required_checks, vec!["required.unknown"]);
        assert_eq!(report.suppressed_attempts, 0);
    }

    #[test]
    fn verify_until_retries_until_success() {
        let attempts = Arc::new(AtomicUsize::new(0));
        let report = verify_until(
            "test",
            "subject",
            ConvergencePolicy {
                timeout: Duration::from_millis(100),
                interval: Duration::from_millis(1),
                stable_successes_required: 1,
            },
            {
                let attempts = Arc::clone(&attempts);
                move || {
                    let current = attempts.fetch_add(1, Ordering::SeqCst);
                    vec![RuntimeCheck {
                        id: "eventual",
                        label: "eventual".to_string(),
                        required: true,
                        command: None,
                        run: Box::new(move || {
                            if current >= 2 {
                                RuntimeCheckResult::passed("ready")
                            } else {
                                RuntimeCheckResult::failed("not ready")
                            }
                        }),
                    }]
                }
            },
        );

        assert!(report.ready);
        assert_eq!(report.attempts, 3);
        assert_eq!(report.suppressed_attempts, 2);
        assert!(report.failed_required_checks.is_empty());
    }

    #[test]
    fn verify_until_fails_after_timeout() {
        let report = verify_until(
            "test",
            "subject",
            ConvergencePolicy {
                timeout: Duration::from_millis(5),
                interval: Duration::from_millis(1),
                stable_successes_required: 1,
            },
            || {
                vec![RuntimeCheck {
                    id: "never",
                    label: "never".to_string(),
                    required: true,
                    command: None,
                    run: Box::new(|| RuntimeCheckResult::failed("not ready")),
                }]
            },
        );

        assert!(!report.ready);
        assert!(report.attempts >= 1);
        assert_eq!(report.failed_required_checks, vec!["never"]);
    }

    #[test]
    fn root_action_systemd_start_uses_fixed_helper_contract() {
        let _guard = TEST_ENV_LOCK.lock().expect("env lock");
        let previous = std::env::var_os(ENV_ROOT_HELPER);
        std::env::remove_var(ENV_ROOT_HELPER);

        let spec = root_action_spec(
            RootAction::StartSystemdUnit {
                unit: "kanidm-files-posix-groups.service".to_string(),
            },
            None,
            Duration::from_secs(5),
        );

        assert_eq!(spec.program, "sudo");
        assert_eq!(
            spec.args,
            vec![
                "-n",
                "kanidm-admin-root",
                "systemd-start",
                "kanidm-files-posix-groups.service"
            ]
        );

        match previous {
            Some(value) => std::env::set_var(ENV_ROOT_HELPER, value),
            None => std::env::remove_var(ENV_ROOT_HELPER),
        }
    }

    #[test]
    fn root_action_respects_configured_helper_path() {
        let _guard = TEST_ENV_LOCK.lock().expect("env lock");
        let previous = std::env::var_os(ENV_ROOT_HELPER);
        std::env::set_var(
            ENV_ROOT_HELPER,
            "/run/current-system/sw/bin/kanidm-admin-root",
        );

        let spec = root_action_spec(
            RootAction::ReadSecretFile {
                path: "/run/agenix/vaultwardenAdminToken".into(),
            },
            None,
            Duration::from_secs(5),
        );

        assert_eq!(
            spec.args,
            vec![
                "-n",
                "/run/current-system/sw/bin/kanidm-admin-root",
                "read-secret",
                "/run/agenix/vaultwardenAdminToken"
            ]
        );
        assert!(spec.redaction.redact_stdout);

        match previous {
            Some(value) => std::env::set_var(ENV_ROOT_HELPER, value),
            None => std::env::remove_var(ENV_ROOT_HELPER),
        }
    }

    #[test]
    fn root_action_chpasswd_never_logs_password_stdin() {
        let _guard = TEST_ENV_LOCK.lock().expect("env lock");
        let dir = tempdir().expect("tempdir");
        let sudo = dir.path().join("sudo");
        write_script(
            &sudo,
            r#"#!/usr/bin/env bash
set -euo pipefail
while IFS= read -r _line; do :; done
printf 'ok\n'
"#,
        );
        let previous_path = std::env::var_os("PATH");
        let previous_helper = std::env::var_os(ENV_ROOT_HELPER);
        let test_path = match &previous_path {
            Some(path) => {
                let mut value = dir.path().as_os_str().to_os_string();
                value.push(":");
                value.push(path);
                value
            }
            None => dir.path().as_os_str().to_os_string(),
        };
        std::env::set_var("PATH", test_path);
        std::env::remove_var(ENV_ROOT_HELPER);

        let execution = run_root_action(
            &cli_for(&sudo),
            "test chpasswd",
            RootAction::Chpasswd {
                username: "alice".to_string(),
            },
            Some("alice:correct horse battery staple\n".to_string()),
            Duration::from_secs(5),
        );

        match previous_path {
            Some(value) => std::env::set_var("PATH", value),
            None => std::env::remove_var("PATH"),
        }
        match previous_helper {
            Some(value) => std::env::set_var(ENV_ROOT_HELPER, value),
            None => std::env::remove_var(ENV_ROOT_HELPER),
        }

        assert_eq!(execution.result.status, CommandStatus::Exited(0));
        let rendered = serde_json::to_string(&execution.backend_payload).expect("payload");
        assert!(!rendered.contains("correct horse battery staple"));
        assert!(rendered.contains("kanidm-admin-root"));
        assert!(rendered.contains("chpasswd"));
    }
}
