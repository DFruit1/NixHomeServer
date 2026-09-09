pub fn parse_range(header: Option<&str>, size: u64) -> Option<(u64, u64)> {
    let value = header?.trim().strip_prefix("bytes=")?;
    if value.contains(',') {
        return None;
    }
    let (raw_start, raw_end) = value.split_once('-')?;
    if raw_start.is_empty() && raw_end.is_empty() || size == 0 {
        return None;
    }
    if raw_start.is_empty() {
        let suffix = raw_end.parse::<u64>().ok()?;
        if suffix == 0 {
            return None;
        }
        return Some((size.saturating_sub(suffix), size - 1));
    }
    let start = raw_start.parse::<u64>().ok()?;
    if start >= size {
        return None;
    }
    let end = if raw_end.is_empty() {
        size - 1
    } else {
        raw_end.parse::<u64>().ok()?.min(size - 1)
    };
    (end >= start).then_some((start, end))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_byte_ranges() {
        assert_eq!(parse_range(Some("bytes=0-4"), 10), Some((0, 4)));
        assert_eq!(parse_range(Some("bytes=5-"), 10), Some((5, 9)));
        assert_eq!(parse_range(Some("bytes=-3"), 10), Some((7, 9)));
        assert_eq!(parse_range(Some("bytes=5-99"), 10), Some((5, 9)));
    }

    #[test]
    fn rejects_unsatisfiable_and_malformed_ranges() {
        assert_eq!(parse_range(Some("bytes=10-"), 10), None);
        assert_eq!(parse_range(Some("bytes=-0"), 10), None);
        assert_eq!(parse_range(Some("bytes=0-4,10-15"), 10), None);
        assert_eq!(parse_range(Some("bytes=-"), 10), None);
        assert_eq!(parse_range(Some("bytes=0-4"), 0), None);
        assert_eq!(parse_range(None, 10), None);
    }
}
