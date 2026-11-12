mod adapters;
pub mod fs;
pub mod worker;
use crate::subtitle_format::SubtitleCue;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Backend {
    Parakeet,
    Whisper,
}
impl Backend {
    pub fn name(self) -> &'static str {
        match self {
            Self::Parakeet => "parakeet",
            Self::Whisper => "whisper",
        }
    }
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "parakeet" => Some(Self::Parakeet),
            "whisper" => Some(Self::Whisper),
            _ => None,
        }
    }
}
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Output {
    #[serde(default = "default_formats")]
    pub formats: Vec<String>,
    pub language: Option<String>,
    #[serde(default)]
    pub diarize: bool,
    #[serde(flatten)]
    pub unknown: std::collections::BTreeMap<String, Value>,
}
fn default_formats() -> Vec<String> {
    vec!["txt".into()]
}
impl Default for Output {
    fn default() -> Self {
        Self {
            formats: default_formats(),
            language: None,
            diarize: false,
            unknown: Default::default(),
        }
    }
}
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct Hints {
    pub language: Option<String>,
    pub prompt: Option<String>,
    #[serde(default)]
    pub vocabulary: Vec<String>,
    #[serde(flatten)]
    pub unknown: std::collections::BTreeMap<String, Value>,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Request {
    pub version: u32,
    #[serde(default)]
    pub source: Value,
    #[serde(default)]
    pub output: Output,
    #[serde(default)]
    pub transcription: Hints,
    #[serde(default)]
    pub force: bool,
    #[serde(flatten)]
    pub unknown: std::collections::BTreeMap<String, Value>,
}
impl Default for Request {
    fn default() -> Self {
        Self {
            version: 1,
            source: Value::Null,
            output: Output {
                formats: default_formats(),
                ..Output::default()
            },
            transcription: Hints::default(),
            force: false,
            unknown: Default::default(),
        }
    }
}
impl Request {
    pub fn parse(bytes: &[u8]) -> Result<Self, String> {
        if bytes.len() > 65536 {
            return Err("request_invalid: JSON exceeds 64 KiB".into());
        }
        let request: Self = serde_json::from_slice(bytes)
            .map_err(|_| "request_invalid: malformed request".to_string())?;
        if request.version != 1
            || request.output.formats.is_empty()
            || request.output.formats.len() > 3
            || request
                .output
                .formats
                .iter()
                .any(|f| !matches!(f.as_str(), "txt" | "srt" | "vtt"))
        {
            return Err("request_invalid: version or formats are unsupported".into());
        }
        for language in [&request.output.language, &request.transcription.language]
            .into_iter()
            .flatten()
        {
            if language.len() > 16
                || language.is_empty()
                || !language
                    .bytes()
                    .all(|b| b.is_ascii_alphabetic() || b == b'-')
            {
                return Err("request_invalid: invalid language".into());
            }
        }
        if request
            .transcription
            .prompt
            .as_ref()
            .is_some_and(|p| p.len() > 4096 || p.contains('\0'))
            || request.transcription.vocabulary.len() > 128
            || request
                .transcription
                .vocabulary
                .iter()
                .any(|v| v.len() > 128 || v.contains('\0'))
        {
            return Err("request_invalid: prompt or vocabulary exceeds limits".into());
        }
        Ok(request)
    }
    pub fn ignored(&self, backend: Backend) -> Vec<Value> {
        let mut fields = Vec::new();
        for key in self.unknown.keys() {
            fields.push(json!({"field": key, "reason": "unknown key"}));
        }
        for (prefix, keys) in [
            ("output", &self.output.unknown),
            ("transcription", &self.transcription.unknown),
        ] {
            for key in keys.keys() {
                fields.push(json!({"field": format!("{prefix}.{key}"), "reason": "unknown key"}));
            }
        }
        if backend == Backend::Parakeet {
            for (key, present) in [
                ("language", self.transcription.language.is_some()),
                ("prompt", self.transcription.prompt.is_some()),
                ("vocabulary", !self.transcription.vocabulary.is_empty()),
            ] {
                if present {
                    fields.push(json!({"field": format!("transcription.{key}"), "reason": "parakeet-cli does not accept this hint"}));
                }
            }
        }
        fields
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Word {
    pub start_ms: u64,
    pub end_ms: u64,
    pub text: String,
    pub confidence: Option<f64>,
}
#[derive(Clone, Debug)]
pub struct Turn {
    pub start_ms: u64,
    pub end_ms: u64,
    pub speaker: String,
}
pub fn build_cues(words: &[Word], turns: &[Turn]) -> Vec<SubtitleCue> {
    let mut cues: Vec<SubtitleCue> = Vec::new();
    let mut text = String::new();
    let mut start = 0;
    let mut end = 0;
    let mut speaker = String::new();
    for word in words.iter().filter(|w| !w.text.trim().is_empty()) {
        let next_speaker = turns
            .iter()
            .max_by_key(|t| {
                t.end_ms
                    .min(word.end_ms)
                    .saturating_sub(t.start_ms.max(word.start_ms))
            })
            .filter(|t| t.end_ms > word.start_ms && t.start_ms < word.end_ms)
            .map(|t| t.speaker.as_str())
            .unwrap_or("");
        if !text.is_empty()
            && (word.start_ms.saturating_sub(end) > 700
                || word.end_ms.saturating_sub(start) > 6000
                || text.chars().count() + word.text.chars().count() > 84
                || speaker != next_speaker)
        {
            cues.push(SubtitleCue {
                index: cues.len() as u64 + 1,
                start_ms: start,
                end_ms: end.max(start + 1),
                text: if speaker.is_empty() {
                    text.clone()
                } else {
                    format!("{speaker}: {text}")
                },
            });
            text.clear();
        }
        if text.is_empty() {
            start = word.start_ms;
            speaker = next_speaker.into();
        }
        if !text.is_empty() && !word.text.starts_with(['.', ',', '!', '?', ':', ';']) {
            text.push(' ');
        }
        text.push_str(word.text.trim());
        end = word.end_ms;
        if text.ends_with(['.', '!', '?']) {
            cues.push(SubtitleCue {
                index: cues.len() as u64 + 1,
                start_ms: start,
                end_ms: end.max(start + 1),
                text: if speaker.is_empty() {
                    text.clone()
                } else {
                    format!("{speaker}: {text}")
                },
            });
            text.clear();
        }
    }
    if !text.is_empty() {
        cues.push(SubtitleCue {
            index: cues.len() as u64 + 1,
            start_ms: start,
            end_ms: end.max(start + 1),
            text: if speaker.is_empty() {
                text
            } else {
                format!("{speaker}: {text}")
            },
        });
    }
    cues
}
pub fn valid_job_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 180
        && !name.starts_with(['-', '.', '_'])
        && !name.contains(['/', '\\', '\0'])
        && !name.chars().any(char::is_control)
}
pub fn media_stem(name: &str) -> Option<&str> {
    let (stem, extension) = name.rsplit_once('.')?;
    (valid_job_name(name)
        && matches!(
            extension.to_ascii_lowercase().as_str(),
            "wav"
                | "mp3"
                | "flac"
                | "ogg"
                | "m4a"
                | "aac"
                | "opus"
                | "mp4"
                | "mkv"
                | "webm"
                | "mov"
                | "m4b"
                | "m4v"
                | "avi"
                | "mpeg"
                | "mpg"
                | "ts"
                | "wma"
                | "aiff"
                | "aif"
        ))
    .then_some(stem)
}
