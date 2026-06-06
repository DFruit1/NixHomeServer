use std::{env, fs, os::unix::fs::PermissionsExt, path::Path, time::Duration};

use serde_json::{json, Value};

use crate::{
    context::ResolvedContext,
    inventory::{clients::parse_client_list, groups::parse_group_list, users::parse_user_list},
    kanidm_cli::{BaseSessionState, KanidmCli, PrivilegedWriteState},
    ops::local_runtime::{
        execute_local_command, root_action_spec, run_local_command, CheckStatus, LocalCommandSpec,
        RootAction, RuntimeCheckReport,
    },
    output::{status_text, CommandOutput},
    AppError,
};

pub fn show_context(context: &ResolvedContext) -> CommandOutput {
    let repo_root = context
        .repo_root
        .as_ref()
        .map(|path| path.display().to_string());
    let kanidm_bin = context.kanidm_bin.to_string_lossy().to_string();
    let vaultwarden_admin_token_file = context
        .vaultwarden_admin_token_file
        .as_ref()
        .map(|path| path.display().to_string());

    CommandOutput {
        message: "loaded kanidm-admin context".to_string(),
        human: format!(
            "Repository Root: {}\nServer URL: {}\nAdmin Name: {}\nKanidm Binary: {}\nVaultwarden URL: {}\nVaultwarden Admin Token File: {}\nSFTP Access Group: {}\nLocal SFTP Bridge Group: {}\nSFTP Chroot Base: {}\nFiles SFTP Port: {}\nFiles SFTP sshd Service: {}\nUser Root Sync Service: {}",
            repo_root.as_deref().unwrap_or("(not resolved)"),
            context.server_url,
            context.admin_name,
            kanidm_bin,
            context.vaultwarden_url.as_deref().unwrap_or("(not resolved)"),
            vaultwarden_admin_token_file
                .as_deref()
                .unwrap_or("(not resolved)"),
            context.sftp_runtime.sftp_access_group,
            context.sftp_runtime.local_sftp_access_group,
            context.sftp_runtime.sftp_chroot_base,
            context.sftp_runtime.files_sftp_port,
            context.sftp_runtime.files_sftp_sshd_service,
            context.sftp_runtime.user_root_sync_service,
        ),
        details: json!({
            "repo_root": repo_root,
            "server_url": context.server_url,
            "admin_name": context.admin_name,
            "kanidm_bin": kanidm_bin,
            "vaultwarden_url": context.vaultwarden_url,
            "vaultwarden_admin_token_file": vaultwarden_admin_token_file,
            "sftp_runtime": context.sftp_runtime,
        }),
        warnings: Vec::new(),
    }
}

