//! Privilege separation: the broker resolves identities but never parses Office
//! data. A fresh exec opens files only after dropping to the proven caller.
use crate::{
    office_identity,
    office_io::{self, Operation, Request},
};
use serde_json::{json, Value};
use std::{env, path::PathBuf, sync::Arc};

pub(crate) async fn serve() -> Result<(), Box<dyn std::error::Error>> {
    let listener =
        crate::gateway_socket::inherited()?.ok_or("Office broker requires socket activation")?;
    let base = env::var("AI_TOOLS_DIRECTORY_URL")?;
    let humans: Vec<String> = serde_json::from_str(&env::var("AI_TOOLS_OFFICE_HUMANS")?)?;
    if humans.is_empty() {
        return Err("Office broker requires approved human identities".into());
    }
    let shared = PathBuf::from(env::var("AI_TOOLS_SHARED_ROOT")?);
    let workspace = PathBuf::from(env::var("AI_TOOLS_WORKSPACE_ROOT")?);
    if !shared.is_absolute() || workspace.parent() != Some(shared.as_path()) {
        return Err("Office workspace must be directly beneath the shared root".into());
    }
    let semaphore = Arc::new(tokio::sync::Semaphore::new(1));
    loop {
        let (mut stream, _) = listener.accept().await?;
        let Ok(permit) = Arc::clone(&semaphore).try_acquire_owned() else {
            continue;
        };
        let (base, humans, shared, workspace) = (
            base.clone(),
            humans.clone(),
            shared.clone(),
            workspace.clone(),
        );
        tokio::spawn(async move {
            let _permit = permit;
            let result = tokio::time::timeout(std::time::Duration::from_secs(80), async {
                let request: Request =
                    serde_json::from_slice(&office_io::receive(&mut stream).await?)
                        .map_err(|_| "Invalid Office request")?;
                let principal =
                    office_identity::resolve(&base, &humans, &request.subject, &request.username)
                        .await?;
                let payload =
                    serde_json::to_vec(&request.operation).map_err(|_| "Invalid Office request")?;
                let mut command = tokio::process::Command::new(
                    env::current_exe().map_err(|_| "Office worker unavailable")?,
                );
                command
                    .env_clear()
                    .env("AI_TOOLS_TRANSPORT", "office-worker")
                    .env("AI_TOOLS_WORKER_UID", principal.uid.to_string())
                    .env("AI_TOOLS_WORKER_GID", principal.gid.to_string())
                    .env(
                        "AI_TOOLS_WORKER_GROUPS",
                        serde_json::to_string(&principal.groups)
                            .map_err(|_| "Invalid Office identity")?,
                    )
                    .env("AI_TOOLS_SHARED_ROOT", shared)
                    .env("AI_TOOLS_WORKSPACE_ROOT", workspace);
                // SAFETY: this closure calls only syscalls with preallocated data.
                unsafe {
                    command.pre_exec(move || office_io::drop_credentials(&principal));
                }
                let output =
                    crate::office_process::run(command, payload, office_io::MAX_FRAME).await?;
                serde_json::from_slice::<Value>(&output)
                    .map_err(|_| "Invalid Office worker response".to_string())
            })
            .await
            .unwrap_or_else(|_| {
                Err("Office access timed out; inspect the workspace before retrying a save".into())
            });
            let response = match result {
                Ok(value) => json!({"result":value}),
                Err(error) => json!({"error":error}),
            };
            if let Ok(bytes) = serde_json::to_vec(&response) {
                let _ = tokio::time::timeout(
                    std::time::Duration::from_secs(5),
                    office_io::send(&mut stream, &bytes),
                )
                .await;
            }
        });
    }
}

pub(crate) fn worker() -> Result<(), String> {
    use std::io::{Read, Write};
    office_io::verify_worker()?;
    // Close every inherited listener/reactor FD before any document is opened.
    if unsafe { libc::syscall(libc::SYS_close_range, 3u32, u32::MAX, 0u32) } != 0 {
        return Err("Office worker descriptor isolation is unavailable".into());
    }
    let mut bytes = Vec::new();
    std::io::stdin()
        .take(office_io::MAX_FRAME as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "Invalid Office request")?;
    if bytes.len() > office_io::MAX_FRAME {
        return Err("Office request exceeds its limit".into());
    }
    let operation: Operation =
        serde_json::from_slice(&bytes).map_err(|_| "Invalid Office request")?;
    let result = office_io::perform(
        operation,
        &PathBuf::from(env::var("AI_TOOLS_SHARED_ROOT").map_err(|_| "Unconfigured Office worker")?),
        &PathBuf::from(
            env::var("AI_TOOLS_WORKSPACE_ROOT").map_err(|_| "Unconfigured Office worker")?,
        ),
    )?;
    let bytes = serde_json::to_vec(&result).map_err(|_| "Invalid Office result")?;
    std::io::stdout()
        .write_all(&bytes)
        .map_err(|_| "Office result unavailable".to_string())
}
