//! Bounded WACZ analysis and transformations shared by capture and library APIs.
//!
//! File analysis belongs here rather than in HTTP handlers. The public types are
//! the contract for the independently developed capture service and interface.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct PageRecord {
    pub url: String,
    pub title: String,
    pub ts: String,
    pub text: String,
    pub bytes: u64,
    pub status: u16,
    pub resource_urls: Vec<String>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct ResourceRecord {
    pub url: String,
    pub mime: String,
    pub status: u16,
    pub bytes: u64,
    pub digest: String,
    pub domain: String,
    pub pages: Vec<String>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct ArchiveReport {
    pub archive_bytes: u64,
    pub sha256: String,
    pub title: String,
    pub description: String,
    pub pages: Vec<PageRecord>,
    pub resources: Vec<ResourceRecord>,
    pub unique_payload_bytes: u64,
    pub duplicate_payload_bytes: u64,
    pub metadata_bytes: u64,
    pub warnings: Vec<String>,
    pub dependencies: Vec<String>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct VerificationCheck {
    pub name: String,
    pub status: String,
    pub details: String,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Verification {
    pub valid: bool,
    pub checked_at: String,
    pub checks: Vec<VerificationCheck>,
    pub warnings: Vec<String>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct ExportOptions {
    pub include_urls: Vec<String>,
    pub exclude_urls: Vec<String>,
    pub exclude_domains: Vec<String>,
    pub exclude_mime_prefixes: Vec<String>,
    pub remove_selectors: Vec<String>,
    pub title: String,
    pub deduplicate: bool,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct ComparisonReport {
    pub added_pages: Vec<String>,
    pub removed_pages: Vec<String>,
    pub changed_pages: Vec<String>,
    pub unchanged_pages: Vec<String>,
    pub added_resources: Vec<String>,
    pub removed_resources: Vec<String>,
    pub changed_resources: Vec<String>,
    pub warnings: Vec<String>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct PageSample {
    pub url: String,
    pub bytes: u64,
    pub shared_bytes: u64,
    pub resource_digests: BTreeMap<String, u64>,
    pub measured: bool,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Estimate {
    pub lower_bytes: u64,
    pub upper_bytes: u64,
    pub expected_bytes: u64,
    pub sample_pages: u64,
    pub discovered_pages: u64,
    pub unknown_scope: bool,
    pub shared_bytes: u64,
    pub marginal_page_bytes: u64,
    pub peak_disk_bytes: u64,
    pub assumptions: Vec<String>,
    pub warnings: Vec<String>,
}
