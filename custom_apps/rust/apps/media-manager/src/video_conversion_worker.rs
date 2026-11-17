//! The low-priority video conversion worker. It runs while conversions are
//! queued or installing and exits when there is nothing left, so a deploy never
//! waits on (or restarts) an encode that takes hours.
use crate::{
    broker::{
        file_fingerprint, open_regular_file_beneath, opened_file_fingerprint, BrokerAction,
        ConvertVideoAction, InstallSubtitleAction,
    },
    catalog::{Catalog, CatalogHandle, ConfirmPlanOutcome, MutationPlanDraft},
    config::{AppConfig, Identity, RootScope},
    media::LibraryCategory,
    scanner::{scan_root_now, ScanRoot},
    transcription::fs::Dir,
    video_conversion::{
        all_jobs, available_space, cancel_marker, cancel_requested, not_enough_space, now,
        output_relative_path, owner_dir, plan, prune_history, verify_output, EncodePlan, Format,
        Job, SourceProbe, STAGING_DIRECTORY,
    },
};
use serde_json::json;
use std::{
    fs::{File, OpenOptions},
    io::{BufRead, BufReader, Read},
    os::{fd::AsRawFd, unix::fs::OpenOptionsExt},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};

/// Applications told to look for the replaced file once a conversion lands.
const REFRESHED_INTEGRATIONS: &[&str] = &["jellyfin", "radarr", "sonarr"];
const PROGRESS_SAVE_INTERVAL: Duration = Duration::from_secs(15);
const STALL_LIMIT: Duration = Duration::from_secs(45 * 60);
const ENCODE_LIMIT: Duration = Duration::from_secs(48 * 3600);
const INSTALL_POLL: Duration = Duration::from_secs(15);

pub fn log(level: &str, event: &str, detail: serde_json::Value) {
    eprintln!(
        "{}",
        json!({ "level": level, "service": "media-manager-video-convert", "event": event, "detail": detail })
    );
}

pub fn run(config: &AppConfig) -> Result<(), String> {
    if config.mutation_mode != crate::config::MutationMode::Enabled {
        return Ok(());
    }
    let ffprobe = config
        .ffprobe_path
        .clone()
        .ok_or("MEDIA_MANAGER_FFPROBE is not set")?;
    let ffmpeg = ffprobe.with_file_name("ffmpeg");
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .mode(0o660)
        .open(config.state_dir.join("video-convert.lock"))
        .map_err(|error| format!("open worker lock: {error}"))?;
    if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        log("info", "video_convert_already_running", json!({}));
        return Ok(());
    }
    // Encodes interrupted by a crash or reboot start again from the beginning.
    for mut job in all_jobs(config)?
        .into_iter()
        .filter(|job| job.state == "encoding")
    {
        job.state = "queued".into();
        job.progress = None;
        job.save(config)?;
    }
    sweep_staging(config);
    loop {
        let jobs = all_jobs(config)?;
        let mut installing = false;
        for job in jobs.iter().filter(|job| job.state == "installing") {
            let mut job = job.clone();
            if let Err(error) = check_installation(config, &mut job) {
                fail(config, &mut job, error);
            }
            installing |= job.state == "installing";
        }
        // One conversion at a time, through installation, so a large batch
        // never holds more than one encode, archive copy and library copy.
        if !installing {
            let Some(mut job) = jobs.into_iter().find(|job| job.state == "queued") else {
                log("info", "video_convert_idle", json!({}));
                return Ok(());
            };
            if let Err(error) = convert(config, &ffmpeg, &ffprobe, &mut job) {
                fail(config, &mut job, error);
            }
            continue;
        }
        std::thread::sleep(INSTALL_POLL);
    }
}

fn fail(config: &AppConfig, job: &mut Job, error: String) {
    log(
        "error",
        "video_conversion_failed",
        json!({ "jobId": job.id, "error": error }),
    );
    if job.state == "cancelled" {
        return;
    }
    job.state = "failed".into();
    job.error = Some(error);
    job.finished_at = Some(now());
    if let Err(error) = job.save(config) {
        log(
            "error",
            "video_conversion_record_failed",
            json!({ "jobId": job.id, "error": error }),
        );
    }
}

