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
    #[serde(default)]
    pub collection: Option<String>,
    #[serde(default)]
    pub options: Option<crate::model::CaptureOptions>,
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
    if input.collection.as_ref().is_some_and(|c| {
        c.is_empty()
            || c.len() > 80
            || !c
                .bytes()
                .all(|v| v.is_ascii_alphanumeric() || v == b'-' || v == b'_')
    }) {
        return Err(ValidationError(
            "collection must be a safe path segment".into(),
        ));
    }
    let scope = input.scope.unwrap_or(CrawlScope::Page);
    let mut options = input.options.unwrap_or_default();
    validate_options(&mut options, scope)?;
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
    if input.scope != Some(CrawlScope::PageSpa) {
        url.set_fragment(None);
    }
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
            collection: input.collection,
            options,
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
            address.octets()[0] == 0
                || address.octets()[0] >= 224
                || address.is_documentation()
                || address.is_private()
                || address.is_loopback()
                || address.is_link_local()
                || address.is_unspecified()
                || address.is_multicast()
                || address.is_broadcast()
                || address.octets()[..2] == [198, 18]
                || address.octets()[..2] == [198, 19]
                || address.octets()[..3] == [192, 0, 0]
                || (address.octets()[0] == 100 && (64..=127).contains(&address.octets()[1]))
        }
        IpAddr::V6(address) => {
            if let Some(mapped) = address.to_ipv4_mapped() {
                return is_private_address(IpAddr::V4(mapped));
            }
            let first = address.segments()[0];
            first & 0xe000 != 0x2000
                || address.segments()[..2] == [0x2001, 0xdb8]
                || first == 0x2002
                || address.segments()[..2] == [0x2001, 0]
                || address.is_loopback()
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

impl CreateJobInput {
    pub fn from_request(r: &CreateJobRequest) -> Self {
        Self {
            url: r.url.clone(),
            scope: Some(r.scope),
            page_limit: Some(r.page_limit),
            time_limit_minutes: Some(r.time_limit_minutes),
            collection: r.collection.clone(),
            options: Some(r.options.clone()),
        }
    }
}
pub fn validate_selectors(rules: &[crate::model::SelectorRule]) -> Result<(), ValidationError> {
    if rules.len() > 50 {
        return Err(ValidationError("at most 50 selector rules".into()));
    }
    for rule in rules {
        if rule.selector.is_empty()
            || rule.selector.len() > 512
            || rule.selector.chars().any(char::is_control)
            || !matches!(rule.action.as_str(), "hide" | "block")
            || rule.url_prefix.as_ref().is_some_and(|v| v.len() > 2048)
        {
            return Err(ValidationError("invalid bounded selector rule".into()));
        }
    }
    Ok(())
}
pub fn validate_interactions(steps: &[crate::model::Interaction]) -> Result<(), ValidationError> {
    if steps.len() > 20 {
        return Err(ValidationError("at most 20 interaction assertions".into()));
    }
    for step in steps {
        if step.selector.is_empty()
            || step.selector.len() > 512
            || step.expected.is_empty()
            || step.expected.len() > 512
            || !matches!(step.assertion.as_str(), "visible" | "hidden" | "text")
            || step.selector.chars().any(char::is_control)
        {
            return Err(ValidationError("interaction requires bounded selector, visible/hidden/text assertion and expected selector/text".into()));
        }
    }
    Ok(())
}
pub fn validate_export(
    options: &crate::archive_engine::ExportOptions,
) -> Result<(), ValidationError> {
    for list in [
        &options.include_urls,
        &options.exclude_urls,
        &options.exclude_domains,
        &options.exclude_mime_prefixes,
        &options.remove_selectors,
    ] {
        if list.len() > 100
            || list
                .iter()
                .any(|v| v.is_empty() || v.len() > 2048 || v.chars().any(char::is_control))
        {
            return Err(ValidationError(
                "export selection exceeds bounded limits".into(),
            ));
        }
    }
    if options.title.len() > 512 {
        return Err(ValidationError("export title too long".into()));
    }
    Ok(())
}
fn validate_options(
    options: &mut crate::model::CaptureOptions,
    scope: CrawlScope,
) -> Result<(), ValidationError> {
    if !matches!(options.preset.as_str(), "faithful" | "balanced" | "reader")
        || !matches!(options.media.as_str(), "full" | "posters" | "none")
    {
        return Err(ValidationError(
            "invalid capture preset/media policy".into(),
        ));
    }
    if !(-1..=32).contains(&options.depth) {
        return Err(ValidationError("depth must be -1 to 32".into()));
    }
    if scope == CrawlScope::Page {
        options.depth = 0;
    }
    if options.seeds.len() > 100 {
        return Err(ValidationError("at most 100 seeds".into()));
    }
    for seed in &mut options.seeds {
        let parsed = parse_create_job(CreateJobInput {
            url: seed.clone(),
            scope: Some(scope),
            page_limit: None,
            time_limit_minutes: None,
            collection: None,
            options: None,
        })?;
        *seed = parsed.request.url;
    }
    options.seeds.sort();
    options.seeds.dedup();
    for rules in [
        &options.include,
        &options.exclude,
        &options.block_rules,
        &options.allow_rules,
    ] {
        if rules.len() > 32
            || rules
                .iter()
                .any(|v| v.is_empty() || v.len() > 512 || v.chars().any(char::is_control))
        {
            return Err(ValidationError(
                "URL rules require at most 32 bounded patterns".into(),
            ));
        }
        for pattern in rules {
            validate_pattern(pattern)?;
        }
    }
    if options.behaviors.len() > 5
        || options.behaviors.iter().any(|v| {
            !matches!(
                v.as_str(),
                "autoscroll" | "autoplay" | "autofetch" | "autoclick" | "siteSpecific"
            )
        })
    {
        return Err(ValidationError("unsupported behavior".into()));
    }
    if !(1..=300).contains(&options.behavior_timeout_seconds)
        || options.post_load_delay_seconds > 60
        || !(320..=3840).contains(&options.viewport_width)
        || !(200..=2160).contains(&options.viewport_height)
        || options.click_selector.len() > 512
        || options.language.len() != 2
        || !options.language.bytes().all(|v| v.is_ascii_lowercase())
    {
        return Err(ValidationError(
            "capture behavior, viewport or ISO-639-1 language is out of bounds".into(),
        ));
    }
    if options
        .size_limit_bytes
        .is_some_and(|n| n == 0 || n > 16 * 1024 * 1024 * 1024)
        || options
            .max_resource_bytes
            .is_some_and(|n| n == 0 || n > 2 * 1024 * 1024 * 1024)
        || options.disk_reserve_bytes > 16 * 1024 * 1024 * 1024
    {
        return Err(ValidationError("byte/disk budget out of bounds".into()));
    }
    options.disk_reserve_bytes = options.disk_reserve_bytes.max(64 * 1024 * 1024);
    if options
        .profile_id
        .as_ref()
        .is_some_and(|v| !crate::custody::safe_id(v))
    {
        return Err(ValidationError("invalid profile ID".into()));
    }
    validate_selectors(&options.selectors)?;
    validate_interactions(&options.interactions)?;
    Ok(())
}

fn validate_pattern(pattern: &str) -> Result<(), ValidationError> {
    regex::RegexBuilder::new(pattern)
        .size_limit(128 * 1024)
        .build()
        .map_err(|_| ValidationError("invalid bounded URL pattern".into()))?;
    if pattern.contains("(?")
        || pattern.contains("\\p")
        || pattern.contains("\\P")
        || pattern.contains("\\A")
        || pattern.contains("\\z")
        || pattern.matches(['*', '+']).count() > 2
        || pattern.matches('|').count() > 16
        || regex::Regex::new(r"\)[*+?{]")
            .expect("constant pattern")
            .is_match(pattern)
    {
        return Err(ValidationError("URL rules support a bounded common Rust/JavaScript regex subset; use simple URL/path patterns without lookarounds, inline flags or repeated groups".into()));
    }
    Ok(())
}
