use serde_json::json;

pub fn log_server_started(service: &str, address: &str) {
    eprintln!(
        "{}",
        json!({
            "level": "info",
            "service": service,
            "event": "server_started",
            "address": address,
        })
    );
}

pub fn log_startup_failed(service: &str, error: &str) {
    eprintln!(
        "{}",
        json!({
            "level": "error",
            "service": service,
            "event": "startup_failed",
            "error": error,
        })
    );
}

pub async fn shutdown_signal() {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };
    #[cfg(unix)]
    let terminate = async {
        if let Ok(mut signal) =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        {
            signal.recv().await;
        }
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();
    tokio::select! {
        () = ctrl_c => {},
        () = terminate => {},
    }
}
