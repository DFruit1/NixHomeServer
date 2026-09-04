use super::super::*;

pub(crate) fn sha256_file(path: &FsPath) -> Result<String, String> {
    let mut file = fs::File::open(path)
        .map_err(|error| format!("failed to open {}: {error}", path.display()))?;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 8192];
    loop {
        let read = file
            .read(&mut buffer)
            .map_err(|error| format!("failed to read {}: {error}", path.display()))?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

pub(crate) fn md5_file(path: &FsPath) -> Result<String, String> {
    let mut file = fs::File::open(path)
        .map_err(|error| format!("failed to open {}: {error}", path.display()))?;
    let mut hasher = Md5::new();
    let mut buffer = [0_u8; 8192];
    loop {
        let read = file
            .read(&mut buffer)
            .map_err(|error| format!("failed to read {}: {error}", path.display()))?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

pub(crate) fn sha256_hex(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

pub(crate) fn detect_attachment_mime_type(path: &FsPath) -> Result<String, String> {
    let output = execute_command(
        "file",
        &["--mime-type", "-b", path.to_string_lossy().as_ref()],
        &[],
    )?;
    if output.status.success() {
        let detected = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if !detected.is_empty() {
            return Ok(detected);
        }
    } else if let Some(fallback) = fallback_mime_from_extension(path) {
        return Ok(fallback);
    } else {
        return Err(command_failure_detail("file", &output));
    }

    Ok(
        fallback_mime_from_extension(path)
            .unwrap_or_else(|| "application/octet-stream".to_string()),
    )
}

pub(crate) fn fallback_mime_from_extension(path: &FsPath) -> Option<String> {
    let extension = path.extension()?.to_string_lossy().to_ascii_lowercase();
    fallback_mime_from_extension_str(&extension)
}

pub(crate) fn fallback_mime_from_extension_str(extension: &str) -> Option<String> {
    Some(
        match extension {
            "pdf" => "application/pdf",
            "txt" => "text/plain",
            "doc" => "application/msword",
            "docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "odt" => "application/vnd.oasis.opendocument.text",
            "rtf" => "application/rtf",
            "png" => "image/png",
            "jpg" | "jpeg" => "image/jpeg",
            "tif" | "tiff" => "image/tiff",
            "gif" => "image/gif",
            "bmp" => "image/bmp",
            "webp" => "image/webp",
            _ => return None,
        }
        .to_string(),
    )
}

pub(crate) fn looks_like_inline_artifact(filename: &str, mime_type: &str, size_bytes: u64) -> bool {
    looks_like_extracted_body_part(filename)
        || mime_type.starts_with("image/") && size_bytes <= 1024
        || filename.eq_ignore_ascii_case("winmail.dat")
        || filename.eq_ignore_ascii_case("smime.p7s")
}

pub(crate) fn attachment_is_body_artifact(attachment: &AttachmentRecord) -> bool {
    looks_like_extracted_body_part(&attachment.original_filename)
        || attachment
            .original_filename
            .eq_ignore_ascii_case("winmail.dat")
        || attachment
            .original_filename
            .eq_ignore_ascii_case("smime.p7s")
}

pub(crate) fn attachment_is_inline_image(attachment: &AttachmentRecord) -> bool {
    attachment.mime_type.starts_with("image/")
        && (attachment.is_inline_artifact
            || u64::try_from(attachment.size_bytes.max(0)).unwrap_or_default() <= 1024)
}

pub(crate) fn looks_like_extracted_body_part(filename: &str) -> bool {
    let lowered = filename.to_ascii_lowercase();
    lowered.strip_prefix("textfile").is_some_and(|suffix| {
        !suffix.is_empty() && suffix.chars().all(|character| character.is_ascii_digit())
    })
}

pub(crate) fn sync_directory(path: &FsPath) -> Result<(), String> {
    let dir = fs::File::open(path)
        .map_err(|error| format!("failed to open {}: {error}", path.display()))?;
    dir.sync_all()
        .map_err(|error| format!("failed to sync {}: {error}", path.display()))
}

pub(crate) fn safe_filename(raw: &str) -> String {
    filename_component(raw, "attachment")
}

pub(crate) fn filename_component(raw: &str, fallback: &str) -> String {
    let sanitized = raw
        .chars()
        .map(|character| {
            if character == '\0' || character == '/' || character == '\\' || character.is_control()
            {
                ' '
            } else {
                character
            }
        })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .trim_matches(|character| matches!(character, '.' | ' '))
        .to_string();
    if sanitized.is_empty() || sanitized == "." || sanitized == ".." {
        fallback.to_string()
    } else {
        sanitized
    }
}

pub(crate) fn ascii_download_fallback(raw: &str, fallback: &str) -> String {
    let sanitized = raw
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | '-' | ' ') {
                character
            } else {
                '_'
            }
        })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .trim_matches(|character| matches!(character, '.' | '_' | ' '))
        .to_string();
    if sanitized.is_empty() {
        fallback.to_string()
    } else {
        sanitized
    }
}

pub(crate) fn rfc5987_encode(value: &str) -> String {
    value
        .bytes()
        .flat_map(|byte| match byte {
            b'A'..=b'Z'
            | b'a'..=b'z'
            | b'0'..=b'9'
            | b'!'
            | b'#'
            | b'$'
            | b'&'
            | b'+'
            | b'-'
            | b'.'
            | b'^'
            | b'_'
            | b'`'
            | b'|'
            | b'~' => vec![byte as char],
            _ => format!("%{byte:02X}").chars().collect::<Vec<_>>(),
        })
        .collect()
}

pub(crate) fn content_disposition_attachment(filename: &str) -> String {
    let safe = filename_component(filename, "download");
    let fallback = ascii_download_fallback(&safe, "download").replace('"', "_");
    format!(
        "attachment; filename=\"{}\"; filename*=UTF-8''{}",
        fallback,
        rfc5987_encode(&safe)
    )
}

pub(crate) fn normalize_download_subfolder(raw: &str) -> Result<String, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Ok(String::new());
    }
    let mut components = Vec::new();
    for component in trimmed.split(['/', '\\']) {
        let component = filename_component(component, "");
        if component.is_empty() {
            continue;
        }
        if component == "." || component == ".." {
            return Err("Download subfolder cannot contain . or .. path components.".to_string());
        }
        components.push(component);
    }
    if components.is_empty() {
        Ok(String::new())
    } else {
        Ok(components.join("/"))
    }
}

