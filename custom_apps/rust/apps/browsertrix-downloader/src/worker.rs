use crate::{
    config::AppConfig,
    crawler::{build_crawl_args, merge_progress, parse_crawl_log_line},
    database::Database,
    model::{Job, JobStatus},
};
use serde_json::json;
use std::{path::Path, process::Stdio, time::Duration};
use tokio::{
    io::AsyncReadExt,
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
    crate::custody::recover(&config, &database)?;
    recover_interrupted(&config, &database).await?;
    log_event("info", "worker_started", None, None);

    loop {
        for job in database.discarded_jobs().map_err(|e| e.to_string())? {
            cleanup_discarded(&config, &database, &job).await?;
        }
        database
            .dispatch_due_schedules()
            .map_err(|e| e.to_string())?;
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
            if let Some(finished) = database.job(&job.id).map_err(|e| e.to_string())? {
                database
                    .finish_schedules(&finished)
                    .map_err(|e| e.to_string())?;
            }
            continue;
        }
        tokio::time::sleep(config.worker_poll_interval).await;
    }
}

/// Recover worker state only after the previous exact capture container has
/// exited. Discard is terminal; checkpoints are never inferred back into life.
pub async fn recover_interrupted(config: &AppConfig, database: &Database) -> Result<(), String> {
    database
        .mark_worker_interrupted()
        .map_err(|error| format!("recover interrupted crawl: {error}"))?;
    // Image preparation is lazy: file-only work does not need a browser runtime.
    for job in database
        .list_jobs_for_recovery()
        .map_err(|e| e.to_string())?
    {
        // A worker/CLI crash does not guarantee the container exited. Stop only
        // the exact previously claimed job before reading its durable checkpoint.
        if job.runtime.control.as_deref() == Some("discard") {
            cleanup_discarded(config, database, &job).await?;
            continue;
        }
        stop_recovery_container(config, &job).await?;
        if let Some(deadline) = job.runtime.attempt_deadline.as_deref() {
            let deadline = chrono::DateTime::parse_from_rfc3339(deadline)
                .map_err(|_| "invalid durable attempt deadline")?;
            let remaining = (deadline.with_timezone(&chrono::Utc) - chrono::Utc::now())
                .num_seconds()
                .max(0) as u64;
            let mut rt = job.runtime.clone();
            rt.runtime_seconds = rt
                .runtime_seconds
                .max((u64::from(job.request.time_limit_minutes) * 60).saturating_sub(remaining));
            rt.attempt_deadline = None;
            database
                .set_runtime_preserving_control(&job.id, &rt)
                .map_err(|e| e.to_string())?;
        }
        let dir = config.checkpoints_root.join(&job.id);
        if let Some(saved) = find_checkpoint(&dir, &job) {
            database
                .restore_checkpoint(&job.id, &saved)
                .map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

async fn stop_recovery_container(config: &AppConfig, job: &Job) -> Result<(), String> {
    if !crate::custody::safe_id(&job.id) {
        return Err("unsafe recovery job identity".into());
    }
    if job.runtime.attempt == 0 {
        return Ok(());
    }
    // --ignore tolerates an already removed --rm container. Failure/timeout is
    // not permission to delete files a still-running container may be writing.
    let mut command = Command::new(&config.podman_bin);
    command
        .args([
            "rm",
            "--force",
            "--ignore",
            &format!("web-archive-{}", job.id),
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    let status = tokio::time::timeout(Duration::from_secs(10), command.status())
        .await
        .map_err(|_| "timed out stopping prior capture; checkpoint retained")?
        .map_err(|e| format!("stop prior capture: {e}"))?;
    if !status.success() {
        return Err("could not stop prior capture; checkpoint retained".into());
    }
    Ok(())
}
async fn cleanup_discarded(config: &AppConfig, db: &Database, job: &Job) -> Result<(), String> {
    stop_recovery_container(config, job).await?;
    let dir = config.checkpoints_root.join(&job.id);
    match std::fs::symlink_metadata(&dir) {
        Ok(meta) if meta.is_dir() && !meta.file_type().is_symlink() => {
            std::fs::remove_dir_all(&dir).map_err(|e| e.to_string())?;
            crate::custody::sync_directory(&config.checkpoints_root)?;
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        _ => {
            return Err("discard checkpoint is not a real directory; retained for diagnosis".into())
        }
    }
    db.finish_discard_cleanup(&job.id)
        .map_err(|e| e.to_string())
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

async fn kill_capture_container(config: &AppConfig, id: &str) {
    if !crate::custody::safe_id(id) {
        return;
    }
    let mut command = Command::new(&config.podman_bin);
    command
        .args(["kill", "--signal=KILL", &format!("web-archive-{id}")])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    let _ = tokio::time::timeout(Duration::from_secs(10), command.status()).await;
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

pub async fn process_job(config: &AppConfig, database: &Database, job: &Job) -> Result<(), String> {
    if !crate::custody::safe_id(&job.id) {
        return Err("job ID is not a safe path segment".into());
    }
    match &job.runtime.operation {
        crate::model::Operation::Capture
        | crate::model::Operation::Sample { .. }
        | crate::model::Operation::Repair { .. } => capture(config, database, job).await,
        _ => {
            let config = config.clone();
            let db = database.clone();
            let job = job.clone();
            tokio::task::spawn_blocking(move || crate::library::execute(&config, &db, &job))
                .await
                .map_err(|e| e.to_string())?
        }
    }
}
async fn capture(config: &AppConfig, database: &Database, job: &Job) -> Result<(), String> {
    let mut effective = job.clone();
    if let crate::model::Operation::Repair {
        archive_id,
        sha256,
        urls,
    } = &job.runtime.operation
    {
        let parent =
            crate::library::checked_archive(config, database, &job.created_by, archive_id, sha256)?;
        effective.request = parent
            .request
            .clone()
            .ok_or("repair requires a frozen capture recipe")?;
        effective.request.url = urls.first().ok_or("repair targets missing")?.clone();
        effective.request.options.seeds = urls.iter().skip(1).cloned().collect();
        effective.request.scope = crate::model::CrawlScope::Page;
        effective.request.page_limit = urls.len().min(100) as u32;
        effective.request.options.depth = 0;
    }
    // Revalidate every seed on execution. Firewall still protects subsequent browser
    // requests, DNS rebinding, redirects and dynamically discovered URLs.
    let queue = crate::queue::JobQueue::new(database.clone(), crate::queue::Resolver::system());
    queue
        .validate_request(&effective.request)
        .await
        .map_err(|e| e.to_string())?;
    let profile = if let Some(id) = &effective.request.options.profile_id {
        Some(crate::profiles::checked_profile(
            config,
            database,
            id,
            &job.created_by,
        )?)
    } else {
        None
    };
    let crawl_dir = config.checkpoints_root.join(&job.id);
    crate::custody::private_directory(&config.checkpoints_root)?;
    crate::custody::private_directory(&crawl_dir)?;
    let mut runtime = job.runtime.clone();
    let remaining_seconds = (u64::from(effective.request.time_limit_minutes) * 60)
        .saturating_sub(runtime.runtime_seconds);
    if remaining_seconds == 0 {
        return Err(
            "cumulative time budget exhausted; explicit additionalMinutes extension required"
                .into(),
        );
    }
    let saved = if runtime.attempt > 0 {
        Some(
            find_checkpoint(&crawl_dir, job)
                .ok_or("saved resume checkpoint is missing; retained files were not changed")?,
        )
    } else {
        None
    };
    crate::crawler::write_capture_config(&effective.request, &crawl_dir, saved.as_deref())?;
    let private = profile.is_some()
        || if let crate::model::Operation::Repair { archive_id, .. } = &job.runtime.operation {
            database
                .archive_for_user(archive_id, &job.created_by)
                .map_err(|e| e.to_string())?
                .is_some_and(|a| a.visibility == "private")
        } else {
            false
        };
    let destination_root = if private {
        &config.private_archive_root
    } else {
        &config.archive_root
    };
    tokio::fs::create_dir_all(destination_root)
        .await
        .map_err(|e| e.to_string())?;
    let reserve = effective.request.options.disk_reserve_bytes;
    if crate::custody::available_bytes(&crawl_dir)? < reserve
        || crate::custody::available_bytes(destination_root)? < reserve
    {
        return Err(
            "disk reserve unavailable before capture; retained checkpoint is unchanged".into(),
        );
    }
    ensure_image(config).await?;
    let mut args = build_crawl_args(
        &effective.request,
        &job.id,
        &crawl_dir,
        &config.crawler_image,
    );
    if let Some(index) = args.iter().position(|v| v == "--timeLimit") {
        args[index + 1] = remaining_seconds.to_string().into();
    }
    if let Some(saved) = saved {
        if let Some(index) = args.iter().rposition(|v| v == "--config") {
            args[index + 1] = format!("/crawls/{saved}").into();
        }
    }
    if let Some(path) = profile {
        let index = args
            .iter()
            .position(|v| v == std::ffi::OsStr::new(&config.crawler_image))
            .ok_or("crawler image argument missing")?;
        args.splice(
            index..index,
            [
                "-v".into(),
                format!("{}:/profiles/selected.tar.gz:ro", path.display()).into(),
            ],
        );
        args.extend(["--profile".into(), "/profiles/selected.tar.gz".into()]);
    }
    let before = database
        .job(&job.id)
        .map_err(|e| e.to_string())?
        .ok_or("job disappeared")?;
    if before.status == JobStatus::Cancelling {
        database
            .set_status(&job.id, JobStatus::Cancelled, None)
            .map_err(|e| e.to_string())?;
        return Ok(());
    }
    if before.runtime.control.is_some() {
        database
            .set_status(&job.id, JobStatus::Paused, None)
            .map_err(|e| e.to_string())?;
        return Ok(());
    }
    runtime.attempt += 1;
    runtime.control = None;
    runtime.can_resume = false;
    runtime.attempt_deadline = Some(
        (chrono::Utc::now() + chrono::Duration::seconds(remaining_seconds as i64)).to_rfc3339(),
    );
    if !database
        .begin_capture(&job.id, &runtime)
        .map_err(|e| e.to_string())?
    {
        let current = database
            .job(&job.id)
            .map_err(|e| e.to_string())?
            .ok_or("job disappeared")?;
        database
            .set_status(
                &job.id,
                if current.status == JobStatus::Cancelling {
                    JobStatus::Cancelled
                } else {
                    JobStatus::Paused
                },
                None,
            )
            .map_err(|e| e.to_string())?;
        return Ok(());
    }

    let mut child = Command::new(&config.podman_bin)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| format!("start crawler container: {e}"))?;
    let pid = child.id().ok_or("crawler has no PID")?;
    let stdout = child.stdout.take().ok_or("stdout missing")?;
    let stderr = child.stderr.take().ok_or("stderr missing")?;
    let (tx, mut rx) = mpsc::channel(64);
    let out = tokio::spawn(read_stdout(stdout, tx));
    let err = tokio::spawn(read_stderr_tail(stderr));
    let mut wait = tokio::spawn(async move { child.wait().await });
    let mut poll = tokio::time::interval(config.worker_poll_interval);
    poll.set_missed_tick_behavior(MissedTickBehavior::Delay);
    let started = Instant::now();
    let mut last_sync = Instant::now();
    let mut signalled: Option<Instant> = None;
    let mut reason: Option<String> = None;
    let mut progress = job.progress.clone().unwrap_or_default();
    let mut last_write = Instant::now();
    let mut policy_ready = false;
    let status = loop {
        tokio::select! {
         result=&mut wait=>break result.map_err(|e|e.to_string())?.map_err(|e|e.to_string())?,
         Some(line)=rx.recv()=>{read_metrics(&line,&mut runtime,&mut policy_ready);record_omission(&crawl_dir,&line)?;if let Some(update)=parse_crawl_log_line(&line){progress=merge_progress(&progress,&update);}if last_write.elapsed()>=Duration::from_secs(2){database.set_progress(&job.id,Some(&progress)).map_err(|e|e.to_string())?;last_write=Instant::now();}if reason.is_none(){if let Some(value)=stop_reason_from_log(&line){reason=Some(value.into());}}},
         _=poll.tick()=>{
           let current=database.job(&job.id).map_err(|e|e.to_string())?.ok_or("active job disappeared")?;
           if signalled.is_none(){let control=current.runtime.control.as_deref();let next=if current.status==JobStatus::Cancelling{Some("discard")}else if control==Some("pause"){Some("pause")}else if control==Some("stop"){Some("stop-and-save")}else if started.elapsed()>=Duration::from_secs(remaining_seconds+30){Some("time-limit")}else{None};
            let disk=if next.is_none(){crate::custody::available_bytes(&crawl_dir)?<reserve||crate::custody::available_bytes(destination_root)?<reserve}else{false};
            if next.is_some()||disk{reason=Some(next.unwrap_or("disk-reserve").into());signal_process(pid,libc::SIGINT)?;signalled=Some(Instant::now());}
           }else if signalled.is_some_and(|t|t.elapsed()>Duration::from_secs(180)){kill_capture_container(config,&job.id).await;signal_process(pid,libc::SIGKILL)?;}
           if last_sync.elapsed()>Duration::from_secs(30){let dir=crawl_dir.clone();tokio::task::spawn_blocking(move||sync_checkpoint(&dir)).await.map_err(|e|e.to_string())??;runtime.warc_bytes=warc_bytes(&crawl_dir)?;runtime.runtime_seconds=job.runtime.runtime_seconds+started.elapsed().as_secs();runtime.coverage=Some(progress.clone());runtime.resume_config=find_checkpoint(&crawl_dir,job);database.set_runtime_preserving_control(&job.id,&runtime).map_err(|e|e.to_string())?;last_sync=Instant::now();}
         }
        }
    };
    while let Some(line) = rx.recv().await {
        read_metrics(&line, &mut runtime, &mut policy_ready);
        if let Some(update) = parse_crawl_log_line(&line) {
            progress = merge_progress(&progress, &update);
        }
        if let Some(value) = stop_reason_from_log(&line) {
            reason.get_or_insert(value.into());
        }
    }
    out.await.map_err(|e| e.to_string())??;
    let stderr = err
        .await
        .map_err(|e| e.to_string())?
        .map_err(|e| e.to_string())?;
    runtime.runtime_seconds = job.runtime.runtime_seconds + started.elapsed().as_secs();
    runtime.attempt_deadline = None;
    runtime.warc_bytes = warc_bytes(&crawl_dir)?;
    runtime.coverage = Some(progress.clone());
    runtime.resume_config = find_checkpoint(&crawl_dir, job);
    runtime.can_resume = runtime.resume_config.is_some();
    runtime.stop_reason = reason.or_else(|| match status.code() {
        Some(14) => Some("byte-limit".into()),
        Some(15) => Some("time-limit".into()),
        Some(16) | Some(3) => Some("disk-reserve".into()),
        Some(11) | Some(13) => Some("interrupted".into()),
        Some(18) => Some("rate-limit".into()),
        _ => None,
    });
    if runtime.stop_reason.is_none()
        && progress.pages_done >= u64::from(effective.request.page_limit)
        && progress.pages_queued > 0
    {
        runtime.stop_reason = Some("page-limit".into());
    }
    let collection = effective.request.collection.as_deref().unwrap_or(&job.id);
    if runtime.stop_reason.as_deref() == Some("page-limit")
        && progress.pages_queued == 0
        && !crate::coverage::unfinished_page_limit(&crawl_dir, collection)?
    {
        runtime.stop_reason = None;
    }
    if runtime.stop_reason.is_none() && progress.pages_failed > 0 {
        runtime.stop_reason = Some("page-failures".into());
    }
    database
        .set_progress(&job.id, Some(&progress))
        .map_err(|e| e.to_string())?;
    database
        .set_runtime_preserving_control(&job.id, &runtime)
        .map_err(|e| e.to_string())?;
    if runtime.stop_reason.as_deref() == Some("discard") {
        runtime.can_resume = false;
        database
            .set_runtime_preserving_control(&job.id, &runtime)
            .map_err(|e| e.to_string())?;
        database
            .set_status(&job.id, JobStatus::Cancelled, None)
            .map_err(|e| e.to_string())?;
        return Ok(());
    }
    let source = crawl_dir
        .join("collections")
        .join(collection)
        .join(format!("{collection}.wacz"));
    let latest = database
        .job(&job.id)
        .map_err(|e| e.to_string())?
        .ok_or("job disappeared")?;
    if latest.status == JobStatus::Cancelling {
        database
            .set_status(&job.id, JobStatus::Cancelled, None)
            .map_err(|e| e.to_string())?;
        return Ok(());
    }
    runtime.control = latest.runtime.control;
    if runtime.stop_reason.is_none() {
        runtime.stop_reason = match runtime.control.as_deref() {
            Some("pause") => Some("pause".into()),
            Some("stop") => Some("stop-and-save".into()),
            _ => None,
        };
        database
            .set_runtime_preserving_control(&job.id, &runtime)
            .map_err(|e| e.to_string())?;
    }
    if !policy_ready {
        return Err(
            "capture policy driver did not load; retained WACZ/checkpoint was not published".into(),
        );
    }
    if !source.is_file() {
        let state = if runtime.can_resume {
            JobStatus::Paused
        } else {
            JobStatus::Failed
        };
        database
            .set_status(
                &job.id,
                state,
                Some(if runtime.can_resume {
                    "checkpoint saved; no packaged WACZ yet"
                } else {
                    "crawler produced no archive or resumable checkpoint"
                }),
            )
            .map_err(|e| e.to_string())?;
        if state == JobStatus::Failed {
            return Err(format!(
                "crawler exited with {status}: {}",
                shorten(&stderr, 200)
            ));
        }
        return Ok(());
    }
    let Some(frozen) = database
        .prepare_publication(&job.id, &runtime)
        .map_err(|e| e.to_string())?
    else {
        database
            .set_status(&job.id, JobStatus::Cancelled, None)
            .map_err(|e| e.to_string())?;
        return Ok(());
    };
    runtime = frozen;
    let partial = runtime.stop_reason.is_some() || !status.success();
    let config2 = config.clone();
    let db = database.clone();
    let mut complete = effective.clone();
    complete.runtime = runtime.clone();
    let finish = if runtime.stop_reason.as_deref() == Some("pause") {
        JobStatus::Paused
    } else if partial {
        JobStatus::Partial
    } else {
        JobStatus::Completed
    };
    tokio::task::spawn_blocking(move || {
        crate::library::publish_capture(&config2, &db, &complete, &source, private, finish)
    })
    .await
    .map_err(|e| e.to_string())??;
    // Native state references WARCs in this directory. Partial versions are immutable
    // catalogue objects; next attempt writes only retained worker state.
    if !partial {
        tokio::fs::remove_dir_all(&crawl_dir)
            .await
            .map_err(|e| e.to_string())?;
        runtime.can_resume = false;
        runtime.resume_config = None;
        let current = database
            .job(&job.id)
            .map_err(|e| e.to_string())?
            .ok_or("published job missing")?;
        runtime.archive_id = current.runtime.archive_id;
        runtime.bytes_stored = current.runtime.bytes_stored;
        runtime.estimate = current.runtime.estimate;
        database
            .set_runtime(&job.id, &runtime)
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}
fn stop_reason_from_log(line: &str) -> Option<&'static str> {
    if let Ok(value) = serde_json::from_str::<serde_json::Value>(line) {
        if value["details"]["limit"]["hit"].as_bool() == Some(true) {
            return Some("page-limit");
        }
    }
    let lower = line.to_ascii_lowercase();
    if lower.contains("size threshold") {
        Some("byte-limit")
    } else if lower.contains("time threshold") {
        Some("time-limit")
    } else if lower.contains("disk utilization") && lower.contains("stopping") {
        Some("disk-reserve")
    } else if lower.contains("page limit")
        && (lower.contains("reached") || lower.contains("not queued"))
    {
        Some("page-limit")
    } else {
        None
    }
}
fn find_checkpoint(root: &Path, job: &Job) -> Option<String> {
    let collection = job.request.collection.as_deref().unwrap_or(&job.id);
    let directory = root.join("collections").join(collection).join("crawls");
    let mut files = std::fs::read_dir(directory)
        .ok()?
        .filter_map(Result::ok)
        .filter(|e| {
            e.file_type().is_ok_and(|t| t.is_file())
                && e.path().extension().is_some_and(|v| v == "yaml")
        })
        .collect::<Vec<_>>();
    files.sort_by_key(|e| e.file_name());
    files
        .last()?
        .path()
        .strip_prefix(root)
        .ok()?
        .to_str()
        .map(str::to_owned)
}
fn walk_files(root: &Path) -> Result<Vec<std::path::PathBuf>, String> {
    let mut pending = vec![(root.to_path_buf(), 0)];
    let mut files = vec![];
    let mut count = 0;
    while let Some((dir, depth)) = pending.pop() {
        for entry in std::fs::read_dir(dir).map_err(|e| e.to_string())? {
            let entry = entry.map_err(|e| e.to_string())?;
            let kind = entry.file_type().map_err(|e| e.to_string())?;
            count += 1;
            if count > 20000 {
                return Err("checkpoint entry limit exceeded".into());
            }
            if kind.is_dir() && depth < 6 {
                pending.push((entry.path(), depth + 1));
            } else if kind.is_file() {
                files.push(entry.path());
            } else if kind.is_symlink() {
                return Err("symlink in worker checkpoint".into());
            }
        }
    }
    Ok(files)
}
fn warc_bytes(root: &Path) -> Result<u64, String> {
    Ok(walk_files(root)?
        .iter()
        .filter(|p| p.to_string_lossy().ends_with(".warc.gz"))
        .map(|p| std::fs::metadata(p).map(|m| m.len()).unwrap_or(0))
        .sum())
}
fn sync_checkpoint(root: &Path) -> Result<(), String> {
    for path in walk_files(root)? {
        crate::custody::open_nofollow(&path)?
            .sync_all()
            .map_err(|e| e.to_string())?;
    }
    crate::custody::sync_directory(root)
}
async fn read_stdout(
    mut input: tokio::process::ChildStdout,
    tx: mpsc::Sender<String>,
) -> Result<(), String> {
    let mut chunk = [0u8; 4096];
    let mut line = Vec::new();
    loop {
        let n = input.read(&mut chunk).await.map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        for b in &chunk[..n] {
            if *b == b'\n' {
                let value = String::from_utf8_lossy(&line).into_owned();
                line.clear();
                if tx.send(value).await.is_err() {
                    return Ok(());
                }
            } else if line.len() < 16384 {
                line.push(*b);
            }
        }
    }
    if !line.is_empty() {
        let _ = tx.send(String::from_utf8_lossy(&line).into_owned()).await;
    }
    Ok(())
}

fn record_omission(root: &Path, line: &str) -> Result<(), String> {
    if !line.contains("policyOmission") {
        return Ok(());
    }
    let path = root.join("coverage.jsonl");
    if path.metadata().is_ok_and(|m| m.len() > 16 * 1024 * 1024) {
        return Ok(());
    }
    use std::io::Write;
    let mut file = std::fs::OpenOptions::new()
        .append(true)
        .create(true)
        .open(path)
        .map_err(|e| e.to_string())?;
    writeln!(file, "{}", line.chars().take(8192).collect::<String>()).map_err(|e| e.to_string())
}

fn read_metrics(line: &str, runtime: &mut crate::model::JobRuntime, ready: &mut bool) {
    if let Ok(value) = serde_json::from_str::<serde_json::Value>(line) {
        match value["message"].as_str() {
            Some("policyReady") => *ready = true,
            Some("transferBytes") => {
                runtime.bytes_downloaded = runtime
                    .bytes_downloaded
                    .saturating_add(value["bytes"].as_u64().unwrap_or(0));
            }
            _ => {}
        }
    }
}
