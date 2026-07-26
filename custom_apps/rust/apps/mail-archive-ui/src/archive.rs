use super::*;

pub(super) fn extract_message_attachments(
    message_path: &FsPath,
    output_dir: &FsPath,
) -> Result<Vec<ExtractedAttachment>, String> {
    if let Ok(extracted) = extract_message_attachments_with_mailparse(message_path, output_dir) {
        if !extracted.is_empty() {
            return Ok(extracted);
        }
    }

    run_command(
        "ripmime",
        &[
            "-i",
            message_path.to_string_lossy().as_ref(),
            "-d",
            output_dir.to_string_lossy().as_ref(),
            "-q",
        ],
        &[],
    )?;
    collect_regular_files(output_dir)?
        .into_iter()
        .map(|path| {
            let original_filename = path
                .file_name()
                .and_then(|value| value.to_str())
                .map(ToString::to_string)
                .unwrap_or_else(|| "attachment".to_string());
            Ok(ExtractedAttachment {
                is_inline_image: false,
                path,
                original_filename,
            })
        })
        .collect()
}

pub(super) fn extract_message_attachments_with_mailparse(
    message_path: &FsPath,
    output_dir: &FsPath,
) -> Result<Vec<ExtractedAttachment>, String> {
    let bytes = fs::read(message_path)
        .map_err(|error| format!("failed to read {}: {error}", message_path.display()))?;
    let parsed = mailparse::parse_mail(&bytes).map_err(|error| {
        format!(
            "failed to parse MIME message {}: {error}",
            message_path.display()
        )
    })?;
    let mut attachments = Vec::new();
    let mut used_names = HashMap::<String, usize>::new();

    for (index, part) in parsed.parts().enumerate() {
        if !part.subparts.is_empty() {
            continue;
        }
        let disposition_header = part.headers.get_first_value("Content-Disposition");
        let disposition = part.get_content_disposition();
        let content_id = part.headers.get_first_value("Content-ID");
        let filename = disposition
            .params
            .get("filename")
            .or_else(|| part.ctype.params.get("name"))
            .cloned();
        let is_attachment = matches!(disposition.disposition, DispositionType::Attachment);
        let is_inline_image = part.ctype.mimetype.starts_with("image/")
            && matches!(disposition.disposition, DispositionType::Inline)
            && (disposition_header.is_some() || content_id.is_some());
        if !is_attachment && filename.is_none() && !is_inline_image {
            continue;
        }

        let fallback = if is_inline_image {
            inline_image_fallback_name(index, &part.ctype.mimetype)
        } else {
            format!("attachment-{index}")
        };
        let original_filename = filename
            .map(|value| filename_component(&value, &fallback))
            .unwrap_or(fallback);
        let file_name = unique_zip_entry_name(
            filename_component(&original_filename, "attachment"),
            &mut used_names,
        );
        let output_path = output_dir.join(file_name);
        let body = part.get_body_raw().map_err(|error| {
            format!(
                "failed to decode MIME attachment {} from {}: {error}",
                original_filename,
                message_path.display()
            )
        })?;
        write_private_file(&output_path, &body)?;
        attachments.push(ExtractedAttachment {
            path: output_path,
            original_filename,
            is_inline_image,
        });
    }

    Ok(attachments)
}

pub(super) fn inline_image_fallback_name(index: usize, mime_type: &str) -> String {
    let extension = match mime_type {
        "image/jpeg" => "jpg",
        "image/png" => "png",
        "image/gif" => "gif",
        "image/webp" => "webp",
        "image/tiff" => "tiff",
        "image/bmp" => "bmp",
        _ => "img",
    };
    format!("inline-image-{index}.{extension}")
}

pub(super) fn collect_regular_files(root: &FsPath) -> Result<Vec<PathBuf>, String> {
    let mut files = Vec::new();
    collect_regular_files_inner(root, &mut files)?;
    files.sort();
    Ok(files)
}

pub(super) fn collect_regular_files_inner(
    root: &FsPath,
    files: &mut Vec<PathBuf>,
) -> Result<(), String> {
    let entries = fs::read_dir(root)
        .map_err(|error| format!("failed to read {}: {error}", root.display()))?;
    for entry in entries {
        let entry = entry.map_err(|error| format!("failed to read {}: {error}", root.display()))?;
        let file_type = entry
            .file_type()
            .map_err(|error| format!("failed to inspect {}: {error}", entry.path().display()))?;
        if file_type.is_dir() {
            collect_regular_files_inner(&entry.path(), files)?;
        } else if file_type.is_file() {
            files.push(entry.path());
        }
    }
    Ok(())
}

pub(super) fn read_message_metadata(message_path: &FsPath) -> Result<MessageMetadata, String> {
    let bytes = fs::read(message_path)
        .map_err(|error| format!("failed to read {}: {error}", message_path.display()))?;
    let normalized_message_id =
        decoded_header_value(&bytes, "message-id").and_then(normalize_message_id);
    let subject = decoded_header_value(&bytes, "subject").unwrap_or_else(|| "(no subject)".into());
    let from = decoded_header_value(&bytes, "from").unwrap_or_else(|| "Unknown sender".into());
    let timestamp = decoded_header_value(&bytes, "date")
        .and_then(|value| parse_message_timestamp(&value))
        .unwrap_or_else(|| {
            fs::metadata(message_path)
                .ok()
                .and_then(|metadata| DateTime::<Utc>::from_timestamp(metadata.mtime(), 0))
                .map(|value| value.timestamp())
                .unwrap_or_default()
        });
    Ok(MessageMetadata {
        message_sha256: normalized_message_id.is_none().then(|| sha256_hex(&bytes)),
        normalized_message_id,
        subject,
        from,
        timestamp,
    })
}

pub(super) fn decoded_header_value(message_bytes: &[u8], target_name: &str) -> Option<String> {
    mailparse::parse_mail(message_bytes)
        .ok()
        .and_then(|message| message.headers.get_first_value(target_name))
        .map(|value| decode_display_header_value(value.trim()))
        .filter(|value| !value.is_empty())
}

pub(super) fn decode_display_header_value(raw: &str) -> String {
    if !raw.contains("=?") {
        return raw.to_string();
    }
    decode_rfc2047_words(raw).unwrap_or_else(|| raw.to_string())
}

pub(super) fn decode_rfc2047_words(raw: &str) -> Option<String> {
    let mut output = String::new();
    let mut index = 0;
    let bytes = raw.as_bytes();
    let mut decoded_any = false;
    while index < raw.len() {
        if bytes.get(index) == Some(&b'=') && bytes.get(index + 1) == Some(&b'?') {
            let rest = &raw[index + 2..];
            let Some(charset_end) = rest.find('?') else {
                output.push_str(&raw[index..]);
                break;
            };
            let charset = &rest[..charset_end];
            let rest = &rest[charset_end + 1..];
            let Some(encoding_end) = rest.find('?') else {
                output.push_str(&raw[index..]);
                break;
            };
            let encoding = &rest[..encoding_end];
            let rest = &rest[encoding_end + 1..];
            let Some(encoded_end) = rest.find("?=") else {
                output.push_str(&raw[index..]);
                break;
            };
            let encoded = &rest[..encoded_end];
            if let Some(decoded) = decode_rfc2047_word(charset, encoding, encoded) {
                if output.ends_with(' ') && raw[..index].trim_end().ends_with("?=") {
                    output.pop();
                }
                output.push_str(&decoded);
                decoded_any = true;
                index += 2 + charset_end + 1 + encoding_end + 1 + encoded_end + 2;
                continue;
            }
        }
        let character = raw[index..].chars().next()?;
        output.push(character);
        index += character.len_utf8();
    }
    decoded_any.then(|| output.trim().to_string())
}

pub(super) fn decode_rfc2047_word(charset: &str, encoding: &str, encoded: &str) -> Option<String> {
    let bytes = match encoding.to_ascii_uppercase().as_str() {
        "Q" => decode_rfc2047_q(encoded)?,
        "B" => BASE64.decode(encoded.as_bytes()).ok()?,
        _ => return None,
    };
    Some(decode_header_bytes(charset, &bytes))
}

pub(super) fn decode_rfc2047_q(encoded: &str) -> Option<Vec<u8>> {
    let mut bytes = Vec::with_capacity(encoded.len());
    let mut iter = encoded.as_bytes().iter().copied();
    while let Some(byte) = iter.next() {
        match byte {
            b'_' => bytes.push(b' '),
            b'=' => {
                let high = iter.next()?;
                let low = iter.next()?;
                let hex = [high, low];
                let value = u8::from_str_radix(std::str::from_utf8(&hex).ok()?, 16).ok()?;
                bytes.push(value);
            }
            value => bytes.push(value),
        }
    }
    Some(bytes)
}

pub(super) fn decode_header_bytes(charset: &str, bytes: &[u8]) -> String {
    match charset.to_ascii_lowercase().as_str() {
        "utf-8" | "utf8" | "us-ascii" => String::from_utf8_lossy(bytes).to_string(),
        "windows-1252" | "cp1252" => decode_windows_1252(bytes),
        "iso-8859-1" | "latin1" | "latin-1" => bytes.iter().map(|byte| *byte as char).collect(),
        _ => String::from_utf8_lossy(bytes).to_string(),
    }
}

pub(super) fn decode_windows_1252(bytes: &[u8]) -> String {
    bytes
        .iter()
        .map(|byte| match byte {
            0x80 => '\u{20ac}',
            0x82 => '\u{201a}',
            0x83 => '\u{0192}',
            0x84 => '\u{201e}',
            0x85 => '\u{2026}',
            0x86 => '\u{2020}',
            0x87 => '\u{2021}',
            0x88 => '\u{02c6}',
            0x89 => '\u{2030}',
            0x8a => '\u{0160}',
            0x8b => '\u{2039}',
            0x8c => '\u{0152}',
            0x8e => '\u{017d}',
            0x91 => '\u{2018}',
            0x92 => '\u{2019}',
            0x93 => '\u{201c}',
            0x94 => '\u{201d}',
            0x95 => '\u{2022}',
            0x96 => '\u{2013}',
            0x97 => '\u{2014}',
            0x98 => '\u{02dc}',
            0x99 => '\u{2122}',
            0x9a => '\u{0161}',
            0x9b => '\u{203a}',
            0x9c => '\u{0153}',
            0x9e => '\u{017e}',
            0x9f => '\u{0178}',
            value => *value as char,
        })
        .collect()
}

pub(super) fn read_message_context_preview(
    message_path: &FsPath,
    limit: usize,
) -> Result<MessageContextPreview, String> {
    let bytes = fs::read(message_path)
        .map_err(|error| format!("failed to read {}: {error}", message_path.display()))?;
    let parsed = mailparse::parse_mail(&bytes).map_err(|error| {
        format!(
            "failed to parse MIME message {}: {error}",
            message_path.display()
        )
    })?;
    let cc = decoded_header_value(&bytes, "cc");
    let mut html_fallback = None;
    let mut html_truncated = false;

    for part in parsed.parts() {
        if !part.subparts.is_empty() {
            continue;
        }
        if matches!(
            part.get_content_disposition().disposition,
            DispositionType::Attachment
        ) {
            continue;
        }
        if part.ctype.mimetype.eq_ignore_ascii_case("text/plain") {
            let body = part.get_body().map_err(|error| {
                format!(
                    "failed to decode text body from {}: {error}",
                    message_path.display()
                )
            })?;
            if let Some((preview, truncated)) = compact_text_preview(&body, limit) {
                return Ok(MessageContextPreview {
                    body: Some(preview),
                    truncated,
                    cc,
                });
            }
        } else if html_fallback.is_none() && part.ctype.mimetype.eq_ignore_ascii_case("text/html") {
            let body = part.get_body().map_err(|error| {
                format!(
                    "failed to decode HTML body from {}: {error}",
                    message_path.display()
                )
            })?;
            if let Some((preview, truncated)) = compact_text_preview(&strip_html_tags(&body), limit)
            {
                html_fallback = Some(preview);
                html_truncated = truncated;
            }
        }
    }

    Ok(MessageContextPreview {
        body: html_fallback,
        truncated: html_truncated,
        cc,
    })
}

pub(super) fn compact_text_preview(raw: &str, limit: usize) -> Option<(String, bool)> {
    let compact = raw.split_whitespace().collect::<Vec<_>>().join(" ");
    if compact.is_empty() {
        return None;
    }
    let truncated = compact.chars().count() > limit;
    let preview = compact
        .chars()
        .take(limit)
        .collect::<String>()
        .trim_end()
        .to_string();
    Some((preview, truncated))
}

pub(super) fn strip_html_tags(raw: &str) -> String {
    let mut text = String::with_capacity(raw.len());
    let mut in_tag = false;
    for character in raw.chars() {
        match character {
            '<' => in_tag = true,
            '>' => {
                in_tag = false;
                text.push(' ');
            }
            _ if !in_tag => text.push(character),
            _ => {}
        }
    }
    text
}

pub(super) fn sender_identity_from_header(raw_sender: &str) -> Option<SenderIdentity> {
    mailparse::addrparse(raw_sender)
        .ok()
        .and_then(|addresses| {
            addresses.iter().find_map(|address| match address {
                MailAddr::Single(single) => normalize_sender_address(&single.addr),
                MailAddr::Group(group) => group
                    .addrs
                    .first()
                    .and_then(|single| normalize_sender_address(&single.addr)),
            })
        })
        .or_else(|| fallback_sender_identity(raw_sender))
}

pub(super) fn sender_display_from_header(raw_sender: &str) -> SenderDisplay {
    if let Some(display) = mailparse::addrparse(raw_sender).ok().and_then(|addresses| {
        addresses.iter().find_map(|address| match address {
            MailAddr::Single(single) => {
                let email = clean_sender_display_part(&single.addr);
                if email.is_empty() {
                    return None;
                }
                Some(sender_display_from_parts(
                    single.display_name.as_deref(),
                    email,
                ))
            }
            MailAddr::Group(group) => group.addrs.first().and_then(|single| {
                let email = clean_sender_display_part(&single.addr);
                if email.is_empty() {
                    return None;
                }
                Some(sender_display_from_parts(
                    single.display_name.as_deref(),
                    email,
                ))
            }),
        })
    }) {
        return display;
    }

    if let Some(identity) = fallback_sender_identity(raw_sender) {
        return SenderDisplay {
            primary: identity.address,
            secondary: None,
        };
    }

    SenderDisplay {
        primary: clean_sender_display_part(raw_sender),
        secondary: None,
    }
}

pub(super) fn sender_display_from_parts(raw_name: Option<&str>, email: String) -> SenderDisplay {
    match raw_name
        .map(clean_sender_display_part)
        .filter(|value| !value.is_empty() && !value.eq_ignore_ascii_case(&email))
    {
        Some(name) => SenderDisplay {
            primary: name,
            secondary: Some(email),
        },
        None => SenderDisplay {
            primary: email,
            secondary: None,
        },
    }
}

pub(super) fn clean_sender_display_part(value: &str) -> String {
    value
        .trim()
        .trim_matches(|character| matches!(character, '<' | '>' | '"' | '\''))
        .trim()
        .to_string()
}

pub(super) fn fallback_sender_identity(raw_sender: &str) -> Option<SenderIdentity> {
    let candidate = raw_sender
        .split(|character: char| {
            character.is_whitespace() || matches!(character, '<' | '>' | ',' | ';' | '"' | '\'')
        })
        .find(|part| part.contains('@'))?;
    normalize_sender_address(candidate)
}

