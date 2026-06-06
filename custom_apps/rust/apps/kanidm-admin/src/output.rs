use clap::ValueEnum;
use console::style;
use serde::Serialize;
use serde_json::{json, Value};

use crate::AppError;

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum OutputFormat {
    Human,
    Json,
}

#[derive(Debug, Clone)]
pub struct CommandOutput {
    pub message: String,
    pub human: String,
    pub details: Value,
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Sensitivity {
    Normal,
    Sensitive,
}

impl CommandOutput {
    pub fn new(
        message: impl Into<String>,
        human: impl Into<String>,
        details: impl Serialize,
    ) -> Self {
        Self {
            message: message.into(),
            human: human.into(),
            details: serde_json::to_value(details).unwrap_or(Value::Null),
            warnings: Vec::new(),
        }
    }

    pub fn with_warnings(mut self, warnings: Vec<String>) -> Self {
        self.warnings = warnings;
        self
    }

    pub fn with_sensitivity(mut self, sensitivity: Sensitivity) -> Self {
        if sensitivity == Sensitivity::Sensitive {
            match &mut self.details {
                Value::Object(map) => {
                    map.insert("sensitive".to_string(), Value::Bool(true));
                }
                other => {
                    self.details = json!({
                        "sensitive": true,
                        "value": std::mem::take(other),
                    });
                }
            }
        }
        self
    }

    pub fn is_sensitive(&self) -> bool {
        self.details
            .get("sensitive")
            .and_then(Value::as_bool)
            .unwrap_or(false)
    }

    pub fn render_human(&self) -> String {
        let mut body = self.human.clone();
        if let Some(backend) = render_backend_steps_summary(self.details.get("backend_steps")) {
            body.push_str(&format!("\n\n{}:\n", section_title("Backend Commands")));
            body.push_str(&backend);
        }

        if self.warnings.is_empty() {
            body
        } else {
            format!(
                "{}\n\n{}:\n{}",
                body,
                warning_text("Warnings"),
                self.warnings
                    .iter()
                    .map(|warning| format!("- {warning}"))
                    .collect::<Vec<_>>()
                    .join("\n")
            )
        }
    }

    pub fn json_payload(&self) -> Value {
        json!({
            "status": "ok",
            "message": self.message,
            "sensitive": self.is_sensitive(),
            "details": self.details,
            "warnings": self.warnings,
        })
    }
}

pub fn render_backend_steps_summary(value: Option<&Value>) -> Option<String> {
    let steps = value.and_then(Value::as_array)?;
    if steps.is_empty() {
        return None;
    }

    let collapsed = collapse_backend_steps(steps);
    let failed = collapsed
        .iter()
        .filter(|entry| !backend_step_succeeded(entry.step))
        .collect::<Vec<_>>();
    if failed.is_empty() {
        let unique = collapsed.len();
        let total = steps.len();
        let note = if total == 1 {
            "1 successful backend command suppressed; open Show Backend Logs for raw output."
                .to_string()
        } else if unique == total {
            format!(
                "{total} successful backend commands suppressed; open Show Backend Logs for raw output."
            )
        } else {
            format!(
                "{total} successful backend commands suppressed ({unique} unique); open Show Backend Logs for raw output."
            )
        };
        return Some(dim_text(&note));
    }

    let mut rendered = failed
        .iter()
        .map(|entry| render_backend_step_summary(entry.step, entry.count))
        .collect::<Vec<_>>();
    let rendered_success_count = if let Some(last_success) = collapsed
        .iter()
        .rev()
        .find(|entry| backend_step_succeeded(entry.step))
    {
        rendered.push(format!(
            "{}\n{}",
            dim_text("Last successful backend command:"),
            render_backend_step_summary(last_success.step, last_success.count)
        ));
        last_success.count
    } else {
        0
    };
    let successful_count = collapsed
        .iter()
        .filter(|entry| backend_step_succeeded(entry.step))
        .map(|entry| entry.count)
        .sum::<usize>();
    let suppressed_success_count = successful_count.saturating_sub(rendered_success_count);
    if suppressed_success_count > 0 {
        rendered.push(dim_text(&format!(
            "{suppressed_success_count} additional successful backend command(s) suppressed; open Show Backend Logs for raw output."
        )));
    }
    (!rendered.is_empty()).then(|| rendered.join("\n\n"))
}

pub fn render_backend_steps_full(value: Option<&Value>) -> Option<String> {
    let steps = value.and_then(Value::as_array)?;
    let rendered = steps
        .iter()
        .map(render_backend_step_full)
        .collect::<Vec<_>>();
    (!rendered.is_empty()).then(|| rendered.join("\n\n"))
}

struct CollapsedBackendStep<'a> {
    step: &'a Value,
    count: usize,
}

