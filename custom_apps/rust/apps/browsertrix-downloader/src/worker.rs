use crate::{
    archive::{allocate_archive_name, archive_name},
    config::AppConfig,
    crawler::{build_crawl_args, log_line_text, merge_progress, parse_crawl_log_line},
    database::Database,
    model::{Job, JobProgress, JobStatus},
    validation::parse_create_job,
};
use serde_json::json;
use std::{path::Path, process::Stdio, time::Duration};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, BufReader},
    process::Command,
    sync::mpsc,
    time::{Instant, MissedTickBehavior},
};

pub async fn run(config: AppConfig) -> Result<(), String> {
    tokio::fs::create_dir_all(&config.crawls_root)
        .await
        .map_err(|error| format!("create crawls root: {error}"))?;
    tokio::fs::create_dir_all(&config.archive_root)
        .await
        .map_err(|error| format!("create archive root: {error}"))?;
    let database = Database::open(&config.database_path)
        .map_err(|error| format!("initialize queue database: {error}"))?;
    database
        .mark_worker_interrupted()
        .map_err(|error| format!("recover interrupted crawl: {error}"))?;
    ensure_image(&config).await?;
    log_event("info", "worker_started", None, None);

    loop {
        if let Some(job) = database
            .claim_next_queued_job()
            .map_err(|error| format!("claim queued job: {error}"))?
        {
            log_event("info", "crawl_started", Some(&job.id), None);
            if let Err(error) = process_job(&config, &database, &job).await {
                log_event("error", "crawl_failed", Some(&job.id), Some(&error));
                let message = shorten(&error, 300);
                database
                    .set_status(&job.id, JobStatus::Failed, Some(&message))
                    .map_err(|db_error| format!("record failed crawl: {db_error}"))?;
            }
            continue;
        }
        tokio::time::sleep(config.worker_poll_interval).await;
    }
}

pub async fn ensure_image(config: &AppConfig) -> Result<(), String> {
    let inspected = Command::new(&config.podman_bin)
        .args(["image", "inspect", &config.crawler_image])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .await
        .map(|status| status.success())
        .unwrap_or(false);
    if inspected {
        return Ok(());
    }
    log_event("info", "crawler_image_pull_started", None, None);
    let status = Command::new(&config.podman_bin)
        .args(["pull", &config.crawler_image])
        .status()
        .await
        .map_err(|error| format!("start crawler image pull: {error}"))?;
    if !status.success() {
        return Err(format!("podman pull exited with {status}"));
    }
    log_event("info", "crawler_image_pull_completed", None, None);
    Ok(())
}

