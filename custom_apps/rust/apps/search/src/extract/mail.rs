use std::path::{Path, PathBuf};

use mailparse::MailHeaderMap;

use super::ExtractedDocument;
use crate::config::SourceConfig;
use crate::text::{decode_document_text, html_to_text, truncate_text};
use crate::timeutil::{parse_date, sha256_hex};

pub struct MailExtractor {
    pub pdftotext: Option<PathBuf>,
}

#[derive(Debug)]
struct MailRoot {
    path: PathBuf,
    /// Mailbox owner derived from the per-user archive layout, or `None` for a
    /// shared archive root.
    owner: Option<String>,
}

fn collect_roots(source: &SourceConfig) -> Result<Vec<MailRoot>, String> {
    let mut roots: Vec<MailRoot> = Vec::new();
    for root in source.setting_str_list("emailsRoots") {
        roots.push(MailRoot {
            path: PathBuf::from(root),
            owner: None,
        });
    }
    if let Some(users_root) = source.setting_str("usersRoot") {
        let users_root = PathBuf::from(users_root);
        if let Ok(entries) = std::fs::read_dir(&users_root) {
            for entry in entries.filter_map(|entry| entry.ok()) {
                let path = entry.path();
                if path.is_dir() {
                    let owner = path
                        .file_name()
                        .and_then(|name| name.to_str())
                        .map(str::to_string);
                    roots.push(MailRoot {
                        path: path.join("_Emails"),
                        owner,
                    });
                }
            }
        }
    }
    Ok(roots)
}

fn walk_eml(dir: &Path, depth: usize, out: &mut Vec<PathBuf>) {
    if depth > 8 {
        return;
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.filter_map(|entry| entry.ok()) {
        let path = entry.path();
        let name = path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or_default();
        if path.is_dir() {
            if name == ".internal-sync" {
                continue;
            }
            walk_eml(&path, depth + 1, out);
        } else if name.to_ascii_lowercase().ends_with(".eml") {
            out.push(path);
        }
    }
}

/// Fingerprints every `.eml` file across the source's roots (path, size, mtime)
/// plus its settings. The archive is append-only in normal operation, so an
/// unchanged inventory means the expensive per-message parse can be skipped.
/// Returns `None` when no root is readable or no message is present, leaving
/// the indexer to run extraction and its normal empty/wipe guards.
pub(crate) fn source_fingerprint(source: &SourceConfig) -> Option<String> {
    let roots = collect_roots(source).ok()?;
    let mut files = Vec::new();
    for root in roots {
        walk_eml(&root.path, 0, &mut files);
    }
    if files.is_empty() {
        return None;
    }
    super::file_inventory_fingerprint(source, files)
}

struct ParsedMail {
    subject: String,
    from: String,
    to: String,
    cc: String,
    date: Option<i64>,
    body: String,
    /// Sparse words recognised in attached pictures.
    incidental: String,
    /// Sent through a mailing list or subscription.
    mailing_list: bool,
    attachments: Vec<String>,
    attachment_texts: Vec<(String, String)>,
}

/// Pictures smaller than this are logos, signatures and tracking pixels.
const PICTURE_MINIMUM_BYTES: usize = 40_000;
const PICTURE_MAXIMUM_BYTES: usize = 16_000_000;
const PICTURES_PER_MESSAGE: usize = 8;
/// A picture with at least this many recognised words is a scanned document
/// and joins the message text; fewer are words that happen to be in a photo.
const SCAN_WORDS: usize = 40;

struct Parts<'a> {
    pdftotext: Option<&'a Path>,
    /// MIME parts still allowed, bounding a hostile or runaway message.
    remaining: usize,
    /// Drop quoted earlier messages from this message's own text.
    strip_quotes: bool,
    pictures: usize,
    incidental: String,
    attachment_texts: Vec<(String, String)>,
}

