use super::*;

const CANARY_DISPLAY_NAME: &str = "Canary mailbox";

pub(super) fn seed_canary_mailbox(config: &AppConfig) -> Result<(), String> {
    let username = env::var("MAIL_ARCHIVE_UI_CANARY_USERNAME")
        .map(|value| value.trim().to_string())
        .unwrap_or_else(|_| "canary".to_string());
    validate_single_line_config_value("Canary username", &username, 128)?;
    if username.is_empty() {
        return Err("Canary username is empty".to_string());
    }

    let account_id = match find_canary_account(config, &username)? {
        Some(existing) => existing,
        None => create_canary_account(config, &username)?,
    };
    let account = load_account_for_user(config, &username, account_id)?;
    let account_paths = ensure_account_paths(config, &account)?;

    // The catalog rebuild only runs when the notmuch database directory
    // exists. `notmuch new` would create it during a real reindex, but
    // pre-creating it keeps the seed path deterministic and testable.
    fs::create_dir_all(&account_paths.notmuch_db_root)
        .map_err(|error| format!("failed to create canary index directory: {error}"))?;

    for message in canary_messages() {
        let path = account_paths.maildir.join(message.relative_path);
        fs::create_dir_all(
            path.parent()
                .ok_or_else(|| "canary mail path has no parent".to_string())?,
        )
        .map_err(|error| format!("failed to create canary mail directory: {error}"))?;
        write_private_file(&path, message.contents.as_bytes())
            .map_err(|error| format!("failed to write canary message: {error}"))?;
    }

    run_account_action(config, &account, AccountAction::Reindex).map_err(|diagnostic| {
        format!(
            "canary mailbox reindex failed: {} ({})",
            diagnostic.summary,
            if diagnostic.detail.is_empty() {
                "no detail available"
            } else {
                diagnostic.detail.as_str()
            }
        )
    })?;

    println!(
        "canary mailbox ready: username={} account_id={} messages={}",
        username,
        account_id,
        canary_messages().len()
    );
    Ok(())
}

fn find_canary_account(config: &AppConfig, username: &str) -> Result<Option<i64>, String> {
    let connection = open_db(config)?;
    connection
        .query_row(
            "SELECT id FROM accounts WHERE username = ?1 AND display_name = ?2 ORDER BY id LIMIT 1",
            params![username, CANARY_DISPLAY_NAME],
            |row| row.get(0),
        )
        .optional()
        .map_err(|error| format!("failed to query canary account: {error}"))
}

fn create_canary_account(config: &AppConfig, username: &str) -> Result<i64, String> {
    insert_account(
        config,
        username,
        ValidatedAccount {
            provider_kind: "generic_imap".to_string(),
            display_name: CANARY_DISPLAY_NAME.to_string(),
            imap_host: "127.0.0.1".to_string(),
            imap_port: 993,
            imap_username: "canary@canary.invalid".to_string(),
            folder_mode: "custom".to_string(),
            folder_patterns: vec!["INBOX".to_string()],
            secret: Some(sha256_hex(username.as_bytes())),
            sync_enabled: false,
        },
    )?;
    find_canary_account(config, username)?
        .ok_or_else(|| "canary account insert did not persist".to_string())
}

struct CanaryMessage {
    relative_path: &'static str,
    contents: String,
}