fn staging_dir(config: &AppConfig) -> Result<(Dir, PathBuf), String> {
    let root = crate::conversion_jobs::staging_root(config);
    std::fs::create_dir_all(&root).map_err(|error| format!("prepare staging: {error}"))?;
    let dir = Dir::open(&root)?.create_shared(STAGING_DIRECTORY)?;
    Ok((dir, root.join(STAGING_DIRECTORY)))
}

fn owner_identity(job: &Job) -> Result<Identity, String> {
    Identity::try_new(&job.owner, ["users"]).map_err(|_| "Invalid owner".to_string())
}

/// Open the library file and confirm it is still the one that was queued.
fn open_source(config: &AppConfig, job: &Job) -> Result<(File, PathBuf), String> {
    let identity = owner_identity(job)?;
    let root = config
        .resolve_visible_root(&identity, &job.root_id)
        .filter(|root| root.available && root.category == LibraryCategory::Videos)
        .ok_or("The video library is unavailable.")?;
    let root_path = PathBuf::from(&root.resolved_path);
    let file = open_regular_file_beneath(&root_path, &job.relative_path)
        .map_err(|_| "The video could not be opened. Rescan the library and try again.")?;
    if opened_file_fingerprint(&file).ok().as_deref() != Some(job.expected_source.as_str()) {
        return Err(
            "The video changed after it was queued, so it was not converted. Queue it again."
                .into(),
        );
    }
    Ok((file, root_path))
}

fn probe(ffprobe: &Path, input: File) -> Result<SourceProbe, String> {
    let output = Command::new(ffprobe)
        .args([
            "-v",
            "error",
            "-print_format",
            "json",
            "-show_streams",
            "-show_format",
            "/proc/self/fd/0",
        ])
        .stdin(Stdio::from(input))
        .stderr(Stdio::null())
        .output()
        .map_err(|error| format!("run ffprobe: {error}"))?;
    if !output.status.success() {
        return Err("The video could not be read.".into());
    }
    SourceProbe::parse(&output.stdout)
}

