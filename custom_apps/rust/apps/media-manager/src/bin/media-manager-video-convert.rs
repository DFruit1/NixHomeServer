//! Converts queued library videos one at a time, then exits when idle.
use media_manager::{config::AppConfig, video_conversion_worker};
use serde_json::json;

fn main() {
    let result = AppConfig::from_env().and_then(|config| video_conversion_worker::run(&config));
    if let Err(error) = result {
        video_conversion_worker::log("error", "video_convert_failed", json!({ "error": error }));
        std::process::exit(1);
    }
}
