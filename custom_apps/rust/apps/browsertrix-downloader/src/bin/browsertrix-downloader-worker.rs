use browsertrix_downloader::{config::AppConfig, worker};
use serde_json::json;

#[tokio::main]
async fn main() {
    let result = match AppConfig::from_env() {
        Ok(config) => worker::run(config).await,
        Err(error) => Err(error),
    };
    if let Err(error) = result {
        eprintln!(
            "{}",
            json!({
                "level": "error",
                "service": "browsertrix-downloader-worker",
                "event": "worker_failed",
                "error": error,
            })
        );
        std::process::exit(1);
    }
}