/// Message identifiers as they appear in `Message-ID`, `In-Reply-To` and
/// `References`: every `<...>` token.
fn message_ids(value: &str) -> impl Iterator<Item = &str> {
    value
        .split('<')
        .skip(1)
        .filter_map(|rest| rest.split('>').next())
        .map(str::trim)
        .filter(|id| !id.is_empty())
}

/// Removes what a message repeats rather than says: the earlier messages it
/// quotes (when `strip_quotes`), long tracking links and legal notices.
/// Quoted text is only dropped when the quoted message is itself in the
/// archive, so nothing becomes unfindable. Forwarded content is kept: there
/// the earlier message is the point.
fn clean_message_text(text: &str, strip_quotes: bool) -> String {
    const NOTICES: [&str; 6] = [
        "this email and any",
        "this e-mail and any",
        "this message and any",
        "this email (including",
        "confidentiality notice",
        "this communication is confidential",
    ];
    let mut out = String::with_capacity(text.len());
    let mut in_notice = false;
    let mut forwarded = false;
    for line in text.lines() {
        let trimmed = line.trim();
        let lower = trimmed.to_ascii_lowercase();
        if lower.contains("forwarded message") || lower.starts_with("begin forwarded message") {
            forwarded = true;
        }
        if strip_quotes && !forwarded {
            // An unprefixed copy of the earlier message follows this marker.
            if lower.trim_matches('-').trim() == "original message" {
                break;
            }
            if trimmed.starts_with('>') || (lower.starts_with("on ") && lower.ends_with("wrote:")) {
                continue;
            }
        }
        // html2text lists link targets as "[3]: https://..."; a long one is a
        // tracking address whose random tokens only add noise.
        if let Some((reference, target)) = trimmed.split_once("]: ")
            && reference.starts_with('[')
            && target.starts_with("http")
            && target.len() > 100
        {
            continue;
        }
        if trimmed.is_empty() {
            in_notice = false;
        } else if NOTICES.iter().any(|notice| lower.starts_with(notice)) {
            in_notice = true;
        }
        if in_notice {
            continue;
        }
        out.push_str(line);
        out.push('\n');
    }
    out
}

fn attachment_name(mail: &mailparse::ParsedMail<'_>) -> Option<String> {
    mail.get_content_disposition()
        .params
        .get("filename")
        .or_else(|| mail.ctype.params.get("name"))
        .filter(|name| !name.trim().is_empty())
        .map(|name| truncate_text(name, 4_096))
}

