use std::sync::{Arc, Mutex};

use serde_json::{json, Value};
use time::OffsetDateTime;

use crate::backend::{BackendExecError, CommandMode, ExitStatusSummary};

const MAX_RECENT_BACKEND_LOGS: usize = 200;

#[derive(Debug, Default)]
struct BackendLogState {
    entries: Vec<Value>,
    next_sequence: u64,
    operation_start_sequence: u64,
}

#[derive(Debug, Clone, Default)]
pub struct BackendLog {
    state: Arc<Mutex<BackendLogState>>,
}

#[derive(Debug, Clone, Copy)]
pub struct BackendLogRecord<'a> {
    pub step: &'a str,
    pub mode: CommandMode,
    pub program: &'a str,
    pub args: &'a [String],
    pub status: ExitStatusSummary,
    pub stdout: &'a str,
    pub stderr: &'a str,
}

impl BackendLog {
    pub fn begin_operation(&self) {
        if let Ok(mut state) = self.state.lock() {
            state.operation_start_sequence = state.next_sequence;
        }
    }

    pub fn operation_entries(&self) -> Vec<Value> {
        self.state
            .lock()
            .map(|mut state| {
                let entries = state
                    .entries
                    .iter()
                    .filter(|entry| {
                        entry
                            .get("sequence")
                            .and_then(Value::as_u64)
                            .is_some_and(|sequence| sequence >= state.operation_start_sequence)
                    })
                    .cloned()
                    .collect::<Vec<_>>();
                state.operation_start_sequence = state.next_sequence;
                entries
            })
            .unwrap_or_default()
    }

    pub fn recent_entries(&self) -> Vec<Value> {
        self.state
            .lock()
            .map(|state| state.entries.clone())
            .unwrap_or_default()
    }

    pub fn record_result(&self, record: BackendLogRecord<'_>) {
        self.push(json!({
            "step": record.step,
            "mode": command_mode_label(record.mode),
            "program": record.program,
            "args": record.args,
            "status": record.status,
            "stdout": record.stdout,
            "stderr": record.stderr,
            "error": null,
        }));
    }

    pub fn record_exec_error(
        &self,
        step: &str,
        mode: CommandMode,
        program: &str,
        args: &[String],
        error: &BackendExecError,
    ) {
        self.push(json!({
            "step": step,
            "mode": command_mode_label(mode),
            "program": program,
            "args": args,
            "status": null,
            "stdout": "",
            "stderr": "",
            "error": exec_error_payload(error),
        }));
    }

    fn push(&self, mut entry: Value) {
        if let Ok(mut state) = self.state.lock() {
            let sequence = state.next_sequence;
            state.next_sequence = state.next_sequence.saturating_add(1);
            entry["sequence"] = json!(sequence);
            entry["recorded_at"] = json!(OffsetDateTime::now_utc()
                .format(&time::format_description::well_known::Rfc3339)
                .unwrap_or_else(|_| OffsetDateTime::now_utc().to_string()));
            state.entries.push(entry);
            if state.entries.len() > MAX_RECENT_BACKEND_LOGS {
                let excess = state.entries.len() - MAX_RECENT_BACKEND_LOGS;
                state.entries.drain(0..excess);
            }
        }
    }
}

fn command_mode_label(mode: CommandMode) -> &'static str {
    match mode {
        CommandMode::InteractiveAuth => "interactive_auth",
        CommandMode::NonInteractiveRead => "non_interactive_read",
        CommandMode::NonInteractiveWrite => "non_interactive_write",
    }
}

fn exec_error_payload(error: &BackendExecError) -> Value {
    match error {
        BackendExecError::MissingDependency { binary } => {
            json!({ "kind": "missing_dependency", "binary": binary })
        }
        BackendExecError::Io {
            message,
            crash_kind,
        } => {
            json!({
                "kind": "io",
                "message": message,
                "crash_kind": crash_kind.map(|kind| kind.as_str()),
            })
        }
        BackendExecError::Timeout { message, details } => {
            json!({
                "kind": "timeout",
                "message": message,
                "details": details,
            })
        }
    }
}
