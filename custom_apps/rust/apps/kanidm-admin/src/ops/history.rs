use std::{
    env,
    fs::{self, OpenOptions},
    io::{BufRead, BufReader, Write},
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
};

use serde_json::{json, Value};
use time::{Duration, OffsetDateTime};

use crate::{output::CommandOutput, sensitivity, AppError};

const HISTORY_DIR_ENV: &str = "KANIDM_ADMIN_HISTORY_DIR";
const HISTORY_FILE: &str = "operations.jsonl";

pub fn record_operation_best_effort(
    args: &[String],
    result: &Result<Option<CommandOutput>, AppError>,
) {
    let Ok(dir) = history_dir() else {
        return;
    };
    if ensure_history_dir_best_effort(&dir).is_err() {
        return;
    }
    let Ok(mut file) = OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(dir.join(HISTORY_FILE))
    else {
        return;
    };
    let _ = file.set_permissions(fs::Permissions::from_mode(0o600));

    let timestamp = OffsetDateTime::now_utc();
    let operation_id = format!(
        "{}-{}",
        timestamp
            .format(&time::format_description::well_known::Rfc3339)
            .unwrap_or_else(|_| timestamp.unix_timestamp().to_string())
            .replace([':', '.'], "-"),
        std::process::id()
    );
    let sensitive = sensitivity::invocation_args_are_sensitive(args) || result_is_sensitive(result);
    let (status, message, details, warnings) = match result {
        Ok(Some(output)) => (
            "ok",
            output.message.clone(),
            sanitize_history_value(output.details.clone(), sensitive),
            json!(output.warnings),
        ),
        Ok(None) => (
            "ok",
            "interactive command completed".to_string(),
            json!(null),
            json!([]),
        ),
        Err(error) => (
            "error",
            if sensitive {
                error.to_string()
            } else {
                error.human_message()
            },
            sanitize_history_value(error.json_payload(), sensitive),
            json!([]),
        ),
    };
    let entry = json!({
        "operation_id": operation_id,
        "timestamp": timestamp
            .format(&time::format_description::well_known::Rfc3339)
            .unwrap_or_else(|_| timestamp.to_string()),
        "command": args.first().cloned().unwrap_or_else(|| "kanidm-admin".to_string()),
        "args": args,
        "status": status,
        "message": message,
        "details": details,
        "warnings": warnings,
    });
    let _ = writeln!(file, "{entry}");
}

pub fn list_history() -> Result<CommandOutput, AppError> {
    let entries = read_history_entries()?;
    let latest = entries.into_iter().rev().take(25).collect::<Vec<_>>();
    Ok(CommandOutput {
        message: format!("loaded {} kanidm-admin history entries", latest.len()),
        human: if latest.is_empty() {
            "No kanidm-admin operation history entries were found.".to_string()
        } else {
            latest
                .iter()
                .map(|entry| {
                    format!(
                        "{}  {}  {}",
                        entry
                            .get("operation_id")
                            .and_then(Value::as_str)
                            .unwrap_or("(unknown)"),
                        entry
                            .get("status")
                            .and_then(Value::as_str)
                            .unwrap_or("unknown"),
                        entry.get("message").and_then(Value::as_str).unwrap_or("")
                    )
                })
                .collect::<Vec<_>>()
                .join("\n")
        },
        details: json!({
            "history_dir": history_dir()?.display().to_string(),
            "entries": latest,
        }),
        warnings: Vec::new(),
    })
}

pub fn show_history(operation_id: &str) -> Result<CommandOutput, AppError> {
    let entry = read_history_entries()?
        .into_iter()
        .find(|entry| entry.get("operation_id").and_then(Value::as_str) == Some(operation_id))
        .ok_or_else(|| AppError::NotFound {
            message: format!("history entry '{operation_id}' was not found"),
            resource: "history entry".to_string(),
            name: operation_id.to_string(),
            details: json!({ "operation_id": operation_id }),
        })?;
    Ok(CommandOutput {
        message: format!("loaded kanidm-admin history entry '{operation_id}'"),
        human: serde_json::to_string_pretty(&entry).unwrap_or_else(|_| entry.to_string()),
        details: json!({ "entry": entry }),
        warnings: Vec::new(),
    })
}

