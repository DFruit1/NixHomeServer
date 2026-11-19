//! Local Bonsai (llama.cpp, OpenAI-compatible) calls with schema-constrained
//! JSON output. Every answer is cross-checked against provider data by the
//! caller; nothing Bonsai says is trusted on its own.

use anyhow::{bail, Context, Result};
use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::time::Duration;

pub struct Bonsai {
    client: reqwest::blocking::Client,
    base: String,
    model: String,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MenuEntry {
    pub season: Option<u32>,
    pub episode: Option<u32>,
    pub title: String,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MenuReading {
    pub series_title: Option<String>,
    pub disc_number: Option<u32>,
    pub entries: Vec<MenuEntry>,
    pub frames_read: usize,
    /// Why a frame batch could not be read; the frames that did read were
    /// still used. Empty unless part of the menus was lost.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub warnings: Vec<String>,
}

const MENU_PROMPT: &str = "These are still frames from one DVD's menus. Transcribe only text \
that is actually visible. Report the series or programme title if shown, a disc number if \
shown, and every episode that is listed or titled on screen with its season (series) number \
and episode number as integers (convert words such as 'Series One - Episode Five' to season 1, \
episode 5) and its episode title without quotation marks. Chapter or scene names and menu \
buttons (Play All, Scene Selection, Main, Next, Subtitles) are not episodes. Use null for \
anything not shown. Do not guess or use outside knowledge.";

impl Bonsai {
    pub fn new(base: &str, model: &str, timeout: Duration) -> Result<Self> {
        Ok(Self {
            client: reqwest::blocking::Client::builder()
                .timeout(timeout)
                .build()?,
            base: base.trim_end_matches('/').to_string(),
            model: model.to_string(),
        })
    }

    /// `think` false asks the model to answer without a reasoning trace.
    /// Bonsai reasons by default, and on a short budget the trace can use
    /// every token before any answer: label splitting (400 tokens) failed
    /// this way on every disc from 2026-11-15 to 2026-11-17.
    fn chat_json(
        &self,
        content: Vec<Value>,
        schema: Value,
        max_tokens: u32,
        think: bool,
    ) -> Result<Value> {
        let mut body = json!({
            "model": self.model,
            "temperature": 0,
            "max_tokens": max_tokens,
            "response_format": {
                "type": "json_schema",
                "json_schema": {"name": "answer", "schema": schema}
            },
            "messages": [{"role": "user", "content": content}],
        });
        if !think {
            body["chat_template_kwargs"] = json!({"enable_thinking": false});
        }
        let url = format!("{}/chat/completions", self.base);
        // The local gate admits one request, queues two (429 beyond that)
        // and answers 504 when a queued request waits over a minute, which a
        // single vision request from another app can take. Those mean "busy"
        // and are retried with growing pauses (about 11 minutes of waiting
        // in all). A 502 can be the gate cutting off a slow generation, which
        // would only repeat, so it and transport errors keep the shorter
        // budget. The caller's deadline still bounds the whole run.
        const BUSY_ATTEMPTS: u64 = 8;
        const FAILURE_ATTEMPTS: u64 = 4;
        let mut attempt = 0;
        let response = loop {
            attempt += 1;
            match self.client.post(&url).json(&body).send() {
                Ok(response)
                    if matches!(response.status().as_u16(), 429 | 503 | 504)
                        && attempt < BUSY_ATTEMPTS => {}
                Ok(response) if response.status().as_u16() == 502 && attempt < FAILURE_ATTEMPTS => {
                }
                Ok(response) => break response,
                Err(error)
                    if attempt < FAILURE_ATTEMPTS && (error.is_connect() || error.is_request()) => {
                }
                Err(error) => return Err(error).with_context(|| format!("POST {url}")),
            }
            std::thread::sleep(Duration::from_secs((30 * attempt).min(120)));
        };
        let status = response.status();
        if !status.is_success() {
            bail!("Bonsai returned HTTP {status}");
        }
        let reply: Value = response.json().context("Bonsai returned invalid JSON")?;
        let choice = &reply["choices"][0];
        let text = choice["message"]["content"].as_str().unwrap_or_default();
        match parse_json_object(text) {
            Some(value) => Ok(value),
            None if choice["finish_reason"] == "length" => {
                bail!("Bonsai reply was cut off at its {max_tokens}-token limit before the answer")
            }
            None => bail!("Bonsai reply is not the requested JSON"),
        }
    }

    /// Read episode listings from menu frames, four frames per request.
    /// A batch that cannot be read is skipped and noted in `warnings`; the
    /// frames that did read still name the disc, so one failing batch no
    /// longer loses the rest. Only a total failure is an error.
    pub fn read_menu(&self, frames: &[Vec<u8>]) -> Result<MenuReading> {
        let schema = json!({
            "type": "object",
            "properties": {
                "series_title": {"type": ["string", "null"]},
                "disc_number": {"type": ["integer", "null"]},
                "episodes": {"type": "array", "items": {
                    "type": "object",
                    "properties": {
                        "season": {"type": ["integer", "null"]},
                        "episode": {"type": ["integer", "null"]},
                        "title": {"type": "string"}
                    },
                    "required": ["season", "episode", "title"]
                }}
            },
            "required": ["series_title", "disc_number", "episodes"]
        });
        let mut reading = MenuReading::default();
        for batch in frames.chunks(4) {
            let mut content = vec![json!({"type": "text", "text": MENU_PROMPT})];
            for frame in batch {
                let encoded = base64::engine::general_purpose::STANDARD.encode(frame);
                content.push(json!({
                    "type": "image_url",
                    "image_url": {"url": format!("data:image/jpeg;base64,{encoded}")}
                }));
            }
            let answer = match self.chat_json(content, schema.clone(), 1500, true) {
                Ok(answer) => answer,
                Err(error) => {
                    reading.warnings.push(format!("{error:#}"));
                    continue;
                }
            };
            reading.frames_read += batch.len();
            if reading.series_title.is_none() {
                reading.series_title = answer["series_title"]
                    .as_str()
                    .map(str::trim)
                    .filter(|title| !title.is_empty() && title.len() <= 200)
                    .map(str::to_string);
            }
            if reading.disc_number.is_none() {
                reading.disc_number = answer["disc_number"]
                    .as_u64()
                    .and_then(|n| u32::try_from(n).ok())
                    .filter(|n| (1..=99).contains(n));
            }
            for item in answer["episodes"].as_array().into_iter().flatten() {
                let title = item["title"]
                    .as_str()
                    .unwrap_or_default()
                    .trim()
                    .trim_matches(|c| c == '"' || c == '“' || c == '”' || c == '\'')
                    .trim()
                    .to_string();
                if title.is_empty() || title.len() > 200 {
                    continue;
                }
                let number = |key: &str| {
                    item[key]
                        .as_u64()
                        .and_then(|n| u32::try_from(n).ok())
                        .filter(|n| *n <= 999)
                };
                let entry = MenuEntry {
                    season: number("season"),
                    episode: number("episode"),
                    title,
                };
                let duplicate = reading.entries.iter().any(|known| {
                    crate::text::normalize(&known.title) == crate::text::normalize(&entry.title)
                });
                if !duplicate {
                    reading.entries.push(entry);
                }
            }
        }
        if reading.frames_read == 0 && !frames.is_empty() {
            bail!("{}", reading.warnings.join("; "));
        }
        Ok(reading)
    }

    /// Split a run-together DVD volume label ("ALLCREATURESGREATANDSMALL")
    /// into a readable title. The answer is only accepted when it contains
    /// exactly the label's letters and digits, so Bonsai cannot substitute a
    /// different title.
    pub fn split_label(&self, label: &str) -> Result<Option<String>> {
        let schema = json!({
            "type": "object",
            "properties": {"title": {"type": "string"}},
            "required": ["title"]
        });
        let prompt = format!(
            "A DVD volume label has its words run together: {label}\n\
Insert spaces to recover the programme title, in title case. Do not add, remove or \
change any letters or digits."
        );
        let answer = self.chat_json(
            vec![json!({"type": "text", "text": prompt})],
            schema,
            400,
            false,
        )?;
        let title = answer["title"]
            .as_str()
            .unwrap_or_default()
            .trim()
            .to_string();
        let letters = |text: &str| -> String {
            text.chars()
                .filter(|c| c.is_alphanumeric())
                .flat_map(char::to_lowercase)
                .collect()
        };
        Ok(
            (!title.is_empty() && letters(&title) == letters(label) && title.contains(' '))
                .then_some(title),
        )
    }

    /// Pick which candidate episode a transcript excerpt comes from. Returns
    /// the chosen candidate index and Bonsai's stated confidence (0..=1).
    pub fn rank_synopses(
        &self,
        transcript: &str,
        candidates: &[(String, String)],
    ) -> Result<Option<(usize, f64)>> {
        if candidates.is_empty() {
            return Ok(None);
        }
        let keys: Vec<String> = (0..candidates.len()).map(|i| format!("c{i}")).collect();
        let mut listing = String::new();
        for (key, (label, summary)) in keys.iter().zip(candidates) {
            listing.push_str(&format!("{key}: {label} — {summary}\n"));
        }
        let mut choices: Vec<Value> = keys.iter().map(|key| json!(key)).collect();
        choices.push(json!("none"));
        let schema = json!({
            "type": "object",
            "properties": {
                "episode": {"type": "string", "enum": choices},
                "confidence": {"type": "number"}
            },
            "required": ["episode", "confidence"]
        });
        let prompt = format!(
            "Below is an automatic transcript of a few minutes of dialogue from one TV episode, \
followed by candidate episodes with their published summaries. Which candidate is the transcript \
from? Rely on names, places, animals, events and situations that appear in both. Answer \"none\" \
if the transcript does not clearly fit one candidate. Give confidence between 0 and 1.\n\n\
TRANSCRIPT:\n{transcript}\n\nCANDIDATES:\n{listing}"
        );
        let answer = self.chat_json(
            vec![json!({"type": "text", "text": prompt})],
            schema,
            1200,
            true,
        )?;
        let chosen = answer["episode"].as_str().unwrap_or("none");
        let confidence = answer["confidence"].as_f64().unwrap_or(0.0).clamp(0.0, 1.0);
        Ok(keys
            .iter()
            .position(|key| key == chosen)
            .map(|index| (index, confidence)))
    }
}

/// Accept a bare object or one wrapped in prose/code fences.
fn parse_json_object(text: &str) -> Option<Value> {
    if let Ok(value) = serde_json::from_str::<Value>(text.trim()) {
        return value.is_object().then_some(value);
    }
    let start = text.find('{')?;
    let end = text.rfind('}')?;
    serde_json::from_str::<Value>(text.get(start..=end)?)
        .ok()
        .filter(Value::is_object)
}

#[cfg(test)]
mod tests {
    use super::parse_json_object;

    #[test]
    fn json_is_recovered_from_fenced_replies() {
        let value = parse_json_object("```json\n{\"episode\": \"c1\"}\n```").unwrap();
        assert_eq!(value["episode"], "c1");
        assert!(parse_json_object("no json here").is_none());
    }
}