pub(super) fn normalize_sender_address(raw_address: &str) -> Option<SenderIdentity> {
    let address = raw_address
        .trim()
        .trim_matches(|character| matches!(character, '<' | '>' | '"' | '\''))
        .to_ascii_lowercase();
    let (local, domain) = address.rsplit_once('@')?;
    let domain = domain.trim().trim_matches('.').to_string();
    if local.trim().is_empty()
        || domain.is_empty()
        || domain.contains('/')
        || domain.contains('@')
        || address.contains(char::is_whitespace)
    {
        return None;
    }
    Some(SenderIdentity { address, domain })
}

pub(super) fn normalize_sender_domain(raw_domain: &str) -> Option<String> {
    let domain = raw_domain
        .trim()
        .trim_start_matches('@')
        .trim_matches(|character| matches!(character, '<' | '>' | '"' | '\''))
        .trim_matches('.')
        .to_ascii_lowercase();
    if domain.is_empty()
        || domain.contains('@')
        || domain.contains('/')
        || domain.contains(char::is_whitespace)
    {
        None
    } else {
        Some(domain)
    }
}

pub(super) fn normalize_sender_rule_value(
    kind: SenderRuleKind,
    raw_value: &str,
) -> Result<String, String> {
    match kind {
        SenderRuleKind::Address => normalize_sender_address(raw_value)
            .map(|identity| identity.address)
            .ok_or_else(|| "Sender address rule must be a valid email address".to_string()),
        SenderRuleKind::Domain => normalize_sender_domain(raw_value)
            .ok_or_else(|| "Sender domain rule must be a valid mail domain".to_string()),
    }
}

pub(super) fn parse_message_timestamp(raw: &str) -> Option<i64> {
    DateTime::parse_from_rfc2822(raw)
        .ok()
        .map(|value| value.with_timezone(&Utc).timestamp())
        .or_else(|| {
            DateTime::parse_from_rfc3339(raw)
                .ok()
                .map(|value| value.with_timezone(&Utc).timestamp())
        })
}

pub(super) fn normalize_message_id(raw: String) -> Option<String> {
    let collapsed = raw.split_whitespace().collect::<String>();
    let trimmed = collapsed
        .trim()
        .trim_start_matches('<')
        .trim_end_matches('>');
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_ascii_lowercase())
    }
}

