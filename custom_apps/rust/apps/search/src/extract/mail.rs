use std::path::{Path, PathBuf};

use mailparse::MailHeaderMap;

use super::ExtractedDocument;
use crate::config::SourceConfig;
use crate::text::html_to_text;
use crate::timeutil::{parse_date, sha256_hex};

pub struct MailExtractor;

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

struct ParsedMail {
    subject: String,
    from: String,
    to: String,
    cc: String,
    date: Option<i64>,
    body: String,
}

fn first_text_part(mail: &mailparse::ParsedMail<'_>, html: bool) -> Option<String> {
    if mail.subparts.is_empty() {
        let content_type = mail
            .get_headers()
            .get_first_value("Content-Type")
            .unwrap_or_default();
        let matches_type = if html {
            content_type.contains("text/html")
        } else {
            content_type.contains("text/plain")
        };
        if !matches_type {
            return None;
        }
        return mail.get_body().ok().filter(|body| !body.trim().is_empty());
    }
    for part in &mail.subparts {
        if let Some(body) = first_text_part(part, html) {
            return Some(body);
        }
    }
    None
}

fn parse_eml(bytes: &[u8]) -> Result<ParsedMail, String> {
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
    let plain = first_text_part(&mail, false);
    let body = match plain {
        Some(text) => text,
        None => match first_text_part(&mail, true) {
            Some(html_body) => html_to_text(&html_body),
            None => String::new(),
        },
    };
    Ok(ParsedMail {
        subject,
        from,
        to,
        cc,
        date,
        body,
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
            let parsed = match parse_eml(&bytes) {
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
            emit(ExtractedDocument {
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
        let parsed = parse_eml(EML.as_bytes()).expect("parse");
        assert_eq!(parsed.subject, "Hello there");
        assert_eq!(parsed.from, "Alice <alice@example.org>");
        assert_eq!(parsed.date, Some(1_700_000_000));
        assert!(parsed.body.contains("See you soon."));
    }

    #[test]
    fn parses_html_email() {
        let parsed = parse_eml(HTML_EML.as_bytes()).expect("parse");
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
