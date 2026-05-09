use serde::Serialize;
use time::{
    format_description::{well_known::Rfc3339, FormatItem},
    macros::format_description,
    OffsetDateTime,
};

use crate::backend::BackendFailure;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionState {
    Authenticated {
        stdout: String,
        session: ParsedSession,
    },
    Expired {
        diagnostic: String,
    },
    Missing {
        diagnostic: String,
    },
    ReauthRequired {
        diagnostic: String,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum BaseSessionState {
    Present,
    Expired,
    Missing,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum PrivilegedWriteState {
    Ready,
    ReauthRequired,
    Unavailable,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ParseConfidence {
    High,
    Heuristic,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionSnapshot {
    pub admin_name: String,
    pub server_url: String,
    pub matched_principal: Option<String>,
    pub base_session_state: BaseSessionState,
    pub privileged_write_state: PrivilegedWriteState,
    pub base_expiry: ParsedExpiry,
    pub privileged_expiry: ParsedExpiry,
    pub diagnostic_raw: String,
    pub parse_confidence: ParseConfidence,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedSession {
    pub principal: String,
    pub session_expiry: ParsedExpiry,
    pub purpose: ParsedSessionPurpose,
    pub raw: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParsedExpiry {
    Never,
    At(OffsetDateTime),
    Unknown(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParsedSessionPurpose {
    ReadOnly,
    ReadWrite { expiry: ParsedExpiry },
    Unknown(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionFailureKind {
    Missing,
    Expired,
    ReauthRequired,
    Unknown,
    BackendUnavailable,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionDiagnostic {
    pub primary: String,
    pub raw: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionObservation {
    Snapshot(SessionSnapshot),
    Failure(SessionFailureKind, SessionDiagnostic),
}

pub struct SessionInterpreter;

impl SessionInterpreter {
    pub fn from_session_list(
        raw: &str,
        admin_name: &str,
        server_url: &str,
        now: OffsetDateTime,
    ) -> SessionSnapshot {
        classify_session_snapshot(raw, admin_name, server_url, now)
    }

    pub fn from_backend_failure(
        failure: &BackendFailure,
        admin_name: &str,
        server_url: &str,
    ) -> SessionObservation {
        let diagnostic = classification_diagnostic(failure);
        let primary = concise_session_diagnostic(failure);
        let details = SessionDiagnostic {
            primary,
            raw: diagnostic.clone(),
        };
        let normalized_diagnostic = normalized(&diagnostic);

        let kind = if is_reauth_required(&normalized_diagnostic) {
            SessionFailureKind::ReauthRequired
        } else if is_session_expired(&normalized_diagnostic) {
            SessionFailureKind::Expired
        } else if is_session_missing(&normalized_diagnostic) {
            SessionFailureKind::Missing
        } else if let Some(snapshot) =
            classify_heuristic_session_snapshot(&diagnostic, admin_name, server_url)
        {
            return SessionObservation::Snapshot(snapshot);
        } else {
            SessionFailureKind::Unknown
        };

        SessionObservation::Failure(kind, details)
    }
}

impl SessionSnapshot {
    pub fn to_session_state(&self) -> SessionState {
        match self.base_session_state {
            BaseSessionState::Expired => SessionState::Expired {
                diagnostic: self.diagnostic_raw.clone(),
            },
            BaseSessionState::Missing | BaseSessionState::Unknown => SessionState::Missing {
                diagnostic: self.diagnostic_raw.clone(),
            },
            BaseSessionState::Present => match self.privileged_write_state {
                PrivilegedWriteState::Ready => SessionState::Authenticated {
                    stdout: self.diagnostic_raw.clone(),
                    session: self.to_parsed_session(),
                },
                PrivilegedWriteState::ReauthRequired
                | PrivilegedWriteState::Unavailable
                | PrivilegedWriteState::Unknown => SessionState::ReauthRequired {
                    diagnostic: self.diagnostic_raw.clone(),
                },
            },
        }
    }

    pub fn base_session_present(&self) -> bool {
        matches!(self.base_session_state, BaseSessionState::Present)
    }

    pub fn privileged_write_ready(&self) -> bool {
        matches!(self.privileged_write_state, PrivilegedWriteState::Ready)
    }

    fn to_parsed_session(&self) -> ParsedSession {
        let principal = self
            .matched_principal
            .clone()
            .unwrap_or_else(|| self.admin_name.clone());
        let purpose = match self.privileged_write_state {
            PrivilegedWriteState::Ready | PrivilegedWriteState::ReauthRequired => {
                ParsedSessionPurpose::ReadWrite {
                    expiry: self.privileged_expiry.clone(),
                }
            }
            PrivilegedWriteState::Unavailable | PrivilegedWriteState::Unknown => {
                ParsedSessionPurpose::Unknown("privileged write state unavailable".to_string())
            }
        };

        ParsedSession {
            principal,
            session_expiry: self.base_expiry.clone(),
            purpose,
            raw: self.diagnostic_raw.clone(),
        }
    }
}

pub fn should_prompt_for_startup_login(snapshot: &SessionSnapshot) -> bool {
    matches!(
        snapshot.base_session_state,
        BaseSessionState::Missing | BaseSessionState::Expired
    )
}

pub fn login_prompt_message(snapshot: &SessionSnapshot) -> Option<&'static str> {
    match snapshot.base_session_state {
        BaseSessionState::Missing => {
            Some("No active admin session was found. Would you like to log in now?")
        }
        BaseSessionState::Expired => {
            Some("Your previous admin session has expired. Would you like to log in again?")
        }
        BaseSessionState::Present | BaseSessionState::Unknown => None,
    }
}

pub fn concise_session_message(admin_name: &str, snapshot: &SessionSnapshot) -> Option<String> {
    match (
        snapshot.base_session_state,
        snapshot.privileged_write_state,
    ) {
        (BaseSessionState::Missing, _) => Some(format!(
            "No active admin session was found for '{admin_name}'. Run `kanidm-admin session login` to log in."
        )),
        (BaseSessionState::Expired, _) => Some(format!(
            "The previous admin session for '{admin_name}' has expired. Run `kanidm-admin session login` to log in again."
        )),
        (BaseSessionState::Present, PrivilegedWriteState::ReauthRequired)
        | (BaseSessionState::Present, PrivilegedWriteState::Unavailable)
        | (BaseSessionState::Present, PrivilegedWriteState::Unknown) => Some(format!(
            "Privileged write access for '{admin_name}' requires reauthentication. Run `kanidm-admin session reauth` first."
        )),
        _ => None,
    }
}

const DISPLAY_TS_WITH_SUBSECOND_AND_OFFSET_SECONDS: &[FormatItem<'static>] = format_description!(
    "[year]-[month]-[day] [hour]:[minute]:[second].[subsecond digits:1+] [offset_hour sign:mandatory]:[offset_minute]:[offset_second]"
);
const DISPLAY_TS_WITH_OFFSET_SECONDS: &[FormatItem<'static>] = format_description!(
    "[year]-[month]-[day] [hour]:[minute]:[second] [offset_hour sign:mandatory]:[offset_minute]:[offset_second]"
);
const DISPLAY_TS_WITH_SUBSECOND: &[FormatItem<'static>] = format_description!(
    "[year]-[month]-[day] [hour]:[minute]:[second].[subsecond digits:1+] [offset_hour sign:mandatory]:[offset_minute]"
);
const DISPLAY_TS: &[FormatItem<'static>] = format_description!(
    "[year]-[month]-[day] [hour]:[minute]:[second] [offset_hour sign:mandatory]:[offset_minute]"
);

pub fn strip_control_sequences(text: &str) -> String {
    let mut result = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();

    while let Some(ch) = chars.next() {
        if ch == '\u{1b}' {
            if matches!(chars.peek(), Some('[')) {
                let _ = chars.next();
                for next in chars.by_ref() {
                    if ('@'..='~').contains(&next) {
                        break;
                    }
                }
                continue;
            }
            continue;
        }

        if ch.is_control() && ch != '\n' && ch != '\r' && ch != '\t' {
            continue;
        }

        result.push(ch);
    }

    result
}

pub fn preferred_diagnostic(failure: &BackendFailure) -> String {
    let stderr = failure.stderr.trim();
    if !stderr.is_empty() {
        stderr.to_string()
    } else {
        failure.stdout.trim().to_string()
    }
}

pub fn classification_diagnostic(failure: &BackendFailure) -> String {
    [failure.stderr.as_str(), failure.stdout.as_str()]
        .into_iter()
        .map(strip_control_sequences)
        .map(|text| text.trim().to_string())
        .filter(|text| !text.is_empty())
        .collect::<Vec<_>>()
        .join("\n")
}

pub fn concise_session_diagnostic(failure: &BackendFailure) -> String {
    let combined = classification_diagnostic(failure);
    let lines = combined
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .collect::<Vec<_>>();

    if let Some(line) = lines.iter().copied().find(|line| {
        let normalized_line = normalized(line);
        is_session_expired(&normalized_line)
            || is_session_missing(&normalized_line)
            || is_reauth_required(&normalized_line)
    }) {
        return line.to_string();
    }

    if let Some(line) = lines.iter().copied().find(|line| {
        let normalized_line = normalized(line);
        !normalized_line.starts_with("thread 'main'")
            && !normalized_line.starts_with("note: run with `rust_backtrace=1`")
            && !normalized_line.contains("panicked at")
            && !normalized_line.contains("failed to interact with interactive session")
    }) {
        return line.to_string();
    }

    preferred_diagnostic(failure)
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .unwrap_or_default()
        .to_string()
}

fn normalized(text: &str) -> String {
    text.trim().to_lowercase()
}

pub fn classify_session_snapshot(
    output: &str,
    admin_name: &str,
    server_url: &str,
    now: OffsetDateTime,
) -> SessionSnapshot {
    let cleaned = strip_control_sequences(output);
    let trimmed = cleaned.trim();
    if trimmed.is_empty() {
        return SessionSnapshot {
            admin_name: admin_name.to_string(),
            server_url: server_url.to_string(),
            matched_principal: None,
            base_session_state: BaseSessionState::Missing,
            privileged_write_state: PrivilegedWriteState::Unavailable,
            base_expiry: ParsedExpiry::Unknown("no matching session was found".to_string()),
            privileged_expiry: ParsedExpiry::Unknown("no matching session was found".to_string()),
            diagnostic_raw: format!("No Kanidm session entries were listed for '{admin_name}'."),
            parse_confidence: ParseConfidence::High,
        };
    }

    let entries = parse_session_entries(trimmed);
    if !entries.is_empty() {
        if let Some(session) = entries
            .into_iter()
            .find(|session| session_matches_admin(&session.principal, admin_name))
        {
            return session.snapshot(admin_name, server_url, now, ParseConfidence::High);
        }

        return SessionSnapshot {
            admin_name: admin_name.to_string(),
            server_url: server_url.to_string(),
            matched_principal: None,
            base_session_state: BaseSessionState::Missing,
            privileged_write_state: PrivilegedWriteState::Unavailable,
            base_expiry: ParsedExpiry::Unknown("no matching session was found".to_string()),
            privileged_expiry: ParsedExpiry::Unknown("no matching session was found".to_string()),
            diagnostic_raw: format!(
                "No Kanidm session entry matched '{admin_name}'.\n\nObserved sessions:\n{trimmed}"
            ),
            parse_confidence: ParseConfidence::High,
        };
    }

    classify_heuristic_session_snapshot(trimmed, admin_name, server_url).unwrap_or_else(|| {
        SessionSnapshot {
            admin_name: admin_name.to_string(),
            server_url: server_url.to_string(),
            matched_principal: None,
            base_session_state: BaseSessionState::Unknown,
            privileged_write_state: PrivilegedWriteState::Unknown,
            base_expiry: ParsedExpiry::Unknown(
                "session list output could not be parsed".to_string(),
            ),
            privileged_expiry: ParsedExpiry::Unknown(
                "session list output could not be parsed".to_string(),
            ),
            diagnostic_raw: trimmed.to_string(),
            parse_confidence: ParseConfidence::Heuristic,
        }
    })
}

pub fn classify_heuristic_session_snapshot(
    diagnostic: &str,
    admin_name: &str,
    server_url: &str,
) -> Option<SessionSnapshot> {
    let trimmed = diagnostic.trim();
    let normalized_diagnostic = normalized(trimmed);
    if is_reauth_required(&normalized_diagnostic) {
        return Some(SessionSnapshot {
            admin_name: admin_name.to_string(),
            server_url: server_url.to_string(),
            matched_principal: session_mentions_admin(trimmed, admin_name)
                .then(|| admin_name.to_string()),
            base_session_state: BaseSessionState::Present,
            privileged_write_state: PrivilegedWriteState::ReauthRequired,
            base_expiry: ParsedExpiry::Unknown("heuristic classification".to_string()),
            privileged_expiry: ParsedExpiry::Unknown("heuristic classification".to_string()),
            diagnostic_raw: trimmed.to_string(),
            parse_confidence: ParseConfidence::Heuristic,
        });
    }
    if is_session_expired(&normalized_diagnostic) {
        return Some(SessionSnapshot {
            admin_name: admin_name.to_string(),
            server_url: server_url.to_string(),
            matched_principal: session_mentions_admin(trimmed, admin_name)
                .then(|| admin_name.to_string()),
            base_session_state: BaseSessionState::Expired,
            privileged_write_state: PrivilegedWriteState::Unavailable,
            base_expiry: ParsedExpiry::Unknown("heuristic classification".to_string()),
            privileged_expiry: ParsedExpiry::Unknown("heuristic classification".to_string()),
            diagnostic_raw: trimmed.to_string(),
            parse_confidence: ParseConfidence::Heuristic,
        });
    }
    if is_session_missing(&normalized_diagnostic) {
        return Some(SessionSnapshot {
            admin_name: admin_name.to_string(),
            server_url: server_url.to_string(),
            matched_principal: None,
            base_session_state: BaseSessionState::Missing,
            privileged_write_state: PrivilegedWriteState::Unavailable,
            base_expiry: ParsedExpiry::Unknown("heuristic classification".to_string()),
            privileged_expiry: ParsedExpiry::Unknown("heuristic classification".to_string()),
            diagnostic_raw: trimmed.to_string(),
            parse_confidence: ParseConfidence::Heuristic,
        });
    }
    session_mentions_admin(trimmed, admin_name).then(|| SessionSnapshot {
        admin_name: admin_name.to_string(),
        server_url: server_url.to_string(),
        matched_principal: Some(admin_name.to_string()),
        base_session_state: BaseSessionState::Present,
        privileged_write_state: PrivilegedWriteState::Unknown,
        base_expiry: ParsedExpiry::Unknown("heuristic classification".to_string()),
        privileged_expiry: ParsedExpiry::Unknown("heuristic classification".to_string()),
        diagnostic_raw: trimmed.to_string(),
        parse_confidence: ParseConfidence::Heuristic,
    })
}

fn parse_session_entries(output: &str) -> Vec<ParsedSession> {
    let mut entries = Vec::new();
    let mut current = Vec::new();
    let mut saw_separator = false;

    for line in output.lines() {
        if line.trim() == "---" {
            saw_separator = true;
            if let Some(session) = parse_session_block(&current) {
                entries.push(session);
            }
            current.clear();
            continue;
        }

        if !line.trim().is_empty() || !current.is_empty() {
            current.push(line.trim_end().to_string());
        }
    }

    if let Some(session) = parse_session_block(&current) {
        entries.push(session);
    }

    if saw_separator {
        entries
    } else {
        Vec::new()
    }
}

fn parse_session_block(lines: &[String]) -> Option<ParsedSession> {
    if lines.is_empty() {
        return None;
    }

    let mut principal = None;
    let mut session_expiry = None;
    let mut purpose = None;

    for line in lines {
        let (key, value) = match line.split_once(':') {
            Some((key, value)) => (normalized(key), value.trim()),
            None => continue,
        };

        match key.as_str() {
            "spn" | "account" | "name" if !value.is_empty() => {
                principal = Some(value.to_string());
            }
            "expiry" => session_expiry = Some(parse_session_expiry(value)),
            "purpose" => purpose = Some(parse_session_purpose(value)),
            _ => {}
        }
    }

    Some(ParsedSession {
        principal: principal?,
        session_expiry: session_expiry.unwrap_or_else(|| {
            ParsedExpiry::Unknown("session expiry line was not present".to_string())
        }),
        purpose: purpose.unwrap_or_else(|| {
            ParsedSessionPurpose::Unknown("session purpose line was not present".to_string())
        }),
        raw: lines.join("\n"),
    })
}

fn parse_session_expiry(value: &str) -> ParsedExpiry {
    match normalized(value).as_str() {
        "-" | "none" | "never" => ParsedExpiry::Never,
        _ => parse_session_timestamp(value)
            .map(ParsedExpiry::At)
            .unwrap_or_else(|| ParsedExpiry::Unknown(value.trim().to_string())),
    }
}

fn parse_session_purpose(value: &str) -> ParsedSessionPurpose {
    let normalized_value = normalized(value);
    if normalized_value == "read only" {
        return ParsedSessionPurpose::ReadOnly;
    }

    if normalized_value.starts_with("read write") {
        let expiry = value
            .split("(expiry:")
            .nth(1)
            .and_then(|segment| segment.strip_suffix(')'))
            .map(str::trim)
            .map(parse_session_expiry)
            .unwrap_or_else(|| {
                ParsedExpiry::Unknown(
                    "read write purpose did not include a parseable expiry".to_string(),
                )
            });
        return ParsedSessionPurpose::ReadWrite { expiry };
    }

    ParsedSessionPurpose::Unknown(value.trim().to_string())
}

fn parse_session_timestamp(value: &str) -> Option<OffsetDateTime> {
    let trimmed = value.trim();
    OffsetDateTime::parse(trimmed, &Rfc3339)
        .ok()
        .or_else(|| {
            OffsetDateTime::parse(trimmed, DISPLAY_TS_WITH_SUBSECOND_AND_OFFSET_SECONDS).ok()
        })
        .or_else(|| OffsetDateTime::parse(trimmed, DISPLAY_TS_WITH_OFFSET_SECONDS).ok())
        .or_else(|| OffsetDateTime::parse(trimmed, DISPLAY_TS_WITH_SUBSECOND).ok())
        .or_else(|| OffsetDateTime::parse(trimmed, DISPLAY_TS).ok())
}

fn session_matches_admin(principal: &str, admin_name: &str) -> bool {
    principal == admin_name
        || principal
            .split_once('@')
            .map(|(local_part, _)| local_part == admin_name)
            .unwrap_or(false)
}

fn session_mentions_admin(diagnostic: &str, admin_name: &str) -> bool {
    if admin_name.is_empty() {
        return false;
    }

    diagnostic
        .lines()
        .filter_map(|line| line.split_once(':'))
        .any(|(key, value)| {
            let normalized_key = normalized(key);
            matches!(normalized_key.as_str(), "spn" | "account" | "name")
                && session_matches_admin(value.trim(), admin_name)
        })
        || diagnostic.contains(admin_name)
}

impl ParsedSession {
    fn snapshot(
        &self,
        admin_name: &str,
        server_url: &str,
        now: OffsetDateTime,
        parse_confidence: ParseConfidence,
    ) -> SessionSnapshot {
        let privileged_expiry = self.privileged_expiry();
        let base_session_state = if self.base_session_expired(now) {
            BaseSessionState::Expired
        } else {
            BaseSessionState::Present
        };
        let privileged_write_state = match base_session_state {
            BaseSessionState::Expired => PrivilegedWriteState::Unavailable,
            BaseSessionState::Present => self.privileged_write_state(now),
            BaseSessionState::Missing | BaseSessionState::Unknown => PrivilegedWriteState::Unknown,
        };

        SessionSnapshot {
            admin_name: admin_name.to_string(),
            server_url: server_url.to_string(),
            matched_principal: Some(self.principal.clone()),
            base_session_state,
            privileged_write_state,
            base_expiry: self.session_expiry.clone(),
            privileged_expiry,
            diagnostic_raw: self.raw.clone(),
            parse_confidence,
        }
    }

    fn base_session_expired(&self, now: OffsetDateTime) -> bool {
        matches!(&self.session_expiry, ParsedExpiry::At(expiry) if now >= *expiry)
    }

    fn privileged_expiry(&self) -> ParsedExpiry {
        match &self.purpose {
            ParsedSessionPurpose::ReadOnly => ParsedExpiry::Unknown(
                "read only sessions do not expose privileged expiry".to_string(),
            ),
            ParsedSessionPurpose::ReadWrite { expiry } => expiry.clone(),
            ParsedSessionPurpose::Unknown(_) => {
                ParsedExpiry::Unknown("session purpose was not parseable".to_string())
            }
        }
    }

    fn privileged_write_state(&self, now: OffsetDateTime) -> PrivilegedWriteState {
        match &self.purpose {
            ParsedSessionPurpose::ReadOnly => PrivilegedWriteState::ReauthRequired,
            ParsedSessionPurpose::ReadWrite { expiry } => match expiry {
                ParsedExpiry::At(expiry) if now < *expiry => PrivilegedWriteState::Ready,
                ParsedExpiry::At(_) | ParsedExpiry::Never | ParsedExpiry::Unknown(_) => {
                    PrivilegedWriteState::ReauthRequired
                }
            },
            ParsedSessionPurpose::Unknown(_) => PrivilegedWriteState::Unknown,
        }
    }
}

pub fn is_session_expired(text: &str) -> bool {
    text.contains("session has expired")
        || text.contains("expired auth token")
        || text.contains("token has expired")
        || text.contains("login again")
}

pub fn is_session_missing(text: &str) -> bool {
    text.contains("no valid auth tokens found")
        || text.contains("not authenticated")
        || text.contains("authentication required")
        || text.contains("no session")
}

pub fn is_reauth_required(text: &str) -> bool {
    text.contains("privileges have expired")
        || text.contains("privileges have not been re-authenticated")
        || text.contains("need to re-authenticate again")
        || text.contains("must re-authenticate")
        || text.contains("privileged session has expired")
}

pub fn is_not_found(text: &str) -> bool {
    text.contains("not found")
        || text.contains("no matching entries")
        || text.contains("does not exist")
        || text.contains("no entries were returned")
        || text.contains("cannot find")
}

pub fn is_already_exists(text: &str) -> bool {
    text.contains("already exists")
        || text.contains("duplicate")
        || text.contains("already present")
}

#[cfg(test)]
pub fn classify_session_state(diagnostic: &str) -> SessionState {
    classify_heuristic_session_snapshot(diagnostic, "", "")
        .map(|snapshot| snapshot.to_session_state())
        .unwrap_or_else(|| SessionState::Missing {
            diagnostic: diagnostic.trim().to_string(),
        })
}

#[cfg(test)]
mod tests {
    use std::ffi::OsString;

    use super::*;
    use crate::backend::{BackendCrashKind, ExitStatusSummary, RawCommandResult};

    fn session_listing_block(spn: &str, expiry: &str, privileged_expiry: &str) -> String {
        format!(
            r#"---
spn: {spn}
uuid: 00000000-0000-0000-0000-000000000001
display: Dan
expiry: {expiry}
purpose: read write (expiry: {privileged_expiry})
"#
        )
    }

    #[test]
    fn reauth_classifier_is_not_triggered_by_unrelated_text() {
        assert!(!is_reauth_required(
            "documentation mentions reauthentication flow"
        ));
        assert!(is_reauth_required("privileges have expired"));
    }

    #[test]
    fn classifies_expired_session_diagnostics() {
        assert!(matches!(
            classify_session_state("Session has expired; login again"),
            SessionState::Expired { .. }
        ));
    }

    #[test]
    fn classifies_missing_session_diagnostics() {
        assert!(matches!(
            classify_session_state("No valid auth tokens found"),
            SessionState::Missing { .. }
        ));
    }

    #[test]
    fn classifies_reauth_required_diagnostics() {
        assert!(matches!(
            classify_session_state("Privileges have expired"),
            SessionState::ReauthRequired { .. }
        ));
    }

    #[test]
    fn session_listing_without_entries_is_missing() {
        let snapshot = classify_session_snapshot(
            "",
            "admindsaw",
            "https://id.example.test",
            OffsetDateTime::UNIX_EPOCH,
        );
        assert_eq!(snapshot.base_session_state, BaseSessionState::Missing);
        assert_eq!(
            snapshot.privileged_write_state,
            PrivilegedWriteState::Unavailable
        );
        assert_eq!(snapshot.parse_confidence, ParseConfidence::High);
    }

    #[test]
    fn session_listing_with_other_user_is_missing() {
        let listing = session_listing_block(
            "someone@example.test",
            "2030-01-01T00:00:00Z",
            "2030-01-01T00:30:00Z",
        );
        let snapshot = classify_session_snapshot(
            &listing,
            "admindsaw",
            "https://id.example.test",
            OffsetDateTime::UNIX_EPOCH,
        );
        assert_eq!(snapshot.base_session_state, BaseSessionState::Missing);
        assert_eq!(snapshot.matched_principal, None);
    }

    #[test]
    fn session_listing_selects_matching_admin_block() {
        let listing = format!(
            "{}\n{}",
            session_listing_block(
                "someone@example.test",
                "2030-01-01T00:00:00Z",
                "2030-01-01T00:30:00Z"
            ),
            session_listing_block(
                "admindsaw@example.test",
                "2030-01-02T00:00:00Z",
                "2030-01-02T00:30:00Z"
            )
        );

        let snapshot = classify_session_snapshot(
            &listing,
            "admindsaw",
            "https://id.example.test",
            OffsetDateTime::UNIX_EPOCH,
        );
        assert_eq!(
            snapshot.matched_principal.as_deref(),
            Some("admindsaw@example.test")
        );
        assert_eq!(snapshot.base_session_state, BaseSessionState::Present);
        assert_eq!(snapshot.privileged_write_state, PrivilegedWriteState::Ready);
    }

    #[test]
    fn session_listing_marks_expired_admin_session_as_expired() {
        let listing = session_listing_block(
            "admindsaw@example.test",
            "2000-01-01T00:00:00Z",
            "2000-01-01T00:30:00Z",
        );
        let snapshot = classify_session_snapshot(
            &listing,
            "admindsaw",
            "https://id.example.test",
            OffsetDateTime::parse("2030-01-01T00:00:00Z", &Rfc3339).expect("now"),
        );
        assert_eq!(snapshot.base_session_state, BaseSessionState::Expired);
        assert_eq!(
            snapshot.privileged_write_state,
            PrivilegedWriteState::Unavailable
        );
    }

    #[test]
    fn session_listing_with_no_expiry_authenticates_base_session() {
        let listing = r#"---
spn: admindsaw@example.test
uuid: 00000000-0000-0000-0000-000000000001
display: Dan
expiry: -
purpose: read write (expiry: 2030-01-01T00:30:00Z)
"#;
        let snapshot = classify_session_snapshot(
            listing,
            "admindsaw",
            "https://id.example.test",
            OffsetDateTime::UNIX_EPOCH,
        );
        assert_eq!(snapshot.base_session_state, BaseSessionState::Present);
        assert_eq!(snapshot.privileged_write_state, PrivilegedWriteState::Ready);
    }

    #[test]
    fn session_listing_with_expired_privileges_requires_reauth() {
        let listing = session_listing_block(
            "admindsaw@example.test",
            "2030-01-01T01:00:00Z",
            "2000-01-01T00:30:00Z",
        );
        let snapshot = classify_session_snapshot(
            &listing,
            "admindsaw",
            "https://id.example.test",
            OffsetDateTime::parse("2030-01-01T00:00:00Z", &Rfc3339).expect("now"),
        );
        assert_eq!(snapshot.base_session_state, BaseSessionState::Present);
        assert_eq!(
            snapshot.privileged_write_state,
            PrivilegedWriteState::ReauthRequired
        );
    }

    #[test]
    fn heuristic_snapshot_keeps_base_session_but_requires_reauth() {
        let snapshot = classify_session_snapshot(
            "active token for admindsaw",
            "admindsaw",
            "https://id.example.test",
            OffsetDateTime::UNIX_EPOCH,
        );
        assert_eq!(snapshot.base_session_state, BaseSessionState::Present);
        assert_eq!(
            snapshot.privileged_write_state,
            PrivilegedWriteState::Unknown
        );
        assert_eq!(snapshot.parse_confidence, ParseConfidence::Heuristic);
        assert!(matches!(
            snapshot.to_session_state(),
            SessionState::ReauthRequired { .. }
        ));
    }

    #[test]
    fn strips_ansi_control_sequences_before_classification() {
        assert!(matches!(
            classify_session_state("\u{1b}[31mSession has expired; login again\u{1b}[0m"),
            SessionState::Expired { .. }
        ));
    }

    #[test]
    fn backend_failures_are_sanitized_to_primary_session_line() {
        let failure = BackendFailure {
            program: "kanidm".to_string(),
            args: vec!["person".to_string(), "list".to_string()],
            status: Some(101),
            stdout: String::new(),
            stderr: "thread 'main' panicked at /build/source/tools/cli/src/cli/common.rs:312:26:\nFailed to interact with interactive session: Io(Custom { kind: NotConnected, error: \"not a terminal\" })\n2026-05-07T11:43:44Z ERROR kanidm_cli::common: Session has expired for admindsaw@example.test - you may need to login again.".to_string(),
            crash_kind: Some(BackendCrashKind::InteractivePanic),
        };

        let observation = SessionInterpreter::from_backend_failure(
            &failure,
            "admindsaw",
            "https://id.example.test",
        );

        assert!(matches!(
            observation,
            SessionObservation::Failure(SessionFailureKind::Expired, SessionDiagnostic { .. })
        ));
        let SessionObservation::Failure(_, diagnostic) = observation else {
            unreachable!();
        };
        assert!(diagnostic.primary.contains("Session has expired"));
        assert!(!diagnostic.primary.contains("thread 'main'"));
    }

    #[test]
    fn startup_login_prompt_only_applies_to_missing_or_expired_base_sessions() {
        let missing = SessionSnapshot {
            admin_name: "admindsaw".to_string(),
            server_url: "https://id.example.test".to_string(),
            matched_principal: None,
            base_session_state: BaseSessionState::Missing,
            privileged_write_state: PrivilegedWriteState::Unavailable,
            base_expiry: ParsedExpiry::Unknown("missing".to_string()),
            privileged_expiry: ParsedExpiry::Unknown("missing".to_string()),
            diagnostic_raw: "missing".to_string(),
            parse_confidence: ParseConfidence::High,
        };
        let expired = SessionSnapshot {
            admin_name: "admindsaw".to_string(),
            server_url: "https://id.example.test".to_string(),
            matched_principal: Some("admindsaw@example.test".to_string()),
            base_session_state: BaseSessionState::Expired,
            privileged_write_state: PrivilegedWriteState::Unavailable,
            base_expiry: ParsedExpiry::Unknown("expired".to_string()),
            privileged_expiry: ParsedExpiry::Unknown("expired".to_string()),
            diagnostic_raw: "expired".to_string(),
            parse_confidence: ParseConfidence::High,
        };
        let ready = SessionSnapshot {
            admin_name: "admindsaw".to_string(),
            server_url: "https://id.example.test".to_string(),
            matched_principal: Some("admindsaw@example.test".to_string()),
            base_session_state: BaseSessionState::Present,
            privileged_write_state: PrivilegedWriteState::Ready,
            base_expiry: ParsedExpiry::Never,
            privileged_expiry: ParsedExpiry::Never,
            diagnostic_raw: "ready".to_string(),
            parse_confidence: ParseConfidence::High,
        };
        let reauth = SessionSnapshot {
            admin_name: "admindsaw".to_string(),
            server_url: "https://id.example.test".to_string(),
            matched_principal: Some("admindsaw@example.test".to_string()),
            base_session_state: BaseSessionState::Present,
            privileged_write_state: PrivilegedWriteState::ReauthRequired,
            base_expiry: ParsedExpiry::Never,
            privileged_expiry: ParsedExpiry::Unknown("reauth".to_string()),
            diagnostic_raw: "reauth".to_string(),
            parse_confidence: ParseConfidence::High,
        };
        let unknown = SessionSnapshot {
            admin_name: "admindsaw".to_string(),
            server_url: "https://id.example.test".to_string(),
            matched_principal: None,
            base_session_state: BaseSessionState::Unknown,
            privileged_write_state: PrivilegedWriteState::Unknown,
            base_expiry: ParsedExpiry::Unknown("unknown".to_string()),
            privileged_expiry: ParsedExpiry::Unknown("unknown".to_string()),
            diagnostic_raw: "unknown".to_string(),
            parse_confidence: ParseConfidence::Heuristic,
        };

        assert!(should_prompt_for_startup_login(&missing));
        assert!(should_prompt_for_startup_login(&expired));
        assert!(!should_prompt_for_startup_login(&ready));
        assert!(!should_prompt_for_startup_login(&reauth));
        assert!(!should_prompt_for_startup_login(&unknown));
    }

    #[test]
    fn concise_session_messages_match_common_operator_states() {
        let missing = SessionSnapshot {
            admin_name: "admindsaw".to_string(),
            server_url: "https://id.example.test".to_string(),
            matched_principal: None,
            base_session_state: BaseSessionState::Missing,
            privileged_write_state: PrivilegedWriteState::Unavailable,
            base_expiry: ParsedExpiry::Unknown("missing".to_string()),
            privileged_expiry: ParsedExpiry::Unknown("missing".to_string()),
            diagnostic_raw: "missing".to_string(),
            parse_confidence: ParseConfidence::High,
        };
        let expired = SessionSnapshot {
            admin_name: "admindsaw".to_string(),
            server_url: "https://id.example.test".to_string(),
            matched_principal: Some("admindsaw@example.test".to_string()),
            base_session_state: BaseSessionState::Expired,
            privileged_write_state: PrivilegedWriteState::Unavailable,
            base_expiry: ParsedExpiry::Unknown("expired".to_string()),
            privileged_expiry: ParsedExpiry::Unknown("expired".to_string()),
            diagnostic_raw: "expired".to_string(),
            parse_confidence: ParseConfidence::High,
        };
        let reauth = SessionSnapshot {
            admin_name: "admindsaw".to_string(),
            server_url: "https://id.example.test".to_string(),
            matched_principal: Some("admindsaw@example.test".to_string()),
            base_session_state: BaseSessionState::Present,
            privileged_write_state: PrivilegedWriteState::ReauthRequired,
            base_expiry: ParsedExpiry::Never,
            privileged_expiry: ParsedExpiry::Unknown("reauth".to_string()),
            diagnostic_raw: "reauth".to_string(),
            parse_confidence: ParseConfidence::High,
        };

        assert_eq!(
            login_prompt_message(&missing),
            Some("No active admin session was found. Would you like to log in now?")
        );
        assert_eq!(
            login_prompt_message(&expired),
            Some("Your previous admin session has expired. Would you like to log in again?")
        );
        assert_eq!(
            concise_session_message("admindsaw", &missing).as_deref(),
            Some(
                "No active admin session was found for 'admindsaw'. Run `kanidm-admin session login` to log in."
            )
        );
        assert_eq!(
            concise_session_message("admindsaw", &expired).as_deref(),
            Some(
                "The previous admin session for 'admindsaw' has expired. Run `kanidm-admin session login` to log in again."
            )
        );
        assert_eq!(
            concise_session_message("admindsaw", &reauth).as_deref(),
            Some(
                "Privileged write access for 'admindsaw' requires reauthentication. Run `kanidm-admin session reauth` first."
            )
        );
    }

    #[test]
    fn unknown_backend_failures_do_not_look_authenticated() {
        let failure = BackendFailure::from_raw(
            &OsString::from("kanidm"),
            vec!["session".to_string(), "list".to_string()],
            RawCommandResult {
                status: ExitStatusSummary {
                    success: false,
                    code: Some(2),
                },
                stdout: String::new(),
                stderr: "totally unrelated backend problem".to_string(),
            },
        );

        let observation = SessionInterpreter::from_backend_failure(
            &failure,
            "admindsaw",
            "https://id.example.test",
        );

        assert!(matches!(
            observation,
            SessionObservation::Failure(SessionFailureKind::Unknown, _)
        ));
    }
}
