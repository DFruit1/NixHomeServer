//! Worker-owned archive transformations and immutable, authorized dependency inputs.
use crate::{
    archive_engine::{
        self, ArchiveReport, AuthorizedDependency, ExportOptions, PageSample, Verification,
        VerificationCheck,
    },
    catalog::{now, Archive, ListQuery, PublicationIntent},
    config::AppConfig,
    custody,
    database::Database,
    model::{Job, JobStatus, Operation},
};
use serde_json::Value;
use std::{
    collections::BTreeSet,
    path::{Path, PathBuf},
};
pub fn checked_archive(
    config: &AppConfig,
    db: &Database,
    owner: &str,
    id: &str,
    hash: &str,
) -> Result<Archive, String> {
    let a = db
        .archive_for_user(id, owner)
        .map_err(|e| e.to_string())?
        .ok_or("archive not found")?;
    if a.sha256 != hash || hash.len() != 64 {
        return Err(
            "archive immutable identity changed or legacy fixity is not established".into(),
        );
    }
    let path = custody::checked_file(custody::root(config, &a), &a.archive_file)?;
    if custody::sha256(&path)? != hash {
        return Err("archive payload does not match catalogue digest".into());
    }
    Ok(a)
}
pub fn authorized_dependencies(
    config: &AppConfig,
    db: &Database,
    archive: &Archive,
) -> Result<Vec<Archive>, String> {
    fn visit(
        config: &AppConfig,
        db: &Database,
        a: &Archive,
        root: &Archive,
        stack: &mut BTreeSet<String>,
        seen: &mut BTreeSet<String>,
        out: &mut Vec<Archive>,
    ) -> Result<(), String> {
        if out.len() > 100 || !stack.insert(a.id.clone()) {
            return Err("archive dependency cycle or limit exceeded".into());
        }
        for id in &a.dependencies {
            if seen.contains(id) {
                continue;
            }
            let hash = a
                .dependency_hashes
                .get(id)
                .ok_or("dependency has no immutable digest")?;
            let dep = checked_archive(config, db, &root.created_by, id, hash)?;
            if dep.visibility != root.visibility {
                return Err("dependency visibility differs from archive".into());
            }
            visit(config, db, &dep, root, stack, seen, out)?;
            seen.insert(id.clone());
            out.push(dep);
        }
        stack.remove(&a.id);
        Ok(())
    }
    let mut out = vec![];
    visit(
        config,
        db,
        archive,
        archive,
        &mut BTreeSet::new(),
        &mut BTreeSet::new(),
        &mut out,
    )?;
    Ok(out)
}
fn engine_dependencies(
    config: &AppConfig,
    archives: &[Archive],
) -> Result<Vec<AuthorizedDependency>, String> {
    archives
        .iter()
        .map(|a| {
            Ok(AuthorizedDependency {
                archive_id: a.id.clone(),
                sha256: a.sha256.clone(),
                authorized_local_path: custody::checked_file(
                    custody::root(config, a),
                    &a.archive_file,
                )?,
            })
        })
        .collect()
}
fn source(config: &AppConfig, a: &Archive) -> Result<PathBuf, String> {
    custody::checked_file(custody::root(config, a), &a.archive_file)
}
fn publish(
    config: &AppConfig,
    db: &Database,
    job: &Job,
    path: &Path,
    mut a: Archive,
    report: ArchiveReport,
    status: JobStatus,
) -> Result<(), String> {
    a.archive_file = format!(
        "{} {} {}.wacz",
        crate::archive::sanitize_segment(
            url::Url::parse(&a.url)
                .ok()
                .and_then(|u| u.host_str().map(str::to_owned))
                .as_deref()
                .unwrap_or("archive"),
            "archive"
        ),
        chrono::Utc::now().date_naive(),
        a.id
    );
    let reserve = a
        .request
        .as_ref()
        .map(|r| r.options.disk_reserve_bytes)
        .unwrap_or(64 * 1024 * 1024);
    let root = custody::root(config, &a);
    std::fs::create_dir_all(root).map_err(|e| e.to_string())?;
    if custody::available_bytes(root)? < a.archive_bytes.saturating_add(reserve) {
        return Err(
            "destination headroom insufficient for atomic publication; checkpoint retained".into(),
        );
    }
    let intent = PublicationIntent {
        archive: a,
        report,
        source: path.to_string_lossy().into_owned(),
        job_id: Some(job.id.clone()),
        final_status: status.as_str().into(),
    };
    custody::publish(config, db, &intent)
}
pub fn publish_capture(
    config: &AppConfig,
    db: &Database,
    job: &Job,
    path: &Path,
    private: bool,
    status: JobStatus,
) -> Result<(), String> {
    let mut actual = path.to_path_buf();
    let mut report = archive_engine::inspect_archive(&actual)?;
    let id = crate::queue::random_job_id();
    let mut a = Archive::new(
        id,
        job.created_by.clone(),
        Some(job.request.clone()),
        &report,
    );
    if private {
        a.visibility = "private".into();
    }
    a.capture_status = if status == JobStatus::Completed {
        "complete"
    } else {
        "partial"
    }
    .into();
    a.stop_reason = job.runtime.stop_reason.clone();
    a.clean_rules = job.request.options.selectors.clone();
    if let Operation::Repair {
        archive_id,
        sha256,
        urls,
    } = &job.runtime.operation
    {
        let parent = checked_archive(config, db, &job.created_by, archive_id, sha256)?;
        let deps = authorized_dependencies(config, db, &parent)?;
        let auth = engine_dependencies(config, &deps)?;
        let destination = path
            .parent()
            .ok_or("repair staging parent missing")?
            .join(format!("repair-{}.wacz", a.id));
        report = archive_engine::compose_repair(
            &source(config, &parent)?,
            path,
            &destination,
            &auth,
            urls,
        )?;
        actual = destination;
        a.parent_id = Some(parent.id.clone());
        a.parent_sha256 = Some(parent.sha256.clone());
        a.capture_status = "repair".into();
        a.visibility = parent.visibility;
        a.request = parent.request;
    } else if job.request.options.deduplicate {
        let host = url::Url::parse(&a.url)
            .ok()
            .and_then(|u| u.host_str().map(str::to_owned))
            .unwrap_or_default();
        let candidates = db
            .archives(
                &job.created_by,
                &ListQuery {
                    q: host,
                    limit: Some(10),
                    ..Default::default()
                },
            )
            .map_err(|e| e.to_string())?
            .items;
        let mut authorized = vec![];
        for parent in candidates
            .into_iter()
            .filter(|p| p.visibility == a.visibility && p.sha256.len() == 64)
        {
            checked_archive(config, db, &job.created_by, &parent.id, &parent.sha256)?;
            for dep in authorized_dependencies(config, db, &parent)? {
                if !authorized.iter().any(|a: &Archive| a.id == dep.id) {
                    authorized.push(dep);
                }
            }
            if !authorized.iter().any(|a| a.id == parent.id) {
                authorized.push(parent);
            }
        }
        if !authorized.is_empty() {
            let destination = path
                .parent()
                .ok_or("dedupe staging parent missing")?
                .join(format!("dedupe-{}.wacz", a.id));
            report = archive_engine::deduplicate_archive(
                path,
                &destination,
                &engine_dependencies(config, &authorized)?,
            )?;
            actual = destination;
            for id in &report.dependencies {
                let dep = authorized
                    .iter()
                    .find(|v| v.id == *id)
                    .ok_or("engine emitted unauthorized dependency")?;
                a.dependencies.push(dep.id.clone());
                a.dependency_hashes
                    .insert(dep.id.clone(), dep.sha256.clone());
            }
        }
    }
    a.archive_bytes = report.archive_bytes;
    a.sha256 = report.sha256.clone();
    a.page_count = report.pages.len() as u64;
    a.resource_count = report.resources.len() as u64;
    a.report.unique_payload_bytes = report.unique_payload_bytes;
    a.report.duplicate_payload_bytes = report.duplicate_payload_bytes;
    a.report.metadata_bytes = report.metadata_bytes;
    a.report.warnings = report.warnings.iter().take(100).cloned().collect();
    if job.request.options.max_resource_bytes.is_some() {
        a.report.warnings.push("Per-resource cap checks advertised Content-Length; unknown-length active requests may overshoot. WARC and disk budgets remain bounded with packaging headroom.".into());
    }
    if a.capture_status == "repair" {
        a.report.warnings.push("Mixed-time repair: selected successful response records take replay precedence; untouched parent records retain original capture times.".into());
    }
    if matches!(job.runtime.operation, Operation::Sample) {
        let samples = page_samples(&report);
        let estimate = archive_engine::estimate_size(
            &samples,
            job.request.page_limit as u64,
            job.request.page_limit,
            true,
        );
        let mut rt = job.runtime.clone();
        rt.estimate = Some(estimate);
        db.set_runtime(&job.id, &rt).map_err(|e| e.to_string())?;
    }
    publish(config, db, job, &actual, a, report, status)
}
pub fn page_samples(report: &ArchiveReport) -> Vec<PageSample> {
    report
        .pages
        .iter()
        .take(20)
        .map(|p| PageSample {
            url: p.url.clone(),
            bytes: p.bytes,
            shared_bytes: 0,
            resource_digests: report
                .resources
                .iter()
                .filter(|r| r.pages.contains(&p.url) || p.resource_urls.contains(&r.url))
                .map(|r| (r.digest.clone(), r.bytes))
                .collect(),
            measured: true,
        })
        .collect()
}
pub fn execute(config: &AppConfig, db: &Database, job: &Job) -> Result<(), String> {
    let current = db
        .job(&job.id)
        .map_err(|e| e.to_string())?
        .ok_or("job not found")?;
    if current.status == JobStatus::Cancelling {
        db.set_status(&job.id, JobStatus::Cancelled, None)
            .map_err(|e| e.to_string())?;
        return Ok(());
    }
    db.set_status(&job.id, JobStatus::Running, None)
        .map_err(|e| e.to_string())?;
    let scratch = config.checkpoints_root.join(&job.id);
    custody::private_directory(&scratch)?;
    match &job.runtime.operation {
        Operation::Import { inbox_id } => {
            if !custody::safe_id(inbox_id) {
                return Err("unsafe inbox identity".into());
            }
            let path = custody::checked_file(&config.inbox_root, inbox_id)?;
            let report = archive_engine::inspect_archive(&path)?;
            if !report.dependencies.is_empty() {
                return Err("import references dependencies without an authorized identity set; use a standalone WACZ".into());
            }
            if let Some(a) = db
                .archive_by_hash(&job.created_by, &report.sha256)
                .map_err(|e| e.to_string())?
            {
                let mut rt = job.runtime.clone();
                rt.archive_id = Some(a.id);
                rt.bytes_stored = a.archive_bytes;
                db.set_runtime(&job.id, &rt).map_err(|e| e.to_string())?;
                db.set_status(&job.id, JobStatus::Completed, None)
                    .map_err(|e| e.to_string())?;
            } else {
                let mut a = Archive::new(
                    crate::queue::random_job_id(),
                    job.created_by.clone(),
                    None,
                    &report,
                );
                a.capture_status = "imported".into();
                a.visibility = "private".into();
                publish(config, db, job, &path, a, report, JobStatus::Completed)?;
            }
            std::fs::remove_file(path).map_err(|e| e.to_string())?;
        }
        Operation::ProfileImport {
            profile_id,
            inbox_id,
        } => {
            crate::profiles::accept(config, db, profile_id, inbox_id, &job.created_by)?;
            db.set_status(&job.id, JobStatus::Completed, None)
                .map_err(|e| e.to_string())?;
        }
        Operation::Export {
            archive_id,
            sha256,
            options,
        } => {
            let parent = checked_archive(config, db, &job.created_by, archive_id, sha256)?;
            let deps = authorized_dependencies(config, db, &parent)?;
            let path = scratch.join("export.wacz");
            let report = archive_engine::materialize_archive(
                &source(config, &parent)?,
                &path,
                &engine_dependencies(config, &deps)?,
                options,
            )?;
            let mut a = Archive::new(
                crate::queue::random_job_id(),
                job.created_by.clone(),
                parent.request.clone(),
                &report,
            );
            a.visibility = parent.visibility;
            a.parent_id = Some(parent.id);
            a.parent_sha256 = Some(parent.sha256);
            a.capture_status = "derived".into();
            a.clean_rules = parent.clean_rules;
            publish(config, db, job, &path, a, report, JobStatus::Completed)?;
        }
        Operation::Verify {
            archive_id,
            sha256,
            mode,
            url,
            interactions,
        } => {
            let mut a = if sha256.is_empty() {
                db.archive_for_user(archive_id, &job.created_by)
                    .map_err(|e| e.to_string())?
                    .ok_or("archive not found")?
            } else {
                checked_archive(config, db, &job.created_by, archive_id, sha256)?
            };
            let deps = authorized_dependencies(config, db, &a)?;
            let mut input = source(config, &a)?;
            if !deps.is_empty() {
                let path = scratch.join("standalone.wacz");
                archive_engine::materialize_archive(
                    &input,
                    &path,
                    &engine_dependencies(config, &deps)?,
                    &ExportOptions::default(),
                )?;
                input = path;
            }
            let mut verification = archive_engine::verify_archive(&input)?;
            if a.sha256.is_empty() && verification.valid {
                let report = archive_engine::inspect_archive(&input)?;
                a.sha256 = report.sha256.clone();
                a.archive_bytes = report.archive_bytes;
                a.page_count = report.pages.len() as u64;
                a.resource_count = report.resources.len() as u64;
                let intent = PublicationIntent {
                    archive: a.clone(),
                    report,
                    source: input.to_string_lossy().into_owned(),
                    job_id: None,
                    final_status: "completed".into(),
                };
                db.replace_legacy_inventory(&intent)
                    .map_err(|e| e.to_string())?;
            }
            if mode == "browser" && verification.valid {
                browser_qa(
                    config,
                    db,
                    job,
                    &a,
                    &input,
                    &scratch,
                    url.as_deref(),
                    interactions,
                    &mut verification,
                )?;
            }
            a.verification = Some(verification);
            a.updated_at = now();
            db.save_archive_metadata(&a).map_err(|e| e.to_string())?;
            let mut rt = job.runtime.clone();
            rt.archive_id = Some(a.id);
            db.set_runtime(&job.id, &rt).map_err(|e| e.to_string())?;
            db.set_status(&job.id, JobStatus::Completed, None)
                .map_err(|e| e.to_string())?;
        }
        Operation::Reconcile => {
            custody::recover(config, db)?;
            let mut files = vec![];
            for root in [&config.archive_root, &config.private_archive_root] {
                if let Ok(entries) = std::fs::read_dir(root) {
                    for entry in entries.take(10000).flatten() {
                        if entry.file_type().is_ok_and(|t| t.is_file())
                            && entry.path().extension().is_some_and(|v| v == "wacz")
                        {
                            files.push(entry.file_name().to_string_lossy().into_owned());
                        }
                    }
                }
            } // Names are never returned: they may reveal another owner's private source.
            db.add_event(&job.id,"reconciliation",Some(&format!("Reconciled known publication intents; {} retained files examined. Unattributed files remain unclaimed; explicit owner import required.",files.len()))).map_err(|e|e.to_string())?;
            db.set_status(&job.id, JobStatus::Completed, None)
                .map_err(|e| e.to_string())?;
        }
        _ => return Err("capture operation must run on asynchronous crawler worker".into()),
    }
    // These operations have no resumable crawl state. Published output and DB commit
    // are durable before their exact task staging is cleaned.
    std::fs::remove_dir_all(&scratch).map_err(|e| e.to_string())?;
    Ok(())
}
fn check(v: &mut Verification, name: &str, status: &str, details: String) {
    if let Some(check) = v.checks.iter_mut().find(|c| c.name == name) {
        check.status = status.into();
        check.details = details;
    } else {
        v.checks.push(VerificationCheck {
            name: name.into(),
            status: status.into(),
            details,
        });
    }
}
fn browser_qa(
    config: &AppConfig,
    db: &Database,
    job: &Job,
    a: &Archive,
    input: &Path,
    scratch: &Path,
    url: Option<&str>,
    interactions: &[crate::model::Interaction],
    v: &mut Verification,
) -> Result<(), String> {
    if let Some(id) = a
        .request
        .as_ref()
        .and_then(|r| r.options.profile_id.as_ref())
    {
        crate::profiles::checked_profile(config, db, id, &job.created_by)?;
    }
    let mut request = a.request.clone().unwrap_or_else(|| job.request.clone());
    request.options.interactions = interactions.to_vec();
    crate::crawler::write_capture_config(&request, scratch, None)?;
    let source = input.canonicalize().map_err(|e| e.to_string())?;
    let mut command = std::process::Command::new(&config.podman_bin);
    command
        .args([
            "run",
            "--rm",
            "--network=none",
            "--shm-size=1g",
            "--cap-add=SYS_ADMIN",
            "--security-opt=seccomp=unconfined",
            "--pid=host",
            "--uts=host",
            "-v",
        ])
        .arg(format!("{}:/qa/source.wacz:ro", source.display()))
        .arg("-v")
        .arg(format!("{}:/crawls", scratch.display()))
        .arg(&config.crawler_image)
        .args([
            "qa",
            "--qaSource",
            "/qa/source.wacz",
            "--config",
            "/crawls/capture.json",
            "--collection",
            "qa",
            "--cwd",
            "/crawls",
            "--timeLimit",
            "240",
            "--workers",
            "1",
        ]);
    if let Some(url) = url {
        let escaped = url
            .chars()
            .map(|c| {
                if ".*+?^${}()|[]\\".contains(c) {
                    format!("\\{c}")
                } else {
                    c.to_string()
                }
            })
            .collect::<String>();
        command.args(["--include", &format!("^{escaped}$")]);
    }
    let log = scratch.join("qa.log");
    let log_file = std::fs::File::create(&log).map_err(|e| e.to_string())?;
    command
        .stdin(std::process::Stdio::null())
        .stdout(log_file.try_clone().map_err(|e| e.to_string())?)
        .stderr(log_file);
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(_) => {
            check(
                v,
                "offline-browser-replay",
                "not-run",
                "Pinned browser runtime unavailable; file fixity only".into(),
            );
            return Ok(());
        }
    };
    let started = std::time::Instant::now();
    let status = loop {
        if let Some(status) = child.try_wait().map_err(|e| e.to_string())? {
            break Some(status);
        }
        if started.elapsed() > std::time::Duration::from_secs(300) {
            let _ = child.kill();
            let _ = child.wait();
            break None;
        }
        if log
            .metadata()
            .map(|m| m.len() > 16 * 1024 * 1024)
            .unwrap_or(false)
        {
            let _ = child.kill();
            let _ = child.wait();
            break None;
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    };
    if status.is_none_or(|s| !s.success()) {
        check(
            v,
            "offline-browser-replay",
            "not-run",
            "Pinned crawler QA could not complete within isolated runtime bounds".into(),
        );
        return Ok(());
    }
    let pagefile = scratch.join("collections/qa/pages/pages.jsonl");
    let bytes = std::fs::read(&pagefile).unwrap_or_default();
    if bytes.len() > 16 * 1024 * 1024 {
        return Err("QA report exceeded bounds".into());
    }
    let pages = String::from_utf8_lossy(&bytes)
        .lines()
        .take(20001)
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .filter(|p| p.get("url").is_some())
        .collect::<Vec<_>>();
    let expected = if url.is_some() { 1 } else { a.page_count };
    let loaded = pages.len() as u64;
    let bad = pages.iter().any(|p| {
        p["comparison"]["resourceCounts"]["replayBad"]
            .as_u64()
            .unwrap_or(0)
            > 0
    });
    check(v,"offline-browser-replay",if loaded>=expected&&loaded>0&&!bad{"pass"}else{"fail"},format!("{loaded}/{expected} pages observed, network=none blocks all live origins including service workers"));
    for (field, name) in [
        ("screenshotMatch", "screenshot-baseline"),
        ("textMatch", "text-baseline"),
    ] {
        let measures = pages
            .iter()
            .filter_map(|p| p["comparison"][field].as_f64())
            .collect::<Vec<_>>();
        let state = if measures.len() != pages.len() || measures.is_empty() {
            "not-run"
        } else if measures.iter().all(|v| *v >= 0.95) {
            "pass"
        } else {
            "fail"
        };
        check(
            v,
            name,
            state,
            format!(
                "{}/{} comparable baselines; acceptance >=95%",
                measures.len(),
                pages.len()
            ),
        );
    }
    let observations = std::fs::read(scratch.join("interactions.jsonl")).unwrap_or_default();
    if observations.len() > 1024 * 1024 {
        return Err("interaction report exceeded bounds".into());
    }
    let checks = String::from_utf8_lossy(&observations)
        .lines()
        .filter_map(|s| serde_json::from_str::<Value>(s).ok())
        .flat_map(|p| p["checks"].as_array().cloned().unwrap_or_default())
        .collect::<Vec<_>>();
    let state = if interactions.is_empty() {
        "not-run"
    } else if checks.len() >= interactions.len() && checks.iter().all(|c| c["status"] == "pass") {
        "pass"
    } else {
        "fail"
    };
    check(
        v,
        "interaction-assertions",
        state,
        format!(
            "{} observed assertions, {} configured per page",
            checks.len(),
            interactions.len()
        ),
    );
    Ok(())
}
