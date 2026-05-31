use super::*;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum RuntimeScope {
    SftpLogin,
    FileAccess,
}

pub(super) struct ReadinessReport {
    pub(super) runtime: RuntimeReport,
    pub(super) readiness: SftpReadiness,
}

pub(super) fn readiness_from_runtime(report: &RuntimeReport) -> SftpReadiness {
    SftpReadiness {
        ready: report.ready,
        checks: report
            .checks
            .iter()
            .map(|check| SftpReadinessCheck {
                name: check.id.clone(),
                ok: check.status == CheckStatus::Passed || check.status == CheckStatus::Skipped,
                required: check.required,
                detail: check.summary.clone(),
                probe: check.probe.clone(),
            })
            .collect(),
    }
}