fn collapse_backend_steps(steps: &[Value]) -> Vec<CollapsedBackendStep<'_>> {
    let mut collapsed: Vec<CollapsedBackendStep<'_>> = Vec::new();
    for step in steps {
        let key = backend_step_summary_key(step);
        if let Some(existing) = collapsed
            .iter_mut()
            .find(|entry| backend_step_summary_key(entry.step) == key)
        {
            existing.count += 1;
        } else {
            collapsed.push(CollapsedBackendStep { step, count: 1 });
        }
    }
    collapsed
}

fn backend_step_summary_key(step: &Value) -> String {
    format!(
        "{}\n{}\n{}\n{}\n{}",
        step.get("step").and_then(Value::as_str).unwrap_or(""),
        step.get("program").and_then(Value::as_str).unwrap_or(""),
        step.get("mode").and_then(Value::as_str).unwrap_or(""),
        step.get("args")
            .and_then(Value::as_array)
            .map(|args| {
                args.iter()
                    .filter_map(Value::as_str)
                    .collect::<Vec<_>>()
                    .join("\u{1f}")
            })
            .unwrap_or_default(),
        render_status_plain(step),
    )
}

fn backend_step_succeeded(step: &Value) -> bool {
    step.get("status")
        .and_then(|status| status.get("success"))
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

fn render_backend_step_summary(step: &Value, count: usize) -> String {
    let label = step
        .get("step")
        .and_then(Value::as_str)
        .unwrap_or("backend command");
    let status = render_status(step);
    let mut lines = vec![
        format!(
            "{} {label} {}",
            style("==").cyan().dim(),
            style("==").cyan().dim()
        ),
        format!("{}: {status}", field_label("Status")),
    ];
    if count > 1 {
        lines.push(format!("{}: {count} times", field_label("Repeated")));
    }
    if let Some(command) = render_command(step) {
        lines.push(format!("{}: {command}", field_label("Command")));
    }
    if let Some(mode) = step.get("mode").and_then(Value::as_str) {
        lines.push(format!("{}: {mode}", field_label("Mode")));
    }
    if step.get("redaction").is_some_and(|value| !value.is_null()) {
        lines.push(dim_text(
            "Backend stdout/stderr was redacted for this command.",
        ));
    } else if has_text(step, "stdout")
        || has_text(step, "stderr")
        || step.get("error").is_some_and(|value| !value.is_null())
    {
        lines.push(dim_text(
            "Raw stdout/stderr is available from Show Backend Logs.",
        ));
    }
    lines.join("\n")
}

fn render_backend_step_full(step: &Value) -> String {
    let stdout = step
        .get("stdout")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim();
    let stderr = step
        .get("stderr")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim();
    let label = step
        .get("step")
        .and_then(Value::as_str)
        .unwrap_or("backend command");
    let mut lines = vec![
        format!(
            "{} {label} {}",
            style("==").cyan().dim(),
            style("==").cyan().dim()
        ),
        format!("{}: {}", field_label("Status"), render_status(step)),
    ];
    if let Some(sequence) = step.get("sequence").and_then(Value::as_u64) {
        lines.push(format!("{}: {sequence}", field_label("Sequence")));
    }
    if let Some(recorded_at) = step.get("recorded_at").and_then(Value::as_str) {
        lines.push(format!("{}: {recorded_at}", field_label("Recorded At")));
    }
    if let Some(mode) = step.get("mode").and_then(Value::as_str) {
        lines.push(format!("{}: {mode}", field_label("Mode")));
    }
    if let Some(command) = render_command(step) {
        lines.push(format!("{}: {command}", field_label("Command")));
    }
    if let Some(error) = step.get("error").filter(|value| !value.is_null()) {
        lines.push(format!(
            "exec error:\n{}",
            serde_json::to_string_pretty(error).unwrap_or_else(|_| error.to_string())
        ));
    }
    if !stdout.is_empty() {
        lines.push(format!("stdout:\n{stdout}"));
    }
    if !stderr.is_empty() {
        lines.push(format!("stderr:\n{stderr}"));
    }
    if stdout.is_empty() && stderr.is_empty() && step.get("error").is_none_or(Value::is_null) {
        lines.push("stdout/stderr: (empty)".to_string());
    }
    lines.join("\n")
}

fn render_command(step: &Value) -> Option<String> {
    let program = step.get("program").and_then(Value::as_str)?;
    let args = step
        .get("args")
        .and_then(Value::as_array)
        .map(|args| {
            args.iter()
                .filter_map(Value::as_str)
                .map(shell_quote_arg)
                .collect::<Vec<_>>()
                .join(" ")
        })
        .unwrap_or_default();

    Some(if args.is_empty() {
        program.to_string()
    } else {
        format!("{program} {args}")
    })
}

pub fn shell_quote_arg(value: &str) -> String {
    if value.is_empty() {
        return "''".to_string();
    }
    if value
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || "_@%+=:,./-".contains(ch))
    {
        value.to_string()
    } else {
        format!("'{}'", value.replace('\'', "'\\''"))
    }
}