pub fn resume_history(operation_id: &str) -> Result<CommandOutput, AppError> {
    let entry = read_history_entries()?
        .into_iter()
        .find(|entry| entry.get("operation_id").and_then(Value::as_str) == Some(operation_id))
        .ok_or_else(|| AppError::NotFound {
            message: format!("history entry '{operation_id}' was not found"),
            resource: "history entry".to_string(),
            name: operation_id.to_string(),
            details: json!({ "operation_id": operation_id }),
        })?;
    let args = history_entry_args(&entry).ok_or_else(|| AppError::Config {
        message: format!("history entry '{operation_id}' does not contain replayable args"),
    })?;
    if args.is_empty() {
        return Err(AppError::Config {
            message: format!("history entry '{operation_id}' contains an empty command"),
        });
    }
    if history_entry_looks_sensitive(&entry) || args.iter().any(|arg| arg == sensitivity::REDACTED)
    {
        return Err(AppError::Unsupported {
            message: format!(
                "history entry '{operation_id}' cannot be resumed because it contains sensitive or redacted data"
            ),
            details: json!({ "operation_id": operation_id }),
        });
    }

    let retry_command = render_shell_command(&args);
    let status = entry
        .get("status")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    Ok(CommandOutput {
        message: format!("prepared retry command for history entry '{operation_id}'"),
        human: format!(
            "Retry command:\n{retry_command}\n\nNo command was executed. Review the command before running it."
        ),
        details: json!({
            "operation_id": operation_id,
            "status": status,
            "args": args,
            "retry_command": retry_command,
            "executed": false,
        }),
        warnings: Vec::new(),
    })
}

pub fn prune_history(older_than: &str) -> Result<CommandOutput, AppError> {
    let duration = parse_history_duration(older_than)?;
    let cutoff = OffsetDateTime::now_utc() - duration;
    let path = writable_history_file_path()?;
    if !path.exists() {
        return Ok(CommandOutput {
            message: "no kanidm-admin history file exists".to_string(),
            human: "No kanidm-admin history file exists.".to_string(),
            details: json!({ "removed": 0, "history_file": path.display().to_string() }),
            warnings: Vec::new(),
        });
    }
    let entries = read_history_entries()?;
    let before = entries.len();
    let retained = entries
        .into_iter()
        .filter(|entry| {
            entry
                .get("timestamp")
                .and_then(Value::as_str)
                .and_then(parse_timestamp)
                .is_none_or(|timestamp| timestamp >= cutoff)
        })
        .collect::<Vec<_>>();
    let removed = before.saturating_sub(retained.len());
    rewrite_history_entries(&path, &retained)?;
    Ok(CommandOutput {
        message: format!("pruned {removed} kanidm-admin history entries"),
        human: format!("Pruned {removed} history entries older than {older_than}."),
        details: json!({
            "removed": removed,
            "retained": retained.len(),
            "history_file": path.display().to_string(),
        }),
        warnings: Vec::new(),
    })
}

pub fn redact_sensitive_history() -> Result<CommandOutput, AppError> {
    let path = writable_history_file_path()?;
    if !path.exists() {
        return Ok(CommandOutput {
            message: "no kanidm-admin history file exists".to_string(),
            human: "No kanidm-admin history file exists.".to_string(),
            details: json!({ "redacted": 0, "history_file": path.display().to_string() }),
            warnings: Vec::new(),
        });
    }

    let entries = read_history_entries()?;
    let mut redacted = 0usize;
    let entries = entries
        .into_iter()
        .map(|entry| {
            let sanitized = sanitize_legacy_history_entry(entry.clone());
            if sanitized != entry {
                redacted = redacted.saturating_add(1);
            }
            sanitized
        })
        .collect::<Vec<_>>();
    rewrite_history_entries(&path, &entries)?;

    let entry_label = if redacted == 1 { "entry" } else { "entries" };
    Ok(CommandOutput {
        message: format!("redacted {redacted} sensitive kanidm-admin history {entry_label}"),
        human: format!("Redacted sensitive fields in {redacted} history {entry_label}."),
        details: json!({
            "redacted": redacted,
            "retained": entries.len(),
            "history_file": path.display().to_string(),
        }),
        warnings: Vec::new(),
    })
}