fn text_parts(mail: &mailparse::ParsedMail<'_>, depth: usize, parts: &mut Parts<'_>) -> String {
    if depth > 16 || parts.remaining == 0 {
        return String::new();
    }
    parts.remaining -= 1;
    let pdftotext = parts.pdftotext;
    let mime = mail.ctype.mimetype.to_ascii_lowercase();
    if !mail.subparts.is_empty() {
        let mut body = String::new();
        // Alternatives describe the same content. Prefer the last readable
        // representation (usually HTML) instead of indexing duplicate prose.
        if mime == "multipart/alternative" {
            for part in mail.subparts.iter().rev() {
                let text = text_parts(part, depth + 1, parts);
                if !text.trim().is_empty() {
                    return text;
                }
            }
        } else {
            for part in &mail.subparts {
                let text = text_parts(part, depth + 1, parts);
                if let Some(name) = attachment_name(part) {
                    if !text.trim().is_empty() && parts.attachment_texts.len() < 64 {
                        parts.attachment_texts.push((name, text));
                    }
                    continue;
                }
                if !text.trim().is_empty() {
                    body.push_str(&truncate_text(
                        &text,
                        super::document::TEXT_LIMIT - body.len(),
                    ));
                    if body.len() >= super::document::TEXT_LIMIT {
                        break;
                    }
                    body.push('\n');
                }
            }
        }
        return body;
    }

    if matches!(
        mime.as_str(),
        "text/plain" | "text/html" | "text/markdown" | "text/csv" | "text/tab-separated-values"
    ) {
        let raw = if let Ok(bytes) = mail.get_body_raw()
            && (bytes.starts_with(&[0xff, 0xfe]) || bytes.starts_with(&[0xfe, 0xff]))
        {
            decode_document_text(&bytes)
        } else {
            mail.get_body().unwrap_or_default()
        };
        let bounded = truncate_text(&raw, super::document::TEXT_LIMIT);
        let text = if mime == "text/html" {
            truncate_text(&html_to_text(&bounded), super::document::TEXT_LIMIT)
        } else {
            bounded
        };
        return clean_message_text(&text, parts.strip_quotes);
    }
    if mime.starts_with("image/") || mime == "application/octet-stream" {
        let name = attachment_name(mail).unwrap_or_default();
        let extension = name
            .rsplit('.')
            .next()
            .unwrap_or_default()
            .to_ascii_lowercase();
        let picture = matches!(
            mime.as_str(),
            "image/png" | "image/jpeg" | "image/tiff" | "image/bmp" | "image/webp"
        ) || (mime == "application/octet-stream"
            && matches!(
                extension.as_str(),
                "png" | "jpg" | "jpeg" | "tif" | "tiff" | "bmp" | "webp"
            ));
        if picture {
            if parts.pictures >= PICTURES_PER_MESSAGE
                || !(PICTURE_MINIMUM_BYTES..=PICTURE_MAXIMUM_BYTES).contains(&mail.raw_bytes.len())
            {
                return String::new();
            }
            let Ok(bytes) = mail.get_body_raw() else {
                return String::new();
            };
            if bytes.len() < PICTURE_MINIMUM_BYTES {
                return String::new();
            }
            parts.pictures += 1;
            let Some(text) = super::ocr::image_text(&bytes) else {
                return String::new();
            };
            if super::ocr::readable(&text, SCAN_WORDS) {
                return format!("{name}\n{}", truncate_text(&text, 200_000));
            }
            if super::ocr::readable(&text, 6) && parts.incidental.len() < 100_000 {
                parts.incidental.push_str(&truncate_text(&text, 20_000));
                parts.incidental.push('\n');
            }
            return String::new();
        }
    }
    // Only decode recognised document types; images, executables and large
    // binary attachments keep their filenames without consuming extraction work.
    let name = attachment_name(mail)
        .unwrap_or_default()
        .to_ascii_lowercase();
    let format = match mime.as_str() {
        "application/pdf" => "pdf",
        "application/epub+zip" => "epub",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document" => "docx",
        "application/vnd.oasis.opendocument.text" => "odt",
        "application/vnd.oasis.opendocument.spreadsheet" => "ods",
        "application/vnd.oasis.opendocument.presentation" => "odp",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" => "xlsx",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation" => "pptx",
        "application/vnd.openxmlformats-officedocument.presentationml.slideshow" => "ppsx",
        "application/vnd.ms-word.document.macroenabled.12" => "docm",
        "application/vnd.ms-excel.sheet.macroenabled.12" => "xlsm",
        "application/vnd.ms-powerpoint.presentation.macroenabled.12" => "pptm",
        "application/x-fictionbook+xml" => "fb2",
        "message/rfc822" => "eml",
        "application/octet-stream" => name.rsplit('.').next().unwrap_or_default(),
        _ => return String::new(),
    };
    if !matches!(
        format,
        "pdf"
            | "epub"
            | "docx"
            | "docm"
            | "odt"
            | "ods"
            | "odp"
            | "xlsx"
            | "xlsm"
            | "pptx"
            | "pptm"
            | "ppsx"
            | "fb2"
            | "htmlz"
            | "txtz"
            | "eml"
            | "txt"
            | "md"
            | "csv"
            | "html"
            | "htm"
    ) || mail.raw_bytes.len() > 8_000_000
    {
        return String::new();
    }
    let Ok(bytes) = mail.get_body_raw() else {
        return String::new();
    };
    let text = match format {
        "pdf" => super::paperless::extract_pdf_bytes(&bytes, pdftotext).ok(),
        "epub" | "docx" | "docm" | "odt" | "ods" | "odp" | "xlsx" | "xlsm" | "pptx" | "pptm"
        | "ppsx" | "htmlz" | "txtz" => {
            super::document::zip_text(std::io::Cursor::new(&bytes), format)
        }
        "fb2" => super::document::xml_text(&decode_document_text(&bytes)),
        // An attached message is forwarded content: keep what it quotes.
        "eml" => mailparse::parse_mail(&bytes).ok().map(|nested| {
            let strip_quotes = std::mem::replace(&mut parts.strip_quotes, false);
            let text = text_parts(&nested, depth + 1, parts);
            parts.strip_quotes = strip_quotes;
            text
        }),
        "html" | "htm" => Some(html_to_text(&decode_document_text(&bytes))),
        _ => Some(decode_document_text(&bytes)),
    };
    truncate_text(&text.unwrap_or_default(), super::document::TEXT_LIMIT)
}