pub fn doctor(
    context: &ResolvedContext,
    cli: &KanidmCli,
    deep: bool,
) -> Result<CommandOutput, AppError> {
    let session = probe_session(cli);
    let users = probe_count(|| {
        let parsed = parse_user_list(&cli.person_list::<Value>()?)?;
        Ok((parsed.value.len(), parsed.warnings))
    });
    let groups = probe_count(|| {
        let parsed = parse_group_list(&cli.group_list::<Value>()?)?;
        Ok((parsed.value.len(), parsed.warnings))
    });
    let clients = probe_count(|| {
        let parsed = parse_client_list(&cli.oauth2_list::<Value>()?)?;
        Ok((parsed.value.len(), parsed.warnings))
    });

    let report = DoctorReport {
        session,
        users,
        groups,
        clients,
        vaultwarden: probe_vaultwarden_helper_context(context),
    };
    let deep_checks = if deep {
        Some(probe_deep_runtime(context, cli))
    } else {
        None
    };
    let repo_root = context
        .repo_root
        .as_ref()
        .map(|path| path.display().to_string());

    Ok(CommandOutput {
        message: "completed kanidm-admin doctor checks".to_string(),
        human: {
            let mut human = report.render_human(context);
            if let Some(checks) = &deep_checks {
                human.push_str("\n\n");
                human.push_str(&render_deep_checks(checks));
            }
            human
        },
        details: json!({
            "context": {
                "repo_root": repo_root,
                "server_url": context.server_url,
                "admin_name": context.admin_name,
                "kanidm_bin": context.kanidm_bin.to_string_lossy().to_string(),
                "vaultwarden_url": context.vaultwarden_url,
                "vaultwarden_admin_token_file": context
                    .vaultwarden_admin_token_file
                    .as_ref()
                    .map(|path| path.display().to_string()),
                "sftp_runtime": context.sftp_runtime,
            },
            "session": report.session.to_value(),
            "probes": {
                "users": report.users.to_value(),
                "groups": report.groups.to_value(),
                "clients": report.clients.to_value(),
                "vaultwarden": report.vaultwarden.to_value(),
            },
            "counts": {
                "users": report.users.count,
                "groups": report.groups.count,
                "clients": report.clients.count,
            },
            "warnings_by_inventory": {
                "users": report.users.warnings,
                "groups": report.groups.warnings,
                "clients": report.clients.warnings,
            },
            "deep": {
                "enabled": deep,
                "checks": deep_checks,
            },
        }),
        warnings: Vec::new(),
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DoctorProbeStatus {
    Ok,
    Warning,
    Error,
}

impl DoctorProbeStatus {
    fn as_str(self) -> &'static str {
        match self {
            Self::Ok => "ok",
            Self::Warning => "warning",
            Self::Error => "error",
        }
    }
}

#[derive(Debug, Clone)]
struct DoctorProbe {
    status: DoctorProbeStatus,
    count: Option<usize>,
    warnings: Vec<String>,
    error: Option<Value>,
}

impl DoctorProbe {
    fn to_value(&self) -> Value {
        json!({
            "status": self.status.as_str(),
            "count": self.count,
            "warnings": self.warnings,
            "error": self.error,
        })
    }
}

#[derive(Debug, Clone)]
struct SessionDoctorProbe {
    status: DoctorProbeStatus,
    authenticated: Option<bool>,
    state: String,
    diagnostic: String,
    error: Option<Value>,
}

impl SessionDoctorProbe {
    fn to_value(&self) -> Value {
        json!({
            "status": self.status.as_str(),
            "authenticated": self.authenticated,
            "state": self.state,
            "diagnostic": self.diagnostic,
            "error": self.error,
        })
    }

    fn summary_line(&self) -> String {
        match self.state.as_str() {
            "authenticated" => "authenticated: the delegated operator session is ready.".to_string(),
            "expired" => {
                "expired: the session exists but has expired, so privileged commands need a fresh login.".to_string()
            }
            "missing" => {
                "missing: no Kanidm session is active for this operator yet.".to_string()
            }
            "reauth_required" => {
                "reauth required: the base session exists, but privileged write access has expired.".to_string()
            }
            _ => format!("unavailable: {}", self.diagnostic),
        }
    }

    fn next_steps(&self) -> Vec<String> {
        match self.state.as_str() {
            "expired" | "missing" => vec![
                "Run `kanidm-admin session login` to start or refresh the delegated operator session.".to_string(),
            ],
            "reauth_required" => vec![
                "Run `kanidm-admin session reauth` to refresh privileged write access.".to_string(),
            ],
            _ => Vec::new(),
        }
    }
}

#[derive(Debug, Clone)]
struct DoctorReport {
    session: SessionDoctorProbe,
    users: DoctorProbe,
    groups: DoctorProbe,
    clients: DoctorProbe,
    vaultwarden: VaultwardenDoctorProbe,
}

impl DoctorReport {
    fn render_human(&self, context: &ResolvedContext) -> String {
        let mut body = format!(
            "Server URL: {}\nAdmin Name: {}\nSession: {}\nUsers: {}\nGroups: {}\nOAuth2 Clients: {}\nVaultwarden Local Helper: {}",
            context.server_url,
            context.admin_name,
            self.session.summary_line(),
            render_count(self.users.count),
            render_count(self.groups.count),
            render_count(self.clients.count),
            self.vaultwarden.summary_line(),
        );

        let next_steps = merge_lists(vec![
            self.session.next_steps(),
            self.vaultwarden.next_steps(),
        ]);
        if !next_steps.is_empty() {
            body.push_str("\n\nNext Step:\n");
            body.push_str(&render_bullets(&next_steps));
        }

        let warnings = merge_lists(vec![
            self.users.warnings.clone(),
            self.groups.warnings.clone(),
            self.clients.warnings.clone(),
            self.vaultwarden.warnings.clone(),
        ]);
        if !warnings.is_empty() {
            body.push_str("\n\nWarnings:\n");
            body.push_str(&render_bullets(&warnings));
        }

        let errors = self.error_lines();
        if !errors.is_empty() {
            body.push_str("\n\nErrors:\n");
            body.push_str(&render_bullets(&errors));
        }

        if !self.session.diagnostic.is_empty() && self.session.state != "authenticated" {
            body.push_str("\n\nSession Diagnostic:\n");
            body.push_str(&self.session.diagnostic);
        }

        body
    }

    fn error_lines(&self) -> Vec<String> {
        let mut errors = Vec::new();
        if self.session.status == DoctorProbeStatus::Error && !self.session.diagnostic.is_empty() {
            errors.push(format!(
                "Session state unavailable: {}",
                self.session.diagnostic
            ));
        }
        append_probe_error("Users", &self.users, &mut errors);
        append_probe_error("Groups", &self.groups, &mut errors);
        append_probe_error("OAuth2 Clients", &self.clients, &mut errors);
        if self.vaultwarden.status == DoctorProbeStatus::Error
            && !self.vaultwarden.detail.is_empty()
        {
            errors.push(format!(
                "Vaultwarden local helper: {}",
                self.vaultwarden.detail
            ));
        }
        errors
    }
}

#[derive(Debug, Clone)]
struct VaultwardenDoctorProbe {
    status: DoctorProbeStatus,
    url_configured: bool,
    admin_token_file_configured: bool,
    detail: String,
    warnings: Vec<String>,
}

impl VaultwardenDoctorProbe {
    fn to_value(&self) -> Value {
        json!({
            "status": self.status.as_str(),
            "url_configured": self.url_configured,
            "admin_token_file_configured": self.admin_token_file_configured,
            "detail": self.detail,
            "warnings": self.warnings,
        })
    }

    fn summary_line(&self) -> String {
        self.detail.clone()
    }

    fn next_steps(&self) -> Vec<String> {
        match self.status {
            DoctorProbeStatus::Ok => Vec::new(),
            DoctorProbeStatus::Warning => vec![
                "Confirm the repo context can resolve the Vaultwarden URL and admin token file before using `kanidm-admin local vaultwarden invite`.".to_string(),
            ],
            DoctorProbeStatus::Error => Vec::new(),
        }
    }
}

fn probe_session(cli: &KanidmCli) -> SessionDoctorProbe {
    match cli.session_snapshot() {
        Ok(snapshot)
            if matches!(snapshot.base_session_state, BaseSessionState::Present)
                && matches!(snapshot.privileged_write_state, PrivilegedWriteState::Ready) =>
        {
            SessionDoctorProbe {
                status: DoctorProbeStatus::Ok,
                authenticated: Some(true),
                state: "authenticated".to_string(),
                diagnostic: snapshot.diagnostic_raw.trim().to_string(),
                error: None,
            }
        }
        Ok(snapshot) if matches!(snapshot.base_session_state, BaseSessionState::Expired) => {
            SessionDoctorProbe {
                status: DoctorProbeStatus::Warning,
                authenticated: Some(false),
                state: "expired".to_string(),
                diagnostic: snapshot.diagnostic_raw.trim().to_string(),
                error: None,
            }
        }
        Ok(snapshot) if matches!(snapshot.base_session_state, BaseSessionState::Present) => {
            SessionDoctorProbe {
                status: DoctorProbeStatus::Warning,
                authenticated: Some(true),
                state: "reauth_required".to_string(),
                diagnostic: snapshot.diagnostic_raw.trim().to_string(),
                error: None,
            }
        }
        Ok(snapshot) => SessionDoctorProbe {
            status: DoctorProbeStatus::Warning,
            authenticated: Some(false),
            state: "missing".to_string(),
            diagnostic: snapshot.diagnostic_raw.trim().to_string(),
            error: None,
        },
        Err(error) => SessionDoctorProbe {
            status: DoctorProbeStatus::Error,
            authenticated: None,
            state: "unavailable".to_string(),
            diagnostic: error.human_message(),
            error: Some(error.json_payload()),
        },
    }
}

fn probe_count<F>(loader: F) -> DoctorProbe
where
    F: FnOnce() -> Result<(usize, Vec<String>), AppError>,
{
    match loader() {
        Ok((count, warnings)) => DoctorProbe {
            status: if warnings.is_empty() {
                DoctorProbeStatus::Ok
            } else {
                DoctorProbeStatus::Warning
            },
            count: Some(count),
            warnings,
            error: None,
        },
        Err(error) => DoctorProbe {
            status: DoctorProbeStatus::Error,
            count: None,
            warnings: Vec::new(),
            error: Some(error.json_payload()),
        },
    }
}

fn probe_vaultwarden_helper_context(context: &ResolvedContext) -> VaultwardenDoctorProbe {
    let url_configured = context.vaultwarden_url.is_some();
    let admin_token_file_configured = context.vaultwarden_admin_token_file.is_some();
    let mut warnings = Vec::new();
    if !url_configured {
        warnings.push("Vaultwarden URL is not configured for local invite helpers".to_string());
    }
    if !admin_token_file_configured {
        warnings.push(
            "Vaultwarden admin token file is not configured for local invite helpers".to_string(),
        );
    }
    let status = if warnings.is_empty() {
        DoctorProbeStatus::Ok
    } else {
        DoctorProbeStatus::Warning
    };
    let detail = if warnings.is_empty() {
        "local invite helper context is configured".to_string()
    } else {
        "local invite helper context is incomplete".to_string()
    };
    VaultwardenDoctorProbe {
        status,
        url_configured,
        admin_token_file_configured,
        detail,
        warnings,
    }
}

fn probe_deep_runtime(context: &ResolvedContext, cli: &KanidmCli) -> Vec<RuntimeCheckReport> {
    let mut checks = vec![
        command_check(
            "doctor.root_bridge.sudo_contract",
            "root bridge sudo contract is callable",
            false,
            LocalCommandSpec::new(
                "sudo",
                [
                    "-n".to_string(),
                    std::env::var("KANIDM_ADMIN_ROOT_HELPER")
                        .unwrap_or_else(|_| "kanidm-admin-root".to_string()),
                    "--help".to_string(),
                ],
            ),
        ),
        command_check(
            "doctor.kanidm_unix.status",
            "kanidm-unix status is available",
            false,
            LocalCommandSpec::new("kanidm-unix", ["status".to_string()]),
        ),
        command_check(
            "doctor.systemd.kanidm_unixd.active",
            "kanidm-unixd service is active",
            false,
            LocalCommandSpec::new(
                "systemctl",
                [
                    "is-active".to_string(),
                    context.sftp_runtime.kanidm_unixd_service.clone(),
                ],
            ),
        ),
        command_check(
            "doctor.systemd.files_sftp_sshd.active",
            "files SFTP sshd service is active",
            false,
            LocalCommandSpec::new(
                "systemctl",
                [
                    "is-active".to_string(),
                    context.sftp_runtime.files_sftp_sshd_service.clone(),
                ],
            ),
        ),
        systemctl_loaded_check(
            "doctor.systemd.posix_groups.exists",
            "POSIX group sync service exists",
            &context.sftp_runtime.posix_groups_service,
        ),
        systemctl_loaded_check(
            "doctor.systemd.user_root_sync.exists",
            "fileshare user root sync service exists",
            &context.sftp_runtime.user_root_sync_service,
        ),
        history_permissions_check(),
        broad_sudo_policy_check(context),
    ];
    if let Some(path) = &context.vaultwarden_admin_token_file {
        checks.push(vaultwarden_token_root_helper_check(cli, path));
    }
    for group in [
        &context.sftp_runtime.sftp_access_group,
        &context.sftp_runtime.local_sftp_access_group,
        &context.sftp_runtime.web_access_group,
        &context.sftp_runtime.usb_access_group,
        &context.sftp_runtime.backup_storage_access_group,
    ] {
        let status = match cli.group_get::<Value>(group) {
            Ok(Value::Object(_)) => CheckStatus::Passed,
            Ok(_) => CheckStatus::Failed,
            Err(_) => CheckStatus::Failed,
        };
        checks.push(RuntimeCheckReport {
            id: "doctor.kanidm.group.exists".to_string(),
            label: format!("Kanidm group '{group}' exists"),
            required: false,
            status,
            command: Some(format!(
                "kanidm group get {} --url {} --name {}",
                group, context.server_url, context.admin_name
            )),
            summary: if status == CheckStatus::Passed {
                "found".to_string()
            } else {
                "not found or unavailable".to_string()
            },
            detail: None,
            probe: None,
        });
    }
    checks
}

fn history_permissions_check() -> RuntimeCheckReport {
    let path = resolved_history_dir_for_check();
    match fs::metadata(&path) {
        Ok(metadata) if metadata.is_dir() => {
            let mode = metadata.permissions().mode() & 0o777;
            let status = if mode == 0o700 {
                CheckStatus::Passed
            } else {
                CheckStatus::Failed
            };
            RuntimeCheckReport {
                id: "doctor.history.permissions".to_string(),
                label: "kanidm-admin history directory is private".to_string(),
                required: false,
                status,
                command: None,
                summary: format!("{} mode {:03o}", path.display(), mode),
                detail: (status == CheckStatus::Failed).then(|| {
                    "Expected mode 0700. New writes enforce this, but existing directories may need chmod 700.".to_string()
                }),
                probe: Some(json!({
                    "path": path.display().to_string(),
                    "mode": format!("{mode:03o}"),
                    "expected_mode": "700",
                })),
            }
        }
        Ok(_) => RuntimeCheckReport {
            id: "doctor.history.permissions".to_string(),
            label: "kanidm-admin history directory is private".to_string(),
            required: false,
            status: CheckStatus::Failed,
            command: None,
            summary: format!("{} exists but is not a directory", path.display()),
            detail: None,
            probe: Some(json!({ "path": path.display().to_string() })),
        },
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => RuntimeCheckReport {
            id: "doctor.history.permissions".to_string(),
            label: "kanidm-admin history directory is private".to_string(),
            required: false,
            status: CheckStatus::Skipped,
            command: None,
            summary: format!("{} does not exist yet", path.display()),
            detail: None,
            probe: Some(json!({ "path": path.display().to_string() })),
        },
        Err(error) => RuntimeCheckReport {
            id: "doctor.history.permissions".to_string(),
            label: "kanidm-admin history directory is private".to_string(),
            required: false,
            status: CheckStatus::Unknown,
            command: None,
            summary: format!("failed to inspect {}: {error}", path.display()),
            detail: None,
            probe: Some(json!({ "path": path.display().to_string() })),
        },
    }
}

fn resolved_history_dir_for_check() -> std::path::PathBuf {
    if let Some(path) = env::var_os("KANIDM_ADMIN_HISTORY_DIR") {
        return path.into();
    }
    let system = Path::new("/var/lib/kanidm-admin/history");
    if system.exists() {
        return system.to_path_buf();
    }
    env::var_os("HOME")
        .map(std::path::PathBuf::from)
        .map(|home| home.join(".local/state/kanidm-admin/history"))
        .unwrap_or_else(|| system.to_path_buf())
}

fn broad_sudo_policy_check(context: &ResolvedContext) -> RuntimeCheckReport {
    let path = context
        .repo_root
        .as_ref()
        .map(|repo| repo.join("modules/Core_Modules/base-system/default.nix"));
    let Some(path) = path else {
        return RuntimeCheckReport {
            id: "doctor.sudo.broad_nopasswd".to_string(),
            label: "broad passwordless sudo policy is absent".to_string(),
            required: false,
            status: CheckStatus::Skipped,
            command: None,
            summary: "repository root is not resolved".to_string(),
            detail: None,
            probe: None,
        };
    };

    match fs::read_to_string(&path) {
        Ok(contents) => {
            let broad = contents.contains("command = \"ALL\"")
                && contents.contains("options = [ \"NOPASSWD\" ]");
            RuntimeCheckReport {
                id: "doctor.sudo.broad_nopasswd".to_string(),
                label: "broad passwordless sudo policy is absent".to_string(),
                required: false,
                status: if broad {
                    CheckStatus::Failed
                } else {
                    CheckStatus::Passed
                },
                command: None,
                summary: if broad {
                    "repo declares NOPASSWD sudo for ALL commands".to_string()
                } else {
                    "repo does not declare broad NOPASSWD sudo".to_string()
                },
                detail: broad.then(|| {
                    "This is retained for deploy/bootstrap compatibility; replacing it requires a separate deploy sudo contract.".to_string()
                }),
                probe: Some(json!({ "path": path.display().to_string(), "broad_nopasswd_all": broad })),
            }
        }
        Err(error) => RuntimeCheckReport {
            id: "doctor.sudo.broad_nopasswd".to_string(),
            label: "broad passwordless sudo policy is absent".to_string(),
            required: false,
            status: CheckStatus::Unknown,
            command: None,
            summary: format!("failed to inspect {}: {error}", path.display()),
            detail: None,
            probe: Some(json!({ "path": path.display().to_string() })),
        },
    }
}

fn vaultwarden_token_root_helper_check(cli: &KanidmCli, path: &Path) -> RuntimeCheckReport {
    let spec = root_action_spec(
        RootAction::ReadSecretFile {
            path: path.to_path_buf(),
        },
        None,
        Duration::from_secs(5),
    );
    let command = spec.display_command().display_string();
    let execution = run_local_command(cli, "doctor vaultwarden token root helper", spec);
    let success = execution
        .result
        .allowed_success(&std::collections::BTreeSet::from([0]));
    RuntimeCheckReport {
        id: "doctor.vaultwarden.token_root_helper".to_string(),
        label: "Vaultwarden token is readable through kanidm-admin-root".to_string(),
        required: false,
        status: if success {
            CheckStatus::Passed
        } else {
            CheckStatus::Failed
        },
        command: Some(command),
        summary: if success {
            "token read helper succeeded with redacted output".to_string()
        } else {
            execution.result.detail()
        },
        detail: None,
        probe: Some(execution.backend_payload),
    }
}

fn systemctl_loaded_check(id: &'static str, label: &str, service: &str) -> RuntimeCheckReport {
    let spec = LocalCommandSpec::new(
        "systemctl",
        [
            "show".to_string(),
            "-p".to_string(),
            "LoadState".to_string(),
            "--value".to_string(),
            service.to_string(),
        ],
    );
    let command = spec.display_command().display_string();
    let result = execute_local_command(&spec);
    let load_state = result.stdout.trim();
    let loaded =
        result.allowed_success(&std::collections::BTreeSet::from([0])) && load_state == "loaded";
    RuntimeCheckReport {
        id: id.to_string(),
        label: label.to_string(),
        required: false,
        status: if loaded {
            CheckStatus::Passed
        } else {
            CheckStatus::Failed
        },
        command: Some(command),
        summary: if loaded {
            format!("{service} is loaded")
        } else if load_state.is_empty() {
            format!("{service} is not confirmed loaded: {}", result.detail())
        } else {
            format!("{service} load state is {load_state}")
        },
        detail: None,
        probe: None,
    }
}

fn command_check(
    id: &'static str,
    label: &str,
    required: bool,
    spec: LocalCommandSpec,
) -> RuntimeCheckReport {
    let command = spec.display_command().display_string();
    let result = execute_local_command(&spec);
    let status = if result.allowed_success(&std::collections::BTreeSet::from([0])) {
        CheckStatus::Passed
    } else {
        CheckStatus::Failed
    };
    RuntimeCheckReport {
        id: id.to_string(),
        label: label.to_string(),
        required,
        status,
        command: Some(command),
        summary: result.detail(),
        detail: None,
        probe: None,
    }
}

fn render_deep_checks(checks: &[RuntimeCheckReport]) -> String {
    let mut body = vec!["Deep Runtime Checks:".to_string()];
    for (title, statuses) in [
        ("Failed", &[CheckStatus::Failed][..]),
        ("Warning / Unknown", &[CheckStatus::Unknown][..]),
        ("Passed", &[CheckStatus::Passed][..]),
        ("Skipped", &[CheckStatus::Skipped][..]),
    ] {
        let matching = checks
            .iter()
            .filter(|check| statuses.contains(&check.status))
            .collect::<Vec<_>>();
        if matching.is_empty() {
            continue;
        }
        body.push(format!("\n{title}:"));
        for check in matching {
            body.push(render_deep_check_line(check));
        }
    }

    let fixes = likely_deep_fixes(checks);
    if !fixes.is_empty() {
        body.push("\nMost likely fix:".to_string());
        body.extend(fixes.into_iter().map(|fix| format!("- {fix}")));
    }

    body.join("\n")
}

fn render_deep_check_line(check: &RuntimeCheckReport) -> String {
    let mut line = format!(
        "- [{}] {}: {}",
        status_text(check_status_word(check.status)),
        check.label,
        check.summary
    );
    if matches!(check.status, CheckStatus::Failed | CheckStatus::Unknown) {
        if let Some(detail) = &check.detail {
            line.push_str(&format!("\n  detail: {detail}"));
        }
        if let Some(command) = &check.command {
            line.push_str(&format!("\n  command: {command}"));
        }
    }
    line
}

fn check_status_word(status: CheckStatus) -> &'static str {
    match status {
        CheckStatus::Passed => "passed",
        CheckStatus::Failed => "failed",
        CheckStatus::Skipped => "skipped",
        CheckStatus::Unknown => "unknown",
    }
}

fn likely_deep_fixes(checks: &[RuntimeCheckReport]) -> Vec<String> {
    let mut fixes = checks
        .iter()
        .filter(|check| matches!(check.status, CheckStatus::Failed | CheckStatus::Unknown))
        .filter_map(|check| {
            if check.id.starts_with("doctor.systemd.") {
                Some("Inspect the named unit with `systemctl status <unit>` on the server.")
            } else if check.id == "doctor.root_bridge.sudo_contract" {
                Some("Check the `kanidm-admin-root` sudo contract and bootstrap sudo deployment.")
            } else if check.id == "doctor.kanidm.group.exists" {
                Some("Confirm the group names in `vars.nix` and rerun provisioning if they are missing in Kanidm.")
            } else if check.id == "doctor.history.permissions" {
                Some("Run `chmod 700` on the kanidm-admin history directory.")
            } else if check.id == "doctor.vaultwarden.token_root_helper" {
                Some("Check the Vaultwarden agenix token path and the root helper read-secret permission.")
            } else {
                None
            }
        })
        .map(ToOwned::to_owned)
        .collect::<Vec<_>>();
    fixes.sort();
    fixes.dedup();
    fixes
}

fn append_probe_error(label: &str, probe: &DoctorProbe, errors: &mut Vec<String>) {
    if let Some(error) = &probe.error {
        let message = error
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("probe failed");
        errors.push(format!("{label}: {message}"));
    }
}

fn render_count(value: Option<usize>) -> String {
    value
        .map(|value| value.to_string())
        .unwrap_or_else(|| "unavailable".to_string())
}

fn render_bullets(items: &[String]) -> String {
    items
        .iter()
        .map(|item| format!("- {item}"))
        .collect::<Vec<_>>()
        .join("\n")
}

fn merge_lists(inventories: Vec<Vec<String>>) -> Vec<String> {
    let mut warnings = inventories.into_iter().flatten().collect::<Vec<_>>();
    warnings.sort();
    warnings.dedup();
    warnings
}

#[cfg(test)]
mod tests {
    use std::{fs, os::unix::fs::PermissionsExt, path::Path, process::Command as ProcessCommand};

    use crate::context::ResolvedContext;

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

    fn stub_cli(script_body: &str) -> KanidmCli {
        let dir = tempfile::tempdir().expect("tempdir");
        let script = dir.path().join("kanidm-stub.sh");
        write_script(&script, script_body);
        let cli = KanidmCli::new(&ResolvedContext {
            repo_root: None,
            server_url: "https://id.example.test".to_string(),
            admin_name: "admindsaw".to_string(),
            kanidm_bin: script.into_os_string(),
            vaultwarden_url: Some("https://passwords.example.test".to_string()),
            vaultwarden_admin_token_file: Some("/run/agenix/vaultwardenAdminToken".into()),
            sftp_runtime: crate::context::SftpRuntimeConfig::default(),
            runtime_policy: crate::context::RuntimePolicy::default(),
        });
        std::mem::forget(dir);
        cli
    }

    fn context() -> ResolvedContext {
        ResolvedContext {
            repo_root: None,
            server_url: "https://id.example.test".to_string(),
            admin_name: "admindsaw".to_string(),
            kanidm_bin: "/bin/true".into(),
            vaultwarden_url: Some("https://passwords.example.test".to_string()),
            vaultwarden_admin_token_file: Some("/run/agenix/vaultwardenAdminToken".into()),
            sftp_runtime: crate::context::SftpRuntimeConfig::default(),
            runtime_policy: crate::context::RuntimePolicy::default(),
        }
    }

    #[test]
    fn doctor_returns_partial_output_when_users_fail() {
        let cli = stub_cli(
            r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "session" && "$2" == "list" ]]; then
  printf 'authenticated'
  exit 0
fi
if [[ "$1" == "person" && "$2" == "list" ]]; then
  printf 'backend exploded\n' >&2
  exit 1
fi
if [[ "$1" == "group" && "$2" == "list" ]]; then
  printf '[{"name":["users"],"description":["Users"]}]'
  exit 0
fi
if [[ "$1" == "system" && "$2" == "oauth2" && "$3" == "list" ]]; then
  printf '[]'
  exit 0
fi
echo "unexpected args: $*" >&2
exit 1
"#,
        );

        let output = doctor(&context(), &cli, false).expect("doctor");
        assert!(output.human.contains("Users: unavailable"));
        assert!(output.human.contains("Errors:"));
        assert_eq!(output.details["counts"]["groups"], 1);
        assert!(output.details["counts"]["users"].is_null());
    }

    #[test]
    fn doctor_includes_next_step_when_session_missing() {
        let cli = stub_cli(
            r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "session" && "$2" == "list" ]]; then
  printf 'No valid auth tokens found\n' >&2
  exit 1
