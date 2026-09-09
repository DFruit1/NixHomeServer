use crate::model::CurrentUser;
use axum::http::HeaderMap;
use homelab_common::from_forwarded_headers;
use std::fmt;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AuthError;

impl fmt::Display for AuthError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("missing authenticated user header")
    }
}

impl std::error::Error for AuthError {}

pub fn current_user(headers: &HeaderMap) -> Result<CurrentUser, AuthError> {
    let forwarded = from_forwarded_headers(headers).map_err(|_| AuthError)?;
    let username = normalize_username(&forwarded.username).ok_or(AuthError)?;
    Ok(CurrentUser {
        username,
        email: forwarded.email,
        groups: forwarded.groups,
    })
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
