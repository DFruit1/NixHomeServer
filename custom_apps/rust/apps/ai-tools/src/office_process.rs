//! Bounded, concurrent pipe I/O. Timeout covers input, output and process exit.
use tokio::io::{AsyncReadExt, AsyncWriteExt};

pub(crate) async fn run(
    mut command: tokio::process::Command,
    payload: Vec<u8>,
    limit: usize,
) -> Result<Vec<u8>, String> {
    command
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    let mut child = command
        .spawn()
        .map_err(|_| "Office subprocess could not start")?;
    let mut stdin = child
        .stdin
        .take()
        .ok_or("Office subprocess input unavailable")?;
    let stdout = child
        .stdout
        .take()
        .ok_or("Office subprocess output unavailable")?;
    let stderr = child
        .stderr
        .take()
        .ok_or("Office subprocess errors unavailable")?;
    let work = async {
        let input = async {
            stdin
                .write_all(&payload)
                .await
                .map_err(|_| "Office subprocess rejected input")?;
            stdin
                .shutdown()
                .await
                .map_err(|_| "Office subprocess rejected input")
        };
        let output = async {
            let mut bytes = Vec::new();
            stdout
                .take(limit as u64 + 1)
                .read_to_end(&mut bytes)
                .await
                .map_err(|_| "Office subprocess output unavailable")?;
            if bytes.len() > limit {
                return Err("Office subprocess output exceeds its limit");
            }
            Ok(bytes)
        };
        let errors = async {
            let mut bytes = Vec::new();
            stderr
                .take(4097)
                .read_to_end(&mut bytes)
                .await
                .map_err(|_| "Office subprocess errors unavailable")?;
            if bytes.len() > 4096 {
                return Err("Office subprocess failed");
            }
            Ok(bytes)
        };
        let exit = async { child.wait().await.map_err(|_| "Office subprocess failed") };
        let (_, output, errors, status) = tokio::try_join!(input, output, errors, exit)?;
        if !status.success() {
            let reason = serde_json::from_slice::<serde_json::Value>(&errors)
                .ok()
                .and_then(|v| v.get("error").and_then(|s| s.as_str()).map(str::to_owned));
            return Err(
                reason.unwrap_or_else(|| "Office subprocess failed its safety checks".into())
            );
        }
        Ok(output)
    };
    tokio::time::timeout(std::time::Duration::from_secs(60), work)
        .await
        .map_err(|_| {
            "Office operation timed out; inspect the workspace before retrying a save".to_string()
        })?
}
