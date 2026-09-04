use super::super::*;

pub(crate) fn build_attachments_zip(
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

pub(crate) fn zip_entry_name(
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

pub(crate) fn unique_zip_entry_name(
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

pub(crate) fn zip_entry_name_with_numeric_suffix(base: &str, suffix: usize) -> String {
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

pub(crate) fn cleanup_old_runtime_exports(config: &AppConfig) -> Result<(), String> {
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
