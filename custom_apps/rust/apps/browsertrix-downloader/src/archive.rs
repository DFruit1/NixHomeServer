use chrono::NaiveDate;
use std::{io, path::Path};

pub fn sanitize_segment(value: &str, fallback: &str) -> String {
    let replaced = value
        .chars()
        .map(|character| {
            if character.is_control() || "<>:\"/\\|?*".contains(character) {
                ' '
            } else {
                character
            }
        })
        .collect::<String>();
    let collapsed = replaced.split_whitespace().collect::<Vec<_>>().join(" ");
    let cleaned = collapsed
        .trim_matches(|character: char| character == '.' || character.is_whitespace())
        .chars()
        .take(120)
        .collect::<String>();
    if cleaned.is_empty() {
        return fallback.to_owned();
    }
    if is_windows_reserved(&cleaned) {
        format!("{cleaned}_")
    } else {
        cleaned
    }
}

pub fn archive_name(hostname: &str, date: NaiveDate) -> String {
    format!("{} {date}.wacz", sanitize_segment(hostname, "site"))
}

pub fn allocate_archive_name(root: &Path, base_name: &str) -> io::Result<String> {
    let stem = base_name.strip_suffix(".wacz").unwrap_or(base_name);
    for index in 0..1_000 {
        let candidate = if index == 0 {
            format!("{stem}.wacz")
        } else {
            format!("{stem} ({index}).wacz")
        };
        match std::fs::symlink_metadata(root.join(&candidate)) {
            Ok(_) => continue,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(candidate),
            Err(error) => return Err(error),
        }
    }
    Err(io::Error::new(
        io::ErrorKind::AlreadyExists,
        format!(
            "could not allocate unique archive file name under {}",
            root.display()
        ),
    ))
}

fn is_windows_reserved(value: &str) -> bool {
    let name = value
        .split('.')
        .next()
        .unwrap_or(value)
        .to_ascii_lowercase();
    matches!(name.as_str(), "con" | "prn" | "aux" | "nul")
        || name
            .strip_prefix("com")
            .or_else(|| name.strip_prefix("lpt"))
            .is_some_and(|suffix| {
                matches!(suffix, "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9")
            })
}
