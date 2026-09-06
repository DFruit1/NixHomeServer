use chrono::{DateTime, Utc};
use sha2::{Digest, Sha256};

/// Converts an epoch-seconds timestamp to a Solr-compatible ISO-8601 UTC date.
pub fn epoch_to_solr_date(seconds: i64) -> String {
    let datetime = DateTime::<Utc>::from_timestamp(seconds, 0).unwrap_or_default();
    datetime.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

/// Parses an RFC-3339 / RFC-2822 / ISO date string into epoch seconds.
pub fn parse_date(raw: &str) -> Option<i64> {
    let raw = raw.trim();
    if raw.is_empty() {
        return None;
    }
    if let Ok(datetime) = DateTime::parse_from_rfc3339(raw) {
        return Some(datetime.timestamp());
    }
    if let Ok(datetime) = DateTime::parse_from_rfc2822(raw) {
        return Some(datetime.timestamp());
    }
    None
}

pub fn now_epoch() -> i64 {
    Utc::now().timestamp()
}

pub fn sha256_hex(parts: &[&str]) -> String {
    let mut hasher = Sha256::new();
    for part in parts {
        hasher.update(part.as_bytes());
        hasher.update(b"\x1f");
    }
    format!("{:x}", hasher.finalize())
}

/// Percent-encodes a path segment for use inside URLs.
pub fn percent_encode_path(value: &str) -> String {
    let mut encoded = String::with_capacity(value.len());
    for byte in value.bytes() {
        let keep =
            byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b'~' | b'/' | b':');
        if keep {
            encoded.push(byte as char);
        } else {
            encoded.push_str(&format!("%{byte:02X}"));
        }
    }
    encoded
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn converts_epoch_to_solr_date() {
        assert_eq!(epoch_to_solr_date(0), "1970-01-01T00:00:00Z");
        assert_eq!(epoch_to_solr_date(1_700_000_000), "2023-11-14T22:13:20Z");
    }

    #[test]
    fn parses_common_date_formats() {
        assert_eq!(parse_date("2023-11-14T22:13:20Z"), Some(1_700_000_000));
        assert_eq!(
            parse_date("Tue, 14 Nov 2023 22:13:20 +0000"),
            Some(1_700_000_000)
        );
        assert_eq!(parse_date(""), None);
        assert_eq!(parse_date("not a date"), None);
    }

    #[test]
    fn hashes_parts_deterministically() {
        let first = sha256_hex(&["paperless", "42"]);
        let second = sha256_hex(&["paperless", "42"]);
        let other = sha256_hex(&["paperless", "43"]);
        assert_eq!(first, second);
        assert_ne!(first, other);
    }

    #[test]
    fn encodes_unsafe_path_bytes() {
        assert_eq!(percent_encode_path("A/B_1.0~"), "A/B_1.0~");
        assert_eq!(percent_encode_path("a b.html"), "a%20b.html");
    }
}
