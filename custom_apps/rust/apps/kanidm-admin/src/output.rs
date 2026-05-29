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
        if let Some(backend) = render_backend_steps(self.details.get("backend_steps")) {
            body.push_str("\n\nBackend Output:\n");
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

fn render_backend_steps(value: Option<&Value>) -> Option<String> {
    let steps = value.and_then(Value::as_array)?;
    let rendered = steps
        .iter()
        .filter_map(render_backend_step)
        .collect::<Vec<_>>();
    (!rendered.is_empty()).then(|| rendered.join("\n\n"))
}

fn render_backend_step(step: &Value) -> Option<String> {
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
    if stdout.is_empty() && stderr.is_empty() {
        return None;
    }

    let label = step
        .get("step")
        .and_then(Value::as_str)
        .unwrap_or("backend command");
    let mut lines = vec![format!("== {label} ==")];
    if let Some(command) = render_command(step) {
        lines.push(format!("Command: {command}"));
    }
    if !stdout.is_empty() {
        lines.push(format!("stdout:\n{stdout}"));
    }
    if !stderr.is_empty() {
        lines.push(format!("stderr:\n{stderr}"));
    }
    Some(lines.join("\n"))
}

fn render_command(step: &Value) -> Option<String> {
    let program = step.get("program").and_then(Value::as_str)?;
    let args = step
        .get("args")
        .and_then(Value::as_array)
        .map(|args| {
            args.iter()
                .filter_map(Value::as_str)
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
        assert!(rendered.contains("Backend Output:"));
        assert!(rendered.contains("== write =="));
        assert!(rendered.contains("stdout:\nupdated"));
    }
}
