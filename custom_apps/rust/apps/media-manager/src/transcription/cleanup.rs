//! Optional Bonsai proofreading of a finished transcript.
//!
//! Bonsai reads the transcript in numbered lines and may only answer with
//! short `{line, from, to}` corrections. Nothing else in its reply is used, so
//! it cannot rephrase, summarise or drop passages: every correction must name
//! words that occur exactly once in its line. Only the words that actually
//! change are judged: they may not shrink (no deletions, so no censoring of
//! swearing or filler) or grow by more than two words, numbers never change,
//! and a word the recogniser was sure of changes only into a name or term the
//! job supplied. A section
//! where Bonsai proposes changing more than a small share of the words is left
//! untouched. Word timings are kept, so subtitles stay in
//! sync, and every applied correction is recorded in the job's `meta.json`.
use super::Word;
use serde::Deserialize;
use serde_json::{json, Value};
use std::{ops::Range, time::Duration};

/// About seven minutes of speech per request. With 4,000-word sections Bonsai
/// proposed corrections only for the first few minutes of each, so shorter
/// sections are read in full; each request takes seconds of prompt time.
const WINDOW_WORDS: usize = 1000;
/// Rewrite-heavy replies outgrew 2,048 tokens; complete edits are salvaged
/// from a reply that still runs out.
const MAX_REPLY_TOKENS: u32 = 3072;
/// Words a correction quotes, including unchanged neighbours for context.
const MAX_FROM_WORDS: usize = 8;
/// Words that actually change, before and after.
const MAX_CHANGED_WORDS: usize = 3;
const MAX_ADDED_WORDS: usize = 2;
/// Letter similarity for merging words, such as "t shirt" into "t-shirt".
const MERGE_SIMILARITY: f64 = 0.8;
const MAX_REJECTIONS_REPORTED: usize = 200;
/// Letter similarity a correction needs unless the recogniser was unsure.
const MIN_SIMILARITY: f64 = 0.4;
/// On a 90-minute recording, Bonsai's sound corrections replaced words the
/// recogniser scored 0.31-0.46 ("Esther" Lauder, "stain" kidney, the
/// "Louge"), while its meaning changes replaced words scored 0.74-1.0 ("an
/// older woman" made younger, "northernmost" made southernmost, "£12,000"
/// made £1,200). Only an unsure word is open to a sound-alike correction.
const UNSURE_CONFIDENCE: f64 = 0.5;
/// Below this every changed word is garbled, and the replacement need not
/// share its letters: "Is Handy got a knife?" (0.31, 0.29) for "Has anyone".
/// Between the two, letter-unrelated guesses were wrong ("udders" for
/// "jockeys", "postcard" for "pocket watch").
const GARBLED_CONFIDENCE: f64 = 0.35;
/// Swearing is part of what was said; a correction may not remove it, even as
/// a sound-alike ("fuck, bo, bo!" proposed as "go, boy, boy!").
const SWEARING: [&str; 9] = [
    "fuck", "shit", "cunt", "bastard", "bollock", "wank", "piss", "arse", "bugger",
];
/// A section with more proposed change than this is not trusted at all.
const MAX_CHANGED_SHARE: f64 = 0.15;
const BUSY_RETRIES: u32 = 30;
const BUSY_DELAY: Duration = Duration::from_secs(20);

const PROMPT: &str = "You proofread automatic speech-recognition transcripts. \
Correct only clear recognition errors: misheard or garbled words that make no sense where they are, \
misspelt names (use the recording title and listed names), and unusual words written as \
similar-sounding common ones. A correction replaces wrong words with the words that were said; \
it never removes words. Every spoken word stays, including swearing, repetitions, false starts \
and filler such as \"you know\". If a word is wrong but you cannot tell what was said, leave it \
as it is rather than deleting it. Keep everything else exactly as spoken: do not rephrase, reorder, \
summarise, censor, translate or tidy grammar, dialect or slang. \
Do not replace real words that make sense where they are, even if you expect different ones, \
and keep numbers as heard. If you are not sure, leave it. Each correction replaces a short exact phrase from one numbered line. \
Reply with JSON only: {\"edits\":[{\"line\":<number>,\"from\":\"<exact words from that line>\",\"to\":\"<corrected words>\"}]}, \
or {\"edits\":[]} when nothing needs correcting.";

