use std::time::Instant;

use serde_json::Value;

use crate::{
    inventory::{clients::parse_client_list, groups::parse_group_list, users::parse_user_list},
    kanidm_cli::{BaseSessionState, KanidmCli, PrivilegedWriteState, SessionSnapshot},
    AppError,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum HomeBaseSessionStatus {
    Active,
    Missing,
    Expired,
    Unavailable,
}

impl HomeBaseSessionStatus {
    pub(super) fn label(self) -> &'static str {
        match self {
            Self::Active => "active",
            Self::Missing => "missing",
            Self::Expired => "expired",
            Self::Unavailable => "unavailable",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum HomePrivilegedWriteStatus {
    Ready,
    ReauthRequired,
    Unavailable,
}

impl HomePrivilegedWriteStatus {
    pub(super) fn label(self) -> &'static str {
        match self {
            Self::Ready => "ready",
            Self::ReauthRequired => "reauth required",
            Self::Unavailable => "unavailable",
        }
    }
}

#[derive(Debug, Clone)]
pub(super) enum HomeCountStatus {
    Ok {
        count: usize,
    },
    Stale {
        count: usize,
        age_seconds: u64,
        reason: String,
    },
    Unavailable {
        reason: String,
    },
}

impl HomeCountStatus {
    pub(super) fn render_count(&self) -> String {
        match self {
            Self::Ok { count } => count.to_string(),
            Self::Stale { count, .. } => format!("{count} (stale)"),
            Self::Unavailable { .. } => "unavailable".to_string(),
        }
    }

    pub(super) fn warning_line(&self, label: &str) -> Option<String> {
        match self {
            Self::Ok { .. } => None,
            Self::Stale {
                count,
                age_seconds,
                reason,
            } => Some(format!(
                "{label} count is stale at {count} (last successful read {age_seconds}s ago): {reason}"
            )),
            Self::Unavailable { reason } => Some(format!("{label} count is unavailable: {reason}")),
        }
    }
}

#[derive(Debug, Clone)]
struct CachedHomeCount {
    count: usize,
    observed_at: Instant,
}

#[derive(Debug, Default)]
pub(super) struct HomeCache {
    users: Option<CachedHomeCount>,
    groups: Option<CachedHomeCount>,
    clients: Option<CachedHomeCount>,
}

pub(super) struct HomeSummary {
    pub base_session: HomeBaseSessionStatus,
    pub privileged_writes: HomePrivilegedWriteStatus,
    pub diagnostic: String,
    pub user_count: HomeCountStatus,
    pub group_count: HomeCountStatus,
    pub client_count: HomeCountStatus,
    pub warnings: Vec<String>,
}

impl HomeSummary {
    pub(super) fn render(&self, server_url: &str, admin_name: &str) -> String {
        format!(
            "Server URL: {}\nAdmin Name: {}\nBase Session: {}\nPrivileged Writes: {}\nDiagnostic: {}\nUsers: {}\nGroups: {}\nOAuth2 Clients: {}",
            server_url,
            admin_name,
            self.base_session.label(),
            self.privileged_writes.label(),
            self.diagnostic,
            self.user_count.render_count(),
            self.group_count.render_count(),
            self.client_count.render_count(),
        )
    }
}

pub(super) fn load_home(kanidm: &KanidmCli, cache: &mut HomeCache) -> HomeSummary {
    let mut warnings = Vec::new();

    let (base_session, privileged_writes, diagnostic) = match kanidm.session_snapshot() {
        Ok(snapshot) => summarize_home_session_state(kanidm.admin_name(), &snapshot),
        Err(error) => {
            warnings.push(error.human_message());
            (
                HomeBaseSessionStatus::Unavailable,
                HomePrivilegedWriteStatus::Unavailable,
                "session state unavailable".to_string(),
            )
        }
    };

    let counts_block_reason = match base_session {
        HomeBaseSessionStatus::Active => None,
        HomeBaseSessionStatus::Missing => {
            Some("base session is not active; run `kanidm-admin session login` first".to_string())
        }
        HomeBaseSessionStatus::Expired => {
            Some("base session has expired; run `kanidm-admin session login` first".to_string())
        }
        HomeBaseSessionStatus::Unavailable => {
            Some("session state is unavailable, so live counts were skipped".to_string())
        }
    };

    let (user_count, group_count, client_count) = match counts_block_reason.as_deref() {
        Some(reason) => (
            skipped_home_count("Users", &cache.users, reason),
            skipped_home_count("Groups", &cache.groups, reason),
            skipped_home_count("OAuth2 Clients", &cache.clients, reason),
        ),
        None => (
            load_home_count("Users", &mut cache.users, || {
                let parsed = parse_user_list(&kanidm.person_list::<Value>()?)?;
                warnings.extend(parsed.warnings.clone());
                Ok(parsed.value.len())
            }),
            load_home_count("Groups", &mut cache.groups, || {
                let parsed = parse_group_list(&kanidm.group_list::<Value>()?)?;
                warnings.extend(parsed.warnings.clone());
                Ok(parsed.value.len())
            }),
            load_home_count("OAuth2 Clients", &mut cache.clients, || {
                let parsed = parse_client_list(&kanidm.oauth2_list::<Value>()?)?;
                warnings.extend(parsed.warnings.clone());
                Ok(parsed.value.len())
            }),
        ),
    };

    for warning in [
        user_count.warning_line("Users"),
        group_count.warning_line("Groups"),
        client_count.warning_line("OAuth2 Clients"),
    ]
    .into_iter()
    .flatten()
    {
        warnings.push(warning);
    }

    warnings.sort();
    warnings.dedup();

    HomeSummary {
        base_session,
        privileged_writes,
        diagnostic,
        user_count,
        group_count,
        client_count,
        warnings,
    }
}

fn load_home_count<F>(
    label: &str,
    cache: &mut Option<CachedHomeCount>,
    loader: F,
) -> HomeCountStatus
where
    F: FnOnce() -> Result<usize, AppError>,
{
    match loader() {
        Ok(count) => {
            *cache = Some(CachedHomeCount {
                count,
                observed_at: Instant::now(),
            });
            HomeCountStatus::Ok { count }
        }
        Err(error) => match cache {
            Some(cached) => HomeCountStatus::Stale {
                count: cached.count,
                age_seconds: cached.observed_at.elapsed().as_secs(),
                reason: format!("{label} probe failed: {}", error.human_message()),
            },
            None => HomeCountStatus::Unavailable {
                reason: error.human_message(),
            },
        },
    }
}

fn skipped_home_count(
    label: &str,
    cache: &Option<CachedHomeCount>,
    reason: &str,
) -> HomeCountStatus {
    match cache {
        Some(cached) => HomeCountStatus::Stale {
            count: cached.count,
            age_seconds: cached.observed_at.elapsed().as_secs(),
            reason: format!("{label} probe skipped: {reason}"),
        },
        None => HomeCountStatus::Unavailable {
            reason: format!("{label} probe skipped: {reason}"),
        },
    }
}

pub(super) fn summarize_home_session_state(
    admin_name: &str,
    snapshot: &SessionSnapshot,
) -> (HomeBaseSessionStatus, HomePrivilegedWriteStatus, String) {
    match (
        snapshot.base_session_state,
        snapshot.privileged_write_state,
    ) {
        (BaseSessionState::Present, PrivilegedWriteState::Ready) => (
            HomeBaseSessionStatus::Active,
            HomePrivilegedWriteStatus::Ready,
            format!(
                "Authenticated base session is active for '{}'. Privileged write commands are ready.",
                admin_name
            ),
        ),
        (BaseSessionState::Expired, _) => (
            HomeBaseSessionStatus::Expired,
            HomePrivilegedWriteStatus::Unavailable,
            format!("Session for '{}' has expired.", admin_name),
        ),
        (BaseSessionState::Missing | BaseSessionState::Unknown, _) => (
            HomeBaseSessionStatus::Missing,
            HomePrivilegedWriteStatus::Unavailable,
            format!("No Kanidm session is active for '{}'.", admin_name),
        ),
        (BaseSessionState::Present, _) => (
            HomeBaseSessionStatus::Active,
            HomePrivilegedWriteStatus::ReauthRequired,
            format!(
                "Session for '{}' is authenticated, but privileged reauthentication is required.",
                admin_name
            ),
        ),
    }
}
