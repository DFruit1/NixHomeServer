use std::time::Duration;

/// Retries an idempotent async operation on failure with exponential backoff.
///
/// One transient Solr/network hiccup must not abort a multi-hour extraction
/// pass, so the HTTP-facing operations wrap their request in this helper.
/// Callers must only use it for idempotent work (adds/deletes/commits are:
/// re-sending the same document id overwrites rather than duplicates).
pub async fn with_retry<F, Fut, T>(label: &str, attempts: u32, op: F) -> Result<T, String>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = Result<T, String>>,
{
    with_retry_delay(label, attempts, Duration::from_millis(500), op).await
}

pub(crate) async fn with_retry_delay<F, Fut, T>(
    label: &str,
    attempts: u32,
    initial_delay: Duration,
    mut op: F,
) -> Result<T, String>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = Result<T, String>>,
{
    let attempts = attempts.max(1);
    let mut delay = initial_delay;
    let mut attempt = 1;
    loop {
        match op().await {
            Ok(value) => return Ok(value),
            Err(err) => {
                if attempt >= attempts {
                    return Err(err);
                }
                eprintln!(
                    "search: {label} failed (attempt {attempt}/{attempts}): {err}; retrying in {delay:?}"
                );
                if !delay.is_zero() {
                    tokio::time::sleep(delay).await;
                }
                delay = (delay * 2).min(Duration::from_secs(30));
                attempt += 1;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    #[test]
    fn retries_until_success() {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .build()
            .expect("runtime");
        let calls = Cell::new(0);
        let result = runtime.block_on(with_retry_delay("test", 3, Duration::ZERO, || {
            calls.set(calls.get() + 1);
            let attempt = calls.get();
            async move {
                if attempt < 3 {
                    Err(format!("transient {attempt}"))
                } else {
                    Ok("ok")
                }
            }
        }));
        assert_eq!(result, Ok("ok"));
        assert_eq!(calls.get(), 3);
    }

    #[test]
    fn returns_last_error_after_exhausting_attempts() {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .build()
            .expect("runtime");
        let calls = Cell::new(0u32);
        let result: Result<(), String> =
            runtime.block_on(with_retry_delay("test", 2, Duration::ZERO, || {
                calls.set(calls.get() + 1);
                async move { Err::<(), String>("still failing".to_string()) }
            }));
        assert_eq!(result, Err("still failing".to_string()));
        assert_eq!(calls.get(), 2);
    }
}
