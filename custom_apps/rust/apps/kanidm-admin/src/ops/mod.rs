use serde_json::{json, Value};

use crate::AppError;

pub mod client;
pub mod context;
pub mod executor;
pub mod group;
pub mod local;
pub mod local_runtime;
pub mod membership;
pub mod policy;
pub mod session;
pub mod sftp;
pub mod user;

pub(crate) struct ReconciledWrite<T> {
    pub value: T,
    pub warning: String,
}

pub(crate) struct FailedWriteContext<'a> {
    pub resource: &'a str,
    pub name: &'a str,
    pub requested_state: Value,
    pub completed_steps: &'a [String],
    pub failed_step: &'a str,
    pub error: AppError,
    pub next_actions: Vec<String>,
}

pub(crate) fn reconcile_failed_write<T, Probe, Matches, Observe>(
    context: FailedWriteContext<'_>,
    probe: Probe,
    matches: Matches,
    observe: Observe,
) -> Result<ReconciledWrite<T>, AppError>
where
    Probe: FnOnce() -> Result<T, AppError>,
    Matches: Fn(&T) -> bool,
    Observe: Fn(&T) -> Value,
{
    let FailedWriteContext {
        resource,
        name,
        requested_state,
        completed_steps,
        failed_step,
        error,
        next_actions,
    } = context;

    let probed = match probe() {
        Ok(value) => value,
        Err(_probe_error) if completed_steps.is_empty() => return Err(error),
        Err(probe_error) => {
            return Err(AppError::PartialSuccess {
                message: format!(
                    "{resource} '{name}' was modified, but '{failed_step}' did not finish cleanly"
                ),
                details: json!({
                    "resource": resource,
                    "name": name,
                    "requested_state": requested_state,
                    "completed_steps": completed_steps,
                    "failed_step": failed_step,
                    "observed_state": probe_error.json_payload(),
                    "next_actions": next_actions,
                    "backend": error.json_payload(),
                }),
            });
        }
    };

    if matches(&probed) {
        return Ok(ReconciledWrite {
            value: probed,
            warning: format!(
                "Kanidm reported a failure during '{failed_step}', but the live {resource} state already matches the requested result."
            ),
        });
    }

    if completed_steps.is_empty() {
        return Err(error);
    }

    Err(AppError::PartialSuccess {
        message: format!(
            "{resource} '{name}' was modified, but '{failed_step}' did not finish cleanly"
        ),
        details: json!({
            "resource": resource,
            "name": name,
            "requested_state": requested_state,
            "completed_steps": completed_steps,
            "failed_step": failed_step,
            "observed_state": observe(&probed),
            "next_actions": next_actions,
            "backend": error.json_payload(),
        }),
    })
}
