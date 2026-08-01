use media_manager::{
    broker::{apply_broker_action, discard_staged_broker_action, recover_broker_action},
    catalog::Catalog,
    config::AppConfig,
};
use serde_json::json;
use std::{
    fs::OpenOptions,
    os::{fd::AsRawFd, unix::fs::OpenOptionsExt},
};

fn main() {
    if let Err(error) = run() {
        log("error", "broker_failed", json!({ "error": error }));
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let config = AppConfig::from_env()?;
    std::fs::create_dir_all(&config.state_dir)
        .map_err(|error| format!("create state directory: {error}"))?;
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .mode(0o660)
        .open(config.state_dir.join("broker.lock"))
        .map_err(|error| format!("open broker lock: {error}"))?;
    let locked = unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if locked != 0 {
        return Err("another mutation broker process holds the global queue lock".to_string());
    }

    let mut catalog = Catalog::open(&config.database_path())
        .map_err(|error| format!("open control database: {error}"))?;
    if let Some(expired) = catalog
        .claim_expired_preview_action(unix_timestamp())
        .map_err(|error| format!("claim expired preview cleanup: {error}"))?
    {
        discard_staged_broker_action(&config, &expired.action)
            .map_err(|error| format!("clean expired preview staging: {error}"))?;
        catalog
            .complete_expired_preview_action(&expired.plan_id, expired.ordinal)
            .map_err(|error| format!("record expired preview cleanup: {error}"))?;
        log(
            "info",
            "expired_preview_cleaned",
            json!({ "planId": expired.plan_id, "ordinal": expired.ordinal }),
        );
    }
    let Some(plan) = catalog
        .claim_or_resume_mutation_plan()
        .map_err(|error| format!("claim mutation plan: {error}"))?
    else {
        log("info", "broker_queue_idle", json!({}));
        return Ok(());
    };
    log(
        "info",
        "mutation_plan_started",
        json!({ "planId": plan.id, "actionCount": plan.actions.len() }),
    );
    for claimed in &plan.actions {
        let already_applied = recover_broker_action(&config, &plan.owner_username, &claimed.action)
            .map_err(|error| format!("verify action recovery state: {error}"))?;
        let result = if already_applied {
            Ok(())
        } else {
            apply_broker_action(&config, &plan.owner_username, &claimed.action)
                .map_err(|error| error.to_string())
        };
        if let Err(error) = result {
            catalog
                .finish_mutation_plan(&plan.id, Some(&error))
                .map_err(|db_error| format!("record failed plan after {error}: {db_error}"))?;
            catalog
                .insert_audit_event(
                    &format!("broker-{}", plan.id),
                    &plan.owner_username,
                    "mutation_plan_failed",
                    Some(&plan.id),
                    &json!({ "ordinal": claimed.ordinal, "error": error }).to_string(),
                )
                .map_err(|db_error| format!("write failure audit event: {db_error}"))?;
            return Err(format!(
                "plan {} action {} failed: {error}",
                plan.id, claimed.ordinal
            ));
        }
        catalog
            .complete_mutation_action(&plan.id, claimed.ordinal)
            .map_err(|error| format!("record completed action: {error}"))?;
        log(
            "info",
            "mutation_action_completed",
            json!({
                "planId": plan.id,
                "ordinal": claimed.ordinal,
                "recovered": already_applied,
            }),
        );
    }
    catalog
        .finish_mutation_plan(&plan.id, None)
        .map_err(|error| format!("complete mutation plan: {error}"))?;
    catalog
        .insert_audit_event(
            &format!("broker-{}", plan.id),
            &plan.owner_username,
            "mutation_plan_completed",
            Some(&plan.id),
            &json!({ "actionCount": plan.actions.len() }).to_string(),
        )
        .map_err(|error| format!("write completion audit event: {error}"))?;
    log(
        "info",
        "mutation_plan_completed",
        json!({ "planId": plan.id, "actionCount": plan.actions.len() }),
    );
    Ok(())
}

fn unix_timestamp() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs().min(i64::MAX as u64) as i64)
        .unwrap_or(0)
}

fn log(level: &str, event: &str, detail: serde_json::Value) {
    eprintln!(
        "{}",
        json!({
            "level": level,
            "service": "media-manager-broker",
            "event": event,
            "detail": detail,
        })
    );
}