pub struct Cleaner {
    url: reqwest::Url,
    model: String,
    client: reqwest::Client,
}

/// What the recording is, for names and terms the recogniser cannot know.
pub struct Context<'a> {
    pub title: &'a str,
    pub vocabulary: &'a [String],
}

#[derive(Deserialize)]
struct Edit {
    line: usize,
    from: String,
    to: String,
}

enum AskError {
    Busy,
    Failed(&'static str),
}

impl Cleaner {
    /// `TRANSCRIBE_CLEANUP_URL` is the loopback Bonsai gate, for example
    /// `http://127.0.0.1:8094/v1`. Unset means proofreading is unavailable.
    pub fn from_env() -> Result<Option<Self>, String> {
        let Ok(base) = std::env::var("TRANSCRIBE_CLEANUP_URL") else {
            return Ok(None);
        };
        let model = std::env::var("TRANSCRIBE_CLEANUP_MODEL").unwrap_or_default();
        let base = reqwest::Url::parse(base.trim_end_matches('/'))
            .map_err(|_| "invalid TRANSCRIBE_CLEANUP_URL")?;
        let loopback = base
            .host_str()
            .map(|host| host.trim_start_matches('[').trim_end_matches(']'))
            .and_then(|host| host.parse::<std::net::IpAddr>().ok())
            .is_some_and(|ip| ip.is_loopback());
        if base.scheme() != "http" || !loopback || model.is_empty() {
            return Err("TRANSCRIBE_CLEANUP_URL must be loopback http with a model named".into());
        }
        Ok(Some(Self {
            url: reqwest::Url::parse(&format!("{base}/chat/completions"))
                .map_err(|_| "invalid TRANSCRIBE_CLEANUP_URL")?,
            model,
            client: reqwest::Client::builder()
                .no_proxy()
                .redirect(reqwest::redirect::Policy::none())
                // The gate queues for up to a minute, then allows ten upstream.
                .timeout(Duration::from_secs(690))
                .build()
                .map_err(|_| "could not initialize the Bonsai client")?,
        }))
    }

    /// Proofreads `words` in place and returns the report kept in meta.json.
    /// Failure leaves the affected section as transcribed; it never fails the
    /// transcription job.
    pub async fn clean(&self, words: &mut Vec<Word>, context: &Context<'_>) -> Value {
        let lines = lines(words);
        // Names the job supplied; a confidently recognised word may become one.
        let known: std::collections::HashSet<String> = std::iter::once(context.title)
            .chain(context.vocabulary.iter().map(String::as_str))
            .flat_map(str::split_whitespace)
            .map(key)
            .filter(|k| k.chars().count() >= 4)
            .collect();
        let mut applied: Vec<(Range<usize>, Vec<String>)> = Vec::new();
        let mut report_edits = Vec::new();
        let mut rejected = 0usize;
        let mut rejections = Vec::new();
        let mut failed = Vec::new();
        let mut names: Vec<String> = Vec::new();
        let windows = windows(&lines);
        for window in &windows {
            let prompt = user_prompt(words, &lines, window.clone(), context, &names);
            let edits = match self.ask(&prompt).await {
                Ok(edits) => edits,
                Err(code) => {
                    failed.push(code);
                    continue;
                }
            };
            let mut accepted: Vec<(Range<usize>, Vec<String>)> = Vec::new();
            for edit in edits {
                match accept(words, &lines, window.clone(), &edit, &accepted, &known) {
                    Ok(change) => accepted.push(change),
                    Err(reason) => {
                        rejected += 1;
                        if rejections.len() < MAX_REJECTIONS_REPORTED {
                            rejections.push(json!({"line": edit.line, "from": edit.from, "to": edit.to, "reason": reason}));
                        }
                    }
                }
            }
            let window_words = lines[window.start].start..lines[window.end - 1].end;
            let changed: usize = accepted.iter().map(|(span, _)| span.len()).sum();
            if changed as f64 > window_words.len() as f64 * MAX_CHANGED_SHARE {
                rejected += accepted.len();
                failed.push("too_many_changes");
                continue;
            }
            for (span, replacement) in accepted {
                let from = join(&words[span.clone()]);
                let to = replacement.join(" ");
                // Later sections are told how names were settled earlier.
                if to.chars().next().is_some_and(char::is_uppercase) && names.len() < 64 {
                    names.push(to.clone());
                }
                report_edits
                    .push(json!({"atMs": words[span.start].start_ms, "from": from, "to": to}));
                applied.push((span, replacement));
            }
        }
        apply(words, applied);
        let status = if failed.len() == windows.len() && !windows.is_empty() {
            "failed"
        } else if report_edits.is_empty() {
            "unchanged"
        } else {
            "applied"
        };
        json!({
            "status": status,
            "model": self.model,
            "sections": windows.len(),
            "failedSections": failed,
            "applied": report_edits.len(),
            "rejected": rejected,
            "edits": report_edits,
            "rejections": rejections,
        })
    }

