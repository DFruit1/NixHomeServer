use super::super::*;

pub(crate) fn extract_message_attachments(
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

pub(crate) fn extract_message_attachments_with_mailparse(
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

pub(crate) fn inline_image_fallback_name(index: usize, mime_type: &str) -> String {
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

pub(crate) fn collect_regular_files(root: &FsPath) -> Result<Vec<PathBuf>, String> {
    let mut files = Vec::new();
    collect_regular_files_inner(root, &mut files)?;
    files.sort();
    Ok(files)
}

pub(crate) fn collect_regular_files_inner(
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

pub(crate) fn read_message_metadata(message_path: &FsPath) -> Result<MessageMetadata, String> {
    let bytes = fs::read(message_path)
        .map_err(|error| format!("failed to read {}: {error}", message_path.display()))?;
    let parsed = mailparse::parse_mail(&bytes).ok();
    let header = |name| {
        parsed
            .as_ref()
            .and_then(|message| decoded_header_value(message, name))
    };
    let normalized_message_id = header("message-id").and_then(normalize_message_id);
    let subject = header("subject").unwrap_or_else(|| "(no subject)".into());
    let from = header("from").unwrap_or_else(|| "Unknown sender".into());
    let timestamp = header("date")
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

fn decoded_header_value(message: &mailparse::ParsedMail<'_>, target_name: &str) -> Option<String> {
    message
        .headers
        .get_first_value(target_name)
        .map(|value| decode_display_header_value(value.trim()))
        .filter(|value| !value.is_empty())
}

pub(crate) fn decode_display_header_value(raw: &str) -> String {
    if !raw.contains("=?") {
        return raw.to_string();
    }
    decode_rfc2047_words(raw).unwrap_or_else(|| raw.to_string())
}

pub(crate) fn decode_rfc2047_words(raw: &str) -> Option<String> {
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

pub(crate) fn decode_rfc2047_word(charset: &str, encoding: &str, encoded: &str) -> Option<String> {
    let bytes = match encoding.to_ascii_uppercase().as_str() {
        "Q" => decode_rfc2047_q(encoded)?,
        "B" => BASE64.decode(encoded.as_bytes()).ok()?,
        _ => return None,
    };
    Some(decode_header_bytes(charset, &bytes))
}

pub(crate) fn decode_rfc2047_q(encoded: &str) -> Option<Vec<u8>> {
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

pub(crate) fn decode_header_bytes(charset: &str, bytes: &[u8]) -> String {
    match charset.to_ascii_lowercase().as_str() {
        "utf-8" | "utf8" | "us-ascii" => String::from_utf8_lossy(bytes).to_string(),
        "windows-1252" | "cp1252" => decode_windows_1252(bytes),
        "iso-8859-1" | "latin1" | "latin-1" => bytes.iter().map(|byte| *byte as char).collect(),
        _ => String::from_utf8_lossy(bytes).to_string(),
    }
}

pub(crate) fn decode_windows_1252(bytes: &[u8]) -> String {
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

pub(crate) fn read_message_context_preview(
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
    let cc = decoded_header_value(&parsed, "cc");
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

pub(crate) fn compact_text_preview(raw: &str, limit: usize) -> Option<(String, bool)> {
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

pub(crate) fn strip_html_tags(raw: &str) -> String {
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

pub(crate) fn sender_identity_from_header(raw_sender: &str) -> Option<SenderIdentity> {
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

pub(crate) fn sender_display_from_header(raw_sender: &str) -> SenderDisplay {
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

pub(crate) fn sender_display_from_parts(raw_name: Option<&str>, email: String) -> SenderDisplay {
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

pub(crate) fn clean_sender_display_part(value: &str) -> String {
    value
        .trim()
        .trim_matches(|character| matches!(character, '<' | '>' | '"' | '\''))
        .trim()
        .to_string()
}

pub(crate) fn fallback_sender_identity(raw_sender: &str) -> Option<SenderIdentity> {
    let candidate = raw_sender
        .split(|character: char| {
            character.is_whitespace() || matches!(character, '<' | '>' | ',' | ';' | '"' | '\'')
        })
        .find(|part| part.contains('@'))?;
    normalize_sender_address(candidate)
}

pub(crate) fn normalize_sender_address(raw_address: &str) -> Option<SenderIdentity> {
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

pub(crate) fn normalize_sender_domain(raw_domain: &str) -> Option<String> {
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

pub(crate) fn normalize_sender_rule_value(
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

pub(crate) fn parse_message_timestamp(raw: &str) -> Option<i64> {
    DateTime::parse_from_rfc2822(raw)
        .ok()
        .map(|value| value.with_timezone(&Utc).timestamp())
        .or_else(|| {
            DateTime::parse_from_rfc3339(raw)
                .ok()
                .map(|value| value.with_timezone(&Utc).timestamp())
        })
}

pub(crate) fn normalize_message_id(raw: String) -> Option<String> {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn metadata_preserves_first_headers_and_decodes_multipart_preview_cc() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("message.eml");
        fs::write(
            &path,
            concat!(
                "Message-ID: <FIRST@Example.com>\r\n",
                "Message-ID: <second@example.com>\r\n",
                "Subject: =?UTF-8?Q?Invoice_=E2=9C=85?=\r\n",
                "Subject: ignored\r\n",
                "From: billing@example.com\r\n",
                "Cc: =?UTF-8?Q?Accounts_Team?= <accounts@example.com>\r\n",
                "Date: Thu, 18 Apr 2024 14:32:00 +0000\r\n",
                "Content-Type: multipart/mixed; boundary=example\r\n\r\n",
                "--example\r\nContent-Type: text/plain\r\n\r\nInvoice body\r\n",
                "--example\r\nContent-Type: application/octet-stream\r\n",
                "Content-Disposition: attachment; filename=data.bin\r\n\r\nAttachment\r\n",
                "--example--\r\n",
            ),
        )
        .unwrap();
        let metadata = read_message_metadata(&path).unwrap();
        assert_eq!(
            metadata.normalized_message_id.as_deref(),
            Some("first@example.com")
        );
        assert_eq!(metadata.subject, "Invoice ✅");
        assert_eq!(metadata.from, "billing@example.com");
        assert_eq!(metadata.timestamp, 1_713_450_720);
        assert!(metadata.message_sha256.is_none());
        let preview = read_message_context_preview(&path, 100).unwrap();
        assert_eq!(
            preview.cc.as_deref(),
            Some("Accounts Team <accounts@example.com>")
        );
        assert_eq!(preview.body.as_deref(), Some("Invoice body"));
        assert!(!preview.truncated);
    }

    #[test]
    fn metadata_keeps_fallbacks_for_empty_and_malformed_headers() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("message.eml");
        for bytes in [
            b"Subject: \r\nFrom: \r\nMessage-ID: <>\r\nDate: invalid\r\n\r\nBody".as_slice(),
            b"malformed header\r\n\r\nBody",
        ] {
            fs::write(&path, bytes).unwrap();
            let metadata = read_message_metadata(&path).unwrap();
            assert_eq!(metadata.subject, "(no subject)");
            assert_eq!(metadata.from, "Unknown sender");
            assert!(metadata.normalized_message_id.is_none());
            assert_eq!(metadata.message_sha256, Some(sha256_hex(bytes)));
            assert_eq!(metadata.timestamp, fs::metadata(&path).unwrap().mtime());
        }
    }
}
