use axum::http::HeaderMap;

/// The authenticated admin performing the search. Authorization itself is
/// enforced by the shared auth gateway; this module only surfaces the identity
/// the gateway forwards, mirroring the other gateway-fronted Rust apps.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Identity {
    pub username: String,
    pub groups: Vec<String>,
}

impl Identity {
    pub fn from_headers(headers: &HeaderMap) -> Result<Self, IdentityError> {
        let forwarded =
            homelab_common::from_forwarded_headers(headers).map_err(|_| IdentityError)?;
        Ok(Self {
            username: forwarded.username,
            groups: forwarded.groups,
        })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct IdentityError;

impl std::fmt::Display for IdentityError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("missing authenticated identity headers")
    }
}

impl std::error::Error for IdentityError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_forwarded_identity() {
        let mut headers = HeaderMap::new();
        headers.insert(
            "x-forwarded-preferred-username",
            "admin".parse().expect("header"),
        );
        headers.insert(
            "x-forwarded-groups",
            "app-admin, domain_admins".parse().expect("header"),
        );
        let identity = Identity::from_headers(&headers).expect("identity");
        assert_eq!(identity.username, "admin");
        assert_eq!(identity.groups, vec!["app-admin", "domain_admins"]);
    }

    #[test]
    fn rejects_missing_identity() {
        assert!(Identity::from_headers(&HeaderMap::new()).is_err());
    }
}