fn canary_messages() -> Vec<CanaryMessage> {
    vec![
        CanaryMessage {
            relative_path: "cur/1735689001.M1.canary:2,S",
            contents: plain_message(
                "Canary: plain text welcome",
                "Canary Mailer <canary@canary.invalid>",
                "Wed, 01 Jan 2025 01:10:01 +0000",
                "1735689001.canary.welcome@canary.invalid",
                "This is a synthetic plain-text message seeded by the mail archive canary.\n\
                 It has no attachments and exists to exercise the list, search, and detail views.\n",
            ),
        },
        CanaryMessage {
            relative_path: "cur/1735689002.M1.canary:2,S",
            contents: attachment_message(
                "Canary: quarterly report PDF",
                "Canary Mailer <canary@canary.invalid>",
                "Wed, 01 Jan 2025 01:10:02 +0000",
                "1735689002.canary.report@canary.invalid",
                "The attached synthetic PDF exercises attachment extraction and document search.\n",
                ("canary-report.pdf", "application/pdf", &minimal_pdf()),
            ),
        },
        CanaryMessage {
            relative_path: "cur/1735689003.M1.canary:2,S",
            contents: attachment_message(
                "Canary: meeting notes text attachment",
                "Canary Mailer <canary@canary.invalid>",
                "Wed, 01 Jan 2025 01:10:03 +0000",
                "1735689003.canary.notes@canary.invalid",
                "The attached text file exercises plain-text attachment indexing.\n",
                (
                    "canary-notes.txt",
                    "text/plain",
                    &BASE64.encode(
                        b"Canary meeting notes\n\
                          ====================\n\
                          Agenda item one: verify the mail archive list view.\n\
                          Agenda item two: verify attachment selection and ZIP download.\n\
                          Agenda item three: verify sender priority sorting.\n",
                    ),
                ),
            ),
        },
        CanaryMessage {
            relative_path: "cur/1735689004.M1.canary:2,S",
            contents: attachment_message(
                "Canary: photo attachment",
                "Canary Mailer <canary@canary.invalid>",
                "Wed, 01 Jan 2025 01:10:04 +0000",
                "1735689004.canary.photo@canary.invalid",
                "The attached one-pixel PNG exercises image attachment handling.\n",
                (
                    "canary-photo.png",
                    "image/png",
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
                ),
            ),
        },
    ]
}

fn plain_message(subject: &str, from: &str, date: &str, message_id: &str, body: &str) -> String {
    format!(
        "From: {from}\r\n\
         To: Canary Reader <reader@canary.invalid>\r\n\
         Subject: {subject}\r\n\
         Date: {date}\r\n\
         Message-ID: <{message_id}>\r\n\
         MIME-Version: 1.0\r\n\
         Content-Type: text/plain; charset=utf-8\r\n\
         \r\n\
         {body}"
    )
}

fn attachment_message(
    subject: &str,
    from: &str,
    date: &str,
    message_id: &str,
    body: &str,
    attachment: (&str, &str, &str),
) -> String {
    let (filename, content_type, payload_b64) = attachment;
    let encoded_body = BASE64.encode(body.as_bytes());
    format!(
        "From: {from}\r\n\
         To: Canary Reader <reader@canary.invalid>\r\n\
         Subject: {subject}\r\n\
         Date: {date}\r\n\
         Message-ID: <{message_id}>\r\n\
         MIME-Version: 1.0\r\n\
         Content-Type: multipart/mixed; boundary=\"canary-boundary-{message_id}\"\r\n\
         \r\n\
         --canary-boundary-{message_id}\r\n\
         Content-Type: text/plain; charset=utf-8\r\n\
         Content-Transfer-Encoding: base64\r\n\
         \r\n\
         {encoded_body}\r\n\
         --canary-boundary-{message_id}\r\n\
         Content-Type: {content_type}; name=\"{filename}\"\r\n\
         Content-Transfer-Encoding: base64\r\n\
         Content-Disposition: attachment; filename=\"{filename}\"\r\n\
         \r\n\
         {payload_b64}\r\n\
         --canary-boundary-{message_id}--\r\n"
    )
}

fn minimal_pdf() -> String {
    let body = "%PDF-1.4\n\
        1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n\
        2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n\
        3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj\n\
        4 0 obj<</Length 44>>stream\n\
        BT /F1 12 Tf 20 100 Td (Canary quarterly report) Tj ET\n\
        endstream\n\
        endobj\n\
        3 0 obj<</Contents 4 0 R>>endobj\n\
        trailer<</Root 1 0 R/Size 5>>\n\
        %%EOF\n";
    BASE64.encode(body.as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canary_messages_parse_and_carry_attachments() {
        let messages = canary_messages();
        assert_eq!(messages.len(), 4);
        for message in &messages {
            let parsed = mailparse::parse_mail(message.contents.as_bytes())
                .expect("canary message must parse as MIME");
            assert!(!parsed.headers.is_empty());
        }
        let attachment_messages = messages
            .iter()
            .filter(|message| message.contents.contains("Content-Disposition: attachment"))
            .count();
        assert_eq!(attachment_messages, 3);
    }
}