pub(crate) fn attachment_inventory_root(config: &AppConfig, account_id: i64) -> PathBuf {
    PathBuf::from(config.runtime_dir.as_ref())
        .join("attachment-inventory")
        .join(format!("account-{account_id}"))
}

pub(crate) fn runtime_export_root(config: &AppConfig) -> PathBuf {
    PathBuf::from(config.runtime_dir.as_ref()).join("attachment-exports")
}

pub(crate) fn attachment_blob_relpath(sha256: &str) -> PathBuf {
    let prefix = sha256.chars().take(2).collect::<String>();
    PathBuf::from("attachments")
        .join("blobs")
        .join("sha256")
        .join(if prefix.len() == 2 {
            prefix
        } else {
            "unknown".to_string()
        })
        .join(sha256)
}

pub(crate) fn attachment_blob_path(
    account_paths: &AccountPaths,
    blob_relpath: &str,
) -> Result<PathBuf, String> {
    let relpath = FsPath::new(blob_relpath);
    if relpath.is_absolute() || blob_relpath.contains("..") {
        return Err(format!("invalid attachment blob path: {blob_relpath}"));
    }
    Ok(account_paths.hidden_sync_root.join(relpath))
}

pub(crate) fn persist_attachment_blob(
    account_paths: &AccountPaths,
    source: &FsPath,
    sha256: &str,
) -> Result<String, String> {
    let relpath = attachment_blob_relpath(sha256);
    let destination = account_paths.hidden_sync_root.join(&relpath);
    if destination.exists() {
        let existing_sha = sha256_file(&destination)?;
        if existing_sha == sha256 {
            return Ok(relpath.to_string_lossy().to_string());
        }
        fs::remove_file(&destination).map_err(|error| {
            format!(
                "failed to replace mismatched attachment blob {}: {error}",
                destination.display()
            )
        })?;
    }

    let parent = destination.parent().ok_or_else(|| {
        format!(
            "attachment blob path has no parent: {}",
            destination.display()
        )
    })?;
    fs::create_dir_all(parent)
        .map_err(|error| format!("failed to create {}: {error}", parent.display()))?;
    let temporary = parent.join(format!(".{}.tmp", random_hex(8)));
    fs::copy(source, &temporary).map_err(|error| {
        format!(
            "failed to copy attachment blob {} to {}: {error}",
            source.display(),
            temporary.display()
        )
    })?;
    fs::set_permissions(&temporary, fs::Permissions::from_mode(0o600)).map_err(|error| {
        format!(
            "failed to set attachment blob permissions {}: {error}",
            temporary.display()
        )
    })?;
    let copied_sha = sha256_file(&temporary)?;
    if copied_sha != sha256 {
        let _ = fs::remove_file(&temporary);
        return Err(format!(
            "attachment blob hash changed while copying: expected {sha256}, got {copied_sha}"
        ));
    }
    fs::rename(&temporary, &destination).map_err(|error| {
        format!(
            "failed to publish attachment blob {}: {error}",
            destination.display()
        )
    })?;
    sync_directory(parent)?;
    Ok(relpath.to_string_lossy().to_string())
}

pub(crate) fn create_runtime_extraction_dir(
    config: &AppConfig,
    account_id: i64,
) -> Result<TempExtractionDir, String> {
    let path = attachment_inventory_root(config, account_id).join(random_hex(8));
    fs::create_dir_all(&path).map_err(|error| {
        format!(
            "failed to create extraction directory {}: {error}",
            path.display()
        )
    })?;
    Ok(TempExtractionDir { path })
}

pub(crate) fn message_relative_path(
    account_paths: &AccountPaths,
    file_path: &FsPath,
) -> Result<PathBuf, String> {
    if let Ok(relative) = file_path.strip_prefix(&account_paths.maildir) {
        return Ok(relative.to_path_buf());
    }

    let canonical_maildir = fs::canonicalize(&account_paths.maildir).map_err(|error| {
        format!(
            "failed to resolve {}: {error}",
            account_paths.maildir.display()
        )
    })?;
    let canonical_file = fs::canonicalize(file_path)
        .map_err(|error| format!("failed to resolve {}: {error}", file_path.display()))?;
    canonical_file
        .strip_prefix(&canonical_maildir)
        .map(|relative| relative.to_path_buf())
        .map_err(|_| {
            format!(
                "message path {} is outside the maildir",
                file_path.display()
            )
        })
}

pub(crate) fn attachment_extension(filename: &str) -> String {
    FsPath::new(filename)
        .extension()
        .and_then(|value| value.to_str())
        .map(|value| value.to_ascii_lowercase())
        .unwrap_or_default()
}

pub(crate) fn attachment_key(
    account_id: i64,
    message_key: &str,
    attachment_index: usize,
    attachment_sha256: &str,
    original_filename: &str,
) -> String {
    sha256_hex(
        format!(
            "{account_id}\u{1f}{message_key}\u{1f}{attachment_index}\u{1f}{attachment_sha256}\u{1f}{original_filename}"
        )
        .as_bytes(),
    )
}
