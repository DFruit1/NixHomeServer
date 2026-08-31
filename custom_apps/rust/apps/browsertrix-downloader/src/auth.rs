use crate::model::CurrentUser;
use axum::http::HeaderMap;
use std::{collections::BTreeSet, fmt};

const USER_HEADERS: [&str; 8] = [
    "x-forwarded-preferred-username",
    "x-auth-request-preferred-username",
    "x-forwarded-login",
    "x-auth-request-login",
    "x-forwarded-email",
    "x-auth-request-email",
    "x-forwarded-user",
    "x-auth-request-user",
];
const EMAIL_HEADERS: [&str; 2] = ["x-forwarded-email", "x-auth-request-email"];
const GROUP_HEADERS: [&str; 2] = ["x-forwarded-groups", "x-auth-request-groups"];

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AuthError;

impl fmt::Display for AuthError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("missing authenticated user header")
    }
}

impl std::error::Error for AuthError {}

pub fn current_user(headers: &HeaderMap) -> Result<CurrentUser, AuthError> {
    let username = USER_HEADERS
        .iter()
        .find_map(|name| header(headers, name).and_then(normalize_username))
        .ok_or(AuthError)?;
    let email = EMAIL_HEADERS
        .iter()
        .find_map(|name| header(headers, name).and_then(first_list_value));
    let mut groups = BTreeSet::new();
    for name in GROUP_HEADERS {
        if let Some(value) = header(headers, name) {
            groups.extend(
                value
                    .split(|character: char| character == ',' || character.is_whitespace())
                    .map(str::trim)
                    .filter(|group| !group.is_empty())
                    .map(str::to_owned),
            );
        }
    }
    Ok(CurrentUser {
        username,
        email,
        groups: groups.into_iter().collect(),
    })
}

fn header<'a>(headers: &'a HeaderMap, name: &str) -> Option<&'a str> {
    headers.get(name)?.to_str().ok()
}

fn first_list_value(value: &str) -> Option<String> {
    let first = value.split(',').next()?.trim();
    (!first.is_empty()).then(|| first.to_owned())
}

fn normalize_username(value: &str) -> Option<String> {
    let first = value.split(',').next()?.trim();
    let local = first.split('@').next()?;
    let valid = !local.is_empty()
        && local.len() <= 64
        && local
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || "._-".contains(character));
    valid.then(|| local.to_owned())
}
