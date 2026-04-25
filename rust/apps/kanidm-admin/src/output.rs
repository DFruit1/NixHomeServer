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
        if self.warnings.is_empty() {
            self.human.clone()
        } else {
            format!(
                "{}\n\nWarnings:\n{}",
                self.human,
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
}
