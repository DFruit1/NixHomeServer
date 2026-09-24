use media_manager::{
    catalog::{Catalog, CatalogHandle},
    config::AppConfig,
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
    log(
        "info",
        "scan_complete",
        json!({ "rootsScanned": roots_scanned }),
    );
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