pub async fn process_job(config: &AppConfig, database: &Database, job: &Job) -> Result<(), String> {
    if !job
        .id
        .chars()
        .all(|character| character.is_ascii_alphanumeric() || character == '-')
    {
        return Err("job ID is not a safe path segment".to_owned());
    }
    let crawl_dir = config.crawls_root.join(&job.id);
    remove_crawl_dir(&crawl_dir).await?;
    tokio::fs::create_dir_all(&crawl_dir)
        .await
        .map_err(|error| format!("create crawl directory: {error}"))?;
    database
        .set_status(&job.id, JobStatus::Running, None)
        .map_err(|error| format!("mark crawl running: {error}"))?;
    database
        .add_event(
            &job.id,
            "running",
            Some(&format!(
                "Crawling {} ({} scope, max {} pages)",
                job.request.url,
                job.request.scope.as_str(),
                job.request.page_limit
            )),
        )
        .map_err(|error| format!("record crawl start: {error}"))?;

    let args = build_crawl_args(&job.request, &job.id, &crawl_dir, &config.crawler_image);
    let mut child = Command::new(&config.podman_bin)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|error| format!("start crawler container: {error}"))?;
    let pid = child
        .id()
        .ok_or_else(|| "crawler process has no process ID".to_owned())?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| "crawler stdout was not captured".to_owned())?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| "crawler stderr was not captured".to_owned())?;

    let (line_sender, mut line_receiver) = mpsc::unbounded_channel();
    let stdout_task = tokio::spawn(async move {
        let mut lines = BufReader::new(stdout).lines();
        while let Some(line) = lines.next_line().await? {
            if line_sender.send(line).is_err() {
                break;
            }
        }
        Ok::<(), std::io::Error>(())
    });
    let stderr_task = tokio::spawn(read_stderr_tail(stderr));
    let mut wait_task = tokio::spawn(async move { child.wait().await });
    let mut poll = tokio::time::interval(config.worker_poll_interval);
    poll.set_missed_tick_behavior(MissedTickBehavior::Delay);
    let timeout_at =
        Instant::now() + Duration::from_secs(u64::from(job.request.time_limit_minutes) * 60 + 300);
    let mut termination: Option<Termination> = None;
    let mut progress = JobProgress {
        pages_done: 0,
        pages_queued: 0,
        pages_failed: 0,
    };
    let mut last_progress_write = Instant::now() - Duration::from_secs(3);
    let mut last_log_write = Instant::now() - Duration::from_secs(11);

    let status = loop {
        tokio::select! {
            result = &mut wait_task => {
                break result
                    .map_err(|error| format!("join crawler process: {error}"))?
                    .map_err(|error| format!("wait for crawler process: {error}"))?;
            }
            Some(line) = line_receiver.recv() => {
                if let Some(update) = parse_crawl_log_line(&line) {
                    progress = merge_progress(&progress, &update);
                    if last_progress_write.elapsed() >= Duration::from_secs(2) {
                        database
                            .set_progress(&job.id, Some(&progress))
                            .map_err(|error| format!("persist crawl progress: {error}"))?;
                        last_progress_write = Instant::now();
                    }
                }
                if last_log_write.elapsed() >= Duration::from_secs(10) {
                    if let Some(text) = log_line_text(&line) {
                        database
                            .add_event(&job.id, "log", Some(&text))
                            .map_err(|error| format!("persist crawl log: {error}"))?;
                        last_log_write = Instant::now();
                    }
                }
            }
            _ = poll.tick() => {
                if termination.is_none() {
                    let cancelling = database
                        .job(&job.id)
                        .map_err(|error| format!("check crawl cancellation: {error}"))?
                        .is_some_and(|current| current.status == JobStatus::Cancelling);
                    if cancelling {
                        signal_process(pid, libc::SIGINT)?;
                        termination = Some(Termination::cancelled());
                    } else if Instant::now() >= timeout_at {
                        signal_process(pid, libc::SIGTERM)?;
                        termination = Some(Termination::timed_out());
                    }
                } else if termination.as_ref().is_some_and(Termination::grace_expired) {
                    signal_process(pid, libc::SIGKILL)?;
                }
            }
        }
    };
    stdout_task
        .await
        .map_err(|error| format!("join crawler stdout: {error}"))?
        .map_err(|error| format!("read crawler stdout: {error}"))?;
    let stderr = stderr_task
        .await
        .map_err(|error| format!("join crawler stderr: {error}"))?
        .map_err(|error| format!("read crawler stderr: {error}"))?;
    while let Ok(line) = line_receiver.try_recv() {
        if let Some(update) = parse_crawl_log_line(&line) {
            progress = merge_progress(&progress, &update);
        }
    }
    database
        .set_progress(&job.id, Some(&progress))
        .map_err(|error| format!("persist final crawl progress: {error}"))?;

    if termination.as_ref().is_some_and(|state| state.cancelled) {
        remove_crawl_dir(&crawl_dir).await?;
        database
            .set_status(&job.id, JobStatus::Cancelled, None)
            .map_err(|error| format!("mark crawl cancelled: {error}"))?;
        log_event("info", "crawl_cancelled", Some(&job.id), None);
        return Ok(());
    }
    if termination.as_ref().is_some_and(|state| state.timed_out) {
        remove_crawl_dir(&crawl_dir).await?;
        database
            .set_status(
                &job.id,
                JobStatus::Failed,
                Some("crawl exceeded its time limit"),
            )
            .map_err(|error| format!("mark crawl timed out: {error}"))?;
        return Ok(());
    }
    if !status.success() {
        remove_crawl_dir(&crawl_dir).await?;
        let detail = stderr
            .lines()
            .rev()
            .take(3)
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect::<Vec<_>>()
            .join(" ");
        let error = if detail.trim().is_empty() {
            format!("crawler exited with {status}")
        } else {
            shorten(&detail, 300)
        };
        database
            .set_status(&job.id, JobStatus::Failed, Some(&error))
            .map_err(|db_error| format!("mark crawl failed: {db_error}"))?;
        return Ok(());
    }

    finish_archive(config, database, job, &crawl_dir).await?;
    log_event("info", "crawl_completed", Some(&job.id), None);
    Ok(())
}