fn rewrite_history_entries(path: &Path, entries: &[Value]) -> Result<(), AppError> {
    let directory = path.parent().ok_or_else(|| AppError::Io {
        message: format!(
            "failed to derive parent directory for history file '{}'",
            path.display()
        ),
    })?;
    let temp_path = history_temp_path(path);
    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(&temp_path)
        .map_err(|error| AppError::Io {
            message: format!(
                "failed to open temporary history file '{}': {error}",
                temp_path.display()
            ),
        })?;
    if let Err(error) = file.set_permissions(fs::Permissions::from_mode(0o600)) {
        cleanup_history_temp_file(&temp_path);
        return Err(AppError::Io {
            message: format!(
                "failed to set temporary history file permissions '{}': {error}",
                temp_path.display()
            ),
        });
    }
    for entry in entries {
        if let Err(error) = writeln!(file, "{entry}") {
            cleanup_history_temp_file(&temp_path);
            return Err(AppError::Io {
                message: format!(
                    "failed to write temporary history file '{}': {error}",
                    temp_path.display()
                ),
            });
        }
    }
    if let Err(error) = file.sync_all() {
        cleanup_history_temp_file(&temp_path);
        return Err(AppError::Io {
            message: format!(
                "failed to fsync temporary history file '{}': {error}",
                temp_path.display()
            ),
        });
    }
    drop(file);

    if let Err(error) = fs::rename(&temp_path, path) {
        cleanup_history_temp_file(&temp_path);
        return Err(AppError::Io {
            message: format!(
                "failed to replace history file '{}' with '{}': {error}",
                path.display(),
                temp_path.display()
            ),
        });
    }
    best_effort_directory_sync(directory);
    Ok(())
}

fn history_temp_path(path: &Path) -> PathBuf {
    let name = path
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or(HISTORY_FILE);
    let timestamp = OffsetDateTime::now_utc().unix_timestamp_nanos();
    path.with_file_name(format!(".{name}.tmp-{}-{timestamp}", std::process::id()))
}

fn cleanup_history_temp_file(path: &Path) {
    let _ = fs::remove_file(path);
}

fn best_effort_directory_sync(directory: &Path) {
    if let Ok(dir) = fs::File::open(directory) {
        let _ = dir.sync_all();
    }
}

fn read_history_entries() -> Result<Vec<Value>, AppError> {
    let path = history_file_path()?;
    if !path.exists() {
        return Ok(Vec::new());
    }
    let file = fs::File::open(&path).map_err(|error| AppError::Io {
        message: format!("failed to open history file '{}': {error}", path.display()),
    })?;
    let reader = BufReader::new(file);
    let mut entries = Vec::new();
    for line in reader.lines() {
        let line = line.map_err(|error| AppError::Io {
            message: format!("failed to read history file '{}': {error}", path.display()),
        })?;
        if line.trim().is_empty() {
            continue;
        }
        let entry = serde_json::from_str::<Value>(&line).map_err(|error| AppError::Json {
            message: format!("history file '{}' contains invalid JSONL", path.display()),
            details: json!({ "error": error.to_string(), "line": line }),
        })?;
        entries.push(entry);
    }
    Ok(entries)
}

fn history_file_path() -> Result<PathBuf, AppError> {
    Ok(history_dir()?.join(HISTORY_FILE))
}

fn writable_history_file_path() -> Result<PathBuf, AppError> {
    let dir = history_dir()?;
    ensure_history_dir(&dir)?;
    Ok(dir.join(HISTORY_FILE))
}

fn ensure_history_dir_best_effort(dir: &Path) -> std::io::Result<()> {
    fs::create_dir_all(dir)?;
    fs::set_permissions(dir, fs::Permissions::from_mode(0o700))
}

fn ensure_history_dir(dir: &Path) -> Result<(), AppError> {
    ensure_history_dir_best_effort(dir).map_err(|error| AppError::Io {
        message: format!(
            "failed to prepare history directory '{}': {error}",
            dir.display()
        ),
    })
}