fi
if [[ "$1" == "person" && "$2" == "list" ]]; then
  printf '[]'
  exit 0
fi
if [[ "$1" == "group" && "$2" == "list" ]]; then
  printf '[]'
  exit 0
fi
if [[ "$1" == "system" && "$2" == "oauth2" && "$3" == "list" ]]; then
  printf '[]'
  exit 0
fi
echo "unexpected args: $*" >&2
exit 1
"#,
        );

        let output = doctor(&context(), &cli, false).expect("doctor");
        assert!(output.human.contains("Session: missing"));
        assert!(output.human.contains("Run `kanidm-admin session login`"));
    }

    #[test]
    fn doctor_surfaces_parse_warnings() {
        let cli = stub_cli(
            r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "session" && "$2" == "list" ]]; then
  printf 'authenticated'
  exit 0
fi
if [[ "$1" == "person" && "$2" == "list" ]]; then
  printf '[{"bad":"entry"}]'
  exit 0
fi
if [[ "$1" == "group" && "$2" == "list" ]]; then
  printf '[]'
  exit 0
fi
if [[ "$1" == "system" && "$2" == "oauth2" && "$3" == "list" ]]; then
  printf '[]'
  exit 0
fi
echo "unexpected args: $*" >&2
exit 1
"#,
        );

        let output = doctor(&context(), &cli, false).expect("doctor");
        assert!(output.human.contains("Warnings:"));
        assert!(output.human.contains("skipped malformed"));
        assert_eq!(output.details["counts"]["users"], 0);
    }

    #[test]
    fn doctor_reports_vaultwarden_local_helper_context_success() {
        let cli = stub_cli(
            r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "session" && "$2" == "list" ]]; then
  printf 'authenticated'
  exit 0