fn render_status(step: &Value) -> String {
    let plain = render_status_plain(step);
    if plain.starts_with("success") {
        success_text(&plain)
    } else if plain.starts_with("failure") || plain.starts_with("exec error") {
        error_text(&plain)
    } else {
        warning_text(&plain)
    }
}

fn render_status_plain(step: &Value) -> String {
    if let Some(status) = step.get("status").filter(|status| !status.is_null()) {
        let success = status
            .get("success")
            .and_then(Value::as_bool)
            .map(|value| if value { "success" } else { "failure" })
            .unwrap_or("unknown");
        let code = status
            .get("code")
            .and_then(Value::as_i64)
            .map(|code| code.to_string())
            .unwrap_or_else(|| "none".to_string());
        format!("{success} (exit code: {code})")
    } else if let Some(error) = step.get("error").filter(|value| !value.is_null()) {
        let kind = error
            .get("kind")
            .and_then(Value::as_str)
            .unwrap_or("exec_error");
        format!("exec error ({kind})")
    } else {
        "unknown".to_string()
    }
}

fn has_text(step: &Value, field: &str) -> bool {
    step.get(field)
        .and_then(Value::as_str)
        .is_some_and(|value| !value.trim().is_empty())
}

pub fn render_output(format: OutputFormat, output: &CommandOutput) -> String {
    match format {
        OutputFormat::Human => output.render_human(),
        OutputFormat::Json => serde_json::to_string_pretty(&output.json_payload())
            .unwrap_or_else(|_| output.json_payload().to_string()),
    }
}

pub fn render_error(format: OutputFormat, error: &AppError) -> String {
    match format {
        OutputFormat::Human => {
            let mut body = colorize_error(&error.human_message());
            if let Some(summary) =
                render_backend_steps_summary(error_details(error).and_then(|details| {
                    details.get("backend_steps").or_else(|| {
                        details
                            .get("details")
                            .and_then(|nested| nested.get("backend_steps"))
                    })
                }))
            {
                body.push_str(&format!(
                    "\n\n{}:\n{summary}",
                    section_title("Backend Commands")
                ));
            }
            body
        }
        OutputFormat::Json => serde_json::to_string_pretty(&error.json_payload())
            .unwrap_or_else(|_| error.json_payload().to_string()),
    }
}

