//! Bounded search views for the model, separate from upstream response limits.
//! Keep identifiers and URLs intact; explicitly mark every omitted text field.
use serde_json::{json, Value};

pub(super) const MAX_BYTES: usize = 24 * 1024;

pub(super) fn bounded(mut payload: Value, key: &str) -> Result<Value, String> {
    let entries = payload[key]
        .as_array_mut()
        .map(std::mem::take)
        .ok_or("Search returned an unexpected result list")?;
    let count = entries.len();
    let mut kept = Vec::new();
    for mut entry in entries {
        let mut truncated_fields = Vec::new();
        for (field, maximum) in [("title", 512), ("snippet", 2000)] {
            if let Some(text) = entry[field].as_str()
                && text.len() > maximum
            {
                let mut end = maximum;
                while !text.is_char_boundary(end) {
                    end -= 1;
                }
                entry[field] = json!(&text[..end]);
                truncated_fields.push(field);
            }
        }
        if let Some(metadata) = entry.get("metadata")
            && metadata.to_string().len() > 2048
        {
            entry.as_object_mut().unwrap().remove("metadata");
            truncated_fields.push("metadata");
        }
        if !truncated_fields.is_empty() {
            entry["truncated_fields"] = json!(truncated_fields);
            payload["content_truncated"] = json!(true);
        }
        kept.push(entry);
        payload[key] = json!(kept);
        // Reserve room for the final counters/warning without cutting JSON.
        if payload.to_string().len() > MAX_BYTES - 1024 {
            kept.pop();
            break;
        }
    }
    let omitted = count - kept.len();
    payload["returned"] = json!(kept.len());
    payload[key] = json!(kept);
    if omitted > 0 {
        payload["limited"] = json!(true);
        payload["truncated"] = json!(true);
        payload["omitted_results"] = json!(omitted);
        let warning = json!({"message":"The model view reached its byte limit. Request fewer max_results and restart at page 0, or narrow the query; omitted results are not a complete page."});
        match payload.get_mut("warnings").and_then(Value::as_array_mut) {
            Some(warnings) => warnings.push(warning),
            None => payload["warnings"] = json!([warning]),
        }
    }
    if (payload["returned"] == 0 && count > 0) || payload.to_string().len() > MAX_BYTES {
        return Err(
            "Search metadata exceeds the model view limit; narrow the query or open the source app"
                .into(),
        );
    }
    Ok(payload)
}
