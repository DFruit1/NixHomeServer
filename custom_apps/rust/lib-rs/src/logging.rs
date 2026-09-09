use serde_json::{json, Value};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

static REQUEST_SEQUENCE: AtomicU64 = AtomicU64::new(1);

pub fn request_id() -> String {
    let micros = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_micros();
    let sequence = REQUEST_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    format!("r{micros:x}-{sequence:x}")
}

pub fn log_event(level: &str, service: &str, event: &str, fields: Value) {
    let mut value = json!({
        "level": level,
        "service": service,
        "event": event,
    });
    if let Value::Object(entries) = fields {
        if let Some(target) = value.as_object_mut() {
            for (key, field) in entries {
                target.insert(key, field);
            }
        }
    }
    eprintln!("{value}");
}