    async fn ask(&self, prompt: &str) -> Result<Vec<Edit>, &'static str> {
        for _ in 0..BUSY_RETRIES {
            match self.ask_once(prompt).await {
                Err(AskError::Busy) => tokio::time::sleep(BUSY_DELAY).await,
                Err(AskError::Failed(code)) => return Err(code),
                Ok(edits) => return Ok(edits),
            }
        }
        Err("bonsai_busy")
    }

    async fn ask_once(&self, prompt: &str) -> Result<Vec<Edit>, AskError> {
        let schema = json!({"type":"object","properties":{"edits":{"type":"array","items":{
            "type":"object","properties":{
                "line":{"type":"integer"},
                "from":{"type":"string","maxLength":120},
                "to":{"type":"string","maxLength":160}},
            "required":["line","from","to"]}}},"required":["edits"]});
        let body = json!({
            "model": self.model,
            "temperature": 0,
            "max_tokens": MAX_REPLY_TOKENS,
            // Reasoning would spend the time budget before the first edit.
            "chat_template_kwargs": {"enable_thinking": false},
            "response_format": {"type":"json_schema","json_schema":{"name":"transcript_edits","schema":schema}},
            "messages": [
                {"role":"system","content":PROMPT},
                {"role":"user","content":prompt}
            ],
        });
        let response = self
            .client
            .post(self.url.clone())
            .json(&body)
            .send()
            .await
            .map_err(|err| {
                if err.is_timeout() {
                    AskError::Failed("bonsai_timeout")
                } else {
                    AskError::Busy
                }
            })?;
        match response.status().as_u16() {
            429 | 503 | 504 => return Err(AskError::Busy),
            status if !(200..300).contains(&status) => {
                return Err(AskError::Failed("bonsai_error"))
            }
            _ => {}
        }
        let reply: Value = response
            .json()
            .await
            .map_err(|_| AskError::Failed("bonsai_reply_invalid"))?;
        let text = reply["choices"][0]["message"]["content"]
            .as_str()
            .unwrap_or_default();
        let text = text
            .find('{')
            .zip(text.rfind('}'))
            .and_then(|(start, end)| text.get(start..=end))
            .unwrap_or_default();
        #[derive(Deserialize)]
        struct Answer {
            edits: Vec<Edit>,
        }
        if let Ok(answer) = serde_json::from_str::<Answer>(text) {
            return Ok(answer.edits);
        }
        // A reply cut off at the token limit still holds complete edits.
        salvage(text).ok_or(AskError::Failed("bonsai_reply_invalid"))
    }
}

/// The complete edits at the start of a truncated `{"edits":[...` reply.
fn salvage(text: &str) -> Option<Vec<Edit>> {
    #[derive(Deserialize)]
    struct Answer {
        edits: Vec<Edit>,
    }
    text.match_indices('}')
        .map(|(i, _)| i)
        .rev()
        .take(400)
        .find_map(|end| serde_json::from_str::<Answer>(&format!("{}]}}", &text[..=end])).ok())
        .map(|answer| answer.edits)
}

/// Word ranges of roughly one sentence each, so Bonsai can point at a line.
fn lines(words: &[Word]) -> Vec<Range<usize>> {
    let mut lines = Vec::new();
    let mut start = 0;
    for (i, word) in words.iter().enumerate() {
        let length = i + 1 - start;
        if (word.text.ends_with(['.', '?', '!']) && length >= 8) || length >= 30 {
            lines.push(start..i + 1);
            start = i + 1;
        }
    }
    if start < words.len() {
        lines.push(start..words.len());
    }
    lines
}

