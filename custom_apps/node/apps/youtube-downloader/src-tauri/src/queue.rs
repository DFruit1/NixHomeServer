use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use rand::RngCore;
use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Manager};

use crate::auth;

const QUEUE_FILE: &str = "pending-jobs.json";
const SETTINGS_FILE: &str = "settings.json";
const SHARED_FILE: &str = "pending-share.jsonl";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PendingJob {
    pub id: String,
    pub url: String,
    pub added_at: u64,
    #[serde(default)]
    pub last_error: Option<String>,
}

#[derive(Serialize)]
pub struct FlushOutcome {
    pub sent: usize,
    pub remaining: usize,
    pub errors: Vec<String>,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct Settings {
    #[serde(default)]
    server_base_url: Option<String>,
}

fn now_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn new_id() -> String {
    let mut buffer = [0u8; 8];
    rand::thread_rng().fill_bytes(&mut buffer);
    format!("{}-{}", now_seconds(), u64::from_be_bytes(buffer))
}

fn app_data_file(app: &AppHandle, name: &str) -> Result<PathBuf, String> {
    let dir = app.path().app_data_dir().map_err(|error| error.to_string())?;
    std::fs::create_dir_all(&dir).map_err(|error| error.to_string())?;
    Ok(dir.join(name))
}

fn load_queue(app: &AppHandle) -> Vec<PendingJob> {
    app_data_file(app, QUEUE_FILE)
        .ok()
        .and_then(|path| std::fs::read_to_string(path).ok())
        .and_then(|contents| serde_json::from_str::<Vec<PendingJob>>(&contents).ok())
        .unwrap_or_default()
}

fn save_queue(app: &AppHandle, jobs: &[PendingJob]) -> Result<(), String> {
    let path = app_data_file(app, QUEUE_FILE)?;
    let serialised = serde_json::to_string_pretty(jobs).map_err(|error| error.to_string())?;
    std::fs::write(path, serialised).map_err(|error| error.to_string())
}

fn load_settings(app: &AppHandle) -> Settings {
    app_data_file(app, SETTINGS_FILE)
        .ok()
        .and_then(|path| std::fs::read_to_string(path).ok())
        .and_then(|contents| serde_json::from_str::<Settings>(&contents).ok())
        .unwrap_or_default()
}

pub fn server_base_url(app: &AppHandle) -> Option<String> {
    load_settings(app)
        .server_base_url
        .map(|url| url.trim_end_matches('/').to_string())
        .filter(|url| !url.is_empty())
}

fn enqueue_url(app: &AppHandle, url: &str) -> Result<(), String> {
    let mut jobs = load_queue(app);
    if jobs.iter().any(|job| job.url == url) {
        return Ok(());
    }
    jobs.push(PendingJob {
        id: new_id(),
        url: url.to_string(),
        added_at: now_seconds(),
        last_error: None,
    });
    save_queue(app, &jobs)
}

/// URLs shared into the app on Android are dropped into a plain-text file by
/// MainActivity before the UI starts; fold them into the queue and clear it.
/// The file may live either beside the app data root or in its `files`
/// subdirectory depending on the platform path mapping.
pub fn sync_shared_files(app: &AppHandle) {
    let mut candidates = Vec::new();
    if let Ok(path) = app_data_file(app, SHARED_FILE) {
        if let Some(parent) = path.parent() {
            candidates.push(parent.join("files").join(SHARED_FILE));
        }
        candidates.push(path);
    }
    for candidate in candidates {
        let contents = match std::fs::read_to_string(&candidate) {
            Ok(contents) => contents,
            Err(_) => continue,
        };
        for line in contents.lines() {
            let url = line.trim();
            if !url.is_empty() {
                let _ = enqueue_url(app, url);
            }
        }
        let _ = std::fs::remove_file(&candidate);
    }
}

fn default_request(url: &str) -> serde_json::Value {
    serde_json::json!({
        "url": url,
        "destination": "personal",
        "mediaType": "audio",
        "audioFormat": "flac",
        "audioQuality": "best",
        "splitChapters": true,
        "embedAudioCoverArt": true,
        "includeChannel": true,
        "includeDate": true,
        "ytDlpVersion": "packaged",
    })
}

#[tauri::command]
pub fn queue_list(app: AppHandle) -> Vec<PendingJob> {
    sync_shared_files(&app);
    load_queue(&app)
}

#[tauri::command]
pub fn queue_add(app: AppHandle, url: String) -> Result<(), String> {
    enqueue_url(&app, url.trim())
}

#[tauri::command]
pub fn queue_remove(app: AppHandle, id: String) -> Result<(), String> {
    let jobs: Vec<PendingJob> = load_queue(&app)
        .into_iter()
        .filter(|job| job.id != id)
        .collect();
    save_queue(&app, &jobs)
}

#[tauri::command]
pub fn set_server_base_url(app: AppHandle, url: String) -> Result<(), String> {
    let mut settings = load_settings(&app);
    let trimmed = url.trim().trim_end_matches('/').to_string();
    settings.server_base_url = if trimmed.is_empty() { None } else { Some(trimmed) };
    let path = app_data_file(&app, SETTINGS_FILE)?;
    let serialised = serde_json::to_string_pretty(&settings).map_err(|error| error.to_string())?;
    std::fs::write(path, serialised).map_err(|error| error.to_string())
}

fn mark_all_errors(app: &AppHandle, message: &str) -> Vec<PendingJob> {
    let mut jobs = load_queue(app);
    for job in &mut jobs {
        job.last_error = Some(message.to_string());
    }
    let _ = save_queue(app, &jobs);
    jobs
}

#[tauri::command]
pub async fn queue_flush(app: AppHandle) -> Result<FlushOutcome, String> {
    sync_shared_files(&app);
    let base_url = match server_base_url(&app) {
        Some(base_url) => base_url,
        None => {
            let message = "No server is configured yet.";
            let jobs = mark_all_errors(&app, message);
            return Ok(FlushOutcome {
                sent: 0,
                remaining: jobs.len(),
                errors: vec![message.into()],
            });
        }
    };
    let token = match auth::authorization_token(&app).await {
        Ok(Some(token)) => token,
        Ok(None) => {
            let message = "Sign in to send the queue.";
            let jobs = mark_all_errors(&app, message);
            return Ok(FlushOutcome {
                sent: 0,
                remaining: jobs.len(),
                errors: vec![message.into()],
            });
        }
        Err(error) => {
            let jobs = mark_all_errors(&app, &error);
            return Ok(FlushOutcome {
                sent: 0,
                remaining: jobs.len(),
                errors: vec![error],
            });
        }
    };
    let client = reqwest::Client::builder()
        .build()
        .map_err(|error| error.to_string())?;

    let mut sent = 0usize;
    let mut errors = Vec::new();
    let mut remaining = Vec::new();
    for mut job in load_queue(&app) {
        let request = client
            .post(format!("{base_url}/api/jobs"))
            // The server's CSRF guard requires a same-origin Origin header on
            // mutations, which a browser sends automatically.
            .header(reqwest::header::ORIGIN, &base_url)
            .bearer_auth(&token)
            .json(&default_request(&job.url));
        match request.send().await {
            Ok(response) if response.status().is_success() => {
                sent += 1;
            }
            Ok(response) => {
                let status = response.status();
                job.last_error = Some(format!("server returned {status}"));
                errors.push(format!("{} ({status})", job.url));
                remaining.push(job);
            }
            Err(error) => {
                job.last_error = Some(error.to_string());
                errors.push(format!("{} ({error})", job.url));
                remaining.push(job);
            }
        }
    }
    save_queue(&app, &remaining)?;
    Ok(FlushOutcome {
        sent,
        remaining: remaining.len(),
        errors,
    })
}