fn history_dir() -> Result<PathBuf, AppError> {
    if let Some(value) = env::var_os(HISTORY_DIR_ENV) {
        return Ok(PathBuf::from(value));
    }
    let system = Path::new("/var/lib/kanidm-admin/history");
    if system.exists() {
        return Ok(system.to_path_buf());
    }
    let home = env::var_os("HOME").ok_or_else(|| AppError::Config {
        message: format!("{HISTORY_DIR_ENV} is not set and HOME is unavailable"),
    })?;
    Ok(PathBuf::from(home).join(".local/state/kanidm-admin/history"))
}

fn result_is_sensitive(result: &Result<Option<CommandOutput>, AppError>) -> bool {
    match result {
        Ok(Some(output)) => output.is_sensitive(),
        Ok(None) | Err(_) => false,
    }
}

fn sanitize_history_value(value: Value, sensitive: bool) -> Value {
    if !sensitive {
        return value;
    }
    sensitivity::sanitize_sensitive_value(value)
}

fn sanitize_legacy_history_entry(entry: Value) -> Value {
    if history_entry_looks_sensitive(&entry) {
        sensitivity::sanitize_sensitive_value(entry)
    } else {
        entry
    }
}

fn history_entry_looks_sensitive(entry: &Value) -> bool {
    history_entry_args(entry)
        .as_deref()
        .is_some_and(sensitivity::invocation_args_are_sensitive)
        || value_contains_sensitive_history_shape(entry)
}

fn history_entry_args(entry: &Value) -> Option<Vec<String>> {
    history_args_array(entry.get("args")?).or_else(|| {
        entry
            .get("command")?
            .get("args")
            .and_then(history_args_array)
    })
}

fn history_args_array(value: &Value) -> Option<Vec<String>> {
    value
        .as_array()?
        .iter()
        .map(|value| value.as_str().map(ToOwned::to_owned))
        .collect()
}

fn render_shell_command(args: &[String]) -> String {
    args.iter()
        .map(|arg| shell_quote(arg))
        .collect::<Vec<_>>()
        .join(" ")
}

fn shell_quote(value: &str) -> String {
    if !value.is_empty()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"-_./:=@+".contains(&byte))
    {
        return value.to_string();
    }
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}

fn value_contains_sensitive_history_shape(value: &Value) -> bool {
    match value {
        Value::Object(map) => {
            map.get("sensitive").and_then(Value::as_bool) == Some(true)
                || map.contains_key("reset_token")
                || map
                    .get("args")
                    .and_then(history_args_array)
                    .as_deref()
                    .is_some_and(sensitivity::invocation_args_are_sensitive)
                || map
                    .get("backend_steps")
                    .and_then(Value::as_array)
                    .is_some_and(|steps| {
                        steps.iter().any(|step| {
                            step.get("args")
                                .and_then(Value::as_array)
                                .and_then(|args| {
                                    args.iter()
                                        .map(|value| value.as_str().map(ToOwned::to_owned))
                                        .collect::<Option<Vec<_>>>()
                                })
                                .as_deref()
                                .is_some_and(sensitivity::invocation_args_are_sensitive)
                        })
                    })
                || map.get("redaction").is_some_and(|value| !value.is_null())
                || map.values().any(value_contains_sensitive_history_shape)
        }
        Value::Array(values) => values.iter().any(value_contains_sensitive_history_shape),
        _ => false,
    }
}

fn parse_history_duration(value: &str) -> Result<Duration, AppError> {
    let (number, unit) = value.trim().split_at(
        value
            .find(|ch: char| !ch.is_ascii_digit())
            .unwrap_or(value.len()),
    );
    let amount = number.parse::<i64>().map_err(|_| AppError::Config {
        message: "history duration must look like 30d, 12h, or 90m".to_string(),
    })?;
    match unit {
        "d" | "day" | "days" => Ok(Duration::days(amount)),
        "h" | "hour" | "hours" => Ok(Duration::hours(amount)),
        "m" | "min" | "mins" | "minute" | "minutes" => Ok(Duration::minutes(amount)),
        _ => Err(AppError::Config {
            message: "history duration unit must be d, h, or m".to_string(),
        }),
    }
}