/// Consecutive line ranges of at most `WINDOW_WORDS` words.
fn windows(lines: &[Range<usize>]) -> Vec<Range<usize>> {
    let mut windows = Vec::new();
    let mut start = 0;
    let mut count = 0;
    for (i, line) in lines.iter().enumerate() {
        if count > 0 && count + line.len() > WINDOW_WORDS {
            windows.push(start..i);
            start = i;
            count = 0;
        }
        count += line.len();
    }
    if start < lines.len() {
        windows.push(start..lines.len());
    }
    windows
}

fn join(words: &[Word]) -> String {
    words
        .iter()
        .map(|w| w.text.as_str())
        .collect::<Vec<_>>()
        .join(" ")
}

fn user_prompt(
    words: &[Word],
    lines: &[Range<usize>],
    window: Range<usize>,
    context: &Context<'_>,
    names: &[String],
) -> String {
    let mut prompt = format!("Recording: {}\n", context.title);
    let mut known: Vec<&str> = context.vocabulary.iter().map(String::as_str).collect();
    known.extend(names.iter().map(String::as_str));
    if !known.is_empty() {
        prompt.push_str(&format!("Names and terms: {}\n", known.join(", ")));
    }
    prompt.push_str("\nTranscript:\n");
    for n in window {
        prompt.push_str(&format!("{}| {}\n", n + 1, join(&words[lines[n].clone()])));
    }
    prompt
}

/// Letters and digits only, lower case: how a word is compared.
fn key(token: &str) -> String {
    token
        .chars()
        .filter(|c| c.is_alphanumeric() || *c == '\'')
        .flat_map(char::to_lowercase)
        .collect()
}

fn similarity(a: &str, b: &str) -> f64 {
    let (a, b): (Vec<char>, Vec<char>) = (a.chars().collect(), b.chars().collect());
    let longest = a.len().max(b.len());
    if longest == 0 {
        return 1.0;
    }
    let mut previous: Vec<usize> = (0..=b.len()).collect();
    for (i, ca) in a.iter().enumerate() {
        let mut current = vec![i + 1];
        for (j, cb) in b.iter().enumerate() {
            let substitute = previous[j] + usize::from(ca != cb);
            current.push(substitute.min(previous[j + 1] + 1).min(current[j] + 1));
        }
        previous = current;
    }
    1.0 - previous[b.len()] as f64 / longest as f64
}