fn convert(config: &AppConfig, ffmpeg: &Path, ffprobe: &Path, job: &mut Job) -> Result<(), String> {
    let format = Format::parse(&job.format).ok_or("Unknown conversion format.")?;
    let (source, _) = open_source(config, job)?;
    let source_probe = probe(
        ffprobe,
        source.try_clone().map_err(|error| error.to_string())?,
    )?;
    let extension = job
        .relative_path
        .rsplit_once('.')
        .map_or("", |(_, extension)| extension);
    let plan = plan(format, extension, &source_probe)?;
    let output_path = output_relative_path(&job.relative_path, format);
    if job.destination_root_id.is_none() && output_path != job.relative_path {
        let (_, root_path) = open_source(config, job)?;
        if std::fs::symlink_metadata(root_path.join(&output_path)).is_ok() {
            return Err(format!(
                "{} already exists beside this video. Move or remove it, then convert again.",
                output_path.rsplit('/').next().unwrap_or(&output_path)
            ));
        }
    }

    // Peak use: the encode, the archived original and the library copy of the
    // conversion, each estimated at the source's size. The broker re-checks
    // its share with exact sizes before copying anything.
    let reserve = config.free_space_reserve_bytes;
    let needed = job.source_bytes.saturating_mul(3).saturating_add(reserve);
    let available = available_space(&crate::conversion_jobs::staging_root(config))?;
    if available < needed {
        return Err(not_enough_space(needed, reserve, available));
    }

    job.state = "encoding".into();
    job.started_at = Some(now());
    job.progress = Some(0.0);
    job.error = None;
    job.save(config)?;
    log(
        "info",
        "video_conversion_started",
        json!({ "jobId": job.id, "format": job.format }),
    );

    let (staging, staging_path) = staging_dir(config)?;
    let partial_name = format!(".{}.partial", job.id);
    let staging_filename = format!("{}.{}", job.id, format.extension());
    let _ = staging.remove(&partial_name);
    let _ = staging.remove(&staging_filename);
    let partial = staging_path.join(&partial_name);
    let result = encode(config, ffmpeg, source, &plan, &partial, &source_probe, job);
    if let Err(error) = result {
        let _ = staging.remove(&partial_name);
        if job.state == "cancelled" {
            let _ =
                owner_dir(config, &job.owner).and_then(|dir| dir.remove(&cancel_marker(&job.id)));
            job.finished_at = Some(now());
            job.progress = None;
            job.save(config)?;
            log(
                "info",
                "video_conversion_cancelled",
                json!({ "jobId": job.id }),
            );
            return Ok(());
        }
        return Err(error);
    }
    staging.rename_new(&staging_filename, &staging, &partial_name)?;
    let staged_path = staging_path.join(&staging_filename);
    let discard = |message: String| {
        let _ = staging.remove(&staging_filename);
        message
    };
    let output_probe =
        probe(ffprobe, staging.file(&staging_filename).map_err(discard)?).map_err(discard)?;
    verify_output(&source_probe, &output_probe, &plan).map_err(discard)?;
    let expected_replacement =
        file_fingerprint(&staged_path).map_err(|error| discard(error.to_string()))?;
    // The library file must still be the one that was encoded.
    open_source(config, job).map_err(discard)?;

    let output_path = if job.destination_root_id.is_some() {
        output_path
            .rsplit('/')
            .next()
            .unwrap_or(&output_path)
            .to_string()
    } else {
        output_path
    };
    let action = if let Some(destination_root_id) = &job.destination_root_id {
        if format != Format::AudioMp3 {
            return Err(discard("Invalid audio format".into()));
        }
        BrokerAction::CopyVideoAudio(InstallSubtitleAction {
            staging_filename: staging_filename.clone(),
            destination_root_id: destination_root_id.clone(),
            destination_relative_path: output_path.clone(),
            expected: expected_replacement,
        })
    } else {
        if format == Format::AudioMp3 {
            return Err(discard("Missing audio destination".into()));
        }
        BrokerAction::ConvertVideo(ConvertVideoAction {
            staging_filename: staging_filename.clone(),
            root_id: job.root_id.clone(),
            source_relative_path: job.relative_path.clone(),
            replacement_relative_path: output_path.clone(),
            archived_relative_path: job.archived_relative_path(),
            expected_source: job.expected_source.clone(),
            expected_replacement,
        })
    };
    let plan_id = format!("plan-video-{}", job.id);
    queue_plan(config, job, &plan_id, action).map_err(discard)?;
    job.state = "installing".into();
    job.progress = Some(1.0);
    job.plan_id = Some(plan_id);
    job.staging_filename = Some(staging_filename);
    job.output_relative_path = Some(output_path);
    job.output_bytes = std::fs::metadata(&staged_path).ok().map(|meta| meta.len());
    job.dropped_subtitles = plan.dropped_subtitles;
    job.save(config)?;
    log(
        "info",
        "video_conversion_encoded",
        json!({ "jobId": job.id }),
    );
    Ok(())
}

