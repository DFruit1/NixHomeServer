use std::{net::IpAddr, path::PathBuf, str::FromStr, time::Duration};

#[derive(Clone, Debug)]
pub struct AppConfig {
    pub address: IpAddr,
    pub port: u16,
    pub state_dir: PathBuf,
    pub database_path: PathBuf,
    pub crawls_root: PathBuf,
    pub frontend_dir: PathBuf,
    pub replay_dir: PathBuf,
    pub archive_root: PathBuf,
    pub podman_bin: PathBuf,
    pub crawler_image: String,
    pub archive_uid: u32,
    pub archive_gid: u32,
    pub worker_poll_interval: Duration,
    pub event_retention_days: u32,
}

impl AppConfig {
    pub fn from_env() -> Result<Self, String> {
        let state_dir = path_env(
            "BROWSERTRIX_DOWNLOADER_STATE_DIR",
            "/var/lib/browsertrix-downloader/state",
        );
        Ok(Self {
            address: value_env("BROWSERTRIX_DOWNLOADER_HOST", "127.0.0.1")?,
            port: positive_env("BROWSERTRIX_DOWNLOADER_PORT", 8_088),
            database_path: std::env::var_os("BROWSERTRIX_DOWNLOADER_DATABASE")
                .map(PathBuf::from)
                .unwrap_or_else(|| state_dir.join("browsertrix-downloader.sqlite")),
            state_dir,
            crawls_root: path_env(
                "BROWSERTRIX_DOWNLOADER_CRAWLS_DIR",
                "/var/lib/browsertrix-downloader/crawls",
            ),
            frontend_dir: required_path_env("BROWSERTRIX_DOWNLOADER_FRONTEND_DIR")?,
            replay_dir: required_path_env("BROWSERTRIX_DOWNLOADER_REPLAY_DIR")?,
            archive_root: path_env(
                "BROWSERTRIX_DOWNLOADER_ARCHIVE_ROOT",
                "/mnt/data/shared/_WebArchives",
            ),
            podman_bin: path_env("BROWSERTRIX_DOWNLOADER_PODMAN_BIN", "podman"),
            crawler_image: std::env::var("BROWSERTRIX_DOWNLOADER_CRAWLER_IMAGE")
                .unwrap_or_else(|_| "docker.io/webrecorder/browsertrix-crawler:1.14.3".to_owned()),
            archive_uid: nonnegative_env("BROWSERTRIX_DOWNLOADER_ARCHIVE_UID", 0),
            archive_gid: nonnegative_env("BROWSERTRIX_DOWNLOADER_ARCHIVE_GID", 0),
            worker_poll_interval: Duration::from_secs(positive_env(
                "BROWSERTRIX_DOWNLOADER_WORKER_POLL_SECONDS",
                3_u64,
            )),
            event_retention_days: positive_env(
                "BROWSERTRIX_DOWNLOADER_EVENT_RETENTION_DAYS",
                90_u32,
            ),
        })
    }

    pub fn for_test(root: &std::path::Path) -> Self {
        Self {
            address: IpAddr::from([127, 0, 0, 1]),
            port: 0,
            state_dir: root.join("state"),
            database_path: root.join("state/jobs.sqlite"),
            crawls_root: root.join("crawls"),
            frontend_dir: root.join("frontend"),
            replay_dir: root.join("replay"),
            archive_root: root.join("archives"),
            podman_bin: PathBuf::from("podman"),
            crawler_image: "test-image".to_owned(),
            archive_uid: 0,
            archive_gid: 0,
            worker_poll_interval: Duration::from_millis(10),
            event_retention_days: 90,
        }
    }
}

fn required_path_env(name: &str) -> Result<PathBuf, String> {
    std::env::var_os(name)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .ok_or_else(|| format!("{name} is required"))
}

fn path_env(name: &str, fallback: &str) -> PathBuf {
    std::env::var_os(name)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(fallback))
}

fn value_env<T>(name: &str, fallback: &str) -> Result<T, String>
where
    T: FromStr,
    T::Err: std::fmt::Display,
{
    std::env::var(name)
        .unwrap_or_else(|_| fallback.to_owned())
        .parse()
        .map_err(|error| format!("invalid {name}: {error}"))
}

fn positive_env<T>(name: &str, fallback: T) -> T
where
    T: FromStr + Copy + Default + PartialOrd,
{
    std::env::var(name)
        .ok()
        .and_then(|value| value.parse().ok())
        .filter(|value| *value > T::default())
        .unwrap_or(fallback)
}

fn nonnegative_env(name: &str, fallback: u32) -> u32 {
    std::env::var(name)
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(fallback)
}
