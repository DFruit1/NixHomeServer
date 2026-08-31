use browsertrix_downloader::{
    config::AppConfig,
    database::Database,
    http::{router, AppState},
    queue::{JobQueue, Resolver},
};
use serde_json::json;

#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        eprintln!(
            "{}",
            json!({
                "level": "error",
                "service": "browsertrix-downloader",
                "event": "startup_failed",
                "error": error,
            })
        );
        std::process::exit(1);
    }
}

async fn run() -> Result<(), String> {
    let config = AppConfig::from_env()?;
    tokio::fs::create_dir_all(&config.state_dir)
        .await
        .map_err(|error| format!("create state directory: {error}"))?;
    let database = Database::open(&config.database_path)
        .map_err(|error| format!("initialize queue database: {error}"))?;
    database
        .prune_events(config.event_retention_days)
        .map_err(|error| format!("prune retained events: {error}"))?;

    let state = AppState {
        config: config.clone(),
        database: database.clone(),
        queue: JobQueue::new(database.clone(), Resolver::system()),
    };
    let address = std::net::SocketAddr::new(config.address, config.port);
    let listener = tokio::net::TcpListener::bind(address)
        .await
        .map_err(|error| format!("bind {address}: {error}"))?;
    eprintln!(
        "{}",
        json!({
            "level": "info",
            "service": "browsertrix-downloader",
            "event": "server_started",
            "address": address.to_string(),
        })
    );

    let prune_database = database;
    let retention_days = config.event_retention_days;
    let prune_task = tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(24 * 60 * 60));
        interval.tick().await;
        loop {
            interval.tick().await;
            if let Err(error) = prune_database.prune_events(retention_days) {
                eprintln!(
                    "{}",
                    json!({
                        "level": "error",
                        "service": "browsertrix-downloader",
                        "event": "event_retention_failed",
                        "error": error.to_string(),
                    })
                );
            }
        }
    });
    let result = axum::serve(listener, router(state))
        .with_graceful_shutdown(shutdown_signal())
        .await
        .map_err(|error| format!("serve requests: {error}"));
    prune_task.abort();
    result
}

async fn shutdown_signal() {
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
