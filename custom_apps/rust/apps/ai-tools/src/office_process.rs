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
        let input = async move {
            stdin
                .write_all(&payload)
                .await
                .map_err(|_| "Office subprocess rejected input")?;
            stdin
                .shutdown()
                .await
                .map_err(|_| "Office subprocess rejected input")?;
            // Pipe shutdown does not close ChildStdin. The helper's json.load
            // reads through EOF, so close the descriptor before awaiting output.
            drop(stdin);
            Ok(())
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

#[cfg(test)]
mod tests {
    // Both Python json.load and the file worker read through EOF. The real
    // MCP startup trial reproduced a deadlock in both paths without this close.
    #[tokio::test]
    async fn delivers_stdin_eof_before_awaiting_output() {
        let output = tokio::time::timeout(
            std::time::Duration::from_secs(2),
            super::run(
                tokio::process::Command::new("cat"),
                b"bounded fixture".to_vec(),
                1024,
            ),
        )
        .await
        .expect("child must receive EOF before the operation timeout")
        .unwrap();
        assert_eq!(output, b"bounded fixture");
    }
}