fn parse_eml(
    bytes: &[u8],
    pdftotext: Option<&Path>,
    archived: &std::collections::HashSet<String>,
) -> Result<ParsedMail, String> {
    let mail =
        mailparse::parse_mail(bytes).map_err(|err| format!("failed to parse email: {err}"))?;
    let headers = mail.get_headers();
    let subject = headers
        .get_first_value("Subject")
        .unwrap_or_default()
        .trim()
        .to_string();
    let from = headers.get_first_value("From").unwrap_or_default();
    let to = headers.get_first_value("To").unwrap_or_default();
    let cc = headers.get_first_value("Cc").unwrap_or_default();
    let date = headers
        .get_first_value("Date")
        .as_deref()
        .and_then(parse_date);
    // A subscription can be left; mail addressed to one person cannot. This
    // marks newsletters, digests and promotions and leaves almost all
    // invoices and receipts alone (9% of them carried these headers here).
    let mailing_list = headers.get_first_value("List-Unsubscribe").is_some()
        || headers.get_first_value("List-Id").is_some();
    let replies_to = [
        headers.get_first_value("In-Reply-To"),
        headers.get_first_value("References"),
    ];
    let mut parts = Parts {
        pdftotext,
        remaining: 256,
        strip_quotes: replies_to
            .iter()
            .flatten()
            .flat_map(|value| message_ids(value))
            .any(|id| archived.contains(id)),
        pictures: 0,
        incidental: String::new(),
        attachment_texts: Vec::new(),
    };
    let body = text_parts(&mail, 0, &mut parts);
    let attachments = mail.parts().filter_map(attachment_name).take(64).collect();
    Ok(ParsedMail {
        subject,
        from,
        to,
        cc,
        date,
        body,
        incidental: parts.incidental,
        mailing_list,
        attachments,
        attachment_texts: parts.attachment_texts,
    })
}

fn header_option(value: &str) -> Option<&str> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed)
    }
}

