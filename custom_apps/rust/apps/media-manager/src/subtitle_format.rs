use serde::Serialize;

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SubtitleCue {
    pub index: u64,
    pub start_ms: u64,
    pub end_ms: u64,
    pub text: String,
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

fn parse_time(token: &str) -> Option<u64> {
    let (clock, fraction) = token
        .split_once(|character| character == ',' || character == '.')
        .unwrap_or((token, "0"));
    let mut parts = clock.split(':');
    let seconds = parts.next_back()?.parse::<u64>().ok()?;
    let mut total_ms = seconds * 1000;
    let mut multiplier = 60_u64;
    for part in parts.rev() {
        total_ms += part.parse::<u64>().ok()? * multiplier * 1000;
        multiplier *= 60;
    }
    let fraction = &fraction[..fraction.len().min(3)];
    let fraction_ms = fraction.parse::<u64>().ok()?;
    Some(total_ms + fraction_ms)
}

#[cfg(test)]
mod tests {
    use super::parse_srt;

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
        let cues = parse_srt(
            "WEBVTT\n\n00:00:01.000 --> 00:00:04.000 align:start position:0%\nCaptioned",
        )
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
}