fn error_details(error: &AppError) -> Option<&Value> {
    match error {
        AppError::NotFound { details, .. }
        | AppError::AlreadyExists { details, .. }
        | AppError::Verification { details, .. }
        | AppError::PartialSuccess { details, .. }
        | AppError::SessionRequired { details, .. }
        | AppError::ReauthRequired { details, .. }
        | AppError::Json { details, .. }
        | AppError::BackendTimeout { details, .. }
        | AppError::InventoryIncomplete { details, .. }
        | AppError::Unsupported { details, .. } => Some(details),
        AppError::Config { .. }
        | AppError::MissingDependency { .. }
        | AppError::Backend { .. }
        | AppError::Io { .. } => None,
    }
}

pub fn section_title(value: &str) -> String {
    style(value).cyan().bold().to_string()
}

pub fn field_label(value: &str) -> String {
    style(value).cyan().to_string()
}

pub fn success_text(value: &str) -> String {
    style(value).green().to_string()
}

pub fn warning_text(value: &str) -> String {
    style(value).yellow().to_string()
}

pub fn error_text(value: &str) -> String {
    style(value).red().to_string()
}

pub fn dim_text(value: &str) -> String {
    style(value).dim().to_string()
}

pub fn status_text(value: &str) -> String {
    match value {
        "ok" | "ready" | "passed" | "success" | "yes" => success_text(value),
        "warning" | "unknown" | "skipped" | "partial" | "no" => warning_text(value),
        "error" | "failed" | "failure" | "not ready" => error_text(value),
        _ => value.to_string(),
    }
}

