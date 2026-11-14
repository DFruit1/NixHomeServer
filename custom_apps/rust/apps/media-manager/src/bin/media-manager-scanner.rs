use media_manager::{
    catalog::{Catalog, CatalogHandle},
    config::AppConfig,
    index_hints::drain_hint_directory,
    scanner::{scan_root_if_due, ScanRoot},
};
use serde_json::json;
use std::time::{SystemTime, UNIX_EPOCH};

fn main() {
    if let Err(error) = run() {
        log("error", "scan_run_failed", json!({ "error": error }));
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let config = AppConfig::from_env()?;
    std::fs::create_dir_all(&config.state_dir)
        .map_err(|error| format!("create state directory: {error}"))?;
    Catalog::initialize(&config.database_path())
        .map_err(|error| format!("open catalog: {error}"))?;
    let handle = CatalogHandle::new(config.database_path());
    match std::env::args().nth(1).as_deref() {
        None => {}
        Some("index-hints") => return run_index_hints(&config, &handle),
        Some(other) => return Err(format!("unknown mode: {other}")),
    }
    let now = unix_timestamp();

    let mut roots_scanned = 0usize;
    let mut roots_failed = 0usize;
    for spec in config.all_scan_specs() {
        if !spec.path.is_dir() {
            continue;
        }
        let root = ScanRoot {
            id: spec.id.clone(),
            owner_username: spec.owner_username.clone(),
            path: spec.path.clone(),
            category: spec.category,
        };
        // Only roots whose adaptive schedule is due are walked, so idle
        // libraries back off toward the 24-hour ceiling without extra I/O.
        match scan_root_if_due(&handle, &root, now) {
            Ok(Some(result)) => {
                roots_scanned += 1;
                log(
                    "info",
                    "root_scanned",
                    json!({
                        "rootId": spec.id,
                        "ownerUsername": spec.owner_username,
                        "result": result,
                    }),
                );
            }
            Ok(None) => {}
            Err(error) => {
                roots_failed += 1;
                log(
                    "error",
                    "root_scan_failed",
                    json!({
                        "rootId": spec.id,
                        "ownerUsername": spec.owner_username,
                        "error": error,
                    }),
                );
            }
        }
    }

    if roots_failed > 0 {
        return Err(format!("{roots_failed} root scans failed"));
    }
    // Bound the insert-only audit trail once per scan run.
    if let Ok(catalog) = Catalog::open(&config.database_path())
        && let Ok(pruned) = catalog.prune_audit_events(90)
        && pruned > 0
    {
        log("info", "audit_events_pruned", json!({ "pruned": pruned }));
    }
    log(
        "info",
        "scan_complete",
        json!({ "rootsScanned": roots_scanned }),
    );
    Ok(())
}

/// Indexes only the files producers announced in the hint directory, so new
/// downloads appear without a full library walk.
fn run_index_hints(config: &AppConfig, handle: &CatalogHandle) -> Result<(), String> {
    let hint_dir = std::env::var_os("MEDIA_MANAGER_INDEX_HINT_DIR")
        .map(std::path::PathBuf::from)
        .ok_or_else(|| "MEDIA_MANAGER_INDEX_HINT_DIR is not set".to_string())?;
    let run = drain_hint_directory(config, handle, &hint_dir)?;
    let mut roots_failed = 0usize;
    for outcome in &run.roots {
        match &outcome.result {
            Ok(result) => log(
                "info",
                "hinted_paths_indexed",
                json!({
                    "rootId": outcome.root_id,
                    "ownerUsername": outcome.owner_username,
                    "result": result,
                }),
            ),
            Err(error) => {
                roots_failed += 1;
                log(
                    "error",
                    "hinted_paths_index_failed",
                    json!({
                        "rootId": outcome.root_id,
                        "ownerUsername": outcome.owner_username,
                        "error": error,
                    }),
                );
            }
        }
    }
    log(
        if run.hints_invalid > 0 || run.paths_unmatched > 0 {
            "warn"
        } else {
            "info"
        },
        "index_hints_complete",
        json!({
            "hintsRead": run.hints_read,
            "hintsInvalid": run.hints_invalid,
            "pathsUnmatched": run.paths_unmatched,
            "rootsIndexed": run.roots.len() - roots_failed,
        }),
    );
    if roots_failed > 0 {
        return Err(format!("{roots_failed} hinted root updates failed"));
    }
    Ok(())
}

fn unix_timestamp() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs().min(i64::MAX as u64) as i64)
        .unwrap_or(0)
}

fn log(level: &str, event: &str, detail: serde_json::Value) {
    eprintln!(
        "{}",
        json!({
            "level": level,
            "service": "media-manager-scanner",
            "event": event,
            "detail": detail,
        })
    );
}
