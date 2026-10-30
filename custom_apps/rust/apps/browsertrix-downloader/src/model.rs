use crate::archive_engine::{Estimate, ExportOptions};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum CrawlScope {
    Page,
    PageSpa,
    Prefix,
    Host,
    Domain,
}
impl CrawlScope {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Page => "page",
            Self::PageSpa => "page-spa",
            Self::Prefix => "prefix",
            Self::Host => "host",
            Self::Domain => "domain",
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct SelectorRule {
    pub selector: String,
    pub action: String,
    pub url_prefix: Option<String>,
}
impl Default for SelectorRule {
    fn default() -> Self {
        Self {
            selector: String::new(),
            action: "hide".into(),
            url_prefix: None,
        }
    }
}
#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Interaction {
    pub selector: String,
    pub assertion: String,
    pub expected: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct CaptureOptions {
    pub preset: String,
    pub depth: i32,
    pub seeds: Vec<String>,
    pub include: Vec<String>,
    pub exclude: Vec<String>,
    pub block_ads: bool,
    pub block_rules: Vec<String>,
    pub allow_rules: Vec<String>,
    pub media: String,
    pub behaviors: Vec<String>,
    pub click_selector: String,
    pub behavior_timeout_seconds: u32,
    pub post_load_delay_seconds: u32,
    pub viewport_width: u32,
    pub viewport_height: u32,
    pub language: String,
    pub size_limit_bytes: Option<u64>,
    pub max_resource_bytes: Option<u64>,
    pub disk_reserve_bytes: u64,
    pub selectors: Vec<SelectorRule>,
    pub profile_id: Option<String>,
    pub deduplicate: bool,
    pub interactions: Vec<Interaction>,
    pub alternate_images: bool,
}
impl Default for CaptureOptions {
    fn default() -> Self {
        Self {
            preset: "faithful".into(),
            depth: 1,
            seeds: vec![],
            include: vec![],
            exclude: vec![],
            block_ads: false,
            block_rules: vec![],
            allow_rules: vec![],
            media: "full".into(),
            behaviors: vec![
                "autoplay".into(),
                "autofetch".into(),
                "autoscroll".into(),
                "siteSpecific".into(),
            ],
            click_selector: "a".into(),
            behavior_timeout_seconds: 90,
            post_load_delay_seconds: 0,
            viewport_width: 1280,
            viewport_height: 900,
            language: "en".into(),
            size_limit_bytes: Some(2 * 1024 * 1024 * 1024),
            max_resource_bytes: None,
            disk_reserve_bytes: 512 * 1024 * 1024,
            selectors: vec![],
            profile_id: None,
            deduplicate: false,
            interactions: vec![],
            alternate_images: true,
        }
    }
}
impl CaptureOptions {
    pub fn preset(name: &str) -> Self {
        let mut value = Self {
            preset: name.into(),
            ..Self::default()
        };
        match name {
            "balanced" => {
                value.block_ads = true;
                value.media = "posters".into();
                value
                    .behaviors
                    .retain(|v| v != "autoplay" && v != "autofetch");
                value.alternate_images = false;
            }
            "reader" => {
                value.block_ads = true;
                value.media = "none".into();
                value.behaviors = vec!["autoscroll".into()];
                value.alternate_images = false;
            }
            _ => {}
        }
        value
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateJobRequest {
    pub url: String,
    pub scope: CrawlScope,
    pub page_limit: u32,
    pub time_limit_minutes: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub collection: Option<String>,
    #[serde(default)]
    pub options: CaptureOptions,
}
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum JobStatus {
    Queued,
    Starting,
    Running,
    Cancelling,
    Completed,
    Failed,
    Cancelled,
    Paused,
    Partial,
    Packaging,
}
impl JobStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Queued => "queued",
            Self::Starting => "starting",
            Self::Running => "running",
            Self::Cancelling => "cancelling",
            Self::Completed => "completed",
            Self::Failed => "failed",
            Self::Cancelled => "cancelled",
            Self::Paused => "paused",
            Self::Partial => "partial",
            Self::Packaging => "packaging",
        }
    }
    pub fn from_database(value: &str) -> Option<Self> {
        [
            Self::Queued,
            Self::Starting,
            Self::Running,
            Self::Cancelling,
            Self::Completed,
            Self::Failed,
            Self::Cancelled,
            Self::Paused,
            Self::Partial,
            Self::Packaging,
        ]
        .into_iter()
        .find(|v| v.as_str() == value)
    }
    pub fn is_terminal(self) -> bool {
        matches!(
            self,
            Self::Completed | Self::Failed | Self::Cancelled | Self::Partial | Self::Paused
        )
    }
}
#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct JobProgress {
    pub pages_done: u64,
    pub pages_queued: u64,
    pub pages_failed: u64,
}
#[derive(Clone, Debug, Deserialize, Serialize, Default)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Operation {
    #[default]
    Capture,
    Sample {
        #[serde(default)]
        target_pages: u32,
    },
    Export {
        archive_id: String,
        sha256: String,
        options: ExportOptions,
    },
    Verify {
        archive_id: String,
        sha256: String,
        mode: String,
        url: Option<String>,
        interactions: Vec<Interaction>,
    },
    Repair {
        archive_id: String,
        sha256: String,
        urls: Vec<String>,
    },
    Import {
        inbox_id: String,
    },
    ProfileImport {
        profile_id: String,
        inbox_id: String,
    },
    Reconcile,
}
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct JobRuntime {
    pub archive_id: Option<String>,
    pub stop_reason: Option<String>,
    pub bytes_downloaded: u64,
    pub bytes_stored: u64,
    pub warc_bytes: u64,
    pub can_resume: bool,
    pub runtime_seconds: u64,
    pub attempt: u32,
    pub coverage: Option<JobProgress>,
    pub estimate: Option<Estimate>,
    #[serde(skip_serializing)]
    pub operation: Operation,
    #[serde(skip_serializing)]
    pub control: Option<String>,
    #[serde(skip_serializing)]
    pub resume_config: Option<String>,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Job {
    pub id: String,
    pub created_at: String,
    pub updated_at: String,
    pub created_by: String,
    pub status: JobStatus,
    pub request: CreateJobRequest,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub progress: Option<JobProgress>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub archive_file: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub archive_bytes: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(flatten)]
    pub runtime: JobRuntime,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CurrentUser {
    pub username: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub email: Option<String>,
    pub groups: Vec<String>,
}
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct ResumeOptions {
    pub additional_pages: u32,
    pub additional_minutes: u32,
    pub additional_bytes: u64,
}

impl JobRuntime {
    pub fn storage_json(&self) -> Result<String, serde_json::Error> {
        let mut value = serde_json::to_value(self)?;
        value["operation"] = serde_json::to_value(&self.operation)?;
        value["control"] = serde_json::to_value(&self.control)?;
        value["resumeConfig"] = serde_json::to_value(&self.resume_config)?;
        serde_json::to_string(&value)
    }
}
