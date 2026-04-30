use serde::Serialize;

use crate::inventory::Parsed;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ResetTokenSummary {
    pub raw_output: String,
    pub reset_url: Option<String>,
    pub token: Option<String>,
}

pub fn parse_reset_token_summary(stdout: &str) -> Parsed<ResetTokenSummary> {
    let raw_output = stdout.trim().to_string();
    let url_candidates = raw_output
        .split_whitespace()
        .filter(|word| word.starts_with("https://") || word.starts_with("http://"))
        .map(trim_token_text)
        .collect::<Vec<_>>();

    let token_candidates = raw_output
        .lines()
        .filter_map(|line| {
            if let Some((label, value)) = line.split_once(':') {
                if !label.trim().to_lowercase().contains("token") {
                    return None;
                }
                let trimmed = value.trim();
                if !trimmed.is_empty() {
                    return Some(trimmed.to_string());
                }
            }
            None
        })
        .collect::<Vec<_>>();

    let mut warnings = Vec::new();
    if url_candidates.is_empty() {
        warnings.push(
            "reset-token output did not contain a reset URL; use the raw backend output"
                .to_string(),
        );
    } else if url_candidates.len() > 1 {
        warnings.push(
            "reset-token output contained multiple reset URLs; using the first parsed URL and preserving the raw backend output"
                .to_string(),
        );
    }

    if token_candidates.is_empty() {
        warnings.push(
            "reset-token output did not contain a parseable token; use the raw backend output"
                .to_string(),
        );
    } else if token_candidates.len() > 1 {
        warnings.push(
            "reset-token output contained multiple token-like lines; using the first parsed token and preserving the raw backend output"
                .to_string(),
        );
    }

    Parsed {
        value: ResetTokenSummary {
            raw_output,
            reset_url: url_candidates.first().cloned(),
            token: token_candidates.first().cloned(),
        },
        warnings,
    }
}

fn trim_token_text(value: &str) -> String {
    value
        .trim_matches(|ch: char| matches!(ch, '"' | '\'' | ',' | '.' | ')' | '('))
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_reset_token_output() {
        let summary = parse_reset_token_summary(
            "Reset token: abc123\nUse this link: https://id.example.test/ui/reset?token=abc123\n",
        );

        assert_eq!(summary.value.token.as_deref(), Some("abc123"));
        assert_eq!(
            summary.value.reset_url.as_deref(),
            Some("https://id.example.test/ui/reset?token=abc123")
        );
        assert!(summary.warnings.is_empty());
    }

    #[test]
    fn warns_when_reset_token_output_is_partial() {
        let summary = parse_reset_token_summary("Reset token: abc123\n");

        assert_eq!(summary.value.token.as_deref(), Some("abc123"));
        assert!(summary.value.reset_url.is_none());
        assert_eq!(summary.warnings.len(), 1);
    }
}