fn colorize_error(message: &str) -> String {
    message
        .lines()
        .enumerate()
        .map(|(index, line)| {
            if index == 0 {
                error_text(line)
            } else if matches!(
                line,
                "What happened:"
                    | "Expected state:"
                    | "Last observed state:"
                    | "Next action:"
                    | "Backend diagnostic:"
                    | "Raw output:"
                    | "Parser error:"
                    | "Command:"
                    | "Completed:"
                    | "Completed steps:"
                    | "Not yet confirmed:"
                    | "Failed step:"
                    | "Current observed state:"
                    | "Warnings:"
                    | "Most likely fix:"
            ) {
                section_title(line)
            } else if line.starts_with("- ") {
                dim_text(line)
            } else {
                line.to_string()
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn renders_json_success_payload() {
        let output = CommandOutput {
            message: "listed users".to_string(),
            human: "listed users".to_string(),
            details: json!({ "count": 1 }),
            warnings: vec!["example warning".to_string()],
        };

        let rendered = render_output(OutputFormat::Json, &output);
        assert!(rendered.contains("\"status\": \"ok\""));
        assert!(rendered.contains("\"count\": 1"));
        assert!(rendered.contains("\"warnings\""));
    }

    #[test]
    fn renders_sensitive_success_flag() {
        let output = CommandOutput {
            message: "secret".to_string(),
            human: "secret".to_string(),
            details: json!({ "sensitive": true }),
            warnings: Vec::new(),
        };

        let rendered = render_output(OutputFormat::Json, &output);
        assert!(rendered.contains("\"sensitive\": true"));
    }

    #[test]
    fn renders_human_warnings() {
        let output = CommandOutput {
            message: "done".to_string(),
            human: "done".to_string(),
            details: json!({}),
            warnings: vec!["warning one".to_string(), "warning two".to_string()],
        };

        let rendered = render_output(OutputFormat::Human, &output);
        assert!(rendered.contains("Warnings:"));
        assert!(rendered.contains("- warning one"));
    }

    #[test]
    fn renders_backend_steps_when_output_is_present() {
        let output = CommandOutput {
            message: "done".to_string(),
            human: "done".to_string(),
            details: json!({
                "backend_steps": [
                    {
                        "step": "write",
                        "program": "kanidm",
                        "args": ["person", "update"],
                        "status": { "success": true, "code": 0 },
                        "stdout": "updated\n",
                        "stderr": ""
                    }
                ]
            }),
            warnings: Vec::new(),
        };

        let rendered = render_output(OutputFormat::Human, &output);
        assert!(rendered.contains("Backend Commands:"));
        assert!(rendered.contains("1 successful backend command suppressed"));
        assert!(!rendered.contains("== write =="));
    }

    #[test]
    fn backend_summary_suppresses_repeated_successful_polling_commands() {
        let rendered = render_backend_steps_summary(Some(&json!([
            {
                "step": "local id -nG",
                "program": "id",
                "args": ["-nG", "dsaw"],
                "mode": "non_interactive_read",
                "status": { "success": true, "code": 0 },
                "stdout": "users\n",
                "stderr": ""
            },
            {
                "step": "local id -nG",
                "program": "id",
                "args": ["-nG", "dsaw"],
                "mode": "non_interactive_read",
                "status": { "success": true, "code": 0 },
                "stdout": "users\n",
                "stderr": ""
            }
        ])))
        .expect("rendered");

        assert!(rendered.contains("2 successful backend commands suppressed"));
        assert!(!rendered.contains("Command: id -nG dsaw"));
    }

    #[test]
    fn backend_summary_keeps_failures_and_suppresses_successes() {
        let rendered = render_backend_steps_summary(Some(&json!([
            {
                "step": "local getent passwd",
                "program": "getent",
                "args": ["passwd", "dsaw"],
                "mode": "non_interactive_read",
                "status": { "success": true, "code": 0 },
                "stdout": "dsaw:x:2000:2000::/home/dsaw:/bin/bash\n",
                "stderr": ""
            },
            {
                "step": "local findmnt",
                "program": "findmnt",
                "args": ["/srv/files-sftp/chroots/dsaw"],
                "mode": "non_interactive_read",
                "status": { "success": false, "code": 1 },
                "stdout": "",
                "stderr": "not mounted\n"
            },
            {
                "step": "local findmnt",
                "program": "findmnt",
                "args": ["/srv/files-sftp/chroots/dsaw"],
                "mode": "non_interactive_read",
                "status": { "success": false, "code": 1 },
                "stdout": "",
                "stderr": "not mounted\n"
            }
        ])))
        .expect("rendered");

        assert!(rendered.contains("== local findmnt =="));
        assert!(rendered.contains("Repeated: 2 times"));
        assert!(rendered.contains("Last successful backend command:"));
        assert!(rendered.contains("Command: getent passwd dsaw"));
    }

    #[test]
    fn full_backend_render_includes_empty_output_commands() {
        let rendered = render_backend_steps_full(Some(&json!([
            {
                "step": "write",
                "program": "kanidm",
                "args": ["person", "update"],
                "status": { "success": true, "code": 0 },
                "stdout": "",
                "stderr": ""
            }
        ])))
        .expect("rendered");

        assert!(rendered.contains("Status: success"));
        assert!(rendered.contains("stdout/stderr: (empty)"));
    }

    #[test]
    fn renders_backend_commands_with_shell_quoted_arguments() {
        let rendered = render_backend_steps_full(Some(&json!([
            {
                "step": "write",
                "program": "kanidm",
                "args": ["person", "create", "alice user", "Alice's User"],
                "status": { "success": true, "code": 0 },
                "stdout": "",
                "stderr": ""
            }
        ])))
        .expect("rendered");

        assert!(rendered.contains("kanidm person create 'alice user' 'Alice'\\''s User'"));
    }

    #[test]
    fn error_render_includes_concise_backend_summary_from_details() {
        let error = AppError::Verification {
            message: "runtime failed".to_string(),
            details: json!({
                "backend_steps": [
                    {
                        "step": "local findmnt",
                        "program": "findmnt",
                        "args": ["/srv/files-sftp/chroots/dsaw"],
                        "mode": "non_interactive_read",
                        "status": { "success": false, "code": 1 },
                        "stdout": "",
                        "stderr": "not mounted\n"
                    }
                ]
            }),
        };

        let rendered = render_error(OutputFormat::Human, &error);
        assert!(rendered.contains("Backend Commands:"));
        assert!(rendered.contains("== local findmnt =="));
    }

    #[test]
    fn json_error_render_does_not_include_ansi_codes() {
        let error = AppError::Verification {
            message: "runtime failed".to_string(),
            details: json!({ "failure_kind": "local_runtime_not_ready" }),
        };

        let rendered = render_error(OutputFormat::Json, &error);
        assert!(rendered.contains("\"status\": \"error\""));
        assert!(!rendered.contains("\u{1b}["));
    }
}
