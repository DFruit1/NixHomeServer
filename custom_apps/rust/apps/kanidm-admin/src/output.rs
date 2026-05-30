use clap::ValueEnum;
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

impl CommandOutput {
    pub fn render_human(&self) -> String {
        let mut body = self.human.clone();
        if let Some(backend) = render_backend_steps_summary(self.details.get("backend_steps")) {
            body.push_str("\n\nBackend Commands:\n");
            body.push_str(&backend);
        }

        if self.warnings.is_empty() {
            body
        } else {
            format!(
                "{}\n\nWarnings:\n{}",
                body,
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
            "details": self.details,
            "warnings": self.warnings,
        })
    }
}

pub fn render_backend_steps_summary(value: Option<&Value>) -> Option<String> {
    let steps = value.and_then(Value::as_array)?;
    let rendered = steps
        .iter()
        .map(render_backend_step_summary)
        .collect::<Vec<_>>();
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

fn render_backend_step_summary(step: &Value) -> String {
    let label = step
        .get("step")
        .and_then(Value::as_str)
        .unwrap_or("backend command");
    let status = render_status(step);
    let mut lines = vec![format!("== {label} ==",), format!("Status: {status}")];
    if let Some(command) = render_command(step) {
        lines.push(format!("Command: {command}"));
    }
    if let Some(mode) = step.get("mode").and_then(Value::as_str) {
        lines.push(format!("Mode: {mode}"));
    }
    if has_text(step, "stdout")
        || has_text(step, "stderr")
        || step.get("error").is_some_and(|value| !value.is_null())
    {
        lines.push("Raw stdout/stderr is available from Show Backend Logs.".to_string());
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
        format!("== {label} =="),
        format!("Status: {}", render_status(step)),
    ];
    if let Some(sequence) = step.get("sequence").and_then(Value::as_u64) {
        lines.push(format!("Sequence: {sequence}"));
    }
    if let Some(recorded_at) = step.get("recorded_at").and_then(Value::as_str) {
        lines.push(format!("Recorded At: {recorded_at}"));
    }
    if let Some(mode) = step.get("mode").and_then(Value::as_str) {
        lines.push(format!("Mode: {mode}"));
    }
    if let Some(command) = render_command(step) {
        lines.push(format!("Command: {command}"));
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

fn shell_quote_arg(value: &str) -> String {
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
        OutputFormat::Human => error.human_message(),
        OutputFormat::Json => serde_json::to_string_pretty(&error.json_payload())
            .unwrap_or_else(|_| error.json_payload().to_string()),
    }
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
        assert!(rendered.contains("== write =="));
        assert!(rendered.contains("Raw stdout/stderr is available from Show Backend Logs."));
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
}
