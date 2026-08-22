use serde::Serialize;

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SubtitleCue {
    pub index: u64,
    pub start_ms: u64,
    pub end_ms: u64,
    pub text: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SubtitleValidationIssue {
    pub kind: String,
    pub cue_index: u64,
    pub message: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SubtitleValidation {
    pub cue_count: usize,
    pub issues: Vec<SubtitleValidationIssue>,
}

pub fn parse_subtitle(format: &str, text: &str) -> Result<Vec<SubtitleCue>, String> {
    match format.to_ascii_lowercase().as_str() {
        "srt" | "vtt" => parse_srt(text),
        "ass" | "ssa" => parse_ass(text),
        _ => Err("unsupported subtitle format".to_string()),
    }
}

pub fn subtitle_validation(cues: &[SubtitleCue]) -> SubtitleValidation {
    let mut issues = Vec::new();
    let mut previous_end = None;
    for cue in cues {
        if cue.end_ms <= cue.start_ms {
            issues.push(SubtitleValidationIssue {
                kind: "invalid-duration".to_string(),
                cue_index: cue.index,
                message: "The cue ends before it starts.".to_string(),
            });
        } else {
            let duration_seconds = (cue.end_ms - cue.start_ms) as f64 / 1000.0;
            let characters = cue
                .text
                .chars()
                .filter(|character| !character.is_whitespace())
                .count();
            if characters as f64 / duration_seconds > 25.0 {
                issues.push(SubtitleValidationIssue {
                    kind: "reading-speed".to_string(),
                    cue_index: cue.index,
                    message: "The cue exceeds 25 characters per second.".to_string(),
                });
            }
        }
        if previous_end.is_some_and(|end| cue.start_ms < end) {
            issues.push(SubtitleValidationIssue {
                kind: "overlap".to_string(),
                cue_index: cue.index,
                message: "The cue overlaps the preceding cue.".to_string(),
            });
        }
        previous_end = Some(cue.end_ms);
    }
    SubtitleValidation {
        cue_count: cues.len(),
        issues,
    }
}

pub fn parse_srt(text: &str) -> Result<Vec<SubtitleCue>, String> {
    let text = text.trim_start_matches('\u{feff}');
    if text.is_empty() {
        return Err("subtitle text is empty".to_string());
    }
    let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
    if !normalized.contains("-->") {
        return Err("no subtitle timing markers found".to_string());
    }
    let mut cues = Vec::new();
    let mut next_index = 0_u64;
    for block in normalized.split("\n\n") {
        let block = block.trim();
        if block.is_empty() {
            continue;
        }
        let lines = block.lines().collect::<Vec<_>>();
        let Some(timing_position) = lines.iter().position(|line| line.contains("-->")) else {
            continue;
        };
        if let Some(index) = lines
            .get(timing_position.saturating_sub(1))
            .and_then(|line| line.trim().parse::<u64>().ok())
        {
            next_index = index;
        } else {
            next_index += 1;
        }
        let (start_ms, end_ms) = parse_timing(lines[timing_position])
            .ok_or_else(|| "invalid subtitle timing".to_string())?;
        let text = lines[timing_position + 1..].join("\n").trim().to_string();
        cues.push(SubtitleCue {
            index: next_index,
            start_ms,
            end_ms,
            text,
        });
    }
    if cues.is_empty() {
        return Err("no parseable subtitle cues".to_string());
    }
    Ok(cues)
}

fn parse_timing(line: &str) -> Option<(u64, u64)> {
    let arrow = line.find("-->")?;
    let start = line[..arrow].split_whitespace().next()?;
    let end = line[arrow + 3..].split_whitespace().next()?;
    Some((parse_time(start)?, parse_time(end)?))
}

fn parse_ass(text: &str) -> Result<Vec<SubtitleCue>, String> {
    let normalized = text
        .trim_start_matches('\u{feff}')
        .replace("\r\n", "\n")
        .replace('\r', "\n");
    if !normalized.lines().any(|line| line.trim() == "[Events]") {
        return Err("ASS subtitle has no Events section".to_string());
    }
    let mut in_events = false;
    let mut start_column = 1_usize;
    let mut end_column = 2_usize;
    let mut text_column = 9_usize;
    let mut column_count = 10_usize;
    let mut cues = Vec::new();
    for line in normalized.lines() {
        let line = line.trim();
        if line.starts_with('[') && line.ends_with(']') {
            in_events = line.eq_ignore_ascii_case("[Events]");
            continue;
        }
        if !in_events {
            continue;
        }
        if let Some(format) = line
            .strip_prefix("Format:")
            .or_else(|| line.strip_prefix("format:"))
        {
            let columns = format
                .split(',')
                .map(|column| column.trim().to_ascii_lowercase())
                .collect::<Vec<_>>();
            column_count = columns.len();
            start_column = columns
                .iter()
                .position(|column| column == "start")
                .ok_or_else(|| "ASS event format has no Start column".to_string())?;
            end_column = columns
                .iter()
                .position(|column| column == "end")
                .ok_or_else(|| "ASS event format has no End column".to_string())?;
            text_column = columns
                .iter()
                .position(|column| column == "text")
                .ok_or_else(|| "ASS event format has no Text column".to_string())?;
            continue;
        }
        let Some(dialogue) = line
            .strip_prefix("Dialogue:")
            .or_else(|| line.strip_prefix("dialogue:"))
        else {
            continue;
        };
        let columns = dialogue
            .trim_start()
            .splitn(column_count.max(text_column + 1), ',')
            .collect::<Vec<_>>();
        let start_ms = columns
            .get(start_column)
            .and_then(|value| parse_time(value.trim()))
            .ok_or_else(|| "invalid ASS start time".to_string())?;
        let end_ms = columns
            .get(end_column)
            .and_then(|value| parse_time(value.trim()))
            .ok_or_else(|| "invalid ASS end time".to_string())?;
        let text = columns
            .get(text_column)
            .map(|value| strip_ass_overrides(value))
            .unwrap_or_default();
        cues.push(SubtitleCue {
            index: cues.len() as u64 + 1,
            start_ms,
            end_ms,
            text,
        });
    }
    if cues.is_empty() {
        return Err("no parseable ASS dialogue cues".to_string());
    }
    Ok(cues)
}

fn strip_ass_overrides(value: &str) -> String {
    let mut result = String::new();
    let mut in_override = false;
    for character in value.replace("\\N", "\n").replace("\\n", "\n").chars() {
        match character {
            '{' => in_override = true,
            '}' if in_override => in_override = false,
            _ if !in_override => result.push(character),
            _ => {}
        }
    }
    result.trim().to_string()
}

fn parse_time(token: &str) -> Option<u64> {
    let (clock, fraction) = token.split_once([',', '.']).unwrap_or((token, "0"));
    let mut parts = clock.split(':');
    let seconds = parts.next_back()?.parse::<u64>().ok()?;
    let mut total_ms = seconds * 1000;
    let mut multiplier = 60_u64;
    for part in parts.rev() {
        total_ms += part.parse::<u64>().ok()? * multiplier * 1000;
        multiplier *= 60;
    }
    let fraction = &fraction[..fraction.len().min(3)];
    let fraction_ms = fraction.parse::<u64>().ok()? * 10_u64.pow(3 - fraction.len() as u32);
    Some(total_ms + fraction_ms)
}

#[cfg(test)]
mod tests {
    use super::{parse_srt, parse_subtitle, subtitle_validation};

    #[test]
    fn standard_srt_blocks_are_parsed_with_timestamps_and_text() {
        let cues = parse_srt(
            "1\r\n00:00:01,000 --> 00:00:04,500\r\nHello world\r\n\r\n\
             2\r\n00:00:05,200 --> 00:00:08,000\r\nSecond line\r\n"
                .trim(),
        )
        .expect("parse srt");
        assert_eq!(cues.len(), 2);
        assert_eq!(cues[0].index, 1);
        assert_eq!(cues[0].start_ms, 1000);
        assert_eq!(cues[0].end_ms, 4500);
        assert_eq!(cues[0].text, "Hello world");
        assert_eq!(cues[1].index, 2);
        assert_eq!(cues[1].start_ms, 5200);
        assert_eq!(cues[1].end_ms, 8000);
    }

    #[test]
    fn blocks_without_indexes_are_auto_numbered() {
        let cues = parse_srt(
            "00:00:01,000 --> 00:00:02,000\nFirst\n\n00:00:03,000 --> 00:00:04,000\nSecond",
        )
        .expect("parse srt");
        assert_eq!(cues[0].index, 1);
        assert_eq!(cues[1].index, 2);
    }

    #[test]
    fn webvtt_headers_and_positioning_metadata_are_tolerated() {
        let cues =
            parse_srt("WEBVTT\n\n00:00:01.000 --> 00:00:04.000 align:start position:0%\nCaptioned")
                .expect("parse srt");
        assert_eq!(cues.len(), 1);
        assert_eq!(cues[0].start_ms, 1000);
        assert_eq!(cues[0].end_ms, 4000);
        assert_eq!(cues[0].text, "Captioned");
    }

    #[test]
    fn multi_line_text_is_joined() {
        let cues = parse_srt("00:00:01,000 --> 00:00:02,000\nLine one\nLine two").expect("srt");
        assert_eq!(cues[0].text, "Line one\nLine two");
    }

    #[test]
    fn utf8_bom_is_stripped() {
        let cues = parse_srt("\u{feff}1\n00:00:01,000 --> 00:00:02,000\nText").expect("srt");
        assert_eq!(cues[0].text, "Text");
    }

    #[test]
    fn missing_timing_markers_are_rejected() {
        assert!(parse_srt("just some text\nwith no markers").is_err());
        assert!(parse_srt("").is_err());
    }

    #[test]
    fn malformed_timing_is_rejected() {
        assert!(parse_srt("1\nnot-a-time --> 00:00:02,000\nText").is_err());
        assert!(parse_srt("1\n00:00:01,000 --> oops\nText").is_err());
    }

    #[test]
    fn long_hours_and_single_digit_minutes_are_supported() {
        let cues = parse_srt("1\n1:00:00,500 --> 1:00:01,000\nText").expect("srt");
        assert_eq!(cues[0].start_ms, 3_600_500);
        assert_eq!(cues[0].end_ms, 3_601_000);
    }

    #[test]
    fn ass_dialogue_rows_are_available_to_the_common_preview() {
        let cues = parse_subtitle(
            "ass",
            "[Script Info]\nTitle: Example\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:01.00,0:00:03.50,Default,,0,0,0,,Hello\\Nworld",
        )
        .expect("ASS preview");
        assert_eq!(cues.len(), 1);
        assert_eq!(cues[0].start_ms, 1000);
        assert_eq!(cues[0].end_ms, 3500);
        assert_eq!(cues[0].text, "Hello\nworld");
    }

    #[test]
    fn validation_reports_overlap_and_excessive_reading_speed() {
        let cues = parse_srt(
            "1\n00:00:01,000 --> 00:00:02,000\nThis line is intentionally much too long to read in one second.\n\n2\n00:00:01,500 --> 00:00:03,000\nOverlap",
        )
        .expect("SRT");
        let validation = subtitle_validation(&cues);
        assert_eq!(validation.cue_count, 2);
        assert!(validation
            .issues
            .iter()
            .any(|issue| issue.kind == "overlap"));
        assert!(validation
            .issues
            .iter()
            .any(|issue| issue.kind == "reading-speed"));
    }
}