/// The word span and replacement words for one acceptable correction, or
/// why it was refused.
fn accept(
    words: &[Word],
    lines: &[Range<usize>],
    window: Range<usize>,
    edit: &Edit,
    taken: &[(Range<usize>, Vec<String>)],
    known: &std::collections::HashSet<String>,
) -> Result<(Range<usize>, Vec<String>), &'static str> {
    let index = edit.line.checked_sub(1).ok_or("no such line")?;
    let line = lines.get(index).ok_or("no such line")?;
    if !window.contains(&index) {
        return Err("outside this section");
    }
    let from: Vec<String> = edit.from.split_whitespace().map(key).collect();
    let mut to: Vec<String> = edit.to.split_whitespace().map(str::to_string).collect();
    if from.is_empty() || from.len() > MAX_FROM_WORDS || from.iter().any(String::is_empty) {
        return Err("quote too long or empty");
    }
    let line_keys: Vec<String> = words[line.clone()].iter().map(|w| key(&w.text)).collect();
    let mut found = (0..line_keys.len().saturating_sub(from.len() - 1))
        .filter(|&i| line_keys[i..i + from.len()] == from[..]);
    let start = line.start + found.next().ok_or("quote not in the line")?;
    if found.next().is_some() {
        return Err("quote occurs more than once");
    }
    // Judge only the words that change, not the context quoted around them.
    let to_keys: Vec<String> = to.iter().map(|t| key(t)).collect();
    let prefix = from
        .iter()
        .zip(&to_keys)
        .take_while(|(a, b)| a == b)
        .count();
    let suffix = from[prefix..]
        .iter()
        .rev()
        .zip(to_keys[prefix..].iter().rev())
        .take_while(|(a, b)| a == b)
        .count();
    let old = &from[prefix..from.len() - suffix];
    let new = &to_keys[prefix..to_keys.len() - suffix];
    if old.is_empty() && new.is_empty() {
        return Err("no change");
    }
    let (old_letters, new_letters) = (old.concat(), new.concat());
    let merge = new.len() < old.len()
        && !new.is_empty()
        && similarity(&old_letters, &new_letters) >= MERGE_SIMILARITY;
    if old.is_empty() || new.is_empty() || (new.len() < old.len() && !merge) {
        return Err("removes or only adds words");
    }
    if old.len() > MAX_CHANGED_WORDS || new.len() > old.len() + MAX_ADDED_WORDS {
        return Err("changes too much");
    }
    let changed = start + prefix..start + from.len() - suffix;
    let span = start..start + from.len();
    if taken
        .iter()
        .any(|(other, _)| other.start < span.end && span.start < other.end)
    {
        return Err("overlaps another correction");
    }
    let digits = |s: &str| s.chars().filter(char::is_ascii_digit).collect::<String>();
    if digits(&old_letters) != digits(&new_letters) {
        return Err("changes a number");
    }
    let swears = |keys: &[String]| {
        keys.iter()
            .filter(|k| SWEARING.iter().any(|s| k.starts_with(s)))
            .count()
    };
    if swears(new) < swears(old) {
        return Err("removes swearing");
    }
    let unsure = |w: &Word| w.confidence.is_some_and(|p| p < UNSURE_CONFIDENCE);
    let similar = similarity(&old_letters, &new_letters) >= MIN_SIMILARITY;
    let doubted = words[changed.clone()].iter().any(unsure);
    let garbled = words[changed]
        .iter()
        .all(|w| w.confidence.is_some_and(|p| p < GARBLED_CONFIDENCE));
    let named = similar && new.iter().all(|k| known.contains(k) || old.contains(k));
    if !(merge || named || (doubted && (similar || garbled))) {
        return Err("the recognised words were not in doubt");
    }
    // Keep the sentence punctuation the recogniser placed after the phrase.
    let last = &words[span.end - 1].text;
    let trailing: String = last
        .chars()
        .rev()
        .take_while(|c| !c.is_alphanumeric())
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect();
    if let Some(end) = to.last_mut()
        && !end.ends_with(|c: char| !c.is_alphanumeric())
    {
        end.push_str(&trailing);
    }
    Ok((span, to))
}

/// Replaces each span with its words, sharing the span's time among them by
/// length so the subtitles stay in step with the audio.
fn apply(words: &mut Vec<Word>, mut changes: Vec<(Range<usize>, Vec<String>)>) {
    changes.sort_by_key(|(span, _)| std::cmp::Reverse(span.start));
    for (span, replacement) in changes {
        let start = words[span.start].start_ms;
        let end = words[span.end - 1].end_ms.max(start + 1);
        let weights: Vec<u64> = replacement
            .iter()
            .map(|t| t.chars().count() as u64 + 1)
            .collect();
        let total: u64 = weights.iter().sum();
        let mut at = start;
        let mut spent = 0;
        let new: Vec<Word> = replacement
            .into_iter()
            .zip(weights)
            .map(|(text, weight)| {
                spent += weight;
                let until = start + (end - start) * spent / total;
                let word = Word {
                    start_ms: at,
                    end_ms: until.max(at + 1),
                    text,
                    confidence: None,
                };
                at = until;
                word
            })
            .collect();
        words.splice(span, new);
    }
}

#[cfg(test)]
mod tests {
    use super::{accept, apply, lines, salvage, Edit, Word};
    use std::collections::HashSet;

    fn words(text: &str, confidence: f64) -> Vec<Word> {
        text.split_whitespace()
            .enumerate()
            .map(|(i, t)| Word {
                start_ms: i as u64 * 100,
                end_ms: i as u64 * 100 + 90,
                text: t.into(),
                confidence: Some(confidence),
            })
            .collect()
    }
    fn edit(from: &str, to: &str) -> Edit {
        Edit {
            line: 1,
            from: from.into(),
            to: to.into(),
        }
    }