pub(super) fn sha256_file(path: &FsPath) -> Result<String, String> {
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

pub(super) fn md5_file(path: &FsPath) -> Result<String, String> {
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

pub(super) fn sha256_hex(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

pub(super) fn detect_attachment_mime_type(path: &FsPath) -> Result<String, String> {
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

pub(super) fn fallback_mime_from_extension(path: &FsPath) -> Option<String> {
    let extension = path.extension()?.to_string_lossy().to_ascii_lowercase();
    fallback_mime_from_extension_str(&extension)
}

pub(super) fn fallback_mime_from_extension_str(extension: &str) -> Option<String> {
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

pub(super) fn looks_like_inline_artifact(filename: &str, mime_type: &str, size_bytes: u64) -> bool {
    looks_like_extracted_body_part(filename)
        || mime_type.starts_with("image/") && size_bytes <= 1024
        || filename.eq_ignore_ascii_case("winmail.dat")
        || filename.eq_ignore_ascii_case("smime.p7s")
}

pub(super) fn attachment_is_body_artifact(attachment: &AttachmentRecord) -> bool {
    looks_like_extracted_body_part(&attachment.original_filename)
        || attachment
            .original_filename
            .eq_ignore_ascii_case("winmail.dat")
        || attachment
            .original_filename
            .eq_ignore_ascii_case("smime.p7s")
}

pub(super) fn attachment_is_inline_image(attachment: &AttachmentRecord) -> bool {
    attachment.mime_type.starts_with("image/")
        && (attachment.is_inline_artifact
            || u64::try_from(attachment.size_bytes.max(0)).unwrap_or_default() <= 1024)
}

pub(super) fn looks_like_extracted_body_part(filename: &str) -> bool {
    let lowered = filename.to_ascii_lowercase();
    lowered.strip_prefix("textfile").is_some_and(|suffix| {
        !suffix.is_empty() && suffix.chars().all(|character| character.is_ascii_digit())
    })
}

pub(super) fn sync_directory(path: &FsPath) -> Result<(), String> {
    let dir = fs::File::open(path)
        .map_err(|error| format!("failed to open {}: {error}", path.display()))?;
    dir.sync_all()
        .map_err(|error| format!("failed to sync {}: {error}", path.display()))
}

pub(super) fn safe_filename(raw: &str) -> String {
    filename_component(raw, "attachment")
}

pub(super) fn filename_component(raw: &str, fallback: &str) -> String {
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

pub(super) fn ascii_download_fallback(raw: &str, fallback: &str) -> String {
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

pub(super) fn rfc5987_encode(value: &str) -> String {
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

pub(super) fn content_disposition_attachment(filename: &str) -> String {
    let safe = filename_component(filename, "download");
    let fallback = ascii_download_fallback(&safe, "download").replace('"', "_");
    format!(
        "attachment; filename=\"{}\"; filename*=UTF-8''{}",
        fallback,
        rfc5987_encode(&safe)
    )
}

pub(super) fn normalize_download_subfolder(raw: &str) -> Result<String, String> {
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

pub(super) fn attachment_inventory_root(config: &AppConfig, account_id: i64) -> PathBuf {
    PathBuf::from(config.runtime_dir.as_ref())
        .join("attachment-inventory")
        .join(format!("account-{account_id}"))
}

pub(super) fn runtime_export_root(config: &AppConfig) -> PathBuf {
    PathBuf::from(config.runtime_dir.as_ref()).join("attachment-exports")
}

pub(super) fn attachment_blob_relpath(sha256: &str) -> PathBuf {
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

pub(super) fn attachment_blob_path(
    account_paths: &AccountPaths,
    blob_relpath: &str,
) -> Result<PathBuf, String> {
    let relpath = FsPath::new(blob_relpath);
    if relpath.is_absolute() || blob_relpath.contains("..") {
        return Err(format!("invalid attachment blob path: {blob_relpath}"));
    }
    Ok(account_paths.hidden_sync_root.join(relpath))
}

pub(super) fn persist_attachment_blob(
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

pub(super) fn create_runtime_extraction_dir(
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

pub(super) fn message_relative_path(
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

pub(super) fn attachment_extension(filename: &str) -> String {
    FsPath::new(filename)
        .extension()
        .and_then(|value| value.to_str())
        .map(|value| value.to_ascii_lowercase())
        .unwrap_or_default()
}

pub(super) fn attachment_key(
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

pub(super) fn list_notmuch_message_files(
    account_paths: &AccountPaths,
    query: &str,
) -> Result<Vec<PathBuf>, String> {
    let output = execute_command(
        "notmuch",
        &["search", "--output=files", "--format=text", query],
        &[
            (
                "HOME",
                account_paths.account_state_root.to_string_lossy().as_ref(),
            ),
            (
                "NOTMUCH_CONFIG",
                account_paths.notmuch_config.to_string_lossy().as_ref(),
            ),
        ],
    )?;

    if !output.status.success() {
        let detail = command_failure_detail("notmuch", &output);
        if detail.contains("No database found") || detail.contains("not initialized") {
            return Ok(Vec::new());
        }
        return Err(detail);
    }

    let mut files = String::from_utf8_lossy(&output.stdout)
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(PathBuf::from)
        .filter(|path| path.is_file())
        .collect::<Vec<_>>();
    files.sort();
    Ok(files)
}

pub(super) fn scan_message_attachments_for_catalog(
    config: &AppConfig,
    account_paths: &AccountPaths,
    account_id: i64,
    message_key: &str,
    message_path: &FsPath,
    source_message_sha256: &str,
) -> Result<(TempExtractionDir, Vec<(AttachmentRecord, PathBuf)>), String> {
    let extraction_dir = create_runtime_extraction_dir(config, account_id)?;
    let extracted_files = extract_message_attachments(message_path, &extraction_dir.path)?;
    let now = Utc::now().to_rfc3339();
    let mut attachments = Vec::new();

    for (index, extracted) in extracted_files.into_iter().enumerate() {
        let metadata = fs::metadata(&extracted.path).map_err(|error| {
            format!(
                "failed to inspect extracted attachment {}: {error}",
                extracted.path.display()
            )
        })?;
        let original_filename = extracted.original_filename;
        let safe_name = safe_filename(&original_filename);
        let extension = attachment_extension(&original_filename);
        let mime_type = detect_attachment_mime_type(&extracted.path)
            .unwrap_or_else(|_| "application/octet-stream".to_string());
        let size_bytes = i64::try_from(metadata.len()).map_err(|_| {
            format!(
                "attachment {} is too large to catalog",
                extracted.path.display()
            )
        })?;
        let attachment_sha256 = sha256_file(&extracted.path)?;
        let blob_relpath =
            persist_attachment_blob(account_paths, &extracted.path, &attachment_sha256)?;
        let attachment_record = AttachmentRecord {
            attachment_key: attachment_key(
                account_id,
                message_key,
                index,
                &attachment_sha256,
                &original_filename,
            ),
            account_id,
            message_key: message_key.to_string(),
            attachment_index: index as i64,
            attachment_sha256,
            original_filename: original_filename.clone(),
            safe_filename: safe_name,
            extension,
            mime_type: mime_type.clone(),
            size_bytes,
            is_inline_artifact: extracted.is_inline_image
                || looks_like_inline_artifact(&original_filename, &mime_type, metadata.len()),
            blob_relpath: Some(blob_relpath),
            source_message_sha256: Some(source_message_sha256.to_string()),
            last_verified_at: Some(now.clone()),
            created_at: now.clone(),
            updated_at: now.clone(),
            last_seen_at: now.clone(),
        };
        attachments.push((attachment_record, extracted.path));
    }

    Ok((extraction_dir, attachments))
}

pub(super) fn load_attachment_messages_for_account(
    connection: &Connection,
    account_id: i64,
) -> Result<Vec<AttachmentMessageRecord>, String> {
    let mut statement = connection
        .prepare(
            r#"
            SELECT
                account_id,
                message_key,
                message_relpath,
                message_mtime,
                message_size,
                subject,
                sender,
                timestamp,
                last_scanned_at,
                has_attachments
            FROM attachment_messages
            WHERE account_id = ?1
            "#,
        )
        .map_err(|error| format!("failed to prepare attachment message query: {error}"))?;
    let rows = statement
        .query_map(params![account_id], |row| {
            Ok(AttachmentMessageRecord {
                account_id: row.get(0)?,
                message_key: row.get(1)?,
                message_relpath: row.get(2)?,
                message_mtime: row.get(3)?,
                message_size: row.get(4)?,
                subject: row.get(5)?,
                from: row.get(6)?,
                timestamp: row.get(7)?,
                last_scanned_at: row.get(8)?,
                has_attachments: row.get::<_, i64>(9)? != 0,
            })
        })
        .map_err(|error| format!("failed to query attachment messages: {error}"))?;

    rows.collect::<Result<Vec<_>, _>>()
        .map_err(|error| format!("failed to decode attachment messages: {error}"))
}

pub(super) fn refresh_attachment_catalog(
    config: &AppConfig,
    account: &AccountRecord,
) -> Result<(), String> {
    let account_paths = ensure_account_paths(config, account)?;
    if account_index_state(&account_paths) != IndexState::Indexed {
        return Ok(());
    }

    let mut connection = open_db(config)?;
    let existing_messages = load_attachment_messages_for_account(&connection, account.id)?;
    let existing_by_relpath = existing_messages
        .iter()
        .map(|record| (record.message_relpath.clone(), record.clone()))
        .collect::<HashMap<_, _>>();
    let message_files = list_notmuch_message_files(&account_paths, "*")?;
    let mut seen_relpaths = HashSet::new();
    let mut seen_message_keys = HashSet::new();

    for message_path in message_files {
        let relpath = message_relative_path(&account_paths, &message_path)?
            .to_string_lossy()
            .to_string();
        let metadata = fs::metadata(&message_path)
            .map_err(|error| format!("failed to inspect {}: {error}", message_path.display()))?;
        let message_mtime = metadata.mtime();
        let message_size = i64::try_from(metadata.size())
            .map_err(|_| format!("message {} is too large to catalog", message_path.display()))?;
        let message_metadata = read_message_metadata(&message_path)?;
        let message_key = message_key_from_metadata(&message_metadata)?;
        let source_message_sha256 = sha256_file(&message_path)?;

        if !seen_message_keys.insert(message_key.clone()) {
            continue;
        }
        seen_relpaths.insert(relpath.clone());

        if existing_by_relpath.get(&relpath).is_some_and(|record| {
            record.message_key == message_key
                && record.message_mtime == message_mtime
                && record.message_size == message_size
        }) {
            continue;
        }

        let (_extraction_dir, scanned_attachments) = scan_message_attachments_for_catalog(
            config,
            &account_paths,
            account.id,
            &message_key,
            &message_path,
            &source_message_sha256,
        )?;
        let now = Utc::now().to_rfc3339();
        let transaction = connection
            .transaction()
            .map_err(|error| format!("failed to start attachment refresh transaction: {error}"))?;

        if let Some(existing) = existing_by_relpath.get(&relpath) {
            transaction
                .execute(
                    "DELETE FROM attachment_catalog WHERE account_id = ?1 AND message_key = ?2",
                    params![account.id, existing.message_key],
                )
                .map_err(|error| format!("failed to clear stale attachment rows: {error}"))?;
        }
        transaction
            .execute(
                "DELETE FROM attachment_catalog WHERE account_id = ?1 AND message_key = ?2",
                params![account.id, message_key],
            )
            .map_err(|error| format!("failed to replace attachment rows: {error}"))?;
        transaction
            .execute(
                "DELETE FROM attachment_messages WHERE account_id = ?1 AND (message_relpath = ?2 OR message_key = ?3)",
                params![account.id, relpath, message_key],
            )
            .map_err(|error| format!("failed to replace attachment message row: {error}"))?;
        transaction
            .execute(
                r#"
                INSERT INTO attachment_messages (
                    account_id,
                    message_key,
                    message_relpath,
                    message_mtime,
                    message_size,
                    subject,
                    sender,
                    timestamp,
                    last_scanned_at,
                    has_attachments
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
                "#,
                params![
                    account.id,
                    message_key,
                    relpath,
                    message_mtime,
                    message_size,
                    message_metadata.subject,
                    message_metadata.from,
                    message_metadata.timestamp,
                    now,
                    if scanned_attachments.is_empty() { 0 } else { 1 },
                ],
            )
            .map_err(|error| format!("failed to store attachment message row: {error}"))?;

        for (attachment, _) in scanned_attachments {
            transaction
                .execute(
                    r#"
                    INSERT INTO attachment_catalog (
                        attachment_key,
                        account_id,
                        message_key,
                        attachment_index,
                        attachment_sha256,
                        original_filename,
                        safe_filename,
                        extension,
                        mime_type,
                        size_bytes,
                        is_inline_artifact,
                        blob_relpath,
                        source_message_sha256,
                        last_verified_at,
                        created_at,
                        updated_at,
                        last_seen_at
                    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17)
                    "#,
                    params![
                        attachment.attachment_key,
                        attachment.account_id,
                        attachment.message_key,
                        attachment.attachment_index,
                        attachment.attachment_sha256,
                        attachment.original_filename,
                        attachment.safe_filename,
                        attachment.extension,
                        attachment.mime_type,
                        attachment.size_bytes,
                        if attachment.is_inline_artifact { 1 } else { 0 },
                        attachment.blob_relpath,
                        attachment.source_message_sha256,
                        attachment.last_verified_at,
                        attachment.created_at,
                        attachment.updated_at,
                        attachment.last_seen_at,
                    ],
                )
                .map_err(|error| format!("failed to store attachment catalog row: {error}"))?;
        }

        transaction
            .commit()
            .map_err(|error| format!("failed to commit attachment refresh transaction: {error}"))?;
    }

    let stale_messages = existing_messages
        .into_iter()
        .filter(|message| !seen_relpaths.contains(&message.message_relpath))
        .collect::<Vec<_>>();
    if !stale_messages.is_empty() {
        let transaction = connection
            .transaction()
            .map_err(|error| format!("failed to start stale attachment cleanup: {error}"))?;
        for stale in stale_messages {
            transaction
                .execute(
                    "DELETE FROM attachment_catalog WHERE account_id = ?1 AND message_key = ?2",
                    params![account.id, stale.message_key],
                )
                .map_err(|error| {
                    format!("failed to delete stale attachment catalog rows: {error}")
                })?;
            transaction
                .execute(
                    "DELETE FROM attachment_messages WHERE account_id = ?1 AND message_key = ?2",
                    params![account.id, stale.message_key],
                )
                .map_err(|error| {
                    format!("failed to delete stale attachment message row: {error}")
                })?;
        }
        transaction
            .commit()
            .map_err(|error| format!("failed to commit stale attachment cleanup: {error}"))?;
    }

    Ok(())
}

pub(super) fn refresh_attachment_catalog_for_user(
    config: &AppConfig,
    username: &str,
    selected_account_id: Option<i64>,
) -> Result<(), String> {
    let accounts = list_accounts_for_user(config, username)?;
    for account in accounts
        .into_iter()
        .filter(|account| selected_account_id.is_none_or(|selected| selected == account.id))
    {
        refresh_attachment_catalog(config, &account)?;
    }
    Ok(())
}
pub(super) fn load_attachment_catalog_rows_for_account(
    connection: &Connection,
    account_id: i64,
) -> Result<Vec<(AttachmentMessageRecord, AttachmentRecord)>, String> {
    let mut statement = connection
        .prepare(
            r#"
            SELECT
                m.account_id,
                m.message_key,
                m.message_relpath,
                m.message_mtime,
                m.message_size,
                m.subject,
                m.sender,
                m.timestamp,
                m.last_scanned_at,
                m.has_attachments,
                c.attachment_key,
                c.account_id,
                c.message_key,
                c.attachment_index,
                c.attachment_sha256,
                c.original_filename,
                c.safe_filename,
                c.extension,
                c.mime_type,
                c.size_bytes,
                c.is_inline_artifact,
                c.blob_relpath,
                c.source_message_sha256,
                c.last_verified_at,
                c.created_at,
                c.updated_at,
                c.last_seen_at
            FROM attachment_catalog c
            INNER JOIN attachment_messages m
                ON m.account_id = c.account_id
               AND m.message_key = c.message_key
            WHERE c.account_id = ?1
            ORDER BY m.timestamp DESC, c.attachment_index ASC
            "#,
        )
        .map_err(|error| format!("failed to prepare attachment catalog query: {error}"))?;
    let rows = statement
        .query_map(params![account_id], |row| {
            Ok((
                AttachmentMessageRecord {
                    account_id: row.get(0)?,
                    message_key: row.get(1)?,
                    message_relpath: row.get(2)?,
                    message_mtime: row.get(3)?,
                    message_size: row.get(4)?,
                    subject: row.get(5)?,
                    from: row.get(6)?,
                    timestamp: row.get(7)?,
                    last_scanned_at: row.get(8)?,
                    has_attachments: row.get::<_, i64>(9)? != 0,
                },
                AttachmentRecord {
                    attachment_key: row.get(10)?,
                    account_id: row.get(11)?,
                    message_key: row.get(12)?,
                    attachment_index: row.get(13)?,
                    attachment_sha256: row.get(14)?,
                    original_filename: row.get(15)?,
                    safe_filename: row.get(16)?,
                    extension: row.get(17)?,
                    mime_type: row.get(18)?,
                    size_bytes: row.get(19)?,
                    is_inline_artifact: row.get::<_, i64>(20)? != 0,
                    blob_relpath: row.get(21)?,
                    source_message_sha256: row.get(22)?,
                    last_verified_at: row.get(23)?,
                    created_at: row.get(24)?,
                    updated_at: row.get(25)?,
                    last_seen_at: row.get(26)?,
                },
            ))
        })
        .map_err(|error| format!("failed to query attachment catalog rows: {error}"))?;

    rows.collect::<Result<Vec<_>, _>>()
        .map_err(|error| format!("failed to decode attachment catalog rows: {error}"))
}

pub(super) fn message_catalog_has_attachments(
    connection: &Connection,
    account_id: i64,
    message_key: &str,
) -> Result<bool, String> {
    connection
        .query_row(
            "SELECT has_attachments FROM attachment_messages WHERE account_id = ?1 AND message_key = ?2 LIMIT 1",
            params![account_id, message_key],
            |row| row.get::<_, i64>(0),
        )
        .optional()
        .map_err(|error| format!("failed to query attachment message state: {error}"))
        .map(|value| value.unwrap_or(0) != 0)
}

pub(super) fn parse_page_number(raw: Option<&str>) -> usize {
    raw.and_then(|value| value.trim().parse::<usize>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(1)
}

pub(super) fn optional_trimmed(raw: Option<&String>) -> String {
    raw.map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_default()
}

pub(super) fn parse_query_bool(raw: Option<&str>) -> Result<Option<bool>, String> {
    match raw.map(str::trim).filter(|value| !value.is_empty()) {
        Some(value) => match value.to_ascii_lowercase().as_str() {
            "1" | "true" | "yes" | "on" => Ok(Some(true)),
            "0" | "false" | "no" | "off" => Ok(Some(false)),
            _ => Err(format!("invalid boolean query value '{value}'")),
        },
        None => Ok(None),
    }
}

pub(super) fn query_bool_is_true(raw: Option<&str>) -> bool {
    matches!(parse_query_bool(raw).ok().flatten(), Some(true))
}

pub(super) fn parse_optional_usize(
    raw: Option<&str>,
    label: &str,
) -> Result<Option<usize>, String> {
    match raw.map(str::trim).filter(|value| !value.is_empty()) {
        Some(value) => value
            .parse::<usize>()
            .map(Some)
            .map_err(|error| format!("invalid {label} '{value}': {error}")),
        None => Ok(None),
    }
}

pub(super) fn parse_optional_nonnegative_i64(
    raw: Option<&str>,
    label: &str,
) -> Result<Option<i64>, String> {
    match parse_optional_query_i64(raw)? {
        Some(value) if value < 0 => Err(format!("{label} cannot be negative")),
        value => Ok(value),
    }
}

pub(super) fn parse_date_start(raw: &str, label: &str) -> Result<Option<i64>, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Ok(None);
    }
    NaiveDate::parse_from_str(trimmed, "%Y-%m-%d")
        .map_err(|error| format!("invalid {label} date '{trimmed}': {error}"))?
        .and_hms_opt(0, 0, 0)
        .and_then(|value| value.and_local_timezone(Utc).single())
        .map(|value| value.timestamp())
        .ok_or_else(|| format!("invalid {label} date '{trimmed}'"))
        .map(Some)
}

pub(super) fn parse_date_end(raw: &str, label: &str) -> Result<Option<i64>, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Ok(None);
    }
    NaiveDate::parse_from_str(trimmed, "%Y-%m-%d")
        .map_err(|error| format!("invalid {label} date '{trimmed}': {error}"))?
        .and_hms_opt(23, 59, 59)
        .and_then(|value| value.and_local_timezone(Utc).single())
        .map(|value| value.timestamp())
        .ok_or_else(|| format!("invalid {label} date '{trimmed}'"))
        .map(Some)
}

pub(super) fn message_filters_from_search_params(
    params: &SearchParams,
    fallback_query: String,
) -> MessageSearchFilters {
    MessageSearchFilters {
        q: optional_trimmed(params.q.as_ref()).if_empty_then(fallback_query),
        sender_address: optional_trimmed(params.sender_address.as_ref()),
        sender_name: optional_trimmed(params.sender_name.as_ref()),
        sender_domain: optional_trimmed(params.sender_domain.as_ref()),
        subject: optional_trimmed(params.subject.as_ref()),
        body_text: optional_trimmed(params.body_text.as_ref()),
        date_from: optional_trimmed(params.date_from.as_ref()),
        date_to: optional_trimmed(params.date_to.as_ref()),
        has_attachments: parse_query_bool(params.has_attachments.as_deref())
            .ok()
            .flatten(),
    }
}

trait EmptyStringFallback {
    fn if_empty_then(self, fallback: String) -> String;
}

impl EmptyStringFallback for String {
    fn if_empty_then(self, fallback: String) -> String {
        if self.is_empty() {
            fallback
        } else {
            self
        }
    }
}

pub(super) fn message_filters_from_attachment_params(
    params: &AttachmentListParams,
) -> MessageSearchFilters {
    MessageSearchFilters {
        q: optional_trimmed(params.q.as_ref()),
        sender_address: optional_trimmed(params.sender_address.as_ref()),
        sender_name: optional_trimmed(params.sender_name.as_ref()),
        sender_domain: optional_trimmed(params.sender_domain.as_ref()),
        subject: optional_trimmed(params.subject.as_ref()),
        body_text: optional_trimmed(params.body_text.as_ref()),
        date_from: optional_trimmed(params.date_from.as_ref()),
        date_to: optional_trimmed(params.date_to.as_ref()),
        has_attachments: None,
    }
}

pub(super) fn message_filters_without_general_query(
    filters: &MessageSearchFilters,
) -> MessageSearchFilters {
    let mut structured = filters.clone();
    structured.q.clear();
    structured
}

pub(super) fn attachment_filters_from_params(
    params: &AttachmentListParams,
) -> AttachmentSearchFilters {
    let custom_extension = optional_trimmed(params.extension_custom.as_ref()).to_ascii_lowercase();
    let extension = if custom_extension.is_empty() {
        optional_trimmed(params.extension.as_ref()).to_ascii_lowercase()
    } else {
        custom_extension
    };
    AttachmentSearchFilters {
        message: message_filters_from_attachment_params(params),
        extension,
        attachment_name: optional_trimmed(params.attachment_name.as_ref()),
        mime_type: String::new(),
        min_size: optional_trimmed(params.min_size.as_ref()),
        max_size: optional_trimmed(params.max_size.as_ref()),
        min_attachments: String::new(),
        max_attachments: String::new(),
    }
}

pub(super) fn attachment_params_from_preset_form(
    form: &AttachmentPresetSaveForm,
) -> Result<AttachmentListParams, String> {
    Ok(AttachmentListParams {
        q: form.q.clone(),
        account_id: parse_optional_query_i64(form.account_id.as_deref())?,
        priority: form.priority.clone(),
        sender_address: form.sender_address.clone(),
        sender_name: form.sender_name.clone(),
        sender_domain: form.sender_domain.clone(),
        subject: form.subject.clone(),
        body_text: form.body_text.clone(),
        date_from: form.date_from.clone(),
        date_to: form.date_to.clone(),
        has_attachments: form.has_attachments.clone(),
        extension: form.extension.clone(),
        extension_custom: None,
        attachment_name: form.attachment_name.clone(),
        mime_type: form.mime_type.clone(),
        min_size: form.min_size.clone(),
        max_size: form.max_size.clone(),
        min_attachments: form.min_attachments.clone(),
        max_attachments: form.max_attachments.clone(),
        include_inline: form.include_inline.clone(),
        include_inline_images: form.include_inline_images.clone(),
        show_mime_details: form.show_mime_details.clone(),
        download_subfolder: form.download_subfolder.clone(),
        page: None,
        flash: None,
        error: None,
    })
}

pub(super) fn attachment_params_from_paperless_task_form(
    form: &AttachmentPaperlessTaskSaveForm,
) -> Result<AttachmentListParams, String> {
    Ok(AttachmentListParams {
        q: form.q.clone(),
        account_id: parse_optional_query_i64(form.account_id.as_deref())?,
        priority: form.priority.clone(),
        sender_address: form.sender_address.clone(),
        sender_name: form.sender_name.clone(),
        sender_domain: form.sender_domain.clone(),
        subject: form.subject.clone(),
        body_text: form.body_text.clone(),
        date_from: form.date_from.clone(),
        date_to: form.date_to.clone(),
        has_attachments: form.has_attachments.clone(),
        extension: form.extension.clone(),
        extension_custom: None,
        attachment_name: form.attachment_name.clone(),
        mime_type: form.mime_type.clone(),
        min_size: form.min_size.clone(),
        max_size: form.max_size.clone(),
        min_attachments: form.min_attachments.clone(),
        max_attachments: form.max_attachments.clone(),
        include_inline: form.include_inline.clone(),
        include_inline_images: form.include_inline_images.clone(),
        show_mime_details: form.show_mime_details.clone(),
        download_subfolder: form.download_subfolder.clone(),
        page: None,
        flash: None,
        error: None,
    })
}

pub(super) fn attachment_params_from_query(query: &str) -> Result<AttachmentListParams, String> {
    let mut params = AttachmentListParams::default();
    for (key, value) in form_urlencoded::parse(query.as_bytes()) {
        let value = value.into_owned();
        match key.as_ref() {
            "q" => params.q = Some(value),
            "account_id" => params.account_id = parse_optional_query_i64(Some(&value))?,
            "priority" => params.priority = Some(value),
            "sender_address" => params.sender_address = Some(value),
            "sender_name" => params.sender_name = Some(value),
            "sender_domain" => params.sender_domain = Some(value),
            "subject" => params.subject = Some(value),
            "body_text" => params.body_text = Some(value),
            "date_from" => params.date_from = Some(value),
            "date_to" => params.date_to = Some(value),
            "has_attachments" => params.has_attachments = Some(value),
            "extension" => params.extension = Some(value),
            "extension_custom" => params.extension_custom = Some(value),
            "attachment_name" => params.attachment_name = Some(value),
            "mime_type" => params.mime_type = Some(value),
            "min_size" => params.min_size = Some(value),
            "max_size" => params.max_size = Some(value),
            "min_attachments" => params.min_attachments = Some(value),
            "max_attachments" => params.max_attachments = Some(value),
            "include_inline" => params.include_inline = Some(value),
            "include_inline_images" => params.include_inline_images = Some(value),
            "show_mime_details" => params.show_mime_details = Some(value),
            "download_subfolder" => params.download_subfolder = Some(value),
            _ => {}
        }
    }
    Ok(params)
}

pub(super) fn parse_message_search_filters(
    filters: MessageSearchFilters,
) -> Result<ParsedMessageSearchFilters, String> {
    let normalized_sender_address = if filters.sender_address.trim().is_empty() {
        None
    } else {
        Some(
            normalize_sender_address(&filters.sender_address)
                .map(|identity| identity.address)
                .ok_or_else(|| "Sender address must be a valid email address.".to_string())?,
        )
    };
    let normalized_sender_domain = if filters.sender_domain.trim().is_empty() {
        None
    } else {
        Some(
            normalize_sender_domain(&filters.sender_domain)
                .ok_or_else(|| "Sender domain must be a valid mail domain.".to_string())?,
        )
    };
    let date_from_timestamp = parse_date_start(&filters.date_from, "from")?;
    let date_to_timestamp = parse_date_end(&filters.date_to, "to")?;
    if let (Some(from), Some(to)) = (date_from_timestamp, date_to_timestamp) {
        if from > to {
            return Err("Date from must be before date to.".to_string());
        }
    }

    Ok(ParsedMessageSearchFilters {
        raw: filters,
        normalized_sender_address,
        normalized_sender_domain,
        date_from_timestamp,
        date_to_timestamp,
    })
}

pub(super) fn parse_attachment_search_filters(
    filters: AttachmentSearchFilters,
) -> Result<ParsedAttachmentSearchFilters, String> {
    parse_message_search_filters(filters.message.clone())?;
    let min_size_bytes = parse_optional_nonnegative_i64(Some(&filters.min_size), "minimum size")?;
    let max_size_bytes = parse_optional_nonnegative_i64(Some(&filters.max_size), "maximum size")?;
    if let (Some(min), Some(max)) = (min_size_bytes, max_size_bytes) {
        if min > max {
            return Err("Minimum size must be less than or equal to maximum size.".to_string());
        }
    }
    let min_attachment_count =
        parse_optional_usize(Some(&filters.min_attachments), "minimum attachment count")?;
    let max_attachment_count =
        parse_optional_usize(Some(&filters.max_attachments), "maximum attachment count")?;
    if let (Some(min), Some(max)) = (min_attachment_count, max_attachment_count) {
        if min > max {
            return Err(
                "Minimum attachment count must be less than or equal to maximum attachment count."
                    .to_string(),
            );
        }
    }

    Ok(ParsedAttachmentSearchFilters {
        raw: filters,
        min_size_bytes,
        max_size_bytes,
        min_attachment_count,
        max_attachment_count,
    })
}

pub(super) fn notmuch_quote(value: &str) -> String {
    format!(
        "\"{}\"",
        value.replace('\\', "\\\\").replace('"', "\\\"").trim()
    )
}

pub(super) fn notmuch_query_for_filters(filters: &ParsedMessageSearchFilters) -> String {
    let mut terms = Vec::new();
    if !filters.raw.q.trim().is_empty() {
        terms.push(filters.raw.q.trim().to_string());
    }
    if let Some(address) = filters.normalized_sender_address.as_deref() {
        terms.push(format!("from:{}", notmuch_quote(address)));
    }
    if !filters.raw.sender_name.trim().is_empty() {
        terms.push(format!("from:{}", notmuch_quote(&filters.raw.sender_name)));
    }
    if let Some(domain) = filters.normalized_sender_domain.as_deref() {
        terms.push(format!("from:{}", notmuch_quote(domain)));
    }
    if !filters.raw.subject.trim().is_empty() {
        terms.push(format!("subject:{}", notmuch_quote(&filters.raw.subject)));
    }
    if !filters.raw.body_text.trim().is_empty() {
        terms.push(notmuch_quote(&filters.raw.body_text));
    }
    if terms.is_empty() {
        "*".to_string()
    } else {
        terms.join(" ")
    }
}

pub(super) fn message_matches_filters(
    metadata: &LiveMessageRecord,
    filters: &ParsedMessageSearchFilters,
    has_attachments: Option<bool>,
) -> bool {
    if let Some(from_timestamp) = filters.date_from_timestamp {
        if metadata.timestamp < from_timestamp {
            return false;
        }
    }
    if let Some(to_timestamp) = filters.date_to_timestamp {
        if metadata.timestamp > to_timestamp {
            return false;
        }
    }
    if let Some(expected) = filters.normalized_sender_address.as_deref() {
        if sender_identity_from_header(&metadata.from)
            .is_none_or(|identity| identity.address != expected)
        {
            return false;
        }
    }
    if let Some(expected) = filters.normalized_sender_domain.as_deref() {
        if sender_identity_from_header(&metadata.from)
            .is_none_or(|identity| identity.domain != expected)
        {
            return false;
        }
    }
    if !filters.raw.sender_name.trim().is_empty() {
        let needle = filters.raw.sender_name.to_ascii_lowercase();
        let display = sender_display_from_header(&metadata.from);
        if !display.primary.to_ascii_lowercase().contains(&needle)
            && !metadata.from.to_ascii_lowercase().contains(&needle)
        {
            return false;
        }
    }
    if !filters.raw.subject.trim().is_empty()
        && !metadata
            .subject
            .to_ascii_lowercase()
            .contains(&filters.raw.subject.to_ascii_lowercase())
    {
        return false;
    }
    if let Some(expected) = filters.raw.has_attachments {
        if has_attachments != Some(expected) {
            return false;
        }
    }
    true
}

pub(super) fn attachment_matches_filters(
    item: &AttachmentListItem,
    filters: &ParsedAttachmentSearchFilters,
    attachment_count: usize,
) -> bool {
    if !filters.raw.extension.is_empty() && item.attachment.extension != filters.raw.extension {
        return false;
    }
    if !filters.raw.attachment_name.is_empty()
        && !item
            .attachment
            .original_filename
            .to_ascii_lowercase()
            .contains(&filters.raw.attachment_name.to_ascii_lowercase())
    {
        return false;
    }
    if !filters.raw.mime_type.is_empty()
        && !item
            .attachment
            .mime_type
            .to_ascii_lowercase()
            .contains(&filters.raw.mime_type)
    {
        return false;
    }
    if let Some(min_size) = filters.min_size_bytes {
        if item.attachment.size_bytes < min_size {
            return false;
        }
    }
    if let Some(max_size) = filters.max_size_bytes {
        if item.attachment.size_bytes > max_size {
            return false;
        }
    }
    if let Some(min_count) = filters.min_attachment_count {
        if attachment_count < min_count {
            return false;
        }
    }
    if let Some(max_count) = filters.max_attachment_count {
        if attachment_count > max_count {
            return false;
        }
    }
    true
}

pub(super) fn attachment_general_query_matches(
    item: &AttachmentListItem,
    query: &str,
    message_body_match: bool,
) -> bool {
    if message_body_match {
        return true;
    }
    let needle = query.trim().to_ascii_lowercase();
    if needle.is_empty() {
        return true;
    }
    let subject = decode_display_header_value(&item.message.subject);
    let sender = decode_display_header_value(&item.message.from);
    [
        item.attachment.original_filename.as_str(),
        item.attachment.safe_filename.as_str(),
        item.attachment.extension.as_str(),
        item.attachment.mime_type.as_str(),
        item.account_name.as_str(),
        subject.as_str(),
        sender.as_str(),
    ]
    .iter()
    .any(|value| value.to_ascii_lowercase().contains(&needle))
}

pub(super) fn build_attachment_base_query(state: AttachmentBaseQuery<'_>) -> String {
    let mut pairs = Vec::new();
    append_message_filter_query_pairs(&mut pairs, &state.filters.message);
    if let Some(account_id) = state.selected_account_id {
        pairs.push(("account_id", account_id.to_string()));
    }
    if state.priority_filter != SenderPriorityFilter::All {
        pairs.push((
            "priority",
            state.priority_filter.as_query_value().to_string(),
        ));
    }
    append_attachment_filter_query_pairs(&mut pairs, state.filters);
    if state.include_inline {
        pairs.push(("include_inline", "1".to_string()));
    }
    if state.include_inline_images {
        pairs.push(("include_inline_images", "1".to_string()));
    }
    if state.show_mime_details {
        pairs.push(("show_mime_details", "1".to_string()));
    }
    if !state.download_subfolder.trim().is_empty() {
        pairs.push((
            "download_subfolder",
            state.download_subfolder.trim().to_string(),
        ));
    }
    pairs
        .into_iter()
        .map(|(key, value)| format!("{key}={}", url_encode_component(&value)))
        .collect::<Vec<_>>()
        .join("&")
}

pub(super) fn attachment_preset_query_from_form(
    form: &AttachmentPresetSaveForm,
) -> Result<String, String> {
    let params = attachment_params_from_preset_form(form)?;
    let filters = attachment_filters_from_params(&params);
    let parsed_filters = parse_attachment_search_filters(filters)?;
    let priority_filter = SenderPriorityFilter::from_query(params.priority.as_deref());
    let include_inline = query_bool_is_true(params.include_inline.as_deref());
    let include_inline_images = query_bool_is_true(params.include_inline_images.as_deref());
    let show_mime_details = query_bool_is_true(params.show_mime_details.as_deref());
    let download_subfolder =
        normalize_download_subfolder(params.download_subfolder.as_deref().unwrap_or_default())?;

    Ok(build_attachment_base_query(AttachmentBaseQuery {
        filters: &parsed_filters.raw,
        selected_account_id: params.account_id,
        priority_filter,
        include_inline,
        include_inline_images,
        show_mime_details,
        download_subfolder: &download_subfolder,
    }))
}

pub(super) fn attachment_paperless_task_query_from_form(
    form: &AttachmentPaperlessTaskSaveForm,
) -> Result<String, String> {
    let params = attachment_params_from_paperless_task_form(form)?;
    let filters = attachment_filters_from_params(&params);
    let parsed_filters = parse_attachment_search_filters(filters)?;
    let priority_filter = SenderPriorityFilter::from_query(params.priority.as_deref());
    let include_inline = query_bool_is_true(params.include_inline.as_deref());
    let include_inline_images = query_bool_is_true(params.include_inline_images.as_deref());
    let show_mime_details = query_bool_is_true(params.show_mime_details.as_deref());
    let download_subfolder =
        normalize_download_subfolder(params.download_subfolder.as_deref().unwrap_or_default())?;

    Ok(build_attachment_base_query(AttachmentBaseQuery {
        filters: &parsed_filters.raw,
        selected_account_id: params.account_id,
        priority_filter,
        include_inline,
        include_inline_images,
        show_mime_details,
        download_subfolder: &download_subfolder,
    }))
}

pub(super) fn append_message_filter_query_pairs(
    pairs: &mut Vec<(&'static str, String)>,
    filters: &MessageSearchFilters,
) {
    for (key, value) in [
        ("q", filters.q.trim()),
        ("sender_address", filters.sender_address.trim()),
        ("sender_name", filters.sender_name.trim()),
        ("sender_domain", filters.sender_domain.trim()),
        ("subject", filters.subject.trim()),
        ("body_text", filters.body_text.trim()),
        ("date_from", filters.date_from.trim()),
        ("date_to", filters.date_to.trim()),
    ] {
        if !value.is_empty() {
            pairs.push((key, value.to_string()));
        }
    }
    if let Some(value) = filters.has_attachments {
        pairs.push(("has_attachments", if value { "1" } else { "0" }.to_string()));
    }
}

pub(super) fn append_attachment_filter_query_pairs(
    pairs: &mut Vec<(&'static str, String)>,
    filters: &AttachmentSearchFilters,
) {
    for (key, value) in [
        ("extension", filters.extension.trim()),
        ("attachment_name", filters.attachment_name.trim()),
        ("min_size", filters.min_size.trim()),
        ("max_size", filters.max_size.trim()),
    ] {
        if !value.is_empty() {
            pairs.push((key, value.to_string()));
        }
    }
}

pub(super) fn message_filters_have_terms(filters: &MessageSearchFilters) -> bool {
    [
        filters.q.as_str(),
        filters.sender_address.as_str(),
        filters.sender_name.as_str(),
        filters.sender_domain.as_str(),
        filters.subject.as_str(),
        filters.body_text.as_str(),
        filters.date_from.as_str(),
        filters.date_to.as_str(),
    ]
    .iter()
    .any(|value| !value.trim().is_empty())
        || filters.has_attachments.is_some()
}

pub(super) fn normalize_attachment_preset_name(raw: &str) -> Result<String, String> {
    let name = raw.split_whitespace().collect::<Vec<_>>().join(" ");
    if name.is_empty() {
        return Err("Preset name is required.".to_string());
    }
    if name.chars().count() > 80 {
        return Err("Preset name must be 80 characters or fewer.".to_string());
    }
    Ok(name)
}

pub(super) fn list_attachment_filter_presets(
    config: &AppConfig,
    username: &str,
) -> Result<Vec<AttachmentFilterPreset>, String> {
    let connection = open_db(config)?;
    let mut statement = connection
        .prepare(
            r#"
            SELECT id, name, query
            FROM attachment_filter_presets
            WHERE username = ?1
            ORDER BY lower(name), name
            "#,
        )
        .map_err(|error| format!("failed to load attachment filter presets: {error}"))?;
    let rows = statement
        .query_map(params![username], |row| {
            Ok(AttachmentFilterPreset {
                id: row.get(0)?,
                name: row.get(1)?,
                query: row.get(2)?,
            })
        })
        .map_err(|error| format!("failed to read attachment filter presets: {error}"))?;
    rows.collect::<Result<Vec<_>, _>>()
        .map_err(|error| format!("failed to decode attachment filter preset: {error}"))
}

pub(super) fn save_attachment_filter_preset_for_user(
    config: &AppConfig,
    username: &str,
    form: &AttachmentPresetSaveForm,
) -> Result<AttachmentFilterPreset, String> {
    let name = normalize_attachment_preset_name(&form.preset_name)?;
    let query = attachment_preset_query_from_form(form)?;
    if query.trim().is_empty() {
        return Err("Add at least one attachment filter before saving a preset.".to_string());
    }

    let now = Utc::now().to_rfc3339();
    let connection = open_db(config)?;
    connection
        .execute(
            r#"
            INSERT INTO attachment_filter_presets (username, name, query, created_at, updated_at)
            VALUES (?1, ?2, ?3, ?4, ?4)
            ON CONFLICT(username, name) DO UPDATE SET
                query = excluded.query,
                updated_at = excluded.updated_at
            "#,
            params![username, name, query, now],
        )
        .map_err(|error| format!("failed to save attachment filter preset: {error}"))?;
    connection
        .execute(
            r#"
            UPDATE attachment_paperless_tasks
            SET query = ?3,
                updated_at = ?4
            WHERE username = ?1 AND name = ?2
            "#,
            params![username, name, query, now],
        )
        .map_err(|error| format!("failed to update linked Paperless task: {error}"))?;

    connection
        .query_row(
            r#"
            SELECT id, name, query
            FROM attachment_filter_presets
            WHERE username = ?1 AND name = ?2
            LIMIT 1
            "#,
            params![username, name],
            |row| {
                Ok(AttachmentFilterPreset {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    query: row.get(2)?,
                })
            },
        )
        .map_err(|error| format!("failed to reload attachment filter preset: {error}"))
}

pub(super) fn delete_attachment_filter_preset_for_user(
    config: &AppConfig,
    username: &str,
    preset_id: i64,
) -> Result<(), String> {
    let mut connection = open_db(config)?;
    let preset_name = connection
        .query_row(
            "SELECT name FROM attachment_filter_presets WHERE username = ?1 AND id = ?2 LIMIT 1",
            params![username, preset_id],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .map_err(|error| format!("failed to load attachment filter preset: {error}"))?
        .ok_or_else(|| "Attachment filter preset was not found.".to_string())?;

    let transaction = connection
        .transaction()
        .map_err(|error| format!("failed to begin preset delete transaction: {error}"))?;
    let deleted = transaction
        .execute(
            "DELETE FROM attachment_filter_presets WHERE username = ?1 AND id = ?2",
            params![username, preset_id],
        )
        .map_err(|error| format!("failed to delete attachment filter preset: {error}"))?;
    if deleted == 0 {
        return Err("Attachment filter preset was not found.".to_string());
    }
    transaction
        .execute(
            "DELETE FROM attachment_paperless_tasks WHERE username = ?1 AND name = ?2",
            params![username, preset_name],
        )
        .map_err(|error| format!("failed to delete linked Paperless task: {error}"))?;
    transaction
        .commit()
        .map_err(|error| format!("failed to commit preset delete: {error}"))?;
    Ok(())
}

pub(super) fn normalize_daily_schedule_time(raw: &str) -> Result<String, String> {
    let trimmed = raw.trim();
    let time = NaiveTime::parse_from_str(trimmed, "%H:%M")
        .map_err(|_| "Schedule time must use HH:MM format.".to_string())?;
    Ok(time.format("%H:%M").to_string())
}

pub(super) fn normalize_paperless_schedule(
    mode: Option<&str>,
    interval_minutes: Option<&str>,
) -> Result<(String, i64), String> {
    match mode.unwrap_or("daily").trim() {
        "daily" => Ok(("daily".to_string(), 24 * 60)),
        "interval" => {
            let minutes = interval_minutes
                .unwrap_or("60")
                .trim()
                .parse::<i64>()
                .map_err(|_| "Repeat interval must be a whole number of minutes.".to_string())?;
            if !(MIN_PAPERLESS_TASK_INTERVAL_MINUTES..=MAX_PAPERLESS_TASK_INTERVAL_MINUTES)
                .contains(&minutes)
            {
                return Err(format!(
                    "Repeat interval must be between {MIN_PAPERLESS_TASK_INTERVAL_MINUTES} and {MAX_PAPERLESS_TASK_INTERVAL_MINUTES} minutes."
                ));
            }
            Ok(("interval".to_string(), minutes))
        }
        _ => Err("Schedule mode must be daily or repeating.".to_string()),
    }
}

pub(super) fn normalize_paperless_task_max_attachments(raw: Option<&str>) -> Result<usize, String> {
    let trimmed = raw.unwrap_or("").trim();
    let value = if trimmed.is_empty() {
        DEFAULT_PAPERLESS_TASK_MAX_ATTACHMENTS
    } else {
        trimmed
            .parse::<usize>()
            .map_err(|_| "Maximum attachments per run must be a whole number.".to_string())?
    };
    if !(1..=MAX_PAPERLESS_TASK_ATTACHMENTS).contains(&value) {
        return Err(format!(
            "Maximum attachments per run must be between 1 and {MAX_PAPERLESS_TASK_ATTACHMENTS}."
        ));
    }
    Ok(value)
}

pub(super) fn map_attachment_paperless_task(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<AttachmentPaperlessTask> {
    Ok(AttachmentPaperlessTask {
        id: row.get(0)?,
        username: row.get(1)?,
        name: row.get(2)?,
        query: row.get(3)?,
        schedule_time: row.get(4)?,
        schedule_mode: row.get(5)?,
        interval_minutes: row.get(6)?,
        max_attachments: row.get(7)?,
        retry_enabled: row.get::<_, i64>(8)? != 0,
        enabled: row.get::<_, i64>(9)? != 0,
        last_run_date: row.get(10)?,
        last_run_at: row.get(11)?,
        last_summary: row.get(12)?,
        last_status: row.get(13)?,
        next_retry_at: row.get(14)?,
        consecutive_failures: row.get(15)?,
        successful_runs: row.get(16)?,
        failed_runs: row.get(17)?,
    })
}

pub(super) fn list_attachment_paperless_tasks(
    config: &AppConfig,
    username: &str,
) -> Result<Vec<AttachmentPaperlessTask>, String> {
    let connection = open_db(config)?;
    let mut statement = connection
        .prepare(
            r#"
            SELECT id, username, name, query, schedule_time, schedule_mode,
                   interval_minutes, max_attachments, retry_enabled, enabled,
                   last_run_date, last_run_at, last_summary, last_status,
                   next_retry_at, consecutive_failures, successful_runs, failed_runs
            FROM attachment_paperless_tasks
            WHERE username = ?1
            ORDER BY schedule_time, lower(name), name
            "#,
        )
        .map_err(|error| format!("failed to load Paperless tasks: {error}"))?;
    let rows = statement
        .query_map(params![username], map_attachment_paperless_task)
        .map_err(|error| format!("failed to read Paperless tasks: {error}"))?;
    rows.collect::<Result<Vec<_>, _>>()
        .map_err(|error| format!("failed to decode Paperless tasks: {error}"))
}

pub(super) fn save_attachment_paperless_task_for_user(
    config: &AppConfig,
    username: &str,
    form: &AttachmentPaperlessTaskSaveForm,
) -> Result<AttachmentPaperlessTask, String> {
    if config.paperless_consume_root.is_none() {
        return Err("Paperless handoff is not configured.".to_string());
    }
    let name = normalize_attachment_preset_name(&form.task_name)?;
    let schedule_time = normalize_daily_schedule_time(&form.schedule_time)?;
    let (schedule_mode, interval_minutes) = normalize_paperless_schedule(
        form.schedule_mode.as_deref(),
        form.interval_minutes.as_deref(),
    )?;
    let max_attachments =
        normalize_paperless_task_max_attachments(form.paperless_max_documents.as_deref())?;
    let retry_enabled = form.retry_enabled.as_deref() != Some("0");
    let query = attachment_paperless_task_query_from_form(form)?;
    if query.trim().is_empty() {
        return Err(
            "Add at least one attachment filter before saving a Paperless task.".to_string(),
        );
    }

    let now = Utc::now().to_rfc3339();
    let connection = open_db(config)?;
    connection
        .execute(
            r#"
            INSERT INTO attachment_paperless_tasks (
                username, name, query, schedule_time, schedule_mode, interval_minutes,
                max_attachments, retry_enabled, enabled, created_at, updated_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 1, ?9, ?9)
            ON CONFLICT(username, name) DO UPDATE SET
                query = excluded.query,
                schedule_time = excluded.schedule_time,
                schedule_mode = excluded.schedule_mode,
                interval_minutes = excluded.interval_minutes,
                max_attachments = excluded.max_attachments,
                retry_enabled = excluded.retry_enabled,
                enabled = 1,
                next_retry_at = NULL,
                consecutive_failures = 0,
                lease_until = NULL,
                updated_at = excluded.updated_at
            "#,
            params![
                username,
                name,
                query,
                schedule_time,
                schedule_mode,
                interval_minutes,
                max_attachments,
                if retry_enabled { 1 } else { 0 },
                now,
            ],
        )
        .map_err(|error| format!("failed to save Paperless task: {error}"))?;

    connection
        .query_row(
            r#"
            SELECT id, username, name, query, schedule_time, schedule_mode,
                   interval_minutes, max_attachments, retry_enabled, enabled,
                   last_run_date, last_run_at, last_summary, last_status,
                   next_retry_at, consecutive_failures, successful_runs, failed_runs
            FROM attachment_paperless_tasks
            WHERE username = ?1 AND name = ?2
            LIMIT 1
            "#,
            params![username, name],
            map_attachment_paperless_task,
        )
        .map_err(|error| format!("failed to reload Paperless task: {error}"))
}

pub(super) fn delete_attachment_paperless_task_for_user(
    config: &AppConfig,
    username: &str,
    task_id: i64,
) -> Result<(), String> {
    let connection = open_db(config)?;
    let deleted = connection
        .execute(
            "DELETE FROM attachment_paperless_tasks WHERE username = ?1 AND id = ?2",
            params![username, task_id],
        )
        .map_err(|error| format!("failed to delete Paperless task: {error}"))?;
    if deleted == 0 {
        return Err("Paperless task was not found.".to_string());
    }
    Ok(())
}

pub(super) fn set_attachment_paperless_task_enabled(
    config: &AppConfig,
    username: &str,
    task_id: i64,
    enabled: bool,
) -> Result<(), String> {
    let now = Utc::now().to_rfc3339();
    let connection = open_db(config)?;
    let updated = connection
        .execute(
            r#"
            UPDATE attachment_paperless_tasks
            SET enabled = ?3, updated_at = ?4
            WHERE username = ?1 AND id = ?2
            "#,
            params![username, task_id, if enabled { 1 } else { 0 }, now],
        )
        .map_err(|error| format!("failed to update Paperless task: {error}"))?;
    if updated == 0 {
        return Err("Paperless task was not found.".to_string());
    }
    Ok(())
}

pub(super) fn load_attachment_page_data(
    config: &AppConfig,
    username: &str,
    params: &AttachmentListParams,
) -> Result<AttachmentPageData, String> {
    let accounts = list_accounts_for_user(config, username)?;
    let presets = list_attachment_filter_presets(config, username)?;
    let paperless_tasks = list_attachment_paperless_tasks(config, username)?;
    let selected_account_id = normalize_selected_account_id(&accounts, params.account_id);
    let priority_filter = SenderPriorityFilter::from_query(params.priority.as_deref());
    let raw_filters = attachment_filters_from_params(params);
    let filters = parse_attachment_search_filters(raw_filters)?;
    let general_query = filters.raw.message.q.trim().to_string();
    let structured_message_filters =
        parse_message_search_filters(message_filters_without_general_query(&filters.raw.message))?;
    let general_query_filters = if general_query.is_empty() {
        None
    } else {
        Some(parse_message_search_filters(MessageSearchFilters {
            q: general_query.clone(),
            ..Default::default()
        })?)
    };
    let include_inline = query_bool_is_true(params.include_inline.as_deref());
    let include_inline_images = query_bool_is_true(params.include_inline_images.as_deref());
    let show_mime_details = query_bool_is_true(params.show_mime_details.as_deref());
    let download_subfolder =
        normalize_download_subfolder(params.download_subfolder.as_deref().unwrap_or_default())?;
    let page = parse_page_number(params.page.as_deref());
    let connection = open_db(config)?;
    let priority_rules = load_sender_priority_rules(config, username)?;
    let mut items = Vec::new();
    let mut query_relpaths_by_account = HashMap::<i64, HashSet<String>>::new();
    let mut general_query_relpaths_by_account = HashMap::<i64, HashSet<String>>::new();

    for account in accounts
        .iter()
        .filter(|account| selected_account_id.is_none_or(|selected| selected == account.id))
    {
        let account_paths = ensure_account_paths(config, account)?;
        if account_index_state(&account_paths) != IndexState::Indexed {
            continue;
        }

        if message_filters_have_terms(&structured_message_filters.raw) {
            let relpaths = list_notmuch_message_files(
                &account_paths,
                &notmuch_query_for_filters(&structured_message_filters),
            )?
            .into_iter()
            .map(|path| {
                message_relative_path(&account_paths, &path)
                    .map(|relative| relative.to_string_lossy().to_string())
            })
            .collect::<Result<HashSet<_>, _>>()?;
            query_relpaths_by_account.insert(account.id, relpaths);
        }
        if let Some(general_query_filters) = general_query_filters.as_ref() {
            let relpaths = list_notmuch_message_files(
                &account_paths,
                &notmuch_query_for_filters(general_query_filters),
            )?
            .into_iter()
            .map(|path| {
                message_relative_path(&account_paths, &path)
                    .map(|relative| relative.to_string_lossy().to_string())
            })
            .collect::<Result<HashSet<_>, _>>()?;
            general_query_relpaths_by_account.insert(account.id, relpaths);
        }

        let catalog_rows = load_attachment_catalog_rows_for_account(&connection, account.id)?;
        let mut attachment_counts = HashMap::<String, usize>::new();
        for (message, _) in &catalog_rows {
            *attachment_counts
                .entry(message.message_key.clone())
                .or_insert(0) += 1;
        }

        for (message, attachment) in catalog_rows {
            if message_filters_have_terms(&structured_message_filters.raw)
                && !query_relpaths_by_account
                    .get(&account.id)
                    .is_some_and(|relpaths| relpaths.contains(&message.message_relpath))
            {
                continue;
            }
            if !include_inline && attachment_is_body_artifact(&attachment) {
                continue;
            }
            if !include_inline_images && attachment_is_inline_image(&attachment) {
                continue;
            }

            let sender_priority = priority_rules.view_for_sender(&message.from);
            if !priority_filter.matches(sender_priority.priority) {
                continue;
            }

            let mut item = AttachmentListItem {
                account_name: account.display_name.clone(),
                attachment,
                message,
                sender_priority,
                paperless_sent_at: None,
                message_preview: None,
                message_preview_truncated: false,
                message_cc: None,
            };
            if !message_matches_filters(
                &LiveMessageRecord {
                    message_key: item.message.message_key.clone(),
                    message_relpaths: vec![item.message.message_relpath.clone()],
                    subject: item.message.subject.clone(),
                    from: item.message.from.clone(),
                    timestamp: item.message.timestamp,
                },
                &structured_message_filters,
                Some(item.message.has_attachments),
            ) {
                continue;
            }
            if !general_query.is_empty() {
                let message_body_match = general_query_relpaths_by_account
                    .get(&account.id)
                    .is_some_and(|relpaths| relpaths.contains(&item.message.message_relpath));
                if !attachment_general_query_matches(&item, &general_query, message_body_match) {
                    continue;
                }
            }
            let attachment_count = attachment_counts
                .get(&item.message.message_key)
                .copied()
                .unwrap_or(0);
            if !attachment_matches_filters(&item, &filters, attachment_count) {
                continue;
            }
            item.paperless_sent_at = load_attachment_paperless_handoff(
                &connection,
                username,
                &item.attachment.attachment_key,
            )?;
            items.push(item);
        }
    }

    items.sort_by(|left, right| {
        left.sender_priority
            .priority
            .sort_rank()
            .cmp(&right.sender_priority.priority.sort_rank())
            .then(right.message.timestamp.cmp(&left.message.timestamp))
            .then(
                left.attachment
                    .attachment_index
                    .cmp(&right.attachment.attachment_index),
            )
    });

    let total_count = items.len();
    let start = (page - 1).saturating_mul(ATTACHMENTS_PER_PAGE);
    let end = usize::min(start + ATTACHMENTS_PER_PAGE, total_count);
    let mut page_items = if start >= total_count {
        Vec::new()
    } else {
        items[start..end].to_vec()
    };
    let accounts_by_id = accounts
        .iter()
        .map(|account| (account.id, account))
        .collect::<HashMap<_, _>>();
    for item in &mut page_items {
        let Some(account) = accounts_by_id.get(&item.message.account_id) else {
            continue;
        };
        let Ok(account_paths) = ensure_account_paths(config, account) else {
            continue;
        };
        let message_path = account_paths.maildir.join(&item.message.message_relpath);
        if let Ok(context) = read_message_context_preview(&message_path, 760) {
            item.message_preview = context.body;
            item.message_preview_truncated = context.truncated;
            item.message_cc = context.cc;
        }
    }
    let base_query = build_attachment_base_query(AttachmentBaseQuery {
        filters: &filters.raw,
        selected_account_id,
        priority_filter,
        include_inline,
        include_inline_images,
        show_mime_details,
        download_subfolder: &download_subfolder,
    });
    let empty_message =
        if selected_account_id.is_some() && page_items.is_empty() && total_count == 0 {
            Some("No attachments matched this mailbox filter.".to_string())
        } else if page_items.is_empty() && total_count == 0 {
            Some("No catalogued attachments matched the current filters.".to_string())
        } else {
            None
        };

    Ok(AttachmentPageData {
        accounts,
        selected_account_id,
        presets,
        paperless_tasks,
        filters: filters.raw,
        include_inline,
        include_inline_images,
        show_mime_details,
        download_subfolder,
        items: page_items,
        state: AttachmentListViewState {
            priority_filter,
            page,
            result_count: total_count,
            has_previous_page: page > 1 && start < total_count,
            has_next_page: end < total_count,
            empty_message,
            base_query,
        },
    })
}

pub(super) fn download_attachment_keys_for_form(
    config: &AppConfig,
    username: &str,
    form: &AttachmentDownloadForm,
) -> Result<Vec<String>, String> {
    let mut keys = Vec::new();
    let mut seen = HashSet::new();

    if form.selection_scope.as_deref() == Some(ATTACHMENT_SELECTION_ALL_MATCHING) {
        let selected_account_id = parse_optional_query_i64(form.account_id.as_deref())?;
        let mut page = 1;
        loop {
            let params = AttachmentListParams {
                q: form.q.clone(),
                account_id: selected_account_id,
                priority: form.priority.clone(),
                sender_address: form.sender_address.clone(),
                sender_name: form.sender_name.clone(),
                sender_domain: form.sender_domain.clone(),
                subject: form.subject.clone(),
                body_text: form.body_text.clone(),
                date_from: form.date_from.clone(),
                date_to: form.date_to.clone(),
                has_attachments: form.has_attachments.clone(),
                extension: form.extension.clone(),
                extension_custom: None,
                attachment_name: form.attachment_name.clone(),
                mime_type: form.mime_type.clone(),
                min_size: form.min_size.clone(),
                max_size: form.max_size.clone(),
                min_attachments: form.min_attachments.clone(),
                max_attachments: form.max_attachments.clone(),
                include_inline: form.include_inline.clone(),
                include_inline_images: form.include_inline_images.clone(),
                show_mime_details: form.show_mime_details.clone(),
                download_subfolder: form.download_subfolder.clone(),
                page: Some(page.to_string()),
                flash: None,
                error: None,
            };
            let data = load_attachment_page_data(config, username, &params)?;
            for item in data.items {
                if seen.insert(item.attachment.attachment_key.clone()) {
                    keys.push(item.attachment.attachment_key);
                }
                if keys.len() > MAX_ZIP_ATTACHMENTS {
                    return Err(format!(
                        "Too many attachments matched. Narrow the filters to {} files or fewer.",
                        MAX_ZIP_ATTACHMENTS
                    ));
                }
            }
            if !data.state.has_next_page {
                break;
            }
            page += 1;
        }
    } else {
        for key in &form.attachment_keys {
            let key = key.trim();
            if !key.is_empty() && seen.insert(key.to_string()) {
                keys.push(key.to_string());
            }
        }
    }

    if keys.is_empty() {
        return Err("Select at least one downloadable attachment.".to_string());
    }
    if keys.len() > MAX_ZIP_ATTACHMENTS {
        return Err(format!(
            "Select {} attachments or fewer for one ZIP download.",
            MAX_ZIP_ATTACHMENTS
        ));
    }

    Ok(keys)
}

pub(super) fn attachment_keys_for_params(
    config: &AppConfig,
    username: &str,
    params: &AttachmentListParams,
    max_keys: usize,
) -> Result<Vec<String>, String> {
    let mut keys = Vec::new();
    let mut seen = HashSet::new();
    let connection = open_db(config)?;
    let mut page = 1;

    loop {
        let mut page_params = params.clone();
        page_params.page = Some(page.to_string());
        page_params.flash = None;
        page_params.error = None;
        let data = load_attachment_page_data(config, username, &page_params)?;
        for item in data.items {
            if seen.insert(item.attachment.attachment_key.clone())
                && attachment_key_is_new_for_paperless(
                    &connection,
                    username,
                    &item.attachment.attachment_key,
                )?
            {
                keys.push(item.attachment.attachment_key);
            }
            if keys.len() >= max_keys {
                return Ok(keys);
            }
        }
        if !data.state.has_next_page {
            break;
        }
        page += 1;
    }

    Ok(keys)
}

pub(super) fn attachment_key_is_new_for_paperless(
    connection: &Connection,
    username: &str,
    attachment_key: &str,
) -> Result<bool, String> {
    load_attachment_paperless_handoff(connection, username, attachment_key)
        .map(|sent| sent.is_none())
}

pub(super) fn send_attachment_filter_to_paperless(
    config: &AppConfig,
    username: &str,
    query: &str,
    max_attachments: usize,
) -> Result<PaperlessHandoffSummary, String> {
    let params = attachment_params_from_query(query)?;
    let keys = attachment_keys_for_params(config, username, &params, max_attachments)?;
    if keys.is_empty() {
        return Ok(PaperlessHandoffSummary {
            skipped: 0,
            ..Default::default()
        });
    }

    send_attachments_to_paperless(config, username, &keys)
}

pub(super) fn parse_attachment_download_form_body(body: &[u8]) -> AttachmentDownloadForm {
    let mut form = AttachmentDownloadForm::default();

    for (key, value) in form_urlencoded::parse(body) {
        let value = value.into_owned();
        match key.as_ref() {
            "attachment_keys" | "attachment_keys[]" => form.attachment_keys.push(value),
            "selection_scope" => form.selection_scope = Some(value),
            "q" => form.q = Some(value),
            "account_id" => form.account_id = Some(value),
            "priority" => form.priority = Some(value),
            "sender_address" => form.sender_address = Some(value),
            "sender_name" => form.sender_name = Some(value),
            "sender_domain" => form.sender_domain = Some(value),
            "subject" => form.subject = Some(value),
            "body_text" => form.body_text = Some(value),
            "date_from" => form.date_from = Some(value),
            "date_to" => form.date_to = Some(value),
            "has_attachments" => form.has_attachments = Some(value),
            "extension" => form.extension = Some(value),
            "attachment_name" => form.attachment_name = Some(value),
            "mime_type" => form.mime_type = Some(value),
            "min_size" => form.min_size = Some(value),
            "max_size" => form.max_size = Some(value),
            "min_attachments" => form.min_attachments = Some(value),
            "max_attachments" => form.max_attachments = Some(value),
            "include_inline" => form.include_inline = Some(value),
            "include_inline_images" => form.include_inline_images = Some(value),
            "show_mime_details" => form.show_mime_details = Some(value),
            "download_subfolder" => form.download_subfolder = Some(value),
            "return_to" => form.return_to = Some(value),
            _ => {}
        }
    }

    form
}

pub(super) fn parse_attachment_paperless_form_body(body: &[u8]) -> AttachmentPaperlessForm {
    let mut form = AttachmentPaperlessForm::default();

    for (key, value) in form_urlencoded::parse(body) {
        let value = value.into_owned();
        match key.as_ref() {
            "attachment_keys" | "attachment_keys[]" => form.attachment_keys.push(value),
            "return_to" => form.return_to = Some(value),
            _ => {}
        }
    }

    form
}

pub(super) fn build_attachments_zip(
    config: &AppConfig,
    username: &str,
    form: &AttachmentDownloadForm,
) -> Result<TempZipFile, String> {
    cleanup_old_runtime_exports(config)?;
    let keys = download_attachment_keys_for_form(config, username, form)?;
    let download_subfolder =
        normalize_download_subfolder(form.download_subfolder.as_deref().unwrap_or_default())?;
    let mut records = Vec::new();
    let mut total_size = 0_u64;

    for key in keys {
        let record = load_attachment_for_user(config, username, &key)?;
        let size = u64::try_from(record.2.size_bytes.max(0))
            .map_err(|_| "Attachment size could not be represented safely".to_string())?;
        total_size = total_size.saturating_add(size);
        if total_size > MAX_ZIP_BYTES {
            return Err("Selected attachments are too large for one ZIP download.".to_string());
        }
        records.push(record);
    }

    let export_root = runtime_export_root(config);
    fs::create_dir_all(&export_root)
        .map_err(|error| format!("failed to create {}: {error}", export_root.display()))?;
    let filename = format!(
        "mail-archive-attachments-{}.zip",
        Utc::now().format("%Y%m%d-%H%M%S")
    );
    let zip_path = export_root.join(format!("{}-{}", random_hex(8), filename));
    let zip_file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&zip_path)
        .map_err(|error| format!("failed to create ZIP file {}: {error}", zip_path.display()))?;
    let mut zip = ZipWriter::new(zip_file);
    let options = SimpleFileOptions::default()
        .compression_method(CompressionMethod::Deflated)
        .unix_permissions(0o600);
    let mut used_names = HashMap::<String, usize>::new();
    let mut manifest_entries = Vec::new();

    for (account, message, attachment) in records {
        let (_dir, attachment_path) =
            resolve_attachment_payload(config, &account, &message, &attachment)?;
        let entry_name = unique_zip_entry_name(
            zip_entry_name(&account, &message, &attachment, &download_subfolder),
            &mut used_names,
        );
        zip.start_file(entry_name.clone(), options)
            .map_err(|error| format!("failed to start ZIP entry: {error}"))?;
        let mut source = fs::File::open(&attachment_path).map_err(|error| {
            format!(
                "failed to open extracted attachment {}: {error}",
                attachment_path.display()
            )
        })?;
        std::io::copy(&mut source, &mut zip)
            .map_err(|error| format!("failed to write ZIP entry: {error}"))?;
        manifest_entries.push(AttachmentZipManifestEntry {
            zip_path: entry_name,
            account: account.display_name,
            account_id: account.id,
            message_key: message.message_key,
            message_relpath: message.message_relpath,
            subject: message.subject,
            sender: message.from,
            message_timestamp: message.timestamp,
            original_filename: attachment.original_filename,
            mime_type: attachment.mime_type,
            size_bytes: attachment.size_bytes,
            attachment_sha256: attachment.attachment_sha256,
            blob_relpath: attachment.blob_relpath,
            source_message_sha256: attachment.source_message_sha256,
        });
    }

    let manifest = AttachmentZipManifest {
        generated_at: Utc::now().to_rfc3339(),
        source: "mail-archive-ui",
        file_count: manifest_entries.len(),
        total_size_bytes: total_size,
        files: manifest_entries,
    };
    zip.start_file("manifest.json", options)
        .map_err(|error| format!("failed to start ZIP manifest: {error}"))?;
    serde_json::to_writer_pretty(&mut zip, &manifest)
        .map_err(|error| format!("failed to write ZIP manifest: {error}"))?;

    zip.finish()
        .map_err(|error| format!("failed to finish ZIP archive: {error}"))?
        .sync_all()
        .map_err(|error| format!("failed to sync ZIP archive {}: {error}", zip_path.display()))?;
    Ok(TempZipFile {
        filename,
        path: zip_path,
    })
}

pub(super) fn zip_entry_name(
    account: &AccountRecord,
    message: &AttachmentMessageRecord,
    attachment: &AttachmentRecord,
    download_subfolder: &str,
) -> String {
    let date = DateTime::<Utc>::from_timestamp(message.timestamp, 0)
        .map(|value| value.format("%Y-%m-%d").to_string())
        .unwrap_or_else(|| "unknown-date".to_string());
    let account_name = filename_component(&account.display_name, "mailbox");
    let subject_name = filename_component(&message.subject, "message");
    let entry = format!(
        "{}/{} - {}/{}",
        account_name,
        date,
        subject_name,
        filename_component(&attachment.original_filename, "attachment")
    );
    if download_subfolder.trim().is_empty() {
        entry
    } else {
        format!("{download_subfolder}/{entry}")
    }
}

pub(super) fn unique_zip_entry_name(
    base: String,
    used_names: &mut HashMap<String, usize>,
) -> String {
    let count = used_names.entry(base.clone()).or_insert(0);
    if *count == 0 {
        *count = 1;
        base
    } else {
        let name = zip_entry_name_with_numeric_suffix(&base, *count);
        *count += 1;
        name
    }
}

pub(super) fn zip_entry_name_with_numeric_suffix(base: &str, suffix: usize) -> String {
    let path = FsPath::new(base);
    let parent = path.parent().filter(|value| !value.as_os_str().is_empty());
    let filename = path
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or(base);
    let suffixed = if let Some((stem, extension)) = filename.rsplit_once('.') {
        if stem.is_empty() || extension.is_empty() {
            format!("{filename} ({suffix})")
        } else {
            format!("{stem} ({suffix}).{extension}")
        }
    } else {
        format!("{filename} ({suffix})")
    };
    parent
        .map(|value| value.join(&suffixed).to_string_lossy().to_string())
        .unwrap_or(suffixed)
}

pub(super) fn cleanup_old_runtime_exports(config: &AppConfig) -> Result<(), String> {
    let export_root = runtime_export_root(config);
    let entries = match fs::read_dir(&export_root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(()),
        Err(error) => {
            return Err(format!(
                "failed to read runtime export directory {}: {error}",
                export_root.display()
            ))
        }
    };
    let now = Utc::now().timestamp();
    for entry in entries {
        let entry = entry.map_err(|error| {
            format!(
                "failed to read runtime export directory {}: {error}",
                export_root.display()
            )
        })?;
        let metadata = entry.metadata().map_err(|error| {
            format!(
                "failed to inspect runtime export {}: {error}",
                entry.path().display()
            )
        })?;
        if !metadata.is_file() {
            continue;
        }
        let modified = metadata
            .modified()
            .ok()
            .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|duration| i64::try_from(duration.as_secs()).unwrap_or(i64::MAX))
            .unwrap_or(now);
        if now.saturating_sub(modified) > RUNTIME_EXPORT_MAX_AGE_SECONDS {
            fs::remove_file(entry.path()).map_err(|error| {
                format!(
                    "failed to remove stale runtime export {}: {error}",
                    entry.path().display()
                )
            })?;
        }
    }
    Ok(())
}

pub(super) fn verify_attachment_archive(
    config: &AppConfig,
    repair: bool,
    report_path: Option<&FsPath>,
) -> Result<AttachmentVerificationReport, String> {
    let connection = open_db(config)?;
    let accounts = list_all_accounts(config)?;
    let mut report = AttachmentVerificationReport {
        generated_at: Utc::now().to_rfc3339(),
        accounts_checked: 0,
        messages_checked: 0,
        attachments_checked: 0,
        missing_sources: 0,
        missing_blobs: 0,
        mismatched_blobs: 0,
        orphaned_blobs: 0,
        warnings: Vec::new(),
    };

    for account in accounts {
        report.accounts_checked += 1;
        let account_paths = ensure_account_paths(config, &account)?;
        let rows = load_attachment_catalog_rows_for_account(&connection, account.id)?;
        let mut seen_messages = HashSet::<String>::new();
        let mut referenced_blobs = HashSet::<String>::new();

        for (message, attachment) in rows {
            report.attachments_checked += 1;
            if seen_messages.insert(message.message_key.clone()) {
                report.messages_checked += 1;
            }

            let source_path = account_paths.maildir.join(&message.message_relpath);
            if !source_path.is_file() {
                report.missing_sources += 1;
                report.warnings.push(format!(
                    "missing source message account={} attachment={} source={}",
                    account.id,
                    attachment.attachment_key,
                    source_path.display()
                ));
                continue;
            }

            let blob_relpath = attachment.blob_relpath.clone().unwrap_or_else(|| {
                attachment_blob_relpath(&attachment.attachment_sha256)
                    .to_string_lossy()
                    .to_string()
            });
            let blob_path = attachment_blob_path(&account_paths, &blob_relpath)?;
            let mut blob_ok = false;
            let mut blob_missing = false;
            let mut blob_mismatched = false;
            if blob_path.is_file() {
                let blob_sha = sha256_file(&blob_path)?;
                let blob_size = fs::metadata(&blob_path)
                    .map_err(|error| format!("failed to inspect {}: {error}", blob_path.display()))?
                    .len();
                if blob_sha == attachment.attachment_sha256
                    && i64::try_from(blob_size).ok() == Some(attachment.size_bytes)
                {
                    blob_ok = true;
                } else {
                    blob_mismatched = true;
                    report.mismatched_blobs += 1;
                    report.warnings.push(format!(
                        "mismatched attachment blob account={} attachment={} blob={}",
                        account.id,
                        attachment.attachment_key,
                        blob_path.display()
                    ));
                }
            } else {
                blob_missing = true;
                report.missing_blobs += 1;
                report.warnings.push(format!(
                    "missing attachment blob account={} attachment={} blob={}",
                    account.id,
                    attachment.attachment_key,
                    blob_path.display()
                ));
            }

            if !blob_ok && repair {
                let (_dir, repaired_path) =
                    resolve_attachment_payload(config, &account, &message, &attachment)?;
                let repaired_sha = sha256_file(&repaired_path)?;
                if repaired_sha == attachment.attachment_sha256 {
                    let repaired_relpath = attachment_blob_relpath(&repaired_sha)
                        .to_string_lossy()
                        .to_string();
                    let now = Utc::now().to_rfc3339();
                    connection
                        .execute(
                            r#"
                            UPDATE attachment_catalog
                            SET blob_relpath = ?3,
                                last_verified_at = ?4
                            WHERE account_id = ?1
                              AND attachment_key = ?2
                            "#,
                            params![account.id, attachment.attachment_key, repaired_relpath, now],
                        )
                        .map_err(|error| {
                            format!("failed to update repaired attachment metadata: {error}")
                        })?;
                    if blob_missing {
                        report.missing_blobs = report.missing_blobs.saturating_sub(1);
                    }
                    if blob_mismatched {
                        report.mismatched_blobs = report.mismatched_blobs.saturating_sub(1);
                    }
                    referenced_blobs.insert(repaired_relpath);
                    continue;
                }
            }

            if blob_ok {
                let now = Utc::now().to_rfc3339();
                connection
                    .execute(
                        r#"
                        UPDATE attachment_catalog
                        SET blob_relpath = ?3,
                            last_verified_at = ?4
                        WHERE account_id = ?1
                          AND attachment_key = ?2
                        "#,
                        params![account.id, attachment.attachment_key, blob_relpath, now],
                    )
                    .map_err(|error| {
                        format!("failed to update attachment verification time: {error}")
                    })?;
            }
            referenced_blobs.insert(blob_relpath);
        }

        for blob in collect_regular_files(&account_paths.attachment_blob_root).unwrap_or_default() {
            let relpath = blob
                .strip_prefix(&account_paths.hidden_sync_root)
                .map(|value| value.to_string_lossy().to_string())
                .unwrap_or_else(|_| blob.to_string_lossy().to_string());
            if !referenced_blobs.contains(&relpath) {
                report.orphaned_blobs += 1;
                report.warnings.push(format!(
                    "orphaned attachment blob account={} blob={}",
                    account.id,
                    blob.display()
                ));
            }
        }
    }

    if let Some(path) = report_path {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|error| {
                format!(
                    "failed to create report directory {}: {error}",
                    parent.display()
                )
            })?;
        }
        let bytes = serde_json::to_vec_pretty(&report)
            .map_err(|error| format!("failed to encode attachment verification report: {error}"))?;
        write_private_file(path, &bytes)?;
    }

    Ok(report)
}

pub(super) fn load_attachment_for_user(
    config: &AppConfig,
    username: &str,
    attachment_key_value: &str,
) -> Result<(AccountRecord, AttachmentMessageRecord, AttachmentRecord), String> {
    let connection = open_db(config)?;
    let mut statement = connection
        .prepare(
            r#"
            SELECT
                a.id,
                a.username,
                a.provider_kind,
                a.display_name,
                a.imap_host,
                a.imap_port,
                a.imap_username,
                a.folder_mode,
                a.folder_patterns_json,
                a.encrypted_secret,
                a.sync_enabled,
                a.created_at,
                a.updated_at,
                a.last_sync_started_at,
                a.last_sync_finished_at,
                a.last_sync_status,
                a.last_sync_error,
                a.last_sync_phase,
                a.last_sync_code,
                a.last_sync_summary,
                a.last_sync_detail,
                m.account_id,
                m.message_key,
                m.message_relpath,
                m.message_mtime,
                m.message_size,
                m.subject,
                m.sender,
                m.timestamp,
                m.last_scanned_at,
                m.has_attachments,
                c.attachment_key,
                c.account_id,
                c.message_key,
                c.attachment_index,
                c.attachment_sha256,
                c.original_filename,
                c.safe_filename,
                c.extension,
                c.mime_type,
                c.size_bytes,
                c.is_inline_artifact,
                c.blob_relpath,
                c.source_message_sha256,
                c.last_verified_at,
                c.created_at,
                c.updated_at,
                c.last_seen_at
            FROM attachment_catalog c
            INNER JOIN attachment_messages m
                ON m.account_id = c.account_id
               AND m.message_key = c.message_key
            INNER JOIN accounts a
                ON a.id = c.account_id
            WHERE a.username = ?1 AND c.attachment_key = ?2
            LIMIT 1
            "#,
        )
        .map_err(|error| format!("failed to prepare attachment lookup: {error}"))?;
    statement
        .query_row(params![username, attachment_key_value], |row| {
            Ok((
                AccountRecord {
                    id: row.get(0)?,
                    username: row.get(1)?,
                    provider_kind: row.get(2)?,
                    display_name: row.get(3)?,
                    imap_host: row.get(4)?,
                    imap_port: row.get(5)?,
                    imap_username: row.get(6)?,
                    folder_mode: row.get(7)?,
                    folder_patterns_json: row.get(8)?,
                    encrypted_secret: row.get(9)?,
                    sync_enabled: row.get::<_, i64>(10)? != 0,
                    created_at: row.get(11)?,
                    updated_at: row.get(12)?,
                    last_sync_started_at: row.get(13)?,
                    last_sync_finished_at: row.get(14)?,
                    last_sync_status: row.get(15)?,
                    last_sync_error: row.get(16)?,
                    last_sync_phase: row.get(17)?,
                    last_sync_code: row.get(18)?,
                    last_sync_summary: row.get(19)?,
                    last_sync_detail: row.get(20)?,
                },
                AttachmentMessageRecord {
                    account_id: row.get(21)?,
                    message_key: row.get(22)?,
                    message_relpath: row.get(23)?,
                    message_mtime: row.get(24)?,
                    message_size: row.get(25)?,
                    subject: row.get(26)?,
                    from: row.get(27)?,
                    timestamp: row.get(28)?,
                    last_scanned_at: row.get(29)?,
                    has_attachments: row.get::<_, i64>(30)? != 0,
                },
                AttachmentRecord {
                    attachment_key: row.get(31)?,
                    account_id: row.get(32)?,
                    message_key: row.get(33)?,
                    attachment_index: row.get(34)?,
                    attachment_sha256: row.get(35)?,
                    original_filename: row.get(36)?,
                    safe_filename: row.get(37)?,
                    extension: row.get(38)?,
                    mime_type: row.get(39)?,
                    size_bytes: row.get(40)?,
                    is_inline_artifact: row.get::<_, i64>(41)? != 0,
                    blob_relpath: row.get(42)?,
                    source_message_sha256: row.get(43)?,
                    last_verified_at: row.get(44)?,
                    created_at: row.get(45)?,
                    updated_at: row.get(46)?,
                    last_seen_at: row.get(47)?,
                },
            ))
        })
        .optional()
        .map_err(|error| format!("failed to load attachment row: {error}"))?
        .ok_or_else(|| "Attachment not found".to_string())
}

pub(super) fn resolve_attachment_payload(
    config: &AppConfig,
    account: &AccountRecord,
    message: &AttachmentMessageRecord,
    attachment: &AttachmentRecord,
) -> Result<(TempExtractionDir, PathBuf), String> {
    let account_paths = ensure_account_paths(config, account)?;
    if let Some(blob_relpath) = attachment.blob_relpath.as_deref() {
        let blob_path = attachment_blob_path(&account_paths, blob_relpath)?;
        if blob_path.is_file() {
            let blob_sha = sha256_file(&blob_path)?;
            if blob_sha == attachment.attachment_sha256 {
                return Ok((
                    TempExtractionDir {
                        path: PathBuf::new(),
                    },
                    blob_path,
                ));
            }
        }
    }

    let message_path = account_paths.maildir.join(&message.message_relpath);
    let source_message_sha256 = sha256_file(&message_path)?;
    let (extraction_dir, scanned) = scan_message_attachments_for_catalog(
        config,
        &account_paths,
        account.id,
        &message.message_key,
        &message_path,
        &source_message_sha256,
    )?;
    scanned
        .into_iter()
        .find(|(scanned_attachment, _)| {
            scanned_attachment.attachment_key == attachment.attachment_key
        })
        .map(|(_, path)| (extraction_dir, path))
        .ok_or_else(|| {
            "Attachment payload could not be reconstructed from the archived message".to_string()
        })
}

pub(super) fn collect_live_messages_for_account(
    config: &AppConfig,
    account: &AccountRecord,
    query: &str,
) -> Result<Vec<LiveMessageRecord>, String> {
    let account_paths = ensure_account_paths(config, account)?;
    if account_index_state(&account_paths) != IndexState::Indexed {
        return Ok(Vec::new());
    }

    let mut by_key = HashMap::<String, LiveMessageRecord>::new();
    for file_path in list_notmuch_message_files(&account_paths, query)? {
        let relpath = message_relative_path(&account_paths, &file_path)?
            .to_string_lossy()
            .to_string();
        let metadata = read_message_metadata(&file_path)?;
        let message_key = message_key_from_metadata(&metadata)?;
        let record = by_key
            .entry(message_key.clone())
            .or_insert_with(|| LiveMessageRecord {
                message_key: message_key.clone(),
                message_relpaths: Vec::new(),
                subject: metadata.subject.clone(),
                from: metadata.from.clone(),
                timestamp: metadata.timestamp,
            });
        record.message_relpaths.push(relpath);
    }

    let mut messages = by_key.into_values().collect::<Vec<_>>();
    messages.sort_by_key(|message| Reverse(message.timestamp));
    Ok(messages)
}

pub(super) fn search_mail(
    config: &AppConfig,
    username: &str,
    selected_account_id: Option<i64>,
    filters: MessageSearchFilters,
    priority_filter: SenderPriorityFilter,
) -> Result<Vec<SearchResult>, String> {
    let filters = parse_message_search_filters(filters)?;
    let query = notmuch_query_for_filters(&filters);
    let connection = open_db(config)?;
    let priority_rules = load_sender_priority_rules(config, username)?;
    let mut results = Vec::new();
    for account in list_accounts_for_user(config, username)?
        .into_iter()
        .filter(|account| selected_account_id.is_none_or(|selected| selected == account.id))
    {
        for item in collect_live_messages_for_account(config, &account, &query)? {
            let has_attachments =
                message_catalog_has_attachments(&connection, account.id, &item.message_key)?;
            if !message_matches_filters(&item, &filters, Some(has_attachments)) {
                continue;
            }
            let sender_priority = priority_rules.view_for_sender(&item.from);
            if !priority_filter.matches(sender_priority.priority) {
                continue;
            }
            results.push(SearchResult {
                account_name: account.display_name.clone(),
                message_relpath: item.message_relpaths.first().cloned().unwrap_or_default(),
                timestamp: item.timestamp,
                date_label: format_timestamp_date_label(item.timestamp),
                from: item.from.clone(),
                subject: item.subject.clone(),
                tags: Vec::new(),
                sender_priority,
            });
        }
    }

    results.sort_by(|left, right| {
        left.sender_priority
            .priority
            .sort_rank()
            .cmp(&right.sender_priority.priority.sort_rank())
            .then(right.timestamp.cmp(&left.timestamp))
    });
    Ok(results)
}

pub(super) fn load_account_progress_snapshot(
    config: &AppConfig,
    account_id: i64,
) -> Result<Option<AccountProgressSnapshotRecord>, String> {
    let connection = open_db(config)?;
    connection
        .query_row(
            r#"
            SELECT
                account_id,
                archived_message_count,
                indexed_message_count,
                pending_index_count,
                index_coverage_percent,
                archive_file_count,
                overlap_file_count,
                last_computed_at,
                source_sync_finished_at,
                snapshot_status,
                snapshot_note
            FROM account_progress_snapshots
            WHERE account_id = ?1
            "#,
            params![account_id],
            |row| {
                Ok(AccountProgressSnapshotRecord {
                    account_id: row.get(0)?,
                    archived_message_count: row.get(1)?,
                    indexed_message_count: row.get(2)?,
                    pending_index_count: row.get(3)?,
                    index_coverage_percent: row.get(4)?,
                    archive_file_count: row.get(5)?,
                    overlap_file_count: row.get(6)?,
                    last_computed_at: row.get(7)?,
                    source_sync_finished_at: row.get(8)?,
                    snapshot_status: row.get(9)?,
                    snapshot_note: row.get(10)?,
                })
            },
        )
        .optional()
        .map_err(|error| format!("failed to load account progress snapshot: {error}"))
}

pub(super) fn store_account_progress_snapshot(
    config: &AppConfig,
    account_id: i64,
    counts: &AccountProgressCounts,
    source_sync_finished_at: Option<&str>,
    snapshot_status: &str,
    snapshot_note: Option<&str>,
) -> Result<(), String> {
    let connection = open_db(config)?;
    let now = Utc::now().to_rfc3339();
    connection
        .execute(
            r#"
            INSERT INTO account_progress_snapshots (
                account_id,
                archived_message_count,
                indexed_message_count,
                pending_index_count,
                index_coverage_percent,
                archive_file_count,
                overlap_file_count,
                last_computed_at,
                source_sync_finished_at,
                snapshot_status,
                snapshot_note
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
            ON CONFLICT(account_id) DO UPDATE SET
                archived_message_count = excluded.archived_message_count,
                indexed_message_count = excluded.indexed_message_count,
                pending_index_count = excluded.pending_index_count,
                index_coverage_percent = excluded.index_coverage_percent,
                archive_file_count = excluded.archive_file_count,
                overlap_file_count = excluded.overlap_file_count,
                last_computed_at = excluded.last_computed_at,
                source_sync_finished_at = excluded.source_sync_finished_at,
                snapshot_status = excluded.snapshot_status,
                snapshot_note = excluded.snapshot_note
            "#,
            params![
                account_id,
                counts.archived_message_count,
                counts.indexed_message_count,
                counts.pending_index_count,
                counts.index_coverage_percent,
                counts.archive_file_count,
                counts.overlap_file_count,
                now,
                source_sync_finished_at,
                snapshot_status,
                snapshot_note,
            ],
        )
        .map_err(|error| format!("failed to store account progress snapshot: {error}"))?;
    Ok(())
}

pub(super) fn snapshot_counts(snapshot: &AccountProgressSnapshotRecord) -> AccountProgressCounts {
    AccountProgressCounts {
        archived_message_count: snapshot.archived_message_count,
        indexed_message_count: snapshot.indexed_message_count,
        pending_index_count: snapshot.pending_index_count,
        index_coverage_percent: snapshot.index_coverage_percent,
        archive_file_count: snapshot.archive_file_count,
        overlap_file_count: snapshot.overlap_file_count,
    }
}

pub(super) fn load_message_mailbox_instances_for_account(
    connection: &Connection,
    account_id: i64,
) -> Result<Vec<MessageMailboxInstanceRecord>, String> {
    let mut statement = connection
        .prepare(
            r#"
            SELECT
                account_id,
                message_key,
                raw_mailbox_path,
                visible_relpath,
                hidden_relpath,
                account_slug,
                mailbox_slug,
                filename,
                last_seen_at
            FROM message_mailbox_instances
            WHERE account_id = ?1
            "#,
        )
        .map_err(|error| format!("failed to prepare mailbox instance query: {error}"))?;
    let rows = statement
        .query_map(params![account_id], |row| {
            Ok(MessageMailboxInstanceRecord {
                account_id: row.get(0)?,
                message_key: row.get(1)?,
                raw_mailbox_path: row.get(2)?,
                visible_relpath: row.get(3)?,
                hidden_relpath: row.get(4)?,
                account_slug: row.get(5)?,
                mailbox_slug: row.get(6)?,
                filename: row.get(7)?,
                last_seen_at: row.get(8)?,
            })
        })
        .map_err(|error| format!("failed to load mailbox instances: {error}"))?;

    rows.collect::<Result<Vec<_>, _>>()
        .map_err(|error| format!("failed to decode mailbox instances: {error}"))
}

pub(super) fn visible_account_slug(
    config: &AppConfig,
    account: &AccountRecord,
) -> Result<String, String> {
    let accounts = list_accounts_for_user(config, &account.username)?;
    let base_source = if account.display_name.trim().is_empty() {
        account.imap_username.as_str()
    } else {
        account.display_name.as_str()
    };
    let base = slugify_component(base_source, "mailbox");
    let conflicting_count = accounts
        .iter()
        .filter(|candidate| {
            let candidate_source = if candidate.display_name.trim().is_empty() {
                candidate.imap_username.as_str()
            } else {
                candidate.display_name.as_str()
            };
            slugify_component(candidate_source, "mailbox") == base
        })
        .count();
    if conflicting_count > 1 {
        Ok(format!("{base}--{}", account.id))
    } else {
        Ok(base)
    }
}

pub(super) fn preferred_mailbox_slug(raw_mailbox_path: &str) -> String {
    match raw_mailbox_path.trim().to_ascii_lowercase().as_str() {
        "" | "inbox" => "inbox".to_string(),
        "[gmail]/all mail" => "archive".to_string(),
        "[gmail]/sent mail" => "sent".to_string(),
        "[gmail]/drafts" => "drafts".to_string(),
        "[gmail]/important" => "important".to_string(),
        "[gmail]/starred" => "starred".to_string(),
        "[gmail]/spam" => "spam".to_string(),
        "[gmail]/trash" => "trash".to_string(),
        other => {
            let label = other.rsplit('/').next().unwrap_or(other);
            slugify_component(label, "mailbox")
        }
    }
}

pub(super) fn raw_mailbox_path_from_hidden_relpath(hidden_relpath: &str) -> String {
    let components = hidden_relpath
        .split('/')
        .filter(|component| !component.is_empty())
        .collect::<Vec<_>>();
    let marker = components
        .iter()
        .position(|component| matches!(*component, "cur" | "new" | "tmp"));
    match marker {
        Some(0) | None => "Inbox".to_string(),
        Some(index) => components[..index].join("/"),
    }
}

pub(super) fn short_message_key(message_key: &str) -> String {
    sha256_hex(message_key.as_bytes())
        .chars()
        .take(8)
        .collect::<String>()
}

pub(super) fn visible_message_subject(subject: &str) -> String {
    let sanitized = subject
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
        .join(" ");
    let visible = if sanitized.chars().count() > VISIBLE_MESSAGE_SUBJECT_MAX_CHARS {
        sanitized
            .chars()
            .take(VISIBLE_MESSAGE_SUBJECT_MAX_CHARS)
            .collect::<String>()
            .trim()
            .to_string()
    } else {
        sanitized
    };
    if visible.is_empty() {
        "No Subject".to_string()
    } else {
        visible
    }
}

pub(super) fn visible_message_filename(timestamp: i64, subject: &str, message_key: &str) -> String {
    let date_label = DateTime::<Utc>::from_timestamp(timestamp, 0)
        .map(|value| value.format("%Y-%m-%d %H-%M").to_string())
        .unwrap_or_else(|| "1970-01-01 00-00".to_string());
    format!(
        "{} - {} [{}].eml",
        date_label,
        visible_message_subject(subject),
        short_message_key(message_key)
    )
}

pub(super) fn timestamp_year_month(timestamp: i64) -> (String, String) {
    DateTime::<Utc>::from_timestamp(timestamp, 0)
        .map(|value| {
            (
                value.format("%Y").to_string(),
                value.format("%m").to_string(),
            )
        })
        .unwrap_or_else(|| ("1970".to_string(), "01".to_string()))
}

pub(super) fn same_file_identity(left: &FsPath, right: &FsPath) -> Result<bool, String> {
    let left_meta = fs::metadata(left)
        .map_err(|error| format!("failed to inspect {}: {error}", left.display()))?;
    let right_meta = fs::metadata(right)
        .map_err(|error| format!("failed to inspect {}: {error}", right.display()))?;
    Ok(left_meta.dev() == right_meta.dev() && left_meta.ino() == right_meta.ino())
}

pub(super) fn ensure_hard_link(source: &FsPath, destination: &FsPath) -> Result<(), String> {
    if destination.exists() {
        if same_file_identity(source, destination)? {
            return Ok(());
        }
        fs::remove_file(destination)
            .map_err(|error| format!("failed to replace {}: {error}", destination.display()))?;
    }
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent)
            .map_err(|error| format!("failed to create {}: {error}", parent.display()))?;
    }
    fs::hard_link(source, destination).map_err(|error| {
        format!(
            "failed to link {} to {}: {error}",
            source.display(),
            destination.display()
        )
    })
}

pub(super) fn reconcile_visible_mirror_read_acl(
    config: &AppConfig,
    account_paths: &AccountPaths,
    destination: &FsPath,
) -> Result<(), String> {
    let Some(group) = config.visible_mirror_read_group.as_deref() else {
        return Ok(());
    };

    let mut directory = destination.parent();
    while let Some(path) = directory {
        if !path.starts_with(&account_paths.visible_emails_root) {
            break;
        }
        setfacl(path, &format!("g:{group}:r-x"))?;
        if path == account_paths.visible_emails_root {
            break;
        }
        directory = path.parent();
    }

    setfacl(destination, &format!("g:{group}:r--"))
}

pub(super) fn setfacl(path: &FsPath, acl: &str) -> Result<(), String> {
    let output = Command::new("setfacl")
        .args(["-m", acl])
        .arg(path)
        .output()
        .map_err(|error| format!("failed to run setfacl for {}: {error}", path.display()))?;
    if output.status.success() {
        return Ok(());
    }

    Err(command_failure_detail("setfacl", &output))
}

pub(super) fn prune_empty_ancestors(path: &FsPath, stop_at: &FsPath) -> Result<(), String> {
    let mut current = path.to_path_buf();
    while current.starts_with(stop_at) && current != stop_at {
        match fs::remove_dir(&current) {
            Ok(()) => {
                if let Some(parent) = current.parent() {
                    current = parent.to_path_buf();
                } else {
                    break;
                }
            }
            Err(error) if error.kind() == ErrorKind::DirectoryNotEmpty => break,
            Err(error) if error.kind() == ErrorKind::NotFound => break,
            Err(error) => {
                return Err(format!(
                    "failed to prune empty directory {}: {error}",
                    current.display()
                ))
            }
        }
    }
    Ok(())
}

pub(super) fn rebuild_message_catalog_and_visible_mailboxes(
    config: &AppConfig,
    account: &AccountRecord,
) -> Result<AccountProgressCounts, String> {
    #[derive(Clone)]
    struct PendingInstance {
        message_key: String,
        hidden_relpath: String,
        raw_mailbox_path: String,
        subject: String,
        timestamp: i64,
        last_seen_at: String,
    }

    let account_paths = ensure_account_paths(config, account)?;
    if account_index_state(&account_paths) != IndexState::Indexed {
        let empty = AccountProgressCounts::default();
        store_account_progress_snapshot(
            config,
            account.id,
            &empty,
            account.last_sync_finished_at.as_deref(),
            "stale",
            Some("Use Sync Now or Repair search to rebuild dashboard counts."),
        )?;
        return Ok(empty);
    }

    let mut connection = open_db(config)?;
    let previous_instances = load_message_mailbox_instances_for_account(&connection, account.id)?;
    let account_slug = visible_account_slug(config, account)?;
    let mut pending_instances = Vec::new();
    let mut catalog_by_key = HashMap::<String, MessageCatalogRecord>::new();

    for file_path in list_notmuch_message_files(&account_paths, "*")? {
        let metadata = read_message_metadata(&file_path)?;
        let message_key = message_key_from_metadata(&metadata)?;

        let hidden_relpath = message_relative_path(&account_paths, &file_path)?
            .to_string_lossy()
            .to_string();
        let raw_mailbox_path = raw_mailbox_path_from_hidden_relpath(&hidden_relpath);
        let last_seen_at = Utc::now().to_rfc3339();
        let message_sha256 = sha256_file(&file_path)?;
        pending_instances.push(PendingInstance {
            message_key: message_key.clone(),
            hidden_relpath: hidden_relpath.clone(),
            raw_mailbox_path,
            subject: metadata.subject.clone(),
            timestamp: metadata.timestamp,
            last_seen_at: last_seen_at.clone(),
        });
        catalog_by_key
            .entry(message_key.clone())
            .and_modify(|record| {
                if hidden_relpath < record.canonical_hidden_relpath {
                    record.canonical_hidden_relpath = hidden_relpath.clone();
                }
            })
            .or_insert_with(|| MessageCatalogRecord {
                account_id: account.id,
                message_key,
                canonical_hidden_relpath: hidden_relpath,
                subject: metadata.subject,
                sender: metadata.from,
                timestamp: metadata.timestamp,
                message_sha256,
                last_seen_at,
            });
    }

    let mut mailbox_slug_map = HashMap::<String, String>::new();
    let mut grouped_mailboxes = HashMap::<String, Vec<String>>::new();
    for raw_mailbox_path in pending_instances
        .iter()
        .map(|instance| instance.raw_mailbox_path.clone())
        .collect::<HashSet<_>>()
    {
        grouped_mailboxes
            .entry(preferred_mailbox_slug(&raw_mailbox_path))
            .or_default()
            .push(raw_mailbox_path);
    }
    for (preferred_slug, mut mailboxes) in grouped_mailboxes {
        mailboxes.sort();
        for (index, raw_mailbox_path) in mailboxes.into_iter().enumerate() {
            let mailbox_slug = if index == 0 {
                preferred_slug.clone()
            } else {
                format!(
                    "{}--{}",
                    preferred_slug,
                    slugify_component(&raw_mailbox_path, "mailbox")
                )
            };
            mailbox_slug_map.insert(raw_mailbox_path, mailbox_slug);
        }
    }

    let mut used_visible_relpaths = HashSet::new();
    let mut desired_instances = Vec::new();
    for instance in pending_instances {
        let mailbox_slug = mailbox_slug_map
            .get(&instance.raw_mailbox_path)
            .cloned()
            .unwrap_or_else(|| preferred_mailbox_slug(&instance.raw_mailbox_path));
        let mailbox_dir = format!("{account_slug}-{mailbox_slug}");
        let (year, month) = timestamp_year_month(instance.timestamp);
        let mut filename =
            visible_message_filename(instance.timestamp, &instance.subject, &instance.message_key);
        let mut visible_relpath = PathBuf::from(&mailbox_dir)
            .join(&year)
            .join(&month)
            .join(&filename)
            .to_string_lossy()
            .to_string();
        if !used_visible_relpaths.insert(visible_relpath.clone()) {
            filename = format!(
                "{}--{}.eml",
                filename.trim_end_matches(".eml"),
                short_message_key(&instance.hidden_relpath)
            );
            visible_relpath = PathBuf::from(&mailbox_dir)
                .join(&year)
                .join(&month)
                .join(&filename)
                .to_string_lossy()
                .to_string();
            used_visible_relpaths.insert(visible_relpath.clone());
        }
        desired_instances.push(MessageMailboxInstanceRecord {
            account_id: account.id,
            message_key: instance.message_key,
            raw_mailbox_path: instance.raw_mailbox_path,
            visible_relpath,
            hidden_relpath: instance.hidden_relpath,
            account_slug: account_slug.clone(),
            mailbox_slug,
            filename,
            last_seen_at: instance.last_seen_at,
        });
    }

    let desired_visible_relpaths = desired_instances
        .iter()
        .map(|instance| instance.visible_relpath.clone())
        .collect::<HashSet<_>>();
    for instance in &desired_instances {
        let source = account_paths.maildir.join(&instance.hidden_relpath);
        let destination = account_paths
            .visible_emails_root
            .join(&instance.visible_relpath);
        ensure_hard_link(&source, &destination)?;
        reconcile_visible_mirror_read_acl(config, &account_paths, &destination)?;
    }
    for previous in previous_instances {
        if desired_visible_relpaths.contains(&previous.visible_relpath) {
            continue;
        }
        let destination = account_paths
            .visible_emails_root
            .join(&previous.visible_relpath);
        if destination.exists() {
            fs::remove_file(&destination)
                .map_err(|error| format!("failed to remove {}: {error}", destination.display()))?;
            if let Some(parent) = destination.parent() {
                prune_empty_ancestors(parent, &account_paths.visible_emails_root)?;
            }
        }
    }

    let transaction = connection
        .transaction()
        .map_err(|error| format!("failed to start mailbox rebuild transaction: {error}"))?;
    transaction
        .execute(
            "DELETE FROM message_mailbox_instances WHERE account_id = ?1",
            params![account.id],
        )
        .map_err(|error| format!("failed to clear mailbox instances: {error}"))?;
    transaction
        .execute(
            "DELETE FROM message_catalog WHERE account_id = ?1",
            params![account.id],
        )
        .map_err(|error| format!("failed to clear message catalog: {error}"))?;
    for record in catalog_by_key.values() {
        transaction
            .execute(
                r#"
                INSERT INTO message_catalog (
                    account_id,
                    message_key,
                    canonical_hidden_relpath,
                    subject,
                    sender,
                    timestamp,
                    message_sha256,
                    last_seen_at
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                "#,
                params![
                    record.account_id,
                    record.message_key,
                    record.canonical_hidden_relpath,
                    record.subject,
                    record.sender,
                    record.timestamp,
                    record.message_sha256,
                    record.last_seen_at,
                ],
            )
            .map_err(|error| format!("failed to insert message catalog row: {error}"))?;
    }
    for record in &desired_instances {
        transaction
            .execute(
                r#"
                INSERT INTO message_mailbox_instances (
                    account_id,
                    message_key,
                    raw_mailbox_path,
                    visible_relpath,
                    hidden_relpath,
                    account_slug,
                    mailbox_slug,
                    filename,
                    last_seen_at
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
                "#,
                params![
                    record.account_id,
                    record.message_key,
                    record.raw_mailbox_path,
                    record.visible_relpath,
                    record.hidden_relpath,
                    record.account_slug,
                    record.mailbox_slug,
                    record.filename,
                    record.last_seen_at,
                ],
            )
            .map_err(|error| format!("failed to insert mailbox instance row: {error}"))?;
    }
    transaction
        .commit()
        .map_err(|error| format!("failed to commit mailbox rebuild transaction: {error}"))?;

    let inventory = MaildirInventory {
        archive_file_count: desired_instances.len(),
        logical_message_count: catalog_by_key.len(),
        overlap_file_count: desired_instances.len().saturating_sub(catalog_by_key.len()),
    };
    let indexed_message_count = count_indexed_messages(&account_paths)?;
    let counts = progress_counts(&inventory, indexed_message_count);
    let snapshot_status = if counts.archived_message_count == 0 {
        "empty"
    } else {
        "ready"
    };
    store_account_progress_snapshot(
        config,
        account.id,
        &counts,
        account.last_sync_finished_at.as_deref(),
        snapshot_status,
        None,
    )?;
    Ok(counts)
}
