use std::{
    env,
    fs::{self, OpenOptions},
    io::{BufRead, BufReader, Write},
    path::{Path, PathBuf},
};

use serde_json::{json, Value};
use time::{Duration, OffsetDateTime};

use crate::{output::CommandOutput, AppError};

const HISTORY_DIR_ENV: &str = "KANIDM_ADMIN_HISTORY_DIR";
const HISTORY_FILE: &str = "operations.jsonl";

pub fn record_operation_best_effort(
    args: &[String],
    result: &Result<Option<CommandOutput>, AppError>,
) {
    let Ok(dir) = history_dir() else {
        return;
    };
    if fs::create_dir_all(&dir).is_err() {
        return;
    }
    let Ok(mut file) = OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join(HISTORY_FILE))
    else {
        return;
    };

    let timestamp = OffsetDateTime::now_utc();
    let operation_id = format!(
        "{}-{}",
        timestamp
            .format(&time::format_description::well_known::Rfc3339)
            .unwrap_or_else(|_| timestamp.unix_timestamp().to_string())
            .replace([':', '.'], "-"),
        std::process::id()
    );
    let (status, message, details, warnings) = match result {
        Ok(Some(output)) => (
            "ok",
            output.message.clone(),
            output.details.clone(),
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
            error.human_message(),
            error.json_payload(),
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

pub fn prune_history(older_than: &str) -> Result<CommandOutput, AppError> {
    let duration = parse_history_duration(older_than)?;
    let cutoff = OffsetDateTime::now_utc() - duration;
    let path = history_file_path()?;
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
    let mut file = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(&path)
        .map_err(|error| AppError::Io {
            message: format!(
                "failed to rewrite history file '{}': {error}",
                path.display()
            ),
        })?;
    for entry in &retained {
        writeln!(file, "{entry}").map_err(|error| AppError::Io {
            message: format!("failed to write history file '{}': {error}", path.display()),
        })?;
    }
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
    use super::*;

    #[test]
    fn parses_history_duration_units() {
        assert_eq!(parse_history_duration("2d").unwrap(), Duration::days(2));
        assert_eq!(parse_history_duration("3h").unwrap(), Duration::hours(3));
        assert_eq!(
            parse_history_duration("45m").unwrap(),
            Duration::minutes(45)
        );
    }
}
