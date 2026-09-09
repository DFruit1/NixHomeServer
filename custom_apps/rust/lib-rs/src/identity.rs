use axum::http::HeaderMap;
use std::fmt;

const SUBJECT_HEADERS: [&str; 2] = ["x-forwarded-user", "x-auth-request-user"];
const USERNAME_HEADERS: [&str; 8] = [
    "x-forwarded-preferred-username",
    "x-auth-request-preferred-username",
    "x-forwarded-login",
    "x-auth-request-login",
    "x-forwarded-user",
    "x-auth-request-user",
    "x-forwarded-email",
    "x-auth-request-email",
];
const EMAIL_HEADERS: [&str; 2] = ["x-forwarded-email", "x-auth-request-email"];
const GROUP_HEADERS: [&str; 2] = ["x-forwarded-groups", "x-auth-request-groups"];

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct IdentityError;

impl fmt::Display for IdentityError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("missing authenticated user header")
    }
}

impl std::error::Error for IdentityError {}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ForwardedIdentity {
    pub subject: String,
    pub username: String,
    pub email: Option<String>,
    pub groups: Vec<String>,
}

pub fn from_forwarded_headers(headers: &HeaderMap) -> Result<ForwardedIdentity, IdentityError> {
    let mut subject = String::new();
    for name in SUBJECT_HEADERS {
        if let Some(value) = candidate_value(headers, name)? {
            subject = value;
            break;
        }
    }
    let mut username = String::new();
    for name in USERNAME_HEADERS {
        if let Some(value) = candidate_value(headers, name)? {
            username = value;
            break;
        }
    }
    if username.is_empty() {
        if !subject.is_empty() {
            username = subject.clone();
        } else {
            return Err(IdentityError);
        }
    }
    let mut email = None;
    for name in EMAIL_HEADERS {
        if let Some(value) = candidate_value(headers, name)? {
            email = first_list_value(&value);
            if email.is_some() {
                break;
            }
        }
    }
    let mut groups = Vec::new();
    for name in GROUP_HEADERS {
        if let Some(value) = candidate_value(headers, name)? {
            groups.extend(split_groups(&value));
        }
    }
    groups.sort();
    groups.dedup();
    Ok(ForwardedIdentity {
        subject,
        username,
        email,
        groups,
    })
}

fn candidate_value(headers: &HeaderMap, name: &str) -> Result<Option<String>, IdentityError> {
    let Some(value) = headers.get(name) else {
        return Ok(None);
    };
    let text = value.to_str().map_err(|_| IdentityError)?;
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Ok(None);
    }
    Ok(Some(trimmed.to_string()))
}

pub fn header_value(headers: &HeaderMap, name: &str) -> Option<String> {
    headers
        .get(name)
        .and_then(|value| value.to_str().ok())
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string)
}

pub fn first_list_value(value: &str) -> Option<String> {
    let first = value.split(',').next()?.trim();
    (!first.is_empty()).then(|| first.to_owned())
}

pub fn split_groups(raw: &str) -> Vec<String> {
    raw.split(|character: char| character == ',' || character == ';' || character.is_whitespace())
        .map(str::trim)
        .filter(|group| !group.is_empty())
        .map(ToString::to_string)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_username_from_preferred_username() {
        let mut headers = HeaderMap::new();
        headers.insert(
            "x-forwarded-preferred-username",
            "alice".parse().expect("header"),
        );
        headers.insert(
            "x-forwarded-email",
            "alice@example.com".parse().expect("header"),
        );
        headers.insert(
            "x-forwarded-groups",
            "editors, viewers".parse().expect("header"),
        );
        let identity = from_forwarded_headers(&headers).expect("identity");
        assert_eq!(identity.username, "alice");
        assert_eq!(identity.subject, "");
        assert_eq!(identity.email.as_deref(), Some("alice@example.com"));
        assert_eq!(identity.groups, vec!["editors", "viewers"]);
    }

    #[test]
    fn username_falls_back_to_subject_and_accepts_auth_request_headers() {
        let mut headers = HeaderMap::new();
        headers.insert("x-auth-request-user", "bob".parse().expect("header"));
        headers.insert("x-auth-request-groups", "users".parse().expect("header"));
        let identity = from_forwarded_headers(&headers).expect("identity");
        assert_eq!(identity.username, "bob");
        assert_eq!(identity.subject, "bob");
        assert_eq!(identity.groups, vec!["users"]);
    }

    #[test]
    fn empty_preferred_username_falls_back_to_subject() {
        let mut headers = HeaderMap::new();
        headers.insert("x-forwarded-user", "legacy-user".parse().expect("header"));
        headers.insert(
            "x-forwarded-preferred-username",
            "  ".parse().expect("header"),
        );
        let identity = from_forwarded_headers(&headers).expect("identity");
        assert_eq!(identity.username, "legacy-user");
    }

    #[test]
    fn malformed_username_header_is_rejected_instead_of_falling_back() {
        let mut headers = HeaderMap::new();
        headers.insert("x-forwarded-user", "fallback-user".parse().expect("header"));
        headers.insert(
            "x-forwarded-preferred-username",
            axum::http::HeaderValue::from_bytes(&[0xff]).expect("opaque header"),
        );
        assert!(from_forwarded_headers(&headers).is_err());
    }

    #[test]
    fn missing_username_header_is_rejected() {
        let headers = HeaderMap::new();
        assert!(from_forwarded_headers(&headers).is_err());
    }

    #[test]
    fn groups_are_split_sorted_and_deduplicated() {
        let mut headers = HeaderMap::new();
        headers.insert("x-forwarded-user", "u".parse().expect("header"));
        headers.insert(
            "x-forwarded-groups",
            "zeta, alpha;zeta\tomega".parse().expect("header"),
        );
        let identity = from_forwarded_headers(&headers).expect("identity");
        assert_eq!(identity.groups, vec!["alpha", "omega", "zeta"]);
    }
}
