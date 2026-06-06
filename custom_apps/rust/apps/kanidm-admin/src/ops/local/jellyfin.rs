use super::*;
use zeroize::Zeroizing;

pub fn stage_jellyfin_password(
    account_id: &str,
    password_env: &str,
) -> Result<CommandOutput, AppError> {
    let account_id = validate_account_id(account_id)?;

    let password = Zeroizing::new(env::var(password_env).map_err(|_| AppError::Config {
        message: format!("environment variable '{password_env}' is required"),
    })?);
    if password.is_empty() {
        return Err(AppError::Config {
            message: format!("environment variable '{password_env}' must not be empty"),
        });
    }

    let directory = env::var_os(PASSWORD_HASH_DIR_ENV)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(DEFAULT_PASSWORD_HASH_DIR));
    let path = directory.join(format!("{account_id}.pbkdf2"));

    write_password_hash_atomic(&directory, &path, &hash_password(password.as_str()))?;

    Ok(CommandOutput {
        message: format!("staged desired Jellyfin password hash for '{account_id}'"),
        human: format!(
            "Staged the desired Jellyfin password hash for '{account_id}'.\nPath: {}\nSource env var: {password_env}\nThe Jellyfin reconcile service still needs to apply this staged hash.",
            path.display()
        ),
        details: json!({
            "account_id": account_id,
            "path": path,
            "password_env": password_env,
            "staged": true,
            "runtime": jellyfin_password_runtime_report(None, &account_id),
        }),
        warnings: vec![
            "The Jellyfin reconcile timer or service must still converge before the password change is active.".to_string(),
        ],
    })
}

pub fn diagnose_jellyfin_password(
    cli: &KanidmCli,
    account_id: &str,
) -> Result<CommandOutput, AppError> {
    let account_id = validate_account_id(account_id)?;
    let runtime = jellyfin_password_runtime_report(Some(cli), &account_id);
    Ok(jellyfin_password_output(&account_id, runtime, "diagnosed"))
}

pub fn reconcile_jellyfin_password(
    cli: &KanidmCli,
    account_id: &str,
) -> Result<CommandOutput, AppError> {
    let account_id = validate_account_id(account_id)?;
    let start = run_root_action(
        cli,
        "local jellyfin password reconcile",
        RootAction::StartSystemdUnit {
            unit: JELLYFIN_RECONCILE_SERVICE.to_string(),
        },
        None,
        Duration::from_secs(20),
    );
    let mut runtime = jellyfin_password_runtime_report(Some(cli), &account_id);
    runtime.checks.insert(
        0,
        RuntimeCheckReport {
            id: "jellyfin.password_reconcile.started".to_string(),
            label: "Jellyfin password reconcile service was started".to_string(),
            required: true,
            status: if start
                .result
                .allowed_success(&std::collections::BTreeSet::from([0]))
            {
                CheckStatus::Passed
            } else {
                runtime.ready = false;
                CheckStatus::Failed
            },
            command: start
                .backend_payload
                .get("args")
                .and_then(serde_json::Value::as_array)
                .map(|args| {
                    format!(
                        "sudo {}",
                        args.iter()
                            .filter_map(serde_json::Value::as_str)
                            .collect::<Vec<_>>()
                            .join(" ")
                    )
                }),
            summary: start.result.detail(),
            detail: None,
            probe: Some(start.backend_payload),
        },
    );
    runtime.ready = runtime.required_checks_passed();
    runtime.refresh_derived();
    if !runtime.ready {
        return Err(AppError::Verification {
            message: format!("Jellyfin password runtime did not converge for '{account_id}'"),
            details: json!({
                "failure_kind": "local_runtime_not_ready",
                "account_id": account_id,
                "runtime": runtime,
            }),
        });
    }
    Ok(jellyfin_password_output(&account_id, runtime, "reconciled"))
}

pub fn test_jellyfin_password(
    cli: &KanidmCli,
    account_id: &str,
) -> Result<CommandOutput, AppError> {
    diagnose_jellyfin_password(cli, account_id)
}
