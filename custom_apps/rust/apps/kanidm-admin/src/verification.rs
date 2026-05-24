use std::{
    thread::sleep,
    time::{Duration, Instant},
};

use serde::Serialize;
use serde_json::{json, Value};

use crate::AppError;

#[derive(Debug)]
pub enum VerificationCheck<T> {
    Matched { observed: Value, value: T },
    Mismatch { observed: Value },
    Fatal { observed: Value, error: AppError },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum VerificationPolicy {
    SessionRecovery,
    ReadAfterWrite,
    MembershipConvergence,
    PolicyConvergence,
    ClientConvergence,
}

#[derive(Debug, Clone, Serialize)]
pub struct VerificationAttempt {
    pub attempt: usize,
    pub delay_ms: u64,
    pub outcome: &'static str,
    pub observed: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<Value>,
}

#[derive(Debug, Clone, Serialize)]
pub struct VerificationReport {
    pub policy_name: &'static str,
    pub total_time_budget_ms: u64,
    pub allow_partial_success_warning: bool,
    pub elapsed_ms: u128,
    pub write_completed: bool,
    pub expected_state: Value,
    pub attempts: Vec<VerificationAttempt>,
}

impl VerificationPolicy {
    pub fn name(self) -> &'static str {
        match self {
            Self::SessionRecovery => "session_recovery",
            Self::ReadAfterWrite => "read_after_write",
            Self::MembershipConvergence => "membership_convergence",
            Self::PolicyConvergence => "policy_convergence",
            Self::ClientConvergence => "client_convergence",
        }
    }

    fn delays_ms(self) -> &'static [u64] {
        match self {
            Self::SessionRecovery => &[250, 500, 1_000, 1_500],
            Self::ReadAfterWrite => &[250, 500, 1_000, 2_000, 2_000, 3_000],
            Self::MembershipConvergence => &[250, 500, 1_000, 2_000, 2_000, 2_000, 3_000],
            Self::PolicyConvergence => &[250, 500, 1_000, 1_500, 2_000, 2_000],
            Self::ClientConvergence => &[250, 500, 1_000, 1_500, 2_000, 2_000],
        }
    }

    pub fn total_time_budget_ms(self) -> u64 {
        match self {
            Self::SessionRecovery => 5_000,
            Self::ReadAfterWrite => 12_000,
            Self::MembershipConvergence => 14_000,
            Self::PolicyConvergence => 10_000,
            Self::ClientConvergence => 10_000,
        }
    }

    pub fn allow_partial_success_warning(self) -> bool {
        !matches!(self, Self::SessionRecovery)
    }
}

pub fn verify_with_retry<T, F>(
    policy: VerificationPolicy,
    context: &str,
    expected: Value,
    write_completed: bool,
    mut probe: F,
) -> Result<T, AppError>
where
    F: FnMut() -> Result<VerificationCheck<T>, AppError>,
{
    let start = Instant::now();
    let mut attempts = Vec::new();
    let total_time_budget_ms = policy.total_time_budget_ms();

    for (attempt_index, delay_ms) in std::iter::once(0)
        .chain(policy.delays_ms().iter().copied())
        .enumerate()
    {
        if attempt_index > 0
            && start.elapsed().as_millis() + u128::from(delay_ms) > u128::from(total_time_budget_ms)
        {
            break;
        }
        if delay_ms > 0 {
            sleep(Duration::from_millis(delay_ms));
        }

        let attempt_number = attempt_index + 1;
        match probe() {
            Ok(VerificationCheck::Matched { observed, value }) => {
                attempts.push(VerificationAttempt {
                    attempt: attempt_number,
                    delay_ms,
                    outcome: "matched",
                    observed,
                    error: None,
                });
                return Ok(value);
            }
            Ok(VerificationCheck::Mismatch { observed }) => {
                attempts.push(VerificationAttempt {
                    attempt: attempt_number,
                    delay_ms,
                    outcome: "mismatch",
                    observed,
                    error: None,
                });
            }
            Ok(VerificationCheck::Fatal { observed, error }) => {
                attempts.push(VerificationAttempt {
                    attempt: attempt_number,
                    delay_ms,
                    outcome: "fatal",
                    observed,
                    error: Some(error.json_payload()),
                });
                return Err(verification_error(
                    policy,
                    context,
                    expected,
                    write_completed,
                    start.elapsed().as_millis(),
                    attempts,
                    Some(error.json_payload()),
                ));
            }
            Err(error) => {
                attempts.push(VerificationAttempt {
                    attempt: attempt_number,
                    delay_ms,
                    outcome: "fatal",
                    observed: error.json_payload(),
                    error: Some(error.json_payload()),
                });
                return Err(verification_error(
                    policy,
                    context,
                    expected,
                    write_completed,
                    start.elapsed().as_millis(),
                    attempts,
                    Some(error.json_payload()),
                ));
            }
        }
    }

    Err(verification_error(
        policy,
        context,
        expected,
        write_completed,
        start.elapsed().as_millis(),
        attempts,
        None,
    ))
}

fn verification_error(
    policy: VerificationPolicy,
    context: &str,
    expected: Value,
    write_completed: bool,
    elapsed_ms: u128,
    attempts: Vec<VerificationAttempt>,
    fatal_error: Option<Value>,
) -> AppError {
    let report = VerificationReport {
        policy_name: policy.name(),
        total_time_budget_ms: policy.total_time_budget_ms(),
        allow_partial_success_warning: policy.allow_partial_success_warning(),
        elapsed_ms,
        write_completed,
        expected_state: expected,
        attempts,
    };

    AppError::Verification {
        message: context.to_string(),
        details: json!({
            "elapsed_ms": report.elapsed_ms,
            "expected_state": report.expected_state,
            "verification_policy": {
                "name": report.policy_name,
                "total_time_budget_ms": report.total_time_budget_ms,
                "allow_partial_success_warning": report.allow_partial_success_warning,
            },
            "attempts": report.attempts,
            "write_completed": report.write_completed,
            "fatal_error": fatal_error,
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn verification_stops_on_fatal_probe_error() {
        let error = verify_with_retry::<(), _>(
            VerificationPolicy::ReadAfterWrite,
            "verification failed",
            json!({"ok": true}),
            true,
            || {
                Err(AppError::Json {
                    message: "bad json".to_string(),
                    details: json!({"stdout": "oops"}),
                })
            },
        )
        .expect_err("fatal error");

        match error {
            AppError::Verification { details, .. } => {
                assert_eq!(details["attempts"][0]["outcome"], "fatal");
            }
            other => panic!("unexpected error: {other:?}"),
        }
    }
}