fi
if [[ "$1" == "person" && "$2" == "list" ]]; then
  printf '[]'
  exit 0
fi
if [[ "$1" == "group" && "$2" == "list" ]]; then
  printf '[{"name":["users"]}]'
  exit 0
fi
if [[ "$1" == "system" && "$2" == "oauth2" && "$3" == "list" ]]; then
  printf '[]'
  exit 0
fi
echo "unexpected args: $*" >&2
exit 1
"#,
        );

        let output = doctor(&context(), &cli, false).expect("doctor");
        assert!(output
            .human
            .contains("Vaultwarden Local Helper: local invite helper context is configured"));
        assert_eq!(output.details["probes"]["vaultwarden"]["status"], "ok");
        assert_eq!(
            output.details["probes"]["vaultwarden"]["url_configured"],
            true
        );
        assert_eq!(
            output.details["probes"]["vaultwarden"]["admin_token_file_configured"],
            true
        );
    }

    #[test]
    fn doctor_warns_when_vaultwarden_helper_context_is_incomplete() {
        let cli = stub_cli(
            r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "session" && "$2" == "list" ]]; then
  printf 'authenticated'
  exit 0
fi
if [[ "$1" == "person" && "$2" == "list" ]]; then
  printf '[]'
  exit 0
fi
if [[ "$1" == "group" && "$2" == "list" ]]; then
  printf '[]'
  exit 0