    #[test]
    fn accepts_close_corrections_and_keeps_punctuation_and_timing() {
        let mut ws = words("Oh Billy Conley, you're so funny.", 0.9);
        let lines = lines(&ws);
        let known: HashSet<String> = ["billy".into(), "connolly".into()].into();
        let fix = edit("Billy Conley", "Billy Connolly");
        assert!(accept(&ws, &lines, 0..1, &fix, &[], &HashSet::new()).is_err());
        let change = accept(&ws, &lines, 0..1, &fix, &[], &known).unwrap();
        assert_eq!(change.1, vec!["Billy", "Connolly,"]);
        apply(&mut ws, vec![change]);
        let text: Vec<_> = ws.iter().map(|w| w.text.as_str()).collect();
        assert_eq!(text, ["Oh", "Billy", "Connolly,", "you're", "so", "funny."]);
        assert_eq!((ws[1].start_ms, ws[2].end_ms), (100, 290));
    }

    #[test]
    fn refuses_deletion_rewrites_and_unknown_or_ambiguous_phrases() {
        let ws = words("and the the dog sat on the mat with the cat today.", 0.9);
        let lines = lines(&ws);
        let refuse = |e: Edit| accept(&ws, &lines, 0..1, &e, &[], &HashSet::new()).is_err();
        assert!(refuse(edit("dog", "")), "deletion");
        assert!(
            refuse(edit("dog sat", "parliament adjourned")),
            "dissimilar rewrite"
        );
        assert!(refuse(edit("the", "a")), "ambiguous: several matches");
        assert!(refuse(edit("horse", "cow")), "not in the line");
        assert!(
            refuse(edit("mat", "mat and then went home to bed")),
            "too long"
        );
        assert!(
            refuse(Edit {
                line: 2,
                from: "dog".into(),
                to: "dog".into()
            }),
            "no such line"
        );
        // Seen from Bonsai: context words must not carry a deletion or rewrite.
        assert!(
            refuse(edit("the the dog sat", "the dog sat")),
            "drops a repetition"
        );
        assert!(
            refuse(edit("sat on the mat with", "sat on the rug with")),
            "rewrite hidden in context"
        );
    }

    #[test]
    fn keeps_swearing_and_merges_only_near_identical_words() {
        let ws = words("you fucking genius in a t shirt today.", 0.9);
        let lines = lines(&ws);
        let check = |e: Edit| accept(&ws, &lines, 0..1, &e, &[], &HashSet::new()).is_ok();
        assert!(!check(edit("you fucking genius", "you genius")));
        assert!(check(edit("a t shirt", "a t-shirt")));
        let doubtful = words("oh there you fuck, bo, bo!", 0.2);
        let e = edit("fuck, bo, bo!", "go, boy, boy!");
        assert!(accept(
            &doubtful,
            &super::lines(&doubtful),
            0..1,
            &e,
            &[],
            &HashSet::new()
        )
        .is_err());
    }

    #[test]
    fn allows_dissimilar_fixes_only_where_the_recogniser_was_unsure() {
        let none = HashSet::new();
        let sure = words("was he an Egypt no", 0.9);
        let unsure = words("was he an Egypt no", 0.3);
        let doubtful = words("was he an Egypt no", 0.45);
        assert!(accept(
            &doubtful,
            &lines(&doubtful),
            0..1,
            &edit("Egypt", "idiot"),
            &[],
            &HashSet::new()
        )
        .is_err());
        let e = edit("Egypt", "idiot");
        assert!(accept(&sure, &lines(&sure), 0..1, &e, &[], &none).is_err());
        assert!(accept(&unsure, &lines(&unsure), 0..1, &e, &[], &none).is_ok());
        // Meaning changes Bonsai proposed for confidently recognised words.
        let heard = words("an older woman paid 12,000 to go northernmost", 0.99);
        let refuse = |e: Edit| accept(&heard, &lines(&heard), 0..1, &e, &[], &none).is_err();
        assert!(refuse(edit("an older", "a younger")));
        assert!(refuse(edit("northernmost", "southernmost")));
        let doubtful = words("an older woman paid 12,000 to go", 0.2);
        let e = edit("12,000", "1,200");
        assert!(accept(&doubtful, &lines(&doubtful), 0..1, &e, &[], &none).is_err());
    }

    #[test]
    fn salvages_complete_edits_from_a_truncated_reply() {
        let cut = r#"{"edits":[{"line":1,"from":"a","to":"b"},{"line":2,"from":"c","to""#;
        let edits = salvage(cut).unwrap();
        assert_eq!((edits.len(), edits[0].line), (1, 1));
    }
}
