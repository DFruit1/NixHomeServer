use axum::http::{HeaderMap, HeaderValue};
use browsertrix_downloader::{
    auth::current_user,
    model::CrawlScope,
    validation::{
        assert_public_addresses, parse_create_job, CreateJobInput, DEFAULT_PAGE_LIMIT,
        DEFAULT_TIME_LIMIT_MINUTES, MAX_PAGE_LIMIT, MAX_TIME_LIMIT_MINUTES,
    },
};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

#[test]
fn forwarded_identity_prefers_canonical_username_and_collects_groups() {
    let mut headers = HeaderMap::new();
    headers.insert(
        "x-forwarded-user",
        HeaderValue::from_static("opaque-subject"),
    );
    headers.insert(
        "x-forwarded-preferred-username",
        HeaderValue::from_static("Alice@example.test"),
    );
    headers.insert(
        "x-forwarded-email",
        HeaderValue::from_static("alice@example.test"),
    );
    headers.insert(
        "x-forwarded-groups",
        HeaderValue::from_static("web-archive-users, users web-archive-users"),
    );

    let user = current_user(&headers).expect("authenticated user");
    assert_eq!(user.username, "Alice");
    assert_eq!(user.email.as_deref(), Some("alice@example.test"));
    assert_eq!(user.groups, ["users", "web-archive-users"]);
}

#[test]
fn missing_or_malformed_forwarded_identity_is_rejected() {
    assert!(current_user(&HeaderMap::new()).is_err());
    let mut headers = HeaderMap::new();
    headers.insert(
        "x-forwarded-preferred-username",
        HeaderValue::from_static("bad/user"),
    );
    assert!(current_user(&headers).is_err());
}

#[test]
fn create_request_is_normalized_defaulted_and_clamped() {
    let parsed = parse_create_job(CreateJobInput {
        url: "  https://Example.COM/path?q=1#fragment  ".to_owned(),
        scope: None,
        page_limit: None,
        time_limit_minutes: None,
    })
    .expect("valid request");
    assert_eq!(parsed.hostname, "example.com");
    assert_eq!(parsed.request.url, "https://example.com/path?q=1");
    assert_eq!(parsed.request.scope, CrawlScope::Page);
    assert_eq!(parsed.request.page_limit, DEFAULT_PAGE_LIMIT);
    assert_eq!(
        parsed.request.time_limit_minutes,
        DEFAULT_TIME_LIMIT_MINUTES
    );

    let clamped = parse_create_job(CreateJobInput {
        url: "https://example.com".to_owned(),
        scope: Some(CrawlScope::Host),
        page_limit: Some(u32::MAX),
        time_limit_minutes: Some(u32::MAX),
    })
    .expect("clamped request");
    assert_eq!(clamped.request.page_limit, MAX_PAGE_LIMIT);
    assert_eq!(clamped.request.time_limit_minutes, MAX_TIME_LIMIT_MINUTES);
}

#[test]
fn unsafe_or_non_http_urls_are_rejected() {
    for url in [
        "file:///etc/passwd",
        "https://user:secret@example.com/",
        "https://example.com/space here",
        "https://localhost/",
        "https://127.0.0.1/",
        "https://[::1]/",
    ] {
        assert!(
            parse_create_job(CreateJobInput {
                url: url.to_owned(),
                scope: None,
                page_limit: None,
                time_limit_minutes: None,
            })
            .is_err(),
            "{url} should be rejected"
        );
    }
}

#[test]
fn resolved_private_or_link_local_destinations_are_rejected() {
    for address in [
        IpAddr::V4(Ipv4Addr::new(10, 0, 0, 1)),
        IpAddr::V4(Ipv4Addr::new(100, 64, 0, 1)),
        IpAddr::V4(Ipv4Addr::new(169, 254, 1, 2)),
        IpAddr::V6(Ipv6Addr::LOCALHOST),
        "fd00::1".parse().expect("IPv6"),
        "fe80::1".parse().expect("IPv6"),
    ] {
        assert!(assert_public_addresses(&[address]).is_err(), "{address}");
    }
    assert!(assert_public_addresses(&[]).is_err());
    assert!(assert_public_addresses(&[IpAddr::V4(Ipv4Addr::new(93, 184, 216, 34))]).is_ok());
}
