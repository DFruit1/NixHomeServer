use media_manager::transcription::worker::Worker;

#[tokio::main]
async fn main() {
    let result = async {
        let worker = Worker::from_env()?;
        if std::env::args().any(|s| s == "--provision") {
            worker.provision()
        } else {
            worker.run().await
        }
    }
    .await;
    if let Err(error) = result {
        // Input contents and decoder output are deliberately excluded.
        eprintln!(
            "{}",
            serde_json::json!({"service": "transcribe", "event": "worker_failed", "error": error})
        );
        std::process::exit(1);
    }
}
