use browsertrix_downloader::{
    archive::{allocate_archive_name, archive_name, sanitize_segment},
    crawler::{build_crawl_args, log_line_text, merge_progress, parse_crawl_log_line},
    model::{CrawlScope, CreateJobRequest, JobProgress},
};
use chrono::NaiveDate;

fn request(scope: CrawlScope) -> CreateJobRequest {
    CreateJobRequest {
        url: "https://example.com/docs/".to_owned(),
        scope,
        page_limit: 25,
        time_limit_minutes: 10,
    }
}

#[test]
fn crawler_arguments_follow_the_documented_container_contract() {
    let args = build_crawl_args(
        &request(CrawlScope::Prefix),
        "jobid",
        std::path::Path::new("/var/lib/browsertrix-downloader/crawls/jobid"),
        "docker.io/webrecorder/browsertrix-crawler:1.14.3",
    );
    let strings = args
        .iter()
        .map(|value| value.to_string_lossy())
        .collect::<Vec<_>>();
    let image = strings
        .iter()
        .position(|value| *value == "docker.io/webrecorder/browsertrix-crawler:1.14.3")
        .expect("image argument");
    assert_eq!(strings[image + 1], "crawl");
    assert_eq!(
        value_after(&strings, "-v"),
        "/var/lib/browsertrix-downloader/crawls/jobid:/crawls"
    );
    assert_eq!(value_after(&strings, "--scopeType"), "prefix");
    assert_eq!(value_after(&strings, "--depth"), "1");
    assert_eq!(value_after(&strings, "--limit"), "25");
    assert_eq!(value_after(&strings, "--timeLimit"), "600");
    assert!(strings.contains(&std::borrow::Cow::Borrowed("--generateWACZ")));
    assert!(strings.contains(&std::borrow::Cow::Borrowed("--cap-add=SYS_ADMIN")));
    assert!(strings.contains(&std::borrow::Cow::Borrowed("--pid=host")));
    assert!(strings.contains(&std::borrow::Cow::Borrowed("--uts=host")));
    assert!(!strings.contains(&std::borrow::Cow::Borrowed("--init")));
    assert!(strings.contains(&std::borrow::Cow::Borrowed(
        "--network=slirp4netns:allow_host_loopback=false"
    )));
    assert!(!strings.contains(&std::borrow::Cow::Borrowed("--network=host")));

    let page = build_crawl_args(
        &request(CrawlScope::Page),
        "jobid",
        std::path::Path::new("/tmp/jobid"),
        "image",
    );
    let page = page
        .iter()
        .map(|value| value.to_string_lossy())
        .collect::<Vec<_>>();
    assert_eq!(value_after(&page, "--depth"), "0");
}

#[test]
fn crawler_json_lines_update_progress_without_regression() {
    let stats =
        parse_crawl_log_line(r#"{"logLevel":"info","stats":{"done":3,"queued":5,"failed":1}}"#)
            .expect("stats");
    assert_eq!(stats.pages_done, Some(3));
    assert_eq!(stats.pages_queued, Some(5));
    assert_eq!(stats.pages_failed, Some(1));
    assert_eq!(
        parse_crawl_log_line(r#"{"message":"pageCrawled","page":"https://example.com/"}"#)
            .expect("page event")
            .pages_done,
        Some(1)
    );
    assert!(parse_crawl_log_line("starting crawler").is_none());

    let current = JobProgress {
        pages_done: 4,
        pages_queued: 2,
        pages_failed: 0,
    };
    let merged = merge_progress(&current, &stats);
    assert_eq!(merged.pages_done, 4);
    assert_eq!(merged.pages_queued, 5);
    assert_eq!(merged.pages_failed, 1);
}

#[test]
fn crawler_log_text_is_short_and_human_readable() {
    assert_eq!(
        log_line_text(r#"{"message":"pageCrawled","page":"https://example.com/"}"#).as_deref(),
        Some("pageCrawled https://example.com/")
    );
    assert_eq!(
        log_line_text("plain log line").as_deref(),
        Some("plain log line")
    );
    assert!(log_line_text("   ").is_none());
    assert!(log_line_text(r#"{"logLevel":"info"}"#).is_none());
}

#[test]
fn archive_names_are_sanitized_dated_and_collision_safe() {
    assert_eq!(sanitize_segment("a/b\\c:d*e?f", "site"), "a b c d e f");
    assert_eq!(sanitize_segment("con", "site"), "con_");
    assert_eq!(sanitize_segment("   ", "site"), "site");
    let date = NaiveDate::from_ymd_opt(2026, 8, 31).expect("date");
    assert_eq!(
        archive_name("example.com", date),
        "example.com 2026-08-31.wacz"
    );

    let temp = tempfile::tempdir().expect("temporary directory");
    assert_eq!(
        allocate_archive_name(temp.path(), "example.com 2026-08-31.wacz").expect("available name"),
        "example.com 2026-08-31.wacz"
    );
    std::fs::write(temp.path().join("example.com 2026-08-31.wacz"), b"x").expect("collision");
    assert_eq!(
        allocate_archive_name(temp.path(), "example.com 2026-08-31.wacz").expect("suffixed name"),
        "example.com 2026-08-31 (1).wacz"
    );
}

fn value_after<'a>(values: &'a [std::borrow::Cow<'a, str>], flag: &str) -> &'a str {
    let index = values.iter().position(|value| value == flag).expect("flag");
    &values[index + 1]
}
