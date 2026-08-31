use crate::model::{CrawlScope, CreateJobRequest};
use serde::Deserialize;
use std::{fmt, net::IpAddr};

pub const DEFAULT_PAGE_LIMIT: u32 = 25;
pub const MAX_PAGE_LIMIT: u32 = 500;
pub const DEFAULT_TIME_LIMIT_MINUTES: u32 = 10;
pub const MAX_TIME_LIMIT_MINUTES: u32 = 120;

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateJobInput {
    pub url: String,
    #[serde(default)]
    pub scope: Option<CrawlScope>,
    #[serde(default)]
    pub page_limit: Option<u32>,
    #[serde(default)]
    pub time_limit_minutes: Option<u32>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ParsedCreateJob {
    pub request: CreateJobRequest,
    pub hostname: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ValidationError(pub String);

impl fmt::Display for ValidationError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for ValidationError {}

pub fn parse_create_job(input: CreateJobInput) -> Result<ParsedCreateJob, ValidationError> {
    let raw = input.url.trim();
    if raw.is_empty() || raw.len() > 2_048 || raw.chars().any(char::is_whitespace) {
        return Err(invalid_url());
    }
    let mut url = url::Url::parse(raw).map_err(|_| invalid_url())?;
    if !matches!(url.scheme(), "http" | "https")
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return Err(invalid_url());
    }
    let (hostname, literal_address) = match url.host().ok_or_else(invalid_url)? {
        url::Host::Domain(host) => (host.trim_end_matches('.').to_ascii_lowercase(), None),
        url::Host::Ipv4(address) => (address.to_string(), Some(IpAddr::V4(address))),
        url::Host::Ipv6(address) => (address.to_string(), Some(IpAddr::V6(address))),
    };
    if hostname.is_empty() || hostname.len() > 253 {
        return Err(invalid_url());
    }
    if hostname == "localhost" {
        return Err(ValidationError(
            "refusing to archive private, loopback, or link-local addresses".to_owned(),
        ));
    }
    if let Some(address) = literal_address {
        assert_public_addresses(&[address])?;
    }
    url.set_fragment(None);
    let page_limit = nonzero_or_default(input.page_limit, DEFAULT_PAGE_LIMIT).min(MAX_PAGE_LIMIT);
    let time_limit_minutes =
        nonzero_or_default(input.time_limit_minutes, DEFAULT_TIME_LIMIT_MINUTES)
            .min(MAX_TIME_LIMIT_MINUTES);
    Ok(ParsedCreateJob {
        request: CreateJobRequest {
            url: url.to_string(),
            scope: input.scope.unwrap_or(CrawlScope::Page),
            page_limit,
            time_limit_minutes,
        },
        hostname,
    })
}

pub fn assert_public_addresses(addresses: &[IpAddr]) -> Result<(), ValidationError> {
    if addresses.is_empty() {
        return Err(ValidationError("could not resolve hostname".to_owned()));
    }
    if addresses.iter().copied().any(is_private_address) {
        return Err(ValidationError(
            "refusing to archive private, loopback, or link-local addresses".to_owned(),
        ));
    }
    Ok(())
}

fn nonzero_or_default(value: Option<u32>, default: u32) -> u32 {
    match value {
        Some(0) | None => default,
        Some(value) => value,
    }
}

fn is_private_address(address: IpAddr) -> bool {
    match address {
        IpAddr::V4(address) => {
            address.is_private()
                || address.is_loopback()
                || address.is_link_local()
                || address.is_unspecified()
                || address.is_multicast()
                || address.is_broadcast()
                || (address.octets()[0] == 100 && (64..=127).contains(&address.octets()[1]))
        }
        IpAddr::V6(address) => {
            if let Some(mapped) = address.to_ipv4_mapped() {
                return is_private_address(IpAddr::V4(mapped));
            }
            let first = address.segments()[0];
            address.is_loopback()
                || address.is_unspecified()
                || address.is_multicast()
                || first & 0xfe00 == 0xfc00
                || first & 0xffc0 == 0xfe80
        }
    }
}

fn invalid_url() -> ValidationError {
    ValidationError("a valid http(s) website URL is required".to_owned())
}
