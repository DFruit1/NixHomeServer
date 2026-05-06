use serde_json::{json, Value};

use crate::{
    context::ResolvedContext,
    inventory::{clients::parse_client_list, groups::parse_group_list, users::parse_user_list},
    kanidm_cli::{BaseSessionState, KanidmCli, PrivilegedWriteState},
    output::CommandOutput,
    AppError,
};

pub fn show_context(context: &ResolvedContext) -> CommandOutput {
    let repo_root = context
        .repo_root
        .as_ref()
        .map(|path| path.display().to_string());
    let kanidm_bin = context.kanidm_bin.to_string_lossy().to_string();

    CommandOutput {
        message: "loaded kanidm-admin context".to_string(),
        human: format!(
            "Repository Root: {}\nServer URL: {}\nAdmin Name: {}\nKanidm Binary: {}",
            repo_root.as_deref().unwrap_or("(not resolved)"),
            context.server_url,
            context.admin_name,
            kanidm_bin,
        ),
        details: json!({
            "repo_root": repo_root,
            "server_url": context.server_url,
            "admin_name": context.admin_name,
            "kanidm_bin": kanidm_bin,
        }),
        warnings: Vec::new(),
    }
}

pub fn doctor(context: &ResolvedContext, cli: &KanidmCli) -> Result<CommandOutput, AppError> {
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
    };
    let repo_root = context
        .repo_root
        .as_ref()
        .map(|path| path.display().to_string());

    Ok(CommandOutput {
        message: "completed kanidm-admin doctor checks".to_string(),
        human: report.render_human(context),
        details: json!({
            "context": {
                "repo_root": repo_root,
                "server_url": context.server_url,
                "admin_name": context.admin_name,
                "kanidm_bin": context.kanidm_bin.to_string_lossy().to_string(),
            },
            "session": report.session.to_value(),
            "probes": {
                "users": report.users.to_value(),
                "groups": report.groups.to_value(),
                "clients": report.clients.to_value(),
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
}

impl DoctorReport {
    fn render_human(&self, context: &ResolvedContext) -> String {
        let mut body = format!(
            "Server URL: {}\nAdmin Name: {}\nSession: {}\nUsers: {}\nGroups: {}\nOAuth2 Clients: {}",
            context.server_url,
            context.admin_name,
            self.session.summary_line(),
            render_count(self.users.count),
            render_count(self.groups.count),
            render_count(self.clients.count),
        );

        let next_steps = self.session.next_steps();
        if !next_steps.is_empty() {
            body.push_str("\n\nNext Step:\n");
            body.push_str(&render_bullets(&next_steps));
        }

        let warnings = merge_lists(vec![
            self.users.warnings.clone(),
            self.groups.warnings.clone(),
            self.clients.warnings.clone(),
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
        errors
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

        let output = doctor(&context(), &cli).expect("doctor");
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

        let output = doctor(&context(), &cli).expect("doctor");
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

        let output = doctor(&context(), &cli).expect("doctor");
        assert!(output.human.contains("Warnings:"));
        assert!(output.human.contains("skipped malformed"));
        assert_eq!(output.details["counts"]["users"], 0);
    }
}