impl super::Extractor for MailExtractor {
    fn extract(
        &self,
        source: &SourceConfig,
        emit: &mut dyn FnMut(ExtractedDocument),
    ) -> Result<(), String> {
        let roots = collect_roots(source)?;
        let app_base = source.app_base.trim_end_matches('/').to_string();
        // A path may be reachable through both a shared and a per-user root;
        // the first (owner-bearing) walk wins.
        let mut emails: Vec<(PathBuf, String)> = Vec::new();
        let mut seen: std::collections::HashSet<PathBuf> = std::collections::HashSet::new();
        for root in &roots {
            let mut found: Vec<PathBuf> = Vec::new();
            walk_eml(&root.path, 0, &mut found);
            let owner = root.owner.clone().unwrap_or_else(|| "shared".to_string());
            for path in found {
                if seen.insert(path.clone()) {
                    emails.push((path, owner.clone()));
                }
            }
        }
        emails.sort_by(|left, right| left.0.cmp(&right.0));

        // Which messages the archive holds, so a reply's quoted copy of one
        // can be dropped without losing the only copy of that text.
        let mut archived = std::collections::HashSet::new();
        for (path, _) in &emails {
            let mut head = Vec::new();
            if let Ok(file) = std::fs::File::open(path) {
                use std::io::Read;
                let _ = file.take(65_536).read_to_end(&mut head);
            }
            if let Ok((headers, _)) = mailparse::parse_headers(&head)
                && let Some(id) = headers.get_first_value("Message-ID")
            {
                archived.extend(message_ids(&id).map(str::to_string));
            }
        }

        for (path, owner) in emails {
            let bytes = match std::fs::read(&path) {
                Ok(bytes) => bytes,
                Err(err) => {
                    eprintln!(
                        "search: skipping unreadable email {}: {err}",
                        path.display()
                    );
                    continue;
                }
            };
            let parsed = match parse_eml(&bytes, self.pdftotext.as_deref(), &archived) {
                Ok(parsed) => parsed,
                Err(err) => {
                    eprintln!(
                        "search: skipping unparseable email {}: {err}",
                        path.display()
                    );
                    continue;
                }
            };
            let size_bytes = bytes.len() as i64;
            let mut metadata = serde_json::Map::new();
            metadata.insert(
                "owner".to_string(),
                serde_json::Value::String(owner.clone()),
            );
            if !parsed.attachments.is_empty() {
                metadata.insert(
                    "attachments".to_string(),
                    serde_json::json!(parsed.attachments),
                );
            }
            if parsed.mailing_list {
                metadata.insert(super::MAILING_LIST.to_string(), serde_json::json!(true));
            }
            if !parsed.incidental.is_empty() {
                metadata.insert(
                    super::INCIDENTAL_LABEL.to_string(),
                    serde_json::json!("Text in an attached picture"),
                );
            }
            for (key, value) in [
                ("from", &parsed.from),
                ("to", &parsed.to),
                ("cc", &parsed.cc),
            ] {
                if let Some(value) = header_option(value) {
                    metadata.insert(
                        key.to_string(),
                        serde_json::Value::String(value.to_string()),
                    );
                }
            }
            let id = sha256_hex(&[path.to_string_lossy().as_ref()]);
            if !parsed.attachment_texts.is_empty() {
                let mut identity = vec![
                    owner.as_str(),
                    parsed.subject.as_str(),
                    parsed.from.as_str(),
                    parsed.to.as_str(),
                    parsed.body.as_str(),
                ];
                let date = parsed.date.map(|date| date.to_string()).unwrap_or_default();
                identity.push(&date);
                for (name, text) in &parsed.attachment_texts {
                    identity.extend([name.as_str(), text.as_str()]);
                }
                metadata.insert(
                    super::SECTION_OF.to_string(),
                    serde_json::json!(sha256_hex(&identity)),
                );
            }
            if path.components().any(|part| {
                part.as_os_str()
                    .to_string_lossy()
                    .to_ascii_lowercase()
                    .split(['[', ']', '.'])
                    .any(|name| name == "important")
            }) {
                metadata.insert("important".to_string(), serde_json::json!(true));
            }
            for (index, (name, text)) in parsed.attachment_texts.iter().enumerate() {
                let mut attachment_metadata = metadata.clone();
                attachment_metadata.insert("attachment".to_string(), serde_json::json!(name));
                emit(ExtractedDocument {
                    incidental_text: String::new(),
                    external_id: format!("{id}#attachment{index}"),
                    kind: "email".to_string(),
                    title: truncate_text(&format!("{} — {name}", parsed.subject), 2_000),
                    body_text: text.clone(),
                    content_type: "message/rfc822".to_string(),
                    origin_url: String::new(),
                    app_url: app_base.clone(),
                    file_path: path.display().to_string(),
                    size_bytes: 0,
                    content_created_at: parsed.date,
                    content_modified_at: None,
                    metadata: serde_json::Value::Object(attachment_metadata),
                });
            }
            emit(ExtractedDocument {
                incidental_text: parsed.incidental,
                external_id: sha256_hex(&[path.to_string_lossy().as_ref()]),
                kind: "email".to_string(),
                title: if parsed.subject.is_empty() {
                    "(no subject)".to_string()
                } else {
                    parsed.subject.clone()
                },
                body_text: parsed.body,
                content_type: "message/rfc822".to_string(),
                origin_url: String::new(),
                app_url: app_base.clone(),
                file_path: path.display().to_string(),
                size_bytes,
                content_created_at: parsed.date,
                content_modified_at: None,
                metadata: serde_json::Value::Object(metadata),
            });
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const EML: &str = "From: Alice <alice@example.org>\r\n\
To: bob@example.org\r\n\
Cc: carol@example.org\r\n\
Subject: Hello there\r\n\
Date: Tue, 14 Nov 2023 22:13:20 +0000\r\n\
Content-Type: text/plain; charset=utf-8\r\n\
\r\n\
Hello Bob,\r\n\
See you soon.\r\n";

    const HTML_EML: &str = "From: a@example.org\r\n\
Subject: Report\r\n\
Date: Tue, 14 Nov 2023 22:13:20 +0000\r\n\
MIME-Version: 1.0\r\n\
Content-Type: multipart/alternative; boundary=\"XYZ\"\r\n\
\r\n\
--XYZ\r\n\
Content-Type: text/html; charset=utf-8\r\n\
\r\n\
<html><body><p>Quarterly <b>report</b> attached</p></body></html>\r\n\
--XYZ--\r\n";

    #[test]
    fn parses_plain_email() {
        let parsed = parse_eml(EML.as_bytes(), None, &Default::default()).expect("parse");
        assert_eq!(parsed.subject, "Hello there");
        assert_eq!(parsed.from, "Alice <alice@example.org>");
        assert_eq!(parsed.date, Some(1_700_000_000));
        assert!(parsed.body.contains("See you soon."));
    }

    #[test]
    fn parses_html_email() {
        let parsed = parse_eml(HTML_EML.as_bytes(), None, &Default::default()).expect("parse");
        assert_eq!(parsed.subject, "Report");
        assert!(
            parsed.body.contains("Quarterly report attached"),
            "got: {}",
            parsed.body
        );
    }

    /// The Search integration populates `emailsRoots` (shared archive) and
    /// `usersRoot` (per-user archives); `collect_roots` must honour both.
    #[test]
    fn collects_shared_and_per_user_roots() {
        let dir = tempfile::tempdir().expect("tempdir");
        let shared = dir.path().join("_Emails");
        std::fs::create_dir_all(&shared).expect("shared root");
        let users = dir.path().join("users");
        std::fs::create_dir_all(users.join("alice/_Emails")).expect("alice root");
        std::fs::create_dir_all(users.join("bob/_Emails")).expect("bob root");

        let source = SourceConfig {
            id: "mail-archive".to_string(),
            display_name: "Mail".to_string(),
            source_type: "mail-archive".to_string(),
            app_base: "https://emails.example.org".to_string(),
            settings: [
                (
                    "emailsRoots".to_string(),
                    serde_json::json!([shared.to_string_lossy()]),
                ),
                (
                    "usersRoot".to_string(),
                    serde_json::json!(users.to_string_lossy()),
                ),
            ]
            .into_iter()
            .collect(),
        };

        let mut roots = collect_roots(&source).expect("roots");
        roots.sort_by(|left, right| left.path.cmp(&right.path));
        assert!(
            roots
                .iter()
                .any(|root| root.path == shared && root.owner.is_none()),
            "shared root missing: {roots:?}"
        );
        assert!(
            roots
                .iter()
                .any(|root| root.path == users.join("alice/_Emails")
                    && root.owner.as_deref() == Some("alice")),
            "alice root missing: {roots:?}"
        );
        assert!(
            roots
                .iter()
                .any(|root| root.path == users.join("bob/_Emails")
                    && root.owner.as_deref() == Some("bob")),
            "bob root missing: {roots:?}"
        );
    }
}
