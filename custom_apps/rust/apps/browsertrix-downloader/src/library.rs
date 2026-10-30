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
pub fn authorized_view_dependencies(
    config: &AppConfig,
    db: &Database,
    a: &Archive,
) -> Result<Vec<AuthorizedDependency>, String> {
    if !a.sha256.is_empty() {
        checked_archive(config, db, &a.created_by, &a.id, &a.sha256)?;
    }
    engine_dependencies(config, &authorized_dependencies(config, db, a)?)
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
    let coverage = crate::coverage::collect(&config.checkpoints_root.join(&job.id), job, &report)?;
    if coverage.iter().any(|r| r.kind == "coverage-limit") {
        a.report.warnings.push("Coverage inventory reached its bound; additional native report rows were not catalogued".into());
    }
    let intent = PublicationIntent {
        archive: a,
        report,
        source: path.to_string_lossy().into_owned(),
        job_id: Some(job.id.clone()),
        final_status: status.as_str().into(),
        coverage,
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
    if matches!(
        job.runtime.operation,
        Operation::Capture | Operation::Sample { .. }
    ) {
        if let Some(parent_id) = &job.runtime.archive_id {
            let parent = db
                .archive_for_user(parent_id, &job.created_by)
                .map_err(|e| e.to_string())?
                .ok_or("previous partial version is not authorized")?;
            checked_archive(config, db, &job.created_by, &parent.id, &parent.sha256)?;
            if parent.visibility == "private" {
                a.visibility = "private".into();
            }
            a.parent_id = Some(parent.id);
            a.parent_sha256 = Some(parent.sha256);
        }
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
            let mut closure = authorized_dependencies(config, db, &parent)?;
            closure.push(parent);
            let additional = closure
                .iter()
                .filter(|dep| !authorized.iter().any(|a: &Archive| a.id == dep.id))
                .count();
            if authorized.len() + additional > 16 {
                report.warnings.push("Deduplication candidate skipped: complete authorized graph exceeds the engine's 16-archive bound; standalone captured bytes retained.".into());
                continue;
            }
            for dep in closure {
                if !authorized.iter().any(|a: &Archive| a.id == dep.id) {
                    authorized.push(dep);
                }
            }
        }
        if !authorized.is_empty() {
            let destination = path
                .parent()
                .ok_or("dedupe staging parent missing")?
                .join(format!("dedupe-{}.wacz", a.id));
            match archive_engine::deduplicate_archive(
                path,
                &destination,
                &engine_dependencies(config, &authorized)?,
            ) {
                Ok(result) => {
                    report = result;
                    actual = destination;
                }
                Err(error) if error == archive_engine::NO_MATCHING_PAYLOADS => {
                    report.warnings.push("Cross-capture deduplication found no matching payloads; original standalone capture retained with zero savings".into());
                }
                Err(error) => return Err(error),
            }
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
    if let Operation::Sample { target_pages } = job.runtime.operation {
        let estimate = stored_estimate(&report, target_pages.max(job.request.page_limit));
        let mut rt = job.runtime.clone();
        rt.estimate = Some(estimate);
        db.set_runtime(&job.id, &rt).map_err(|e| e.to_string())?;
    }
    publish(config, db, job, &actual, a, report, status)
}
pub fn page_samples(report: &ArchiveReport) -> Vec<PageSample> {
    let page_urls = report
        .pages
        .iter()
        .map(|p| p.url.as_str())
        .collect::<BTreeSet<_>>();
    report
        .pages
        .iter()
        .take(20)
        .map(|p| {
            let mut resource_digests = std::collections::BTreeMap::<String, u64>::new();
            for resource in report.resources.iter().filter(|r| {
                r.url == p.url
                    || (!page_urls.contains(r.url.as_str())
                        && (r.pages.contains(&p.url) || p.resource_urls.contains(&r.url)))
            }) {
                let key = if resource.digest.is_empty() {
                    format!("unknown-digest:{}", resource.url)
                } else {
                    resource.digest.clone()
                };
                resource_digests
                    .entry(key)
                    .and_modify(|bytes| *bytes = (*bytes).max(resource.bytes))
                    .or_insert(resource.bytes);
            }
            let own_document = report.resources.iter().any(|r| r.url == p.url);
            let bytes = resource_digests
                .values()
                .fold(0u64, |n, b| n.saturating_add(*b))
                .saturating_add(if own_document { 0 } else { p.bytes });
            PageSample {
                url: p.url.clone(),
                bytes,
                shared_bytes: 0,
                resource_digests,
                measured: bytes > 0,
            }
        })
        .collect()
}

/// Project measured stored bytes, not transfer. Dynamic requests lacking static
/// page attribution and package/baseline costs stay visible as uncertain overhead.
pub fn stored_estimate(report: &ArchiveReport, target_pages: u32) -> archive_engine::Estimate {
    let samples = page_samples(report);
    let target_pages = target_pages.max(samples.len() as u32);
    let mut estimate =
        archive_engine::estimate_size(&samples, u64::from(target_pages), target_pages, true);
    if !estimate.measured {
        return estimate;
    }
    let mut attributed = std::collections::BTreeMap::<&str, u64>::new();
    for sample in &samples {
        for (digest, bytes) in &sample.resource_digests {
            attributed
                .entry(digest)
                .and_modify(|n| *n = (*n).max(*bytes))
                .or_insert(*bytes);
        }
    }
    let known = attributed.values().fold(0u64, |n, b| n.saturating_add(*b));
    let overhead = report.archive_bytes.saturating_sub(known);
    let mut unknown = std::collections::BTreeMap::<&str, u64>::new();
    for resource in &report.resources {
        if !attributed.contains_key(resource.digest.as_str()) {
            unknown
                .entry(&resource.digest)
                .and_modify(|n| *n = (*n).max(resource.bytes))
                .or_insert(resource.bytes);
        }
    }
    let unattributed = unknown.values().fold(0u64, |n, b| n.saturating_add(*b));
    let scale = u64::from(target_pages)
        .div_ceil(estimate.sample_pages.max(1))
        .max(1);
    estimate.lower_bytes = estimate
        .lower_bytes
        .saturating_add(overhead)
        .max(report.archive_bytes);
    estimate.expected_bytes = estimate
        .expected_bytes
        .saturating_add(overhead.saturating_mul(scale))
        .max(report.archive_bytes);
    estimate.upper_bytes = estimate
        .upper_bytes
        .saturating_add(overhead.saturating_mul(scale).saturating_mul(2))
        .max(estimate.expected_bytes)
        .max(estimate.lower_bytes);
    estimate.peak_disk_bytes = estimate.upper_bytes.saturating_mul(3);
    estimate.assumptions.push(format!("Observed sample package {}B; distinct attributed resource spans {}B; measured unattributed/duplicate/ZIP/baseline overhead {}B. Each page includes its own document once plus distinct attributed assets.",report.archive_bytes,known,overhead));
    estimate.assumptions.push(format!("Overhead projection is uncertain: lower includes observed overhead once, expected scales it {scale}x by target/sample pages, upper allows twice that projection. Stored samples do not measure network transfer."));
    if !unknown.is_empty() {
        estimate.warnings.push(format!("{} distinct resource payloads ({}B) have no sampled-page attribution, including possible dynamic API/XHR and browser baselines; counted conservatively in capture overhead, not silently omitted or assumed to be fixed shared assets.",unknown.len(),unattributed));
    }
    estimate
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
            let mut a = db
                .archive_for_user(archive_id, &job.created_by)
                .map_err(|e| e.to_string())?
                .ok_or("archive not found")?;
            if !sha256.is_empty() && a.sha256 != *sha256 {
                return Err("queued verification identity differs from archive catalogue".into());
            }
            let (input, mut verification) = verify_custody(config, db, &a, &scratch);
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
                    coverage: vec![],
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
    let retain_diagnostics = if let Operation::Verify {
        archive_id, mode, ..
    } = &job.runtime.operation
    {
        mode == "browser"
            && db
                .archive_for_user(archive_id, &job.created_by)
                .map_err(|e| e.to_string())?
                .and_then(|a| a.verification)
                .is_some_and(|v| {
                    v.checks
                        .iter()
                        .any(|c| c.name == "offline-browser-replay" && c.status == "not-run")
                })
    } else {
        false
    };
    if !retain_diagnostics {
        std::fs::remove_dir_all(&scratch).map_err(|e| e.to_string())?;
    }
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
    let config_path = scratch.join("capture.json");
    let mut qa_config: Value =
        serde_json::from_slice(&std::fs::read(&config_path).map_err(|e| e.to_string())?)
            .map_err(|e| e.to_string())?;
    qa_config["qaMode"] = Value::Bool(true);
    qa_config["applyViewport"] = Value::Bool(a.request.is_some());
    qa_config["behaviors"] = serde_json::json!([]);
    std::fs::write(
        config_path,
        serde_json::to_vec(&qa_config).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;
    let source = input.canonicalize().map_err(|e| e.to_string())?;
    let mut command = std::process::Command::new(&config.podman_bin);
    command
        .args([
            "run",
            "--pull=never",
            "--rm",
            "--name",
            &format!("web-archive-qa-{}", job.id),
            "--network=none",
            "--shm-size=1g",
            "--tmpfs=/browser-state:rw,nosuid,nodev,mode=0700,size=512m",
            "--cap-add=SYS_ADMIN",
            "--security-opt=seccomp=unconfined",
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
            "120",
            "--limit",
            "100",
            "--pageLoadTimeout",
            "20",
            "--behaviorTimeout",
            "15",
            "--sizeLimit",
            "134217728",
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
        if started.elapsed() > std::time::Duration::from_secs(150) {
            stop_qa_container(config, &job.id);
            let _ = child.kill();
            let _ = child.wait();
            break None;
        }
        if log
            .metadata()
            .map(|m| m.len() > 16 * 1024 * 1024)
            .unwrap_or(false)
        {
            stop_qa_container(config, &job.id);
            let _ = child.kill();
            let _ = child.wait();
            break None;
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    };
    let bytes = std::fs::read(scratch.join("qa-observations.jsonl")).unwrap_or_default();
    if bytes.len() > 16 * 1024 * 1024 {
        return Err("QA observation report exceeded bounds".into());
    }
    let pages = String::from_utf8_lossy(&bytes)
        .lines()
        .take(101)
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .collect::<Vec<_>>();
    if pages.is_empty() {
        check(
            v,
            "offline-browser-replay",
            "not-run",
            format!(
                "Pinned QA produced no completed page observations ({}); diagnostics retained",
                status
                    .map(|s| s.to_string())
                    .unwrap_or_else(|| "timeout/log cap".into())
            ),
        );
        return Ok(());
    }
    let expected = if url.is_some() {
        1
    } else {
        a.page_count.min(100)
    };
    if url.is_none() && a.page_count > 100 {
        v.warnings.push(format!(
            "Browser QA scope bounded to100 of{}pages; remaining pages not tested",
            a.page_count
        ));
    }
    let loaded = pages.len() as u64;
    let mut gaps = Vec::new();
    let mut missing = 0usize;
    let connection = db.connect().map_err(|e| e.to_string())?;
    for page in &pages {
        for item in page["badResources"]
            .as_array()
            .into_iter()
            .flatten()
            .take(100)
        {
            let url = item["url"].as_str().unwrap_or("");
            let status = item["status"].as_i64().unwrap_or(0);
            use rusqlite::OptionalExtension;
            let original:Option<i64>=connection.query_row("SELECT json_extract(document,'$.status') FROM archive_resources WHERE archive_id=?1 AND url=?2 LIMIT 1",rusqlite::params![a.id,url],|r|r.get(0)).optional().map_err(|e|e.to_string())?;
            let same = original == Some(status);
            if !same {
                missing += 1;
            }
            if gaps.len() < 10 {
                gaps.push(serde_json::json!({"url":url,"replayStatus":status,"capturedStatus":original,"provenance":if same{"captured-error-response"}else{"replay-missing-or-changed"}}));
            }
        }
    }
    check(v,"offline-browser-replay",if loaded>=expected&&loaded>0{"pass"}else{"fail"},format!("{loaded}/{expected} pages observed; container network=none blocks live origins including service workers"));
    let comparable = pages
        .iter()
        .filter(|p| {
            p["comparison"]["resourceCounts"]
                .as_object()
                .is_some_and(|o| o.contains_key("replayGood"))
        })
        .count();
    let receipts_complete = pages.iter().all(|p| {
        p["comparison"]["resourceCounts"]["replayBad"]
            .as_u64()
            .is_some_and(|count| {
                count
                    == p["badResources"]
                        .as_array()
                        .map(|a| a.len() as u64)
                        .unwrap_or(0)
            })
    });
    check(v,"resource-fidelity",if missing>0{"fail"}else if comparable!=pages.len()||!receipts_complete{"not-run"}else{"pass"},format!("Native1.14.3 pageinfo comparison; {missing} missing/changed error responses; complete bounded error receipts={receipts_complete}; bounded examples: {}",serde_json::to_string(&gaps).map_err(|e|e.to_string())?));
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
    } else if checks.len() >= interactions.len().saturating_mul(pages.len())
        && checks.iter().all(|c| c["status"] == "pass")
    {
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

fn stop_qa_container(config: &AppConfig, job_id: &str) {
    let _ = std::process::Command::new(&config.podman_bin)
        .args([
            "kill",
            "--signal",
            "KILL",
            &format!("web-archive-qa-{job_id}"),
        ])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();
}

static ARCHIVE_READ_SLOTS: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(2);
pub async fn analyze<T: Send + 'static, F: FnOnce() -> Result<T, String> + Send + 'static>(
    function: F,
) -> Result<Result<T, String>, tokio::task::JoinError> {
    let _permit = ARCHIVE_READ_SLOTS
        .acquire()
        .await
        .expect("archive read semaphore remains open");
    tokio::task::spawn_blocking(function).await
}

fn verify_custody(
    config: &AppConfig,
    db: &Database,
    a: &Archive,
    scratch: &Path,
) -> (PathBuf, Verification) {
    let result = (|| -> Result<(PathBuf, Verification), String> {
        let mut input = source(config, a)?;
        let actual = custody::sha256(&input)?;
        let deps = authorized_dependencies(config, db, a)?;
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
        let mut v = archive_engine::verify_archive(&input)?;
        if !a.sha256.is_empty() && actual != a.sha256 {
            v.valid = false;
            check(
                &mut v,
                "catalogue-sha256",
                "fail",
                "Retained payload differs from immutable catalogue digest".into(),
            );
        }
        Ok((input, v))
    })();
    match result {
        Ok(value) => value,
        Err(error) => {
            let mut v = Verification {
                valid: false,
                checked_at: now(),
                checks: vec![VerificationCheck {
                    name: "custody-identity".into(),
                    status: "fail".into(),
                    details: error,
                }],
                warnings: vec![],
            };
            for name in [
                "offline-browser-replay",
                "screenshot-baseline",
                "interaction-assertions",
            ] {
                check(
                    &mut v,
                    name,
                    "not-run",
                    "File custody/fixity must succeed before browser QA".into(),
                );
            }
            (PathBuf::new(), v)
        }
    }
}