fn encode(
    config: &AppConfig,
    ffmpeg: &Path,
    source: File,
    plan: &EncodePlan,
    partial: &Path,
    source_probe: &SourceProbe,
    job: &mut Job,
) -> Result<(), String> {
    let mut child = Command::new(ffmpeg)
        .args([
            "-hide_banner",
            "-nostdin",
            "-loglevel",
            "error",
            "-fflags",
            "+genpts",
        ])
        .args(["-i", "/proc/self/fd/0"])
        .args(&plan.args)
        .args([
            "-progress",
            "pipe:1",
            "-stats_period",
            "5",
            "-f",
            plan.muxer,
        ])
        .arg(partial)
        .stdin(Stdio::from(source))
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| format!("start ffmpeg: {error}"))?;
    let position_us = Arc::new(AtomicU64::new(0));
    let stdout = child.stdout.take().ok_or("ffmpeg stdout missing")?;
    let reader_position = position_us.clone();
    let progress_reader = std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if let Some(value) = line
                .strip_prefix("out_time_us=")
                .and_then(|value| value.trim().parse::<u64>().ok())
            {
                reader_position.store(value, Ordering::Relaxed);
            }
        }
    });
    let stderr = child.stderr.take().ok_or("ffmpeg stderr missing")?;
    let error_reader = std::thread::spawn(move || {
        let mut tail = String::new();
        let _ = BufReader::new(stderr.take(1024 * 1024)).read_to_string(&mut tail);
        let lines = tail.lines().rev().take(3).collect::<Vec<_>>();
        lines.into_iter().rev().collect::<Vec<_>>().join(" ")
    });

    let started = Instant::now();
    let mut last_save = Instant::now();
    let mut last_change = Instant::now();
    let mut last_position = 0;
    let duration_us = source_probe
        .duration_seconds
        .map(|seconds| (seconds * 1_000_000.0) as u64);
    let outcome = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Ok(status),
            Ok(None) => {}
            Err(error) => break Err(format!("wait for ffmpeg: {error}")),
        }
        let position = position_us.load(Ordering::Relaxed);
        if position != last_position {
            last_position = position;
            last_change = Instant::now();
        }
        if cancel_requested(config, job) {
            job.state = "cancelled".into();
            break Err("Cancelled.".into());
        }
        if last_change.elapsed() > STALL_LIMIT || started.elapsed() > ENCODE_LIMIT {
            break Err("The conversion stopped making progress, so it was stopped.".into());
        }
        if last_save.elapsed() >= PROGRESS_SAVE_INTERVAL {
            last_save = Instant::now();
            // An encode larger than estimated stops before it eats the reserve.
            match available_space(partial) {
                Ok(available) if available < config.free_space_reserve_bytes => {
                    let reserve = config.free_space_reserve_bytes;
                    break Err(not_enough_space(reserve, reserve, available));
                }
                Err(error) => break Err(error),
                Ok(_) => {}
            }
            if let Some(duration) = duration_us.filter(|duration| *duration > 0) {
                job.progress = Some((position as f64 / duration as f64).clamp(0.0, 0.99));
                // Stop ffmpeg rather than leave it running unattended.
                if let Err(error) = job.save(config) {
                    break Err(error);
                }
            }
        }
        std::thread::sleep(Duration::from_millis(500));
    };
    let status = match outcome {
        Ok(status) => status,
        Err(error) => {
            let _ = child.kill();
            let _ = child.wait();
            let _ = progress_reader.join();
            let _ = error_reader.join();
            return Err(error);
        }
    };
    let _ = progress_reader.join();
    let detail = error_reader.join().unwrap_or_default();
    if !status.success() {
        log(
            "error",
            "video_conversion_ffmpeg_failed",
            json!({ "jobId": job.id, "status": status.to_string(), "detail": detail }),
        );
        return Err(if detail.is_empty() {
            "The converter could not convert this video.".to_string()
        } else {
            format!("The converter could not convert this video: {detail}")
        });
    }
    Ok(())
}

fn queue_plan(
    config: &AppConfig,
    job: &Job,
    plan_id: &str,
    action: BrokerAction,
) -> Result<(), String> {
    let mut catalog = Catalog::initialize(&config.database_path())
        .map_err(|error| format!("open control database: {error}"))?;
    let actions = vec![action];
    let request = json!({ "kind": "video_conversion", "jobId": job.id, "itemIds": [job.item_id] });
    let expires_at = now().saturating_add(3600) as i64;
    let digest = homelab_common::sha256_hex(
        &serde_json::to_vec(&json!({
            "actor": job.owner,
            "request": request,
            "actions": actions,
            "expiresAt": expires_at,
        }))
        .map_err(|error| error.to_string())?,
    );
    catalog
        .create_mutation_plan(&MutationPlanDraft {
            id: plan_id.to_string(),
            owner_username: job.owner.clone(),
            digest: digest.clone(),
            request_json: request.to_string(),
            expires_at,
            actions,
        })
        .map_err(|error| format!("record conversion plan: {error}"))?;
    // Queuing the conversion was the confirmation; the broker applies it next.
    match catalog
        .confirm_mutation_plan(plan_id, &job.owner, &digest, now() as i64)
        .map_err(|error| format!("queue conversion plan: {error}"))?
    {
        ConfirmPlanOutcome::Queued => {}
        outcome => return Err(format!("The conversion could not be queued ({outcome:?}).")),
    }
    let _ = catalog.insert_audit_event(
        &format!("video-{}", job.id),
        &job.owner,
        "video_conversion_queued",
        Some(plan_id),
        &json!({ "itemId": job.item_id, "format": job.format }).to_string(),
    );
    Ok(())
}