fi
if [[ "$1" == "system" && "$2" == "oauth2" && "$3" == "list" ]]; then
  printf '[]'
  exit 0
fi
echo "unexpected args: $*" >&2
exit 1
"#,
        );

        let mut context = context();
        context.vaultwarden_url = None;
        context.vaultwarden_admin_token_file = None;
        let output = doctor(&context, &cli, false).expect("doctor");
        assert_eq!(output.details["probes"]["vaultwarden"]["status"], "warning");
        assert_eq!(
            output.details["probes"]["vaultwarden"]["url_configured"],
            false
        );
        assert_eq!(
            output.details["probes"]["vaultwarden"]["admin_token_file_configured"],
            false
        );
        assert!(output
            .human
            .contains("Vaultwarden Local Helper: local invite helper context is incomplete"));
    }

    #[test]
    fn deep_doctor_render_groups_failures_with_commands_and_fixes() {
        let rendered = render_deep_checks(&[
            RuntimeCheckReport {
                id: "doctor.systemd.files_sftp_sshd.active".to_string(),
                label: "files SFTP sshd service is active".to_string(),
                required: false,
                status: CheckStatus::Failed,
                command: Some("systemctl is-active files-sftp-sshd.service".to_string()),
                summary: "files-sftp-sshd.service is inactive".to_string(),
                detail: Some("inactive".to_string()),
                probe: None,
            },
            RuntimeCheckReport {
                id: "doctor.history.permissions".to_string(),
                label: "kanidm-admin history directory is private".to_string(),
                required: false,
                status: CheckStatus::Passed,
                command: None,
                summary: "mode 700".to_string(),
                detail: None,
                probe: None,
            },
        ]);

        assert!(rendered.contains("Deep Runtime Checks:"));
        assert!(rendered.contains("Failed:"));
        assert!(rendered.contains("command: systemctl is-active files-sftp-sshd.service"));
        assert!(rendered.contains("Most likely fix:"));
        assert!(rendered.contains("Passed:"));
    }
}
