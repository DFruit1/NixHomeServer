//! Gateway-forwarded identity.
//!
//! Authentication and coarse authorization are enforced by the shared auth
//! gateway before a request reaches this loopback listener; it strips any
//! client-supplied identity headers and injects its own. This module surfaces
//! the forwarded identity and resolves it against the role that grants access,
//! mirroring the other gateway-fronted Rust apps in this repo.

use axum::http::HeaderMap;

/// The authenticated user.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Identity {
    pub username: String,
    pub groups: Vec<String>,
}

/// Role a caller holds, derived from their Kanidm groups.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Role {
    /// May read dashboards, charts and the message log.
    Viewer,
    /// May additionally change device state. Command endpoints require this.
    Operator,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum IdentityError {
    Missing,
}

impl std::fmt::Display for IdentityError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("missing authenticated identity headers")
    }
}

impl std::error::Error for IdentityError {}

impl Identity {
    pub fn from_headers(headers: &HeaderMap) -> Result<Self, IdentityError> {
        let forwarded = homelab_common::from_forwarded_headers(headers).map_err(|_| IdentityError::Missing)?;
        Ok(Self {
            username: forwarded.username,
            groups: forwarded.groups,
        })
    }

    pub fn has_group(&self, group: &str) -> bool {
        self.groups
            .iter()
            .any(|candidate| candidate.eq_ignore_ascii_case(group))
    }
}

/// Resolves the caller's role from their groups.
///
/// `app-admin` is the existing repository-wide administrator group and grants
/// operator access. `groundwater-user` is the read-only viewer group for this
/// app. Anyone else authenticated is refused.
pub fn role_for(identity: &Identity) -> Option<Role> {
    if identity.has_group("app-admin") {
        return Some(Role::Operator);
    }
    if identity.has_group("groundwater-user") {
        return Some(Role::Viewer);
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn identity_with(groups: &str) -> Identity {
        let mut headers = HeaderMap::new();
        headers.insert(
            "x-forwarded-preferred-username",
            "operator".parse().expect("header"),
        );
        headers.insert("x-forwarded-groups", groups.parse().expect("header"));
        Identity::from_headers(&headers).expect("identity")
    }

    #[test]
    fn reads_forwarded_identity() {
        let identity = identity_with("app-admin, domain_admins");
        assert_eq!(identity.username, "operator");
        assert_eq!(identity.groups, vec!["app-admin", "domain_admins"]);
        assert!(identity.has_group("app-admin"));
        assert!(identity.has_group("APP-ADMIN"));
    }

    #[test]
    fn rejects_missing_identity() {
        assert_eq!(Identity::from_headers(&HeaderMap::new()), Err(IdentityError::Missing));
    }

    #[test]
    fn admin_is_operator_and_groundwater_user_is_viewer() {
        assert_eq!(role_for(&identity_with("app-admin")), Some(Role::Operator));
        assert_eq!(
            role_for(&identity_with("groundwater-user")),
            Some(Role::Viewer)
        );
    }

    #[test]
    fn unrelated_group_is_refused() {
        assert_eq!(role_for(&identity_with("domain_admins")), None);
    }

    #[test]
    fn admin_outranks_viewer_in_the_group_list() {
        // Both groups present resolves to the more privileged role.
        assert_eq!(role_for(&identity_with("groundwater-user,app-admin")), Some(Role::Operator));
    }
}