fn check_installation(config: &AppConfig, job: &mut Job) -> Result<(), String> {
    let plan_id = job
        .plan_id
        .clone()
        .ok_or("The conversion lost its install plan.")?;
    let catalog = Catalog::initialize(&config.database_path())
        .map_err(|error| format!("open control database: {error}"))?;
    let status = catalog
        .mutation_plan_status_for_owner(&plan_id, &job.owner)
        .map_err(|error| format!("read conversion plan: {error}"))?
        .ok_or("The conversion's install plan is missing.")?;
    match status.state.as_str() {
        "completed" => {
            job.state = "completed".into();
            job.finished_at = Some(now());
            job.save(config)?;
            log(
                "info",
                "video_conversion_completed",
                json!({ "jobId": job.id }),
            );
            after_install(config, job);
            let _ = prune_history(config, &job.owner);
            Ok(())
        }
        "queued" | "running" => Ok(()),
        _ => {
            // The plan will not run again on its own; drop its staged encode.
            if let (Some(filename), Ok((staging, _))) =
                (job.staging_filename.as_deref(), staging_dir(config))
            {
                let _ = staging.remove(filename);
            }
            Err(status
                .error
                .unwrap_or_else(|| format!("Installing the conversion {}.", status.state)))
        }
    }
}

/// Remove encodes left by a crash: partial files (no encode runs while the
/// worker lock is held here) and finished encodes no installing job owns.
fn sweep_staging(config: &AppConfig) {
    let Ok((staging, _)) = staging_dir(config) else {
        return;
    };
    // Without the job list nothing can be judged orphaned.
    let Ok(jobs) = all_jobs(config) else {
        return;
    };
    let installing = jobs
        .into_iter()
        .filter(|job| job.state == "installing")
        .filter_map(|job| job.staging_filename)
        .collect::<std::collections::BTreeSet<_>>();
    for name in staging.names().unwrap_or_default() {
        let orphan = if name.starts_with('.') {
            name.ends_with(".partial")
        } else {
            !installing.contains(&name)
        };
        if orphan && staging.remove(&name).is_ok() {
            log(
                "info",
                "video_conversion_orphan_removed",
                json!({ "file": name }),
            );
        }
    }
}

/// Update the catalog and the applications that index the library.
fn after_install(config: &AppConfig, job: &Job) {
    if let Ok(identity) = owner_identity(job)
        && let Some(root) = config.resolve_visible_root(
            &identity,
            job.destination_root_id.as_deref().unwrap_or(&job.root_id),
        )
    {
        let scan_root = ScanRoot {
            id: root.id.clone(),
            owner_username: (root.scope == RootScope::Personal).then(|| job.owner.clone()),
            path: root.resolved_path.clone().into(),
            category: root.category,
        };
        if let Err(error) = scan_root_now(
            &CatalogHandle::new(config.database_path()),
            &scan_root,
            now() as i64,
        ) {
            log(
                "error",
                "video_conversion_rescan_failed",
                json!({ "jobId": job.id, "error": error }),
            );
        }
    }
    for integration in if job.destination_root_id.is_some() {
        &["audiobookshelf"][..]
    } else {
        REFRESHED_INTEGRATIONS
    } {
        if !crate::applications::refresh_adapter_available(config, integration) {
            continue;
        }
        if let Err(error) = queue_refresh(config, integration, &job.owner) {
            log(
                "error",
                "video_conversion_refresh_failed",
                json!({ "jobId": job.id, "integrationId": integration, "error": error }),
            );
        }
    }
}

/// Same marker the App refresh page writes; an already queued refresh covers it.
fn queue_refresh(config: &AppConfig, integration: &str, actor: &str) -> Result<(), String> {
    let directory = Dir::open(&config.state_dir)?.child("refresh-requests")?;
    let marker = format!("{integration}.request");
    if directory.file(&marker).is_ok() {
        return Ok(());
    }
    let payload = json!({
        "schemaVersion": 1,
        "integrationId": integration,
        "actor": actor,
        "requestId": homelab_common::logging::request_id(),
        "queuedAt": now(),
        "state": "queued",
    });
    directory.write(&marker, payload.to_string().as_bytes())
}