fn parse_timestamp(value: &str) -> Option<OffsetDateTime> {
    OffsetDateTime::parse(value, &time::format_description::well_known::Rfc3339).ok()
}

#[cfg(test)]
mod tests {
    use std::{env, ffi::OsString, os::unix::fs::PermissionsExt, path::Path};

    use crate::TEST_ENV_LOCK;

    use super::*;

    struct EnvVarGuard {
        name: &'static str,
        original: Option<OsString>,
    }

    impl EnvVarGuard {
        fn set_path(name: &'static str, value: &Path) -> Self {
            let original = env::var_os(name);
            env::set_var(name, value);
            Self { name, original }
        }
    }

    impl Drop for EnvVarGuard {
        fn drop(&mut self) {
            match &self.original {
                Some(value) => env::set_var(self.name, value),
                None => env::remove_var(self.name),
            }
        }
    }

    #[test]
    fn parses_history_duration_units() {
        assert_eq!(parse_history_duration("2d").unwrap(), Duration::days(2));
        assert_eq!(parse_history_duration("3h").unwrap(), Duration::hours(3));
        assert_eq!(
            parse_history_duration("45m").unwrap(),
            Duration::minutes(45)
        );
    }

    #[test]
    fn redacts_sensitive_reset_token_history() {
        let value = json!({
            "reset_token": {
                "raw_output": "Reset token: SECRET123",
                "token": "SECRET123",
                "reset_url": "https://id.example.test/ui/reset?token=SECRET123",
            },
            "backend_steps": [
                {
                    "stdout": "Reset token: SECRET123",
                    "stderr": "SECRET123",
                    "args": ["person", "credential", "create-reset-token", "alice"],
                }
            ],
        });

        let sanitized = sanitize_history_value(value, true);
        let rendered = serde_json::to_string(&sanitized).expect("history json");

        assert!(!rendered.contains("SECRET123"));
        assert!(rendered.contains(sensitivity::REDACTED));
    }

    #[test]
    fn history_file_is_private_when_recorded() {
        let _guard = TEST_ENV_LOCK.lock().expect("env lock");
        let dir = tempfile::tempdir().expect("tempdir");
        let _history_dir = EnvVarGuard::set_path(HISTORY_DIR_ENV, dir.path());

        let output = CommandOutput {
            message: "done".to_string(),
            human: "done".to_string(),
            details: json!({ "ok": true }),
            warnings: Vec::new(),
        };
        record_operation_best_effort(
            &["kanidm-admin".to_string(), "doctor".to_string()],
            &Ok(Some(output)),
        );

        let history_dir_mode = fs::metadata(dir.path())
            .expect("history dir metadata")
            .permissions()
            .mode()
            & 0o777;
        let history_file_mode = fs::metadata(dir.path().join(HISTORY_FILE))
            .expect("history file metadata")
            .permissions()
            .mode()
            & 0o777;

        assert_eq!(history_dir_mode, 0o700);
        assert_eq!(history_file_mode, 0o600);
    }

    #[test]
    fn persisted_sensitive_history_is_redacted() {
        let _guard = TEST_ENV_LOCK.lock().expect("env lock");
        let dir = tempfile::tempdir().expect("tempdir");
        let _history_dir = EnvVarGuard::set_path(HISTORY_DIR_ENV, dir.path());

        let output = CommandOutput {
            message: "created a password reset token for 'alice'".to_string(),
            human: "secret output".to_string(),
            details: json!({
                "reset_token": {
                    "raw_output": "Reset token: SECRET123",
                    "token": "SECRET123",
                    "reset_url": "https://id.example.test/ui/reset?token=SECRET123",
                },
                "backend_steps": [
                    {
                        "stdout": "Reset token: SECRET123",
                        "stderr": "",
                    }
                ],
            }),
            warnings: Vec::new(),
        };
        record_operation_best_effort(
            &[
                "kanidm-admin".to_string(),
                "user".to_string(),
                "reset-token".to_string(),
                "alice".to_string(),
            ],
            &Ok(Some(output)),
        );

        let persisted =
            fs::read_to_string(dir.path().join(HISTORY_FILE)).expect("history file contents");
        assert!(!persisted.contains("SECRET123"));
        assert!(persisted.contains(sensitivity::REDACTED));
    }

