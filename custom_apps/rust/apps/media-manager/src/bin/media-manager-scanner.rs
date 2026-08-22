use media_manager::{
    catalog::{Catalog, CatalogHandle},
    config::AppConfig,
    scanner::{rescan_root, ScanRoot},
};
use serde_json::json;

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
    Catalog::open(&config.database_path()).map_err(|error| format!("open catalog: {error}"))?;
    let handle = CatalogHandle::new(config.database_path());

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
            category: spec.category.clone(),
        };
        match rescan_root(&handle, &root) {
            Ok(result) => {
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