async fn finish_archive(
    config: &AppConfig,
    database: &Database,
    job: &Job,
    crawl_dir: &Path,
) -> Result<(), String> {
    let source = crawl_dir
        .join("collections")
        .join(&job.id)
        .join(format!("{}.wacz", job.id));
    let source_metadata = tokio::fs::metadata(&source)
        .await
        .map_err(|_| "crawl finished but no WACZ archive was produced".to_owned())?;
    if !source_metadata.is_file() {
        return Err("crawl finished but no WACZ archive was produced".to_owned());
    }
    let parsed = parse_create_job(crate::validation::CreateJobInput {
        url: job.request.url.clone(),
        scope: Some(job.request.scope),
        page_limit: Some(job.request.page_limit),
        time_limit_minutes: Some(job.request.time_limit_minutes),
    })
    .map_err(|error| format!("read archived hostname: {error}"))?;
    tokio::fs::create_dir_all(&config.archive_root)
        .await
        .map_err(|error| format!("create archive root: {error}"))?;
    let base_name = archive_name(&parsed.hostname, chrono::Local::now().date_naive());
    let archive_file = allocate_archive_name(&config.archive_root, &base_name)
        .map_err(|error| format!("allocate archive name: {error}"))?;
    let destination = config.archive_root.join(&archive_file);
    tokio::fs::copy(&source, &destination)
        .await
        .map_err(|error| format!("copy completed archive: {error}"))?;
    set_archive_permissions(&destination, config.archive_uid, config.archive_gid)?;
    remove_crawl_dir(crawl_dir).await?;
    database
        .set_archive(&job.id, &archive_file, source_metadata.len())
        .map_err(|error| format!("record completed archive: {error}"))?;
    database
        .set_status(&job.id, JobStatus::Completed, None)
        .map_err(|error| format!("mark crawl completed: {error}"))
}

async fn remove_crawl_dir(path: &Path) -> Result<(), String> {
    match tokio::fs::remove_dir_all(path).await {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!("remove crawl directory: {error}")),
    }
}

async fn read_stderr_tail(mut stderr: tokio::process::ChildStderr) -> std::io::Result<String> {
    let mut tail = Vec::new();
    let mut chunk = [0_u8; 8 * 1024];
    loop {
        let read = stderr.read(&mut chunk).await?;
        if read == 0 {
            break;
        }
        tail.extend_from_slice(&chunk[..read]);
        if tail.len() > 64 * 1024 {
            tail.drain(..tail.len() - 64 * 1024);
        }
    }
    Ok(String::from_utf8_lossy(&tail).into_owned())
}

fn set_archive_permissions(path: &Path, uid: u32, gid: u32) -> Result<(), String> {
    #[cfg(unix)]
    {
        use std::{ffi::CString, os::unix::ffi::OsStrExt, os::unix::fs::PermissionsExt};
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o660))
            .map_err(|error| format!("set archive permissions: {error}"))?;
        let path = CString::new(path.as_os_str().as_bytes())
            .map_err(|_| "archive path contains a NUL byte".to_owned())?;
        if unsafe { libc::chown(path.as_ptr(), uid, gid) } != 0 {
            return Err(format!(
                "set archive ownership: {}",
                std::io::Error::last_os_error()
            ));
        }
    }
    Ok(())
}

fn signal_process(pid: u32, signal: i32) -> Result<(), String> {
    if unsafe { libc::kill(pid as i32, signal) } == 0 {
        Ok(())
    } else {
        let error = std::io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::ESRCH) {
            Ok(())
        } else {
            Err(format!("signal crawler process: {error}"))
        }
    }
}

struct Termination {
    cancelled: bool,
    timed_out: bool,
    kill_at: Instant,
}

impl Termination {
    fn cancelled() -> Self {
        Self {
            cancelled: true,
            timed_out: false,
            kill_at: Instant::now() + Duration::from_secs(10),
        }
    }

    fn timed_out() -> Self {
        Self {
            cancelled: false,
            timed_out: true,
            kill_at: Instant::now() + Duration::from_secs(30),
        }
    }

    fn grace_expired(&self) -> bool {
        Instant::now() >= self.kill_at
    }
}

fn shorten(value: &str, max_chars: usize) -> String {
    value.chars().take(max_chars).collect()
}

fn log_event(level: &str, event: &str, job_id: Option<&str>, error: Option<&str>) {
    let mut value = json!({
        "level": level,
        "service": "browsertrix-downloader-worker",
        "event": event,
    });
    if let Some(job_id) = job_id {
        value["jobId"] = json!(job_id);
    }
    if let Some(error) = error {
        value["error"] = json!(shorten(error, 500));
    }
    eprintln!("{value}");
}