    #[test]
    fn redacts_existing_sensitive_history_file() {
        let _guard = TEST_ENV_LOCK.lock().expect("env lock");
        let dir = tempfile::tempdir().expect("tempdir");
        let _history_dir = EnvVarGuard::set_path(HISTORY_DIR_ENV, dir.path());
        fs::write(
            dir.path().join(HISTORY_FILE),
            format!(
                "{}\n{}\n",
                json!({
                "args": ["kanidm-admin", "client", "secret", "show", "files"],
                "status": "ok",
                "details": {
                    "raw_output": "CLIENT_SECRET_XYZ",
                    "backend_steps": [
                        {
                            "args": ["system", "oauth2", "show-basic-secret", "files"],
                            "stdout": "CLIENT_SECRET_XYZ",
                            "stderr": "",
                        }
                    ]
                }
                }),
                json!({
                    "command": {
                        "args": ["user", "reset-token", "alice"],
                        "details": {
                            "raw_output": "https://id.example/reset?token=RESET_TOKEN_ABC",
                            "reset_token": "RESET_TOKEN_ABC",
                        }
                    },
                    "result": {
                        "details": {
                            "reset_token": "RESET_TOKEN_ABC",
                        }
                    },
                    "backend": [
                        {
                            "args": ["person", "credential", "create-reset-token", "alice"],
                            "stdout": "RESET_TOKEN_ABC",
                            "stderr": "",
                        }
                    ]
                })
            ),
        )
        .expect("history file");

        let output = redact_sensitive_history().expect("redact history");
        assert_eq!(output.details["redacted"], 2);

        let persisted =
            fs::read_to_string(dir.path().join(HISTORY_FILE)).expect("history contents");
        assert!(!persisted.contains("CLIENT_SECRET_XYZ"));
        assert!(!persisted.contains("RESET_TOKEN_ABC"));
        assert!(persisted.contains(sensitivity::REDACTED));
    }

    #[test]
    fn resume_history_prepares_retry_command_without_executing() {
        let _guard = TEST_ENV_LOCK.lock().expect("env lock");
        let dir = tempfile::tempdir().expect("tempdir");
        let _history_dir = EnvVarGuard::set_path(HISTORY_DIR_ENV, dir.path());
        fs::write(
            dir.path().join(HISTORY_FILE),
            format!(
                "{}\n",
                json!({
                    "operation_id": "op-1",
                    "timestamp": "2026-01-01T00:00:00Z",
                    "args": [
                        "kanidm-admin",
                        "--server-url",
                        "https://id.example.test",
                        "membership",
                        "add",
                        "alice",
                        "files users"
                    ],
                    "status": "error",
                    "message": "failed",
                    "details": null,
                    "warnings": [],
                })
            ),
        )
        .expect("history file");

        let output = resume_history("op-1").expect("resume history");

        assert_eq!(output.details["executed"], false);
        assert_eq!(output.details["status"], "error");
        assert!(output.human.contains("No command was executed"));
        assert!(output.human.contains(
            "kanidm-admin --server-url https://id.example.test membership add alice 'files users'"
        ));
    }

    #[test]
    fn resume_history_refuses_sensitive_entries() {
        let _guard = TEST_ENV_LOCK.lock().expect("env lock");
        let dir = tempfile::tempdir().expect("tempdir");
        let _history_dir = EnvVarGuard::set_path(HISTORY_DIR_ENV, dir.path());
        fs::write(
            dir.path().join(HISTORY_FILE),
            format!(
                "{}\n",
                json!({
                    "operation_id": "op-secret",
                    "timestamp": "2026-01-01T00:00:00Z",
                    "args": ["kanidm-admin", "user", "reset-token", "alice"],
                    "status": "ok",
                    "details": { "reset_token": sensitivity::REDACTED },
                })
            ),
        )
        .expect("history file");

        let error = resume_history("op-secret").expect_err("sensitive history should not resume");

        assert!(matches!(error, AppError::Unsupported { .. }));
    }
}
