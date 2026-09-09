use axum::http::HeaderMap;
use url::{Position, Url};

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SameOriginError {
    MissingExpectedOrigin,
    Mismatch,
    MissingOriginOrReferer,
}

impl std::fmt::Display for SameOriginError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let message = match self {
            Self::MissingExpectedOrigin => "Unable to determine the expected request origin",
            Self::Mismatch => "Cross-origin state-changing requests are not allowed",
            Self::MissingOriginOrReferer => {
                "Origin or Referer is required for state-changing requests"
            }
        };
        formatter.write_str(message)
    }
}

pub fn assert_same_origin(headers: &HeaderMap) -> Result<(), SameOriginError> {
    if let Some(site) = header_value(headers, "sec-fetch-site") {
        if site != "same-origin" {
            return Err(SameOriginError::Mismatch);
        }
    }
    let expected_hosts = expected_hosts(headers);
    if expected_hosts.is_empty() {
        return Err(SameOriginError::MissingExpectedOrigin);
    }
    let forwarded_proto =
        header_value(headers, "x-forwarded-proto").and_then(|value| first_list_value(&value));
    let candidate = header_value(headers, "origin")
        .map(|value| (value, true))
        .or_else(|| header_value(headers, "referer").map(|value| (value, false)))
        .ok_or(SameOriginError::MissingOriginOrReferer)?;
    let (candidate, is_origin) = candidate;
    let parsed = Url::parse(&candidate).map_err(|_| SameOriginError::Mismatch)?;
    if !matches!(parsed.scheme(), "http" | "https") {
        return Err(SameOriginError::Mismatch);
    }
    if let Some(proto) = &forwarded_proto {
        if parsed.scheme() != proto.as_str() {
            return Err(SameOriginError::Mismatch);
        }
    }
    let authority = &parsed[Position::BeforeHost..Position::AfterPort];
    if !expected_hosts
        .iter()
        .any(|host| authority.eq_ignore_ascii_case(host))
    {
        return Err(SameOriginError::Mismatch);
    }
    if is_origin && parsed.origin().ascii_serialization() != candidate {
        return Err(SameOriginError::Mismatch);
    }
    Ok(())
}

fn expected_hosts(headers: &HeaderMap) -> Vec<String> {
    let mut hosts = Vec::new();
    if let Some(forwarded) = header_value(headers, "x-forwarded-host") {
        if let Some(first) = first_list_value(&forwarded) {
            hosts.push(first);
        }
    }
    if let Some(host) = header_value(headers, "host") {
        hosts.push(host);
    }
    hosts
}

fn header_value(headers: &HeaderMap, name: &str) -> Option<String> {
    headers
        .get(name)
        .and_then(|value| value.to_str().ok())
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn first_list_value(value: &str) -> Option<String> {
    let first = value.split(',').next()?.trim().to_string();
    (!first.is_empty()).then_some(first)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn headers(pairs: &[(&str, &str)]) -> HeaderMap {
        let mut headers = HeaderMap::new();
        for (name, value) in pairs {
            headers.insert(
                axum::http::HeaderName::from_lowercase(name.as_bytes()).expect("header name"),
                value.parse().expect("header value"),
            );
        }
        headers
    }

    #[test]
    fn accepts_origin_matching_host() {
        let headers = headers(&[
            ("host", "archives.example.test"),
            ("origin", "https://archives.example.test"),
        ]);
        assert_eq!(assert_same_origin(&headers), Ok(()));
    }

    #[test]
    fn accepts_forwarded_host_with_forwarded_proto() {
        let headers = headers(&[
            ("x-forwarded-host", "mail.example.test"),
            ("x-forwarded-proto", "https"),
            ("origin", "https://mail.example.test"),
        ]);
        assert_eq!(assert_same_origin(&headers), Ok(()));
    }

    #[test]
    fn accepts_same_origin_referer_when_origin_is_absent() {
        let headers = headers(&[
            ("x-forwarded-host", "mail.example.test"),
            ("x-forwarded-proto", "https"),
            ("referer", "https://mail.example.test/attachments"),
        ]);
        assert_eq!(assert_same_origin(&headers), Ok(()));
    }

    #[test]
    fn rejects_cross_site_origin() {
        let headers = headers(&[
            ("host", "archives.example.test"),
            ("origin", "https://evil.example"),
        ]);
        assert_eq!(assert_same_origin(&headers), Err(SameOriginError::Mismatch));
    }

    #[test]
    fn rejects_scheme_conflicts_with_forwarded_proto() {
        let headers = headers(&[
            ("x-forwarded-host", "mail.example.test"),
            ("x-forwarded-proto", "https"),
            ("origin", "http://mail.example.test"),
        ]);
        assert_eq!(assert_same_origin(&headers), Err(SameOriginError::Mismatch));
    }

    #[test]
    fn rejects_lookalike_host_suffix() {
        let headers = headers(&[
            ("x-forwarded-host", "mail.example.test"),
            ("referer", "https://mail.example.test.evil/"),
        ]);
        assert_eq!(assert_same_origin(&headers), Err(SameOriginError::Mismatch));
    }

    #[test]
    fn rejects_missing_origin_and_referer() {
        let headers = headers(&[("host", "archives.example.test")]);
        assert_eq!(
            assert_same_origin(&headers),
            Err(SameOriginError::MissingOriginOrReferer)
        );
    }

    #[test]
    fn rejects_cross_site_fetch_metadata() {
        let headers = headers(&[
            ("host", "archives.example.test"),
            ("sec-fetch-site", "cross-site"),
            ("origin", "https://archives.example.test"),
        ]);
        assert_eq!(assert_same_origin(&headers), Err(SameOriginError::Mismatch));
    }
}
