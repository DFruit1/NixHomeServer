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
}

impl CommandOutput {
    pub fn json_payload(&self) -> Value {
        json!({
            "status": "ok",
            "message": self.message,
            "details": self.details,
        })
    }
}

pub fn render_output(format: OutputFormat, output: &CommandOutput) -> String {
    match format {
        OutputFormat::Human => output.human.clone(),
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
        };

        let rendered = render_output(OutputFormat::Json, &output);
        assert!(rendered.contains("\"status\": \"ok\""));
        assert!(rendered.contains("\"count\": 1"));
    }
}
