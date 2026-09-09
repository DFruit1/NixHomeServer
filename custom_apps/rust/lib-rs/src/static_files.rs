use std::io;
use std::path::{Component, Path, PathBuf};

pub fn decode_relative_path(value: &str) -> Option<PathBuf> {
    let mut path = PathBuf::new();
    for segment in value.split('/') {
        if segment.is_empty() {
            continue;
        }
        let decoded = percent_decode(segment)?;
        if matches!(decoded.as_str(), "." | "..") || decoded.contains(['/', '\\', '\0']) {
            return None;
        }
        path.push(decoded);
    }
    Some(path)
}

fn percent_decode(value: &str) -> Option<String> {
    let bytes = value.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            let high = *bytes.get(index + 1)?;
            let low = *bytes.get(index + 2)?;
            decoded.push((hex(high)? << 4) | hex(low)?);
            index += 3;
        } else {
            decoded.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8(decoded).ok()
}

fn hex(value: u8) -> Option<u8> {
    match value {
        b'0'..=b'9' => Some(value - b'0'),
        b'a'..=b'f' => Some(value - b'a' + 10),
        b'A'..=b'F' => Some(value - b'A' + 10),
        _ => None,
    }
}

pub fn is_safe_single_component(value: &str) -> bool {
    let relative = Path::new(value);
    relative.components().count() == 1
        && matches!(relative.components().next(), Some(Component::Normal(_)))
}

#[derive(Debug)]
pub enum StaticFileError {
    NotFound,
    EscapesRoot,
    Io(io::Error),
}

impl std::fmt::Display for StaticFileError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotFound => formatter.write_str("static file not found"),
            Self::EscapesRoot => formatter.write_str("static path escapes root"),
            Self::Io(error) => write!(formatter, "static file read failed: {error}"),
        }
    }
}

pub async fn read_static_file(root: &Path, relative: &Path) -> Result<Vec<u8>, StaticFileError> {
    let canonical_root = tokio::fs::canonicalize(root)
        .await
        .map_err(|_| StaticFileError::NotFound)?;
    let candidate = root.join(relative);
    let canonical_candidate = tokio::fs::canonicalize(&candidate)
        .await
        .map_err(|_| StaticFileError::NotFound)?;
    if !canonical_candidate.starts_with(&canonical_root) {
        return Err(StaticFileError::EscapesRoot);
    }
    let metadata = tokio::fs::metadata(&canonical_candidate)
        .await
        .map_err(|_| StaticFileError::NotFound)?;
    if !metadata.is_file() {
        return Err(StaticFileError::NotFound);
    }
    tokio::fs::read(&canonical_candidate)
        .await
        .map_err(StaticFileError::Io)
}

pub fn content_type_for_path(path: &Path) -> &'static str {
    content_type_for_extension(
        path.extension()
            .and_then(|extension| extension.to_str())
            .unwrap_or_default(),
    )
}

pub fn content_type_for_extension(extension: &str) -> &'static str {
    match extension {
        "css" => "text/css; charset=utf-8",
        "gif" => "image/gif",
        "gz" => "application/gzip",
        "html" => "text/html; charset=utf-8",
        "jpg" | "jpeg" => "image/jpeg",
        "js" | "mjs" => "text/javascript; charset=utf-8",
        "json" => "application/json; charset=utf-8",
        "png" => "image/png",
        "svg" => "image/svg+xml",
        "wasm" => "application/wasm",
        "webp" => "image/webp",
        "woff2" => "font/woff2",
        _ => "application/octet-stream",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_percent_encoded_segments() {
        assert_eq!(
            decode_relative_path("assets/foo%20bar.js"),
            Some(PathBuf::from("assets/foo bar.js"))
        );
    }

    #[test]
    fn rejects_traversal_and_separators() {
        assert_eq!(decode_relative_path("..%2fsecret"), None);
        assert_eq!(decode_relative_path("a/../../b"), None);
        assert_eq!(decode_relative_path("a%5Cb"), None);
        assert_eq!(decode_relative_path("bad%zz"), None);
    }

    #[test]
    fn maps_common_content_types() {
        assert_eq!(
            content_type_for_path(Path::new("app.css")),
            "text/css; charset=utf-8"
        );
        assert_eq!(content_type_for_path(Path::new("i.webp")), "image/webp");
        assert_eq!(content_type_for_path(Path::new("f.woff2")), "font/woff2");
        assert_eq!(
            content_type_for_path(Path::new("blob.bin")),
            "application/octet-stream"
        );
    }

    #[test]
    fn single_component_check() {
        assert!(is_safe_single_component("archive.wacz"));
        assert!(!is_safe_single_component("a/b"));
        assert!(!is_safe_single_component(".."));
    }
}